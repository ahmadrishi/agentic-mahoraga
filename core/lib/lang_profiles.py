#!/usr/bin/env python3
"""lang_profiles.py — shared per-language profiles for the Mahoraga core engine.

Single source of truth for three language-dependent decisions, so the decontamination gate,
the diff extractor and the forge scanners never disagree:

  * distinctive-identifier heuristic — which added identifiers in a human diff are
    ANSWER-SPECIFIC (a method/field/const/type the human newly introduced) versus framework or
    common vocabulary an unrelated skill may legitimately mention. Used by leak_gate.sh.
  * build-artifact diff-excludes — directories whose contents are generated, so they must not
    pollute the AI-vs-fork diff. Used by extract_ai_diff.sh.
  * fail-loud scan resolution — which languages a repo holds (a census over every recognised source
    extension, scannable or not) and whether a scanner can honestly cover it. Used by mapping_scan.py
    and oracle_scan.py, which exit 3 (UNSUPPORTED) instead of mapping a minority language.

Pure stdlib. Import it, or run as a CLI:
    python3 lang_profiles.py excludes <language>       # print exclude dir names, one per line
    python3 lang_profiles.py distinctive <language>    # filter identifiers on stdin -> distinctive ones
    python3 lang_profiles.py languages                 # list known languages

The heuristics are deliberately HIGH-PRECISION candidate nets: leak_gate.sh then SUBTRACTS every
candidate that already exists at the unit's fork-point, so a common symbol that slips through but
predates the change is dropped anyway. The net only has to catch the newly-introduced answer symbols
without drowning in framework noise.
"""
import os
import re
import subprocess
import sys

# ---- build-artifact directories to exclude from the AI-vs-fork diff, per language ----
# '.git' is always excluded by the caller regardless of language.
_EXCLUDES = {
    "java":       ["target", "build", ".gradle"],
    "kotlin":     ["build", ".gradle"],
    "scala":      ["target"],
    "typescript": ["node_modules", "dist", "build", ".next", "coverage", ".turbo"],
    "javascript": ["node_modules", "dist", "build", ".next", "coverage", ".turbo"],
    "python":     ["__pycache__", ".venv", "venv", ".pytest_cache", ".mypy_cache", "dist", "build", ".eggs"],
    "go":         ["vendor", "bin"],
    "rust":       ["target"],
    "ruby":       ["vendor", ".bundle", "tmp"],
    "csharp":     ["bin", "obj"],
    "php":        ["vendor"],
}
# Fallback when the language is unknown: the union of the most common build dirs (never empty, so a
# never-declared language still gets basic protection rather than a diff full of generated files).
_COMMON_EXCLUDES = ["node_modules", "target", "dist", "build", "__pycache__",
                    ".venv", "venv", "vendor", "bin", "obj"]


def excludes(language):
    """Return the list of build-artifact directory names to exclude for a language."""
    return _EXCLUDES.get((language or "").strip().lower(), _COMMON_EXCLUDES)


# ---- distinctive-identifier heuristics, per language family ----
def _humps(m):
    return len(re.findall(r"[a-z][A-Z]", m))


def _is_constant_case(m):
    # A CONFIG KEY / enum-ish constant: SCREAMING_SNAKE with >=2 separators, reasonably long.
    return m.isupper() and m.count("_") >= 2 and len(m) >= 12


def _camel(m):
    # Java / Kotlin / TS / JS / Scala: lowerCamelCase method or field the human introduced.
    # >=2 humps (getTranscribedText) OR 1 hump but long (inactivityTimer). PascalCase type names are
    # intentionally NOT matched here — they are framework vocabulary (ObjectMapper, PageRequest) and
    # the main false-positive source; a genuine class-name answer is covered by curated answer_tokens.
    is_lower_camel = m[0].islower() and (_humps(m) >= 2 or (_humps(m) >= 1 and len(m) >= 18))
    return is_lower_camel or _is_constant_case(m)


def _snake(m):
    # Python / Ruby / Rust: snake_case with >=2 separators and a reasonable length
    # (compute_prorated_refund, confirmed_refund_amount). Short generics (to_string, is_valid) have
    # <2 separators or are short, so they are dropped. CONSTANT_CASE keys count too.
    is_snake = (
        (m[0].islower() or m[0] == "_")
        and not m.isupper()
        and m.count("_") >= 2
        and len(m) >= 12
    )
    return is_snake or _is_constant_case(m)


