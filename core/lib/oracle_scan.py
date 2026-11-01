#!/usr/bin/env python3
"""oracle_scan.py — deterministic behavioural-oracle scan for the Mahoraga FORGE.

The sibling of `mapping_scan.py`: where that scans DEFINITIONS into a subsystem-map.md names table,
this scans TEST FILES into the `oracle-library.md` **oracle table** — every test carried as an oracle
row `(oracle | expected | tier | evidence)` with `path:line` evidence, plus the counted grounding
denominator (`<real> real / <total> tests / <files> files (stubs: <stub>)`).

It is a FLOOR: it emits ONLY what it read — a witnessed assertion literal / expected exception at a
`file:line`, or a STUB for a trivially-true / existence-only / empty test. It NEVER infers "what a
test proves" (that stays agent-at-ticket-time). The denominator must not over-count grounding, so the
classifier (in the sibling `oracle_extractors`) errs toward STUB for the trivially-true / empty cases.

Tiers emitted here: **WITNESSED** (a real assertion read at a file:line) or **STUB**. RUN is stamped
later by `verify` when the oracle actually executed; UNVERIFIED is the agentic layer's (referenced but
no oracle found) — this scanner never emits them.

Design contract (mirrors mapping_scan.py): stdlib only, `py_compile`-clean, DETERMINISTIC
(byte-identical output — sorted walk, dedup + stable sort), never crashes on an unparseable file,
and FAILS LOUD on what it cannot read: the CLI exits 3 when the dominant or requested language has no
extractor or no files, or the requested one is under 10% of the application source (PARTIAL, unless
--allow-partial), instead of reporting "0 / 0 / 0" for a repo whose tests it never looked at. Tests in
a non-dominant language are not counted; the Coverage line names that language.
Per-language extraction lives in the sibling `oracle_extractors` module and is re-exported here; this
file is the driver: language auto-detect, the test include-set + walk, dedup + stable sort, the
denominator, markdown/json rendering, the CLI, and the self-test.

CLI:
    python3 core/lib/oracle_scan.py <repo> [--lang LANG] [--allow-partial] [--format md|json] [--title T]
    python3 core/lib/oracle_scan.py --self-test
    Exit: 0 ok · 2 usage / not a directory · 3 UNSUPPORTED (the reason is printed on stderr)

`--format md` (default) prints the full oracle-library.md; `--format json` prints
`{"oracles": [{"oracle","expected","tier","evidence"}], "denominator": {...}}`. `--lang`
auto-detects the dominant language when omitted; `--title` defaults to the repo basename.

Importable: `scan_repo`, `detect_language`, `render_markdown`, `render_json`, and the per-language
`extract_*` helpers are the public surface the tests / verify layer unit-test.
"""
import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# Per-language extractors live in the sibling oracle_extractors module (split out to stay under the
# per-file legibility cap). Re-exported here so scan_repo, the tests and the verify layer keep
# importing them from oracle_scan.
from oracle_extractors import (  # noqa: E402
    EXTRACTORS,
    extract_go,
    extract_java,
    extract_python,
    extract_ts_js,
)

try:
    import lang_profiles  # noqa: E402

    def _lang_excludes(lang):
        return lang_profiles.excludes(lang)
    _resolve, _GENERATED, _source_files = (lang_profiles.resolve_scan_language, lang_profiles.GENERATED_DIRS,
                                           lang_profiles.source_files)
except Exception:  # pragma: no cover - never crash if the sibling is missing
    _FALLBACK = ["node_modules", "target", "dist", "build", "__pycache__",
                 ".venv", "venv", "vendor", "bin", "obj"]

    def _lang_excludes(lang):
        return list(_FALLBACK)

    def _resolve(repo, lang, tool, **_):  # fail loud: coverage cannot be checked without lang_profiles
        return None, "", "%s: lang_profiles.py is missing — cannot check language coverage" % tool
    _GENERATED = set(_FALLBACK)

    def _source_files(repo):
        return sorted(os.path.relpath(os.path.join(d, f), repo).replace(os.sep, "/")
                      for d, _, fs in os.walk(repo) for f in fs)


_MAX_BYTES = 2_000_000

# Code extensions per language (test files live in the same language's extensions). typescript and
# javascript share the extractor and one extension family (a TS project routinely ships .js tooling).
LANG_EXTS = {
    "python":     {".py", ".pyi"},
    "typescript": {".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"},
    "javascript": {".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"},
    "java":       {".java"},
    "go":         {".go"},
}


