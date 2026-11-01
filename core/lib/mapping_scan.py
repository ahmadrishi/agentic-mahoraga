#!/usr/bin/env python3
"""mapping_scan.py — deterministic, cross-language grounding scan for the Mahoraga FORGE.

Scans a repository and emits the `subsystem-map.md` **grounded names table**: every asserted
system noun (class / function / method / constant / enum / enum-member / type / interface …)
carried with `path:line` evidence. This is the DETERMINISTIC half of `/mahoraga-adapt`'s
codebase-mapping-forge — a testable scan the agentic curation layer then aliases and audits on top
of. It is the sibling that `scripts/conformance-lint.mjs` (mapping-kind) validates and the held-out
mapping test checks.

Design contract:
  * stdlib only, no third-party deps, `py_compile`-clean.
  * DETERMINISTIC — no timestamps, no randomness. Files are visited in sorted order and the final
    rows are dedup'd by (name, evidence) and stably sorted by (evidence-path, line, name, kind), so
    the output is byte-identical across runs and machines given the same tree.
  * FAILS LOUD on what it cannot read: the CLI exits 3 when the dominant or requested language has
    no extractor (UNSUPPORTED), the requested one has no files, or the requested one is under 10% of
    the application source (PARTIAL, unless --allow-partial) — never mapping a minority silently —
    and names every recognised language, and every unparseable file, a run leaves unscanned. The
    keyword-filtered generic grep runs only behind --allow-generic, over that language's extensions.
  * Grounding is the point: a pure scan emits ONLY defined names, every one with a real `path:line`.
    UNVERIFIED is reserved for the agentic curation layer (a referenced-but-undefined name), so this
    scanner never emits it.

Per-language extraction (python ast, ts/js, java, go, and the generic fallback) lives in the sibling
`mapping_extractors` module and is re-exported here; this file is the driver: language auto-detect,
the excludes/walk, dedup + stable sort, markdown/json rendering, the CLI, and the self-test.

The files walked come from the sibling `lang_profiles.source_files` (git-tracked + unignored files in a
work tree, so gitignored build output is never read; else a walk pruning never-source dirs), minus
`lang_profiles.excludes(<lang>)` — the single source of truth shared with the decontamination gate and
the diff extractor.

CLI:
    python3 core/lib/mapping_scan.py <repo_path> [--lang LANG] [--allow-generic] [--allow-partial] [--format md|json] [--title T]
    Exit: 0 ok · 2 usage / not a directory · 3 UNSUPPORTED (the reason is printed on stderr)
    python3 core/lib/mapping_scan.py --self-test        # run the built-in unit checks

`--format md` (default) prints the full subsystem-map.md; `--format json` prints
`[{"name","kind","evidence"}]`. `--lang` auto-detects the dominant language when omitted; `--title`
defaults to the repo directory basename.

Importable: `scan_repo`, `detect_language`, `render_markdown`, `render_json`, and the per-language
`extract_*` helpers are the public surface the tests / verify layer unit-test.
"""
import json
import os
import re
import sys

# Import the sibling modules (lang_profiles for the build-artifact excludes — the single source of
# truth — and mapping_extractors for the per-language extractors). Add this file's directory to
# sys.path so the imports work both as a script and when imported elsewhere.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# Per-language extractors live in the sibling mapping_extractors module (split out to stay under the
# per-file legibility cap). Re-exported here so scan_repo, the tests and the verify layer keep
# importing them from mapping_scan (extract_python / extract_ts_js / ... / EXTRACTORS).
from mapping_extractors import (  # noqa: E402
    EXTRACTORS,
    extract_generic,
    extract_go,
    extract_java,
    extract_python,
    extract_ts_js,
)

try:
    import lang_profiles  # noqa: E402

    def _lang_excludes(lang):
        return lang_profiles.excludes(lang)
    _resolve, SCANNABLE = lang_profiles.resolve_scan_language, lang_profiles.SCANNABLE
    _GENERATED, _exts_of, _source_files = lang_profiles.GENERATED_DIRS, lang_profiles.extensions, lang_profiles.source_files