def _mixed(m):
    # Go / C#: exported MixedCaps and unexported camelCase both use humps; treat like camel but also
    # accept CONSTANT_CASE. (Go rarely uses underscores, so the hump signal carries the distinctiveness.)
    return (_humps(m) >= 2 and len(m) >= 12) or (m[0].islower() and _humps(m) >= 2) or _is_constant_case(m)


_FAMILY = {
    "java": _camel, "kotlin": _camel, "typescript": _camel, "javascript": _camel, "scala": _camel,
    "python": _snake, "ruby": _snake, "rust": _snake,
    "go": _mixed, "csharp": _mixed,
}


def distinctive_fn(language):
    """Return the distinctive-identifier predicate for a language (default: camelCase, the original behaviour)."""
    return _FAMILY.get((language or "").strip().lower(), _camel)


def distinctive(language, m):
    """True iff identifier `m` looks answer-specific for `language`."""
    if len(m) < 4:
        return False
    return distinctive_fn(language)(m)


# ---- fail-loud scanning: what a repo holds vs what a scanner can read ----
# Every language recognisable by extension — scannable or not — so a scan names what it is NOT
# reading instead of silently picking a minority language it does read (a Kotlin repo with two .mjs
# tools must not be mapped as JavaScript).
_CENSUS_EXT = {
    ".py": "python", ".pyi": "python", ".java": "java", ".go": "go",
    ".ts": "typescript", ".tsx": "typescript", ".mts": "typescript", ".cts": "typescript",
    ".js": "javascript", ".jsx": "javascript", ".mjs": "javascript", ".cjs": "javascript",
    ".kt": "kotlin", ".kts": "kotlin", ".scala": "scala", ".groovy": "groovy", ".rs": "rust",
    ".cs": "csharp", ".fs": "fsharp", ".rb": "ruby", ".php": "php", ".swift": "swift",
    ".m": "objective-c", ".mm": "objective-c", ".c": "c", ".h": "c", ".cc": "cpp", ".cpp": "cpp",
    ".cxx": "cpp", ".hpp": "cpp", ".dart": "dart", ".ex": "elixir", ".exs": "elixir",
    ".erl": "erlang", ".hs": "haskell", ".clj": "clojure", ".lua": "lua", ".pl": "perl",
    ".pm": "perl", ".r": "r", ".vue": "vue", ".svelte": "svelte", ".sh": "shell", ".bash": "shell",
    ".tf": "terraform", ".sql": "sql",
}
SCANNABLE = ("go", "java", "javascript", "python", "typescript")
# Support languages are listed as unscanned but never decide what a repo IS (a Go service with SQL
# migrations is a Go repo; this harness is a Python one with many shell scripts; *.gradle.kts files
# are build scripts, not Kotlin code).
_SUPPORT = {"shell", "sql", "terraform", "gradle"}
# Never-source directories, pruned by name at any depth: generated output outside git (inside git,
# .gitignore decides), plus `.claude/` — the agent harness, never the project's source (the lint
# rejects evidence there too). Names that are also real package names (vendor, target, out, bin,
# dist, build …) are left to the per-language excludes.
GENERATED_DIRS = {"node_modules", ".next", ".nuxt", ".svelte-kit", "coverage", "htmlcov", ".turbo",
                  "__pycache__", ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache", ".eggs",
                  ".gradle", ".terraform", ".cache", ".parcel-cache", "_build", "staticfiles", ".git",
                  ".claude"}
PARTIAL_SHARE = 0.1  # an explicit --lang below this share of the application source is PARTIAL


def extensions(lang):
    """The source extensions recognised for `lang` (empty for an unknown language)."""
    return {e for e, l in _CENSUS_EXT.items() if l == lang}