# --------------------------------------------------------------------------------------------------
# file reading + traversal (deterministic, sorted; never raises)
# --------------------------------------------------------------------------------------------------
def _read_text(path):
    try:
        with open(path, "rb") as fh:
            data = fh.read(_MAX_BYTES + 1)
    except OSError:
        return None
    if len(data) > _MAX_BYTES or b"\x00" in data[:8192]:
        return None
    # one newline convention for every extractor (a lone \r is a line break, as in editors + ast)
    return data.decode("utf-8-sig", errors="replace").replace("\r\n", "\n").replace("\r", "\n")


def _relpath(path, repo):
    return os.path.relpath(path, repo).replace(os.sep, "/")


def _walk_files(repo, include_exts, exclude_dirs):
    for rel in _source_files(repo):  # git-tracked + unignored files in a work tree (lang_profiles)
        if set(rel.split("/")[:-1]) & exclude_dirs or os.path.splitext(rel)[1].lower() not in include_exts:
            continue
        yield os.path.join(repo, rel)


def _is_test_file(rel, lang):
    """True iff `rel` is in the language's TEST include-set (its own conventions)."""
    base = rel.rsplit("/", 1)[-1]
    segs = rel.split("/")
    if lang == "python":
        return bool(re.match(r"test_.+\.py$", base) or re.search(r"_test\.py$", base)
                    or "tests" in segs or "test" in segs)
    if lang in ("typescript", "javascript"):
        return bool(re.search(r"\.(test|spec)\.[cm]?[jt]sx?$", base) or "__tests__" in segs)
    if lang == "java":
        return ("Test" in base) or ("src/test/" in rel) or ("test" in segs)
    if lang == "go":
        return bool(re.search(r"_test\.go$", base))
    return False


# --------------------------------------------------------------------------------------------------
# scan orchestration, dedup + stable sort, denominator
# --------------------------------------------------------------------------------------------------
def detect_language(repo):
    """The language the CLI would scan (lang_profiles.resolve_scan_language), or None when it would
    fail loud (UNSUPPORTED) — the same census, family and tie rules as the CLI."""
    lang, _note, err = _resolve(repo, None, "oracle_scan")
    return None if err else lang


def scan_repo(repo, lang=None):
    """Scan `repo`'s test files and return (rows, resolved_lang, denominator).

    rows: dedup'd, stably-sorted [{"oracle","expected","tier","evidence"}] (evidence "path:line").
    denominator: {"real","total","files","stubs"} — the counted grounding measure (measured, never
    assumed; STUBs are excluded from `real` so grounding is not over-counted).
    """
    lang = (lang or "").strip().lower() or None
    if lang is None:  # the raw engine: the CLI resolves first; here an unscannable repo raises
        lang, _note, err = _resolve(repo, None, "oracle_scan")
        if err:
            raise ValueError(err)
    extractor = EXTRACTORS.get(lang)
    if extractor is None:
        return [], (lang or "unknown"), {"real": 0, "total": 0, "files": 0, "stubs": 0}
    exclude = set(_lang_excludes(lang)) | _GENERATED | {".git"}
    rows = []
    for path in _walk_files(repo, LANG_EXTS[lang], exclude):
        rel = _relpath(path, repo)
        if not _is_test_file(rel, lang):
            continue
        text = _read_text(path)
        if text is None:
            continue
        try:
            found = extractor(rel, text)
        except Exception:  # pragma: no cover - an unexpected file never aborts the scan
            found = []
        for name, expected, tier, line in found:
            if not name or line is None:
                continue
            rows.append({"oracle": name, "expected": expected, "tier": tier,
                         "evidence": "%s:%d" % (rel, line)})
    rows = _dedup_sort(rows)
    return rows, lang, _denominator(rows)