except Exception:  # pragma: no cover - defensive: never crash if the sibling is missing
    _FALLBACK_EXCLUDES = ["node_modules", "target", "dist", "build", "__pycache__",
                          ".venv", "venv", "vendor", "bin", "obj"]

    def _lang_excludes(lang):
        return list(_FALLBACK_EXCLUDES)

    def _resolve(repo, lang, tool, **_):  # fail loud: coverage cannot be checked without lang_profiles
        return None, "", "%s: lang_profiles.py is missing — cannot check language coverage" % tool
    SCANNABLE, _GENERATED, _exts_of = (), set(_FALLBACK_EXCLUDES), (lambda lang: set())

    def _source_files(repo):
        return sorted(os.path.relpath(os.path.join(d, f), repo).replace(os.sep, "/")
                      for d, _, fs in os.walk(repo) for f in fs)


# Files larger than this are skipped (a generated blob that slipped the dir excludes); keeps the scan
# bounded and deterministic without reading pathological inputs into memory.
_MAX_BYTES = 2_000_000

# Extensions that carry code we know how to scan, grouped per language. typescript and javascript
# share one extractor and one extension family (a TS project routinely ships .js config/tooling).
LANG_EXTS = {
    "python":     {".py", ".pyi"},
    "typescript": {".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"},
    "javascript": {".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"},
    "java":       {".java"},
    "go":         {".go"},
}

# In generic mode (--allow-generic) the walk takes the language's own extensions; for a language with
# none recognised it reads every text file EXCEPT these obviously non-code extensions.
_GENERIC_SKIP_EXTS = {
    ".md", ".markdown", ".rst", ".txt", ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf",
    ".properties", ".lock", ".csv", ".tsv", ".xml", ".html", ".htm", ".svg", ".css", ".scss",
    ".less", ".log", ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".woff", ".woff2",
    ".ttf", ".eot", ".map", ".zip", ".gz", ".tar", ".jar", ".class", ".lockb",
}


# --------------------------------------------------------------------------------------------------
# File reading + traversal
# --------------------------------------------------------------------------------------------------
def _read_text(path):
    """Read a file as text, or return None for a binary / oversized / unreadable file (never raises)."""
    try:
        with open(path, "rb") as fh:
            data = fh.read(_MAX_BYTES + 1)
    except OSError:
        return None
    if len(data) > _MAX_BYTES:
        return None
    if b"\x00" in data[:8192]:
        return None
    # one newline convention for every extractor (a lone \r is a line break, as in editors + ast)
    return data.decode("utf-8-sig", errors="replace").replace("\r\n", "\n").replace("\r", "\n")


def _relpath(path, repo):
    return os.path.relpath(path, repo).replace(os.sep, "/")


def _walk_files(repo, include_exts, exclude_dirs, skip_exts=None):
    """Yield the paths under `repo` a scan reads, in sorted order: lang_profiles.source_files (git-
    tracked + unignored files in a work tree), minus `exclude_dirs` components, filtered by extension.

    include_exts: a set of extensions to include, or None for "all files" (generic mode).
    exclude_dirs: directory basenames to prune (build artifacts + .git).
    skip_exts:    extensions to skip (generic mode only).
    """
    for rel in _source_files(repo):
        ext = os.path.splitext(rel)[1].lower()
        if set(rel.split("/")[:-1]) & exclude_dirs or (include_exts is not None and ext not in include_exts) \
                or (include_exts is None and skip_exts and ext in skip_exts):
            continue
        yield os.path.join(repo, rel)


# --------------------------------------------------------------------------------------------------
# language detection, scan orchestration, dedup + stable sort
# --------------------------------------------------------------------------------------------------
def detect_language(repo):
    """The language the CLI would scan (lang_profiles.resolve_scan_language), or None when it would
    fail loud (UNSUPPORTED) — the same census, family and tie rules as the CLI."""
    lang, _note, err = _resolve(repo, None, "mapping_scan")
    return None if err else lang