def source_files(repo):
    """Sorted repo-relative paths a scan may read. In a git work tree: tracked + untracked-not-ignored
    files (so .gitignore'd build output never counts); otherwise an os.walk with GENERATED_DIRS pruned.
    Symlinks resolving outside `repo` are dropped either way (the lint would reject them)."""
    root = os.path.realpath(repo)
    keep = lambda rel: os.path.realpath(os.path.join(repo, rel)).startswith(root + os.sep) and \
        not set(rel.split("/")[:-1]) & GENERATED_DIRS and os.path.isfile(os.path.join(repo, rel))
    try:
        out = subprocess.run(["git", "-C", repo, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                             capture_output=True, timeout=300)
        if out.returncode == 0:
            return sorted(p for p in set(out.stdout.decode("utf-8", "replace").split("\0")) if p and keep(p))
    except (OSError, subprocess.SubprocessError):
        pass
    found = []
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [d for d in dirnames if d not in GENERATED_DIRS]
        found += [os.path.relpath(os.path.join(dirpath, f), repo).replace(os.sep, "/") for f in filenames]
    return sorted(p for p in found if keep(p))


def _lang_of(path):
    return "gradle" if path.endswith(".gradle.kts") else _CENSUS_EXT.get(os.path.splitext(path)[1].lower())


def census(repo, files=None):
    """{language: file count} over `files` (default: source_files(repo))."""
    counts = {}
    for p in files if files is not None else source_files(repo):
        lang = _lang_of(p)
        if lang:
            counts[lang] = counts.get(lang, 0) + 1
    return counts


def _family(k):
    return ("javascript", "typescript") if k in ("javascript", "typescript") else (k,)


def _dominance(counts):
    """(dominant, order, size, need_partial) — support languages never win; TS/JS count as one family
    (labelled by its larger member); a tie goes to the language we CANNOT read (fail loud)."""
    size = lambda k: sum(counts.get(f, 0) for f in _family(k))
    order = sorted((k for k in counts if k not in _SUPPORT), key=lambda k: (-size(k), k in SCANNABLE, k))
    dominant = order[0] if order else ""
    if dominant in ("javascript", "typescript"):
        dominant = max(_family(dominant), key=lambda f: (counts.get(f, 0), f == "typescript"))
    app = sum(c for k, c in counts.items() if k not in _SUPPORT)
    need_partial = lambda k: bool(dominant) and set(_family(k)) != set(_family(dominant)) and size(k) < PARTIAL_SHARE * app
    return dominant, order, size, need_partial


def resolve_scan_language(repo, lang, tool, allow_generic=False, allow_partial=False, offers_generic=False):
    """(lang, note, error) for a scanner run. `lang` is the requested or dominant language; `note`
    names what this run will NOT read; `error` (fail loud — the caller exits 3) is set when the scan
    cannot honestly cover the repo: an unscannable dominant or requested language (unless
    allow_generic and it has files), a requested language with no files, or a requested language under
    PARTIAL_SHARE of the application source (unless allow_partial)."""
    counts = census(repo)
    dominant, order, size, need_partial = _dominance(counts)
    found = ", ".join("%s %d" % (k, counts[k]) for k in sorted(counts, key=lambda k: (-counts[k], k))) or "none"
    flags = lambda k, extra="": "--lang %s%s%s" % (k, extra, " --allow-partial" if need_partial(k) else "")
    lang = (lang or "").strip().lower() or dominant
    if not lang:
        return None, "", "%s: UNSUPPORTED — no application source files under %s (found: %s)" % (tool, repo, found)
    if not size(lang):
        return None, "", "%s: UNSUPPORTED — no %s source files under %s (found: %s)" % (tool, lang, repo, found)
    if lang not in SCANNABLE and not allow_generic:
        alt = [k for k in order if k in SCANNABLE]
        hint = " Pass %s to scan only its %d file(s)." % (flags(alt[0]), size(alt[0])) if alt else ""
        if offers_generic:
            hint += " Or pass %s for a low-precision keyword grep you must audit row by row." % flags(lang, " --allow-generic")
        return None, "", ("%s: UNSUPPORTED — no extractor for %s (found: %s; scannable: %s).%s"
                          % (tool, lang, found, ", ".join(SCANNABLE), hint))
    if need_partial(lang) and not allow_partial:
        return None, "", ("%s: PARTIAL — %s is %d of this repo's source files (dominant: %s; found: %s). Pass "
                          "--allow-partial to scan only that part." % (tool, lang, size(lang), dominant, found))
    rest = ["%s %d" % (k, counts[k]) for k in sorted(counts, key=lambda k: (-counts[k], k)) if k not in _family(lang)]
    note = "Not scanned in this run (one language per scan): " + ", ".join(rest) if rest else ""
    if lang not in SCANNABLE:
        note = "generic keyword grep for %s (low precision) — audit every row" % lang + ("; " + note if note else "")
    return lang, note, None


def languages():
    return sorted(set(list(_EXCLUDES) + list(_FAMILY)))


if __name__ == "__main__":
    op = sys.argv[1] if len(sys.argv) > 1 else ""
    lang = sys.argv[2] if len(sys.argv) > 2 else ""
    if op == "excludes":
        for d in excludes(lang):
            print(d)
    elif op == "distinctive":
        for line in sys.stdin:
            tok = line.strip()
            if tok and distinctive(lang, tok):
                print(tok)
    elif op == "languages":
        for l in languages():
            print(l)
    else:
        sys.stderr.write("usage: lang_profiles.py {excludes|distinctive|languages} <language>\n")
        sys.exit(2)