def _dedup_sort(rows):
    """Dedup by (oracle, evidence); stable-sort by (evidence-path, line, oracle)."""
    seen, unique = set(), []
    for r in rows:
        key = (r["oracle"], r["evidence"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(r)

    def sort_key(r):
        path, _, ln = r["evidence"].rpartition(":")
        try:
            line = int(ln)
        except ValueError:
            path, line = r["evidence"], 0
        return (path, line, r["oracle"])

    return sorted(unique, key=sort_key)


def _denominator(rows):
    real = sum(1 for r in rows if r["tier"] == "WITNESSED")
    stub = sum(1 for r in rows if r["tier"] == "STUB")
    files = len({r["evidence"].rpartition(":")[0] for r in rows})
    return {"real": real, "total": real + stub, "files": files, "stubs": stub}


# --------------------------------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------------------------------
def _cell(s):
    s = str(s).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
    return s if len(s) <= 80 else s[:79] + "…"


def render_markdown(rows, denom, title, regenerate_cmd, note=""):
    """Render the full oracle-library.md (matches the fixed FORMAT contract exactly). `note` records
    what the run did NOT cover."""
    lines = [
        "# %s — behavioural oracle library" % title,
        "",
        "Regenerate: `%s`" % regenerate_cmd,
        "",
    ] + (["Coverage: %s" % note, ""] if note else []) + [
        "Behavioural grounding: %d real oracle(s) / %d test(s) / %d file(s)  (stubs: %d)" % (
            denom["real"], denom["total"], denom["files"], denom["stubs"]),
        "",
        "## Oracles",
        "",
        "| oracle | expected | tier | evidence |",
        "|--------|----------|------|----------|",
    ]
    for r in rows:
        lines.append("| %s | %s | %s | %s |" % (
            _cell(r["oracle"]), _cell(r["expected"]), r["tier"], r["evidence"]))
    return "\n".join(lines) + "\n"


def render_json(rows, denom):
    return json.dumps({"oracles": rows, "denominator": denom}, indent=2, ensure_ascii=False)


# --------------------------------------------------------------------------------------------------
# self-test — stdlib-only unit checks (so verify can gate on it)
# --------------------------------------------------------------------------------------------------
def _self_test():
    import shutil
    import tempfile

    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    def by(rows):
        return {r[0]: (r[1], r[2]) for r in rows}

    py = (
        "import unittest, pytest\n"
        "def test_computes_prorated_refund():\n"
        "    assert compute() == 4200\n"
        "def test_rejects_negative():\n"
        "    with pytest.raises(ValueError):\n"
        "        do()\n"
        "def test_placeholder():\n"
        "    pass\n"
        "class TestLedger(unittest.TestCase):\n"
        "    def test_equal(self):\n"
        "        self.assertEqual(7, add(3, 4))\n"
        "    def test_truthy_stub(self):\n"
        "        self.assertTrue(True)\n"
    )
    p = by(extract_python("tests/test_ledger.py", py))
    check(p.get("test_computes_prorated_refund") == ("4200", "WITNESSED"), "py eq: %r" % (p.get("test_computes_prorated_refund"),))
    check(p.get("test_rejects_negative") == ("raises ValueError", "WITNESSED"), "py raises: %r" % (p.get("test_rejects_negative"),))
    check(p.get("test_placeholder") == ("—", "STUB"), "py stub: %r" % (p.get("test_placeholder"),))
    # isolated case (kept out of the denominator fixture above): existence-only is-not-None must be STUB, never over-counted
    nn = by(extract_python("tests/nn.py", "def test_nn():\n    assert x is not None\n"))
    check(nn.get("test_nn") == ("—", "STUB"), "py is-not-None existence-only must be STUB: %r" % (nn.get("test_nn"),))
    check(p.get("test_equal") == ("7", "WITNESSED"), "py assertEqual: %r" % (p.get("test_equal"),))
    check(p.get("test_truthy_stub") == ("—", "STUB"), "py trivial-true: %r" % (p.get("test_truthy_stub"),))

    js = (
        "it('adds numbers', () => { expect(add(2, 3)).toBe(5); });\n"
        "test('throws on bad', () => { expect(() => f()).toThrow('bad'); });\n"
        "it('should create', () => {});\n"
        "it('exists only', () => { expect(x).toBeDefined(); });\n"
    )
    j = by(extract_ts_js("src/ledger.test.ts", js))
    check(j.get("adds numbers") == ("5", "WITNESSED"), "js toBe: %r" % (j.get("adds numbers"),))
    check(j.get("throws on bad") == ("throws 'bad'", "WITNESSED"), "js throw: %r" % (j.get("throws on bad"),))
    check(j.get("should create") == ("—", "STUB"), "js empty stub: %r" % (j.get("should create"),))
    check(j.get("exists only") == ("—", "STUB"), "js existence stub: %r" % (j.get("exists only"),))

    java = (
        "public class LedgerTest {\n"
        "    @Test\n"
        "    public void computesRefund() {\n"
        "        assertEquals(4200, refund());\n"
        "    }\n"
        "    @Test\n"
        "    public void rejectsNegative() {\n"
        "        assertThrows(IllegalArgumentException.class, () -> f());\n"
        "    }\n"
        "    @Test\n"
        "    public void placeholder() {\n"
        "    }\n"
        "}\n"
    )
    jv = by(extract_java("src/test/LedgerTest.java", java))
    check(jv.get("computesRefund") == ("4200", "WITNESSED"), "java eq: %r" % (jv.get("computesRefund"),))
    check(jv.get("rejectsNegative") == ("throws IllegalArgumentException", "WITNESSED"), "java throws: %r" % (jv.get("rejectsNegative"),))
    check(jv.get("placeholder") == ("—", "STUB"), "java stub: %r" % (jv.get("placeholder"),))

    go = (
        "func TestRefund(t *testing.T) {\n"
        "    assert.Equal(t, 4200, refund())\n"
        "}\n"
        "func TestErr(t *testing.T) {\n"
        "    require.Error(t, err)\n"
        "}\n"
        "func TestStub(t *testing.T) {\n"
        "}\n"
    )
    g = by(extract_go("ledger_test.go", go))
    check(g.get("TestRefund") == ("4200", "WITNESSED"), "go eq: %r" % (g.get("TestRefund"),))
    check(g.get("TestErr") == ("returns error", "WITNESSED"), "go err: %r" % (g.get("TestErr"),))
    check(g.get("TestStub") == ("—", "STUB"), "go stub: %r" % (g.get("TestStub"),))

    # full scan through a temp repo: denominator, md/json rendering, determinism
    tmp = tempfile.mkdtemp(prefix="oracle_selftest_")
    try:
        os.makedirs(os.path.join(tmp, "tests"))
        with open(os.path.join(tmp, "tests", "test_ledger.py"), "w", encoding="utf-8") as fh:
            fh.write(py)
        rows, lang, denom = scan_repo(tmp, "python")
        check(lang == "python", "scan lang: %r" % lang)
        check(detect_language(tmp) == "python", "detect: %r" % detect_language(tmp))
        check(denom == {"real": 3, "total": 5, "files": 1, "stubs": 2}, "denominator: %r" % (denom,))
        for r in rows:
            check(re.fullmatch(r"\S+:\d+", r["evidence"]) is not None,
                  "evidence path:line: %r" % r["evidence"])
        rows2, _, denom2 = scan_repo(tmp, "python")
        check(rows == rows2 and denom == denom2, "determinism: rows/denominator differ across runs")
        md = render_markdown(rows, denom, "sample", "python3 core/lib/oracle_scan.py %s --lang python" % tmp)
        check(md.startswith("# sample — behavioural oracle library"), "md title header")
        check("| oracle | expected | tier | evidence |" in md, "md header row")
        check("|--------|----------|------|----------|" in md, "md separator row")
        check(re.search(r"(^|\n)Regenerate: `", md) is not None, "md Regenerate line")
        check("Behavioural grounding: 3 real oracle(s) / 5 test(s) / 1 file(s)  (stubs: 2)" in md,
              "md grounding denominator line")
        check("| test_computes_prorated_refund | 4200 | WITNESSED |" in md, "md witnessed row")
        data = json.loads(render_json(rows, denom))
        check(set(data) == {"oracles", "denominator"}, "json keys: %r" % (sorted(data),))
        check(all(set(o) == {"oracle", "expected", "tier", "evidence"} for o in data["oracles"]),
              "json oracle shape")
        check(data["denominator"] == denom, "json denominator")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

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
        prog="oracle_scan.py",
        description="Deterministic behavioural-oracle scan -> oracle-library.md oracle table.")
    p.add_argument("repo", nargs="?", help="path to the repository to scan")
    p.add_argument("--lang", help="language override (auto-detected from file extensions if omitted)")
    p.add_argument("--allow-partial", action="store_true",
                   help="allow a --lang that is not the repo's dominant language (the rest stays unscanned)")
    p.add_argument("--format", choices=["md", "json"], default="md",
                   help="md (full oracle-library.md, default) or json (oracles + denominator)")
    p.add_argument("--title", help="title for the md header (default: repo directory basename)")
    p.add_argument("--self-test", action="store_true", help="run the built-in unit checks and exit")
    args = p.parse_args(argv)

    if args.self_test:
        return _self_test()
    if not args.repo:
        p.error("repo path is required (or pass --self-test)")
    if not os.path.isdir(args.repo):
        sys.stderr.write("oracle_scan: not a directory: %r\n" % args.repo)
        return 2

    lang, note, err = _resolve(args.repo, args.lang, "oracle_scan", allow_partial=args.allow_partial)
    if err:
        sys.stderr.write(err + "\n")
        return 3
    if note:
        sys.stderr.write("oracle_scan: NOTE — %s\n" % note)
    rows, lang, denom = scan_repo(args.repo, lang)
    if args.format == "json":
        print(render_json(rows, denom))
    else:
        title = args.title or os.path.basename(os.path.abspath(args.repo)) or "repo"
        regen = "python3 core/lib/oracle_scan.py %s --lang %s%s" % (
            args.repo, lang, " --allow-partial" if args.allow_partial else "")
        sys.stdout.write(render_markdown(rows, denom, title, regen, note))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