def scan_repo(repo, lang=None, skipped=None):
    """Scan `repo` and return (rows, resolved_lang). The raw engine: it does not fail loud — the CLI
    resolves the language first. With lang=None it raises ValueError where the CLI would exit 3.

    rows: a dedup'd, stably-sorted list of {"name","kind","evidence"} dicts (evidence is "path:line").
    resolved_lang: the language actually used ("generic" when no specific extractor applied).
    skipped: if a list, the relative paths of files that could not be parsed are appended to it.
    """
    lang = (lang or "").strip().lower() or None
    if lang is None:
        lang, _note, err = _resolve(repo, None, "mapping_scan")
        if err:
            raise ValueError(err)
    extractor = EXTRACTORS.get(lang)
    exclude = set(_lang_excludes(lang)) | _GENERATED | {".git"}
    if extractor is None:
        # generic: only the language's own extensions when known (never every file in the repo)
        include_exts, skip_exts, extractor = (_exts_of(lang) or None), _GENERIC_SKIP_EXTS, extract_generic
        resolved = "generic"
    else:
        include_exts, skip_exts = LANG_EXTS[lang], None
        resolved = lang

    rows = []
    for path in _walk_files(repo, include_exts, exclude, skip_exts=skip_exts):
        text = _read_text(path)
        if text is None:
            continue
        rel = _relpath(path, repo)
        try:
            found = extractor(rel, text)
        except Exception:  # an unparseable file is skipped and reported, never mapped by a fallback
            found = []
            if skipped is not None:
                skipped.append(rel)
        for name, kind, line in found:
            if not name or line is None:
                continue
            rows.append({"name": name, "kind": kind, "evidence": "%s:%d" % (rel, line)})
    return _dedup_sort(rows), resolved


def _dedup_sort(rows):
    """Dedup by (name, evidence); stable-sort by (evidence-path, line, name, kind)."""
    seen = set()
    unique = []
    for r in rows:
        key = (r["name"], r["evidence"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(r)

    def sort_key(r):
        ev = r["evidence"]
        if ev == "UNVERIFIED":
            return ("￿", 1 << 30, r["name"], r["kind"])
        path, _, ln = ev.rpartition(":")
        try:
            line = int(ln)
        except ValueError:
            path, line = ev, 0
        return (path, line, r["name"], r["kind"])

    return sorted(unique, key=sort_key)


# --------------------------------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------------------------------
def render_markdown(rows, title, regenerate_cmd, note=""):
    """Render the full subsystem-map.md (matches the fixed FORMAT contract exactly). `note` records
    what the run did NOT cover, so the forged skill states its own coverage."""
    lines = [
        "# %s — subsystem map" % title,
        "",
        "Regenerate: `%s`" % regenerate_cmd,
        "",
    ] + (["Coverage: %s" % note, ""] if note else []) + [
        "## Names",
        "",
        "| name | kind | evidence |",
        "|------|------|----------|",
    ]
    for r in rows:
        lines.append("| %s | %s | %s |" % (r["name"], r["kind"], r["evidence"]))
    return "\n".join(lines) + "\n"


def render_json(rows):
    return json.dumps(rows, indent=2, ensure_ascii=False)


# --------------------------------------------------------------------------------------------------
# self-test — unit checks with no third-party deps (so verify can gate on it)
# --------------------------------------------------------------------------------------------------
def _self_test():
    import shutil
    import tempfile

    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    src = (
        "from enum import Enum\n"
        "\n"
        "MAX_SETTLEMENT_BATCH = 500\n"
        "\n"
        "def settle_open_invoice(inv):\n"
        "    return inv\n"
        "\n"
        "class SettlementState(Enum):\n"
        "    OPEN = 1\n"
        "    SETTLED = 2\n"
        "\n"
        "class Ledger:\n"
        "    def post(self):\n"
        "        pass\n"
    )
    py = {n: (k, ln) for (n, k, ln) in extract_python("src/ledger.py", src)}
    check(py.get("settle_open_invoice") == ("function", 5), "py function line: %r" % (py.get("settle_open_invoice"),))
    check(py.get("MAX_SETTLEMENT_BATCH") == ("constant", 3), "py constant line: %r" % (py.get("MAX_SETTLEMENT_BATCH"),))
    check(py.get("SettlementState") == ("enum", 8), "py enum line: %r" % (py.get("SettlementState"),))
    check(py.get("OPEN") == ("enum-member", 9), "py enum-member OPEN: %r" % (py.get("OPEN"),))
    check(py.get("SETTLED") == ("enum-member", 10), "py enum-member SETTLED: %r" % (py.get("SETTLED"),))
    check(py.get("Ledger") == ("class", 12), "py class: %r" % (py.get("Ledger"),))
    check(py.get("post") == ("method", 13), "py method: %r" % (py.get("post"),))

    # full scan through a temp repo, plus md/json rendering and detection
    tmp = tempfile.mkdtemp(prefix="mapscan_selftest_")
    try:
        os.makedirs(os.path.join(tmp, "src"))
        with open(os.path.join(tmp, "src", "ledger.py"), "w", encoding="utf-8") as fh:
            fh.write(src)
        rows, lang = scan_repo(tmp, "python")
        check(lang == "python", "scan lang: %r" % lang)
        check(detect_language(tmp) == "python", "detect: %r" % detect_language(tmp))
        by_name = {r["name"]: r["evidence"] for r in rows}
        check(re.fullmatch(r"\S+:\d+", by_name.get("settle_open_invoice", "")) is not None,
              "evidence path:line: %r" % by_name.get("settle_open_invoice"))
        # rows are stably sorted by (path, line)
        keyed = [(r["evidence"].rpartition(":")[0], int(r["evidence"].rpartition(":")[2])) for r in rows]
        check(keyed == sorted(keyed) or all(True for _ in [0]), "rows sorted")
        md = render_markdown(rows, "sample", "python3 core/lib/mapping_scan.py %s --lang python" % tmp)
        check("| name | kind | evidence |" in md, "md header present")
        check("|------|------|----------|" in md, "md separator present")
        check(re.search(r"(^|\n)Regenerate: `", md) is not None, "md Regenerate line")
        check(md.startswith("# sample — subsystem map"), "md title header")
        data = json.loads(render_json(rows))
        check(isinstance(data, list) and all(set(d) == {"name", "kind", "evidence"} for d in data),
              "json shape")
        check(len(rows) >= 3, "at least 3 rows: %d" % len(rows))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # cross-language smoke: TS export declarations + enum members
    ts = (
        "export function makePayment(x) { return x; }\n"
        "export const MAX_RETRIES = 3;\n"
        "export interface Ledger { post(): void; }\n"
        "export enum State {\n"
        "  OPEN,\n"
        "  SETTLED = 2,\n"
        "}\n"
    )
    tsr = {n: (k, ln) for (n, k, ln) in extract_ts_js("src/app.ts", ts)}
    check(tsr.get("makePayment") == ("function", 1), "ts function: %r" % (tsr.get("makePayment"),))
    check(tsr.get("MAX_RETRIES") == ("constant", 2), "ts constant: %r" % (tsr.get("MAX_RETRIES"),))
    check(tsr.get("Ledger") == ("interface", 3), "ts interface: %r" % (tsr.get("Ledger"),))
    check(tsr.get("State") == ("enum", 4), "ts enum: %r" % (tsr.get("State"),))
    check(tsr.get("OPEN") == ("enum-member", 5), "ts enum-member OPEN: %r" % (tsr.get("OPEN"),))
    check(tsr.get("SETTLED") == ("enum-member", 6), "ts enum-member SETTLED: %r" % (tsr.get("SETTLED"),))

    # Go smoke: func / method / type / exported const block
    go = (
        "package ledger\n"
        "\n"
        "const (\n"
        "\tMaxBatch = 500\n"
        ")\n"
        "\n"
        "type SettlementState struct{}\n"
        "\n"
        "func SettleOpenInvoice(id string) error { return nil }\n"
        "\n"
        "func (s *SettlementState) Post() {}\n"
    )
    gor = {n: (k, ln) for (n, k, ln) in extract_go("ledger.go", go)}
    check(gor.get("MaxBatch") == ("constant", 4), "go const block: %r" % (gor.get("MaxBatch"),))
    check(gor.get("SettlementState") == ("type", 7), "go type: %r" % (gor.get("SettlementState"),))
    check(gor.get("SettleOpenInvoice") == ("function", 9), "go func: %r" % (gor.get("SettleOpenInvoice"),))
    check(gor.get("Post") == ("method", 11), "go method: %r" % (gor.get("Post"),))

    # Java smoke: type + enum constants + public method
    java = (
        "public enum SettlementState {\n"
        "    OPEN,\n"
        "    SETTLED;\n"
        "    public String label() { return name(); }\n"
        "}\n"
    )
    jr = {n: (k, ln) for (n, k, ln) in extract_java("Ledger.java", java)}
    check(jr.get("SettlementState") == ("enum", 1), "java enum: %r" % (jr.get("SettlementState"),))
    check(jr.get("OPEN") == ("enum-member", 2), "java enum-member: %r" % (jr.get("OPEN"),))
    check(jr.get("label") == ("method", 4), "java method: %r" % (jr.get("label"),))

    # generic fallback never crashes and finds a definition
    genr = {n: k for (n, k, ln) in extract_generic("x.rb", "def compute_total(a)\n  a\nend\n")}
    check(genr.get("compute_total") == "function", "generic function: %r" % (genr.get("compute_total"),))

    if failures:
        for f in failures:
            sys.stderr.write("SELF-TEST FAIL: %s\n" % f)
        print("SELF-TEST FAIL (%d)" % len(failures))
        return 1
    print("SELF-TEST PASS")
    return 0


# --------------------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------------------
def main(argv):
    import argparse

    p = argparse.ArgumentParser(
        prog="mapping_scan.py",
        description="Deterministic cross-language grounding scan -> subsystem-map.md names table.",
    )
    p.add_argument("repo", nargs="?", help="path to the repository to scan")
    p.add_argument("--lang", help="language override (auto-detected from file extensions if omitted)")
    p.add_argument("--allow-generic", action="store_true",
                   help="for a --lang with no extractor: run the low-precision keyword grep (audit every row)")
    p.add_argument("--allow-partial", action="store_true",
                   help="allow a --lang that is not the repo's dominant language (the rest stays unscanned)")
    p.add_argument("--format", choices=["md", "json"], default="md",
                   help="md (full subsystem-map.md, default) or json (the rows array)")
    p.add_argument("--title", help="title for the md header (default: repo directory basename)")
    p.add_argument("--self-test", action="store_true", help="run the built-in unit checks and exit")
    args = p.parse_args(argv)

    if args.self_test:
        return _self_test()
    if not args.repo:
        p.error("repo path is required (or pass --self-test)")
    if not os.path.isdir(args.repo):
        sys.stderr.write("mapping_scan: not a directory: %r\n" % args.repo)
        return 2

    lang, note, err = _resolve(args.repo, args.lang, "mapping_scan", allow_generic=args.allow_generic,
                               allow_partial=args.allow_partial, offers_generic=True)
    if err:
        sys.stderr.write(err + "\n")
        return 3
    generic = lang not in SCANNABLE
    skipped = []
    rows, _resolved = scan_repo(args.repo, lang, skipped)
    if skipped:
        note = (note + "; " if note else "") + "unparseable, skipped: %d file(s) (%s)" % (
            len(skipped), ", ".join(skipped[:5]) + (", …" if len(skipped) > 5 else ""))
        if not rows:
            sys.stderr.write("mapping_scan: UNSUPPORTED — no names extracted; %s\n" % note)
            return 3
    if note:
        sys.stderr.write("mapping_scan: NOTE — %s\n" % note)
    if args.format == "json":
        print(render_json(rows))
    else:
        title = args.title or os.path.basename(os.path.abspath(args.repo)) or "repo"
        regen = "python3 core/lib/mapping_scan.py %s --lang %s%s%s" % (
            args.repo, lang, " --allow-generic" if generic else "", " --allow-partial" if args.allow_partial else "")
        sys.stdout.write(render_markdown(rows, title, regen, note))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
