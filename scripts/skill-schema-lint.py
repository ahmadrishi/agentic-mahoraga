#!/usr/bin/env python3
"""skill-schema-lint.py — the emitted-SKILL.md schema gate (core/schema/SKILL.schema.md).

Walks skills/**/SKILL.md, parses the YAML frontmatter, and enforces the container contract every
skill Mahoraga forges or ships must hold — the machine half of docs/SKILL-SCHEMA.md. It checks the
FRONTMATTER + size budget, never the truth of a claim (that is the forge's adversarial audit).

Rules (all from core/schema/SKILL.schema.md; a "hard" rule fails the gate):
  name          REQUIRED, <=64 chars, ^[a-z0-9-]+$, matches its folder name, and must NOT contain
                "anthropic" or "claude" (reserved).                                        [hard]
  description   REQUIRED, <=1024 chars.                                                     [hard]
  mahoraga.kind when a `mahoraga` block exists, must be one of {guard, mapping, spec, meta}. [hard]
  body          <=500 lines (the Markdown after the frontmatter; progressive-disclosure budget). [hard]
  allowed-tools RECOMMENDED on a `kind: guard` skill — WARN (never fail) when it is absent.  [warn]

Frontmatter is parsed with PyYAML when importable (correct on quoting/escaping); when PyYAML is
absent it falls back to a focused stdlib parser for exactly the fields checked here, so this gate
runs in a pure-stdlib CI job with no install step. Either way the verdicts are identical for the
scalar fields this schema constrains.

Stdlib only (PyYAML optional). Python 3.8+.

Usage:  scripts/skill-schema-lint.py [SKILLS_ROOT]   (default: skills)
Exit:   0 = every SKILL.md conforms (warnings allowed) · 1 = at least one hard violation
"""
from __future__ import annotations

import os
import re
import sys

NAME_RE = re.compile(r"^[a-z0-9-]+$")
VALID_KINDS = {"guard", "mapping", "spec", "meta"}
RESERVED = ("anthropic", "claude")
NAME_MAX = 64
DESC_MAX = 1024
BODY_MAX = 500
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build"}

try:
    import yaml  # PyYAML — the one allowed runtime dep (deps-allowlist.txt)

    _HAVE_YAML = True
except Exception:  # pragma: no cover - exercised only where PyYAML is absent
    yaml = None
    _HAVE_YAML = False


# ---- frontmatter ---------------------------------------------------------------------------------

def split_frontmatter(text: str):
    """Return (frontmatter_body, markdown_body). frontmatter_body is None when there is no header."""
    m = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*(?:\n|$)", text, re.S)
    if not m:
        return None, text
    return m.group(1), text[m.end():]


def _unquote(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


def _fallback_parse(fm: str) -> dict:
    """Minimal frontmatter reader for the scalar fields this gate checks (used only sans PyYAML).

    Handles top-level `key: value`, the `mahoraga:` block (indented `kind: value`) and the inline
    flow form `mahoraga: {kind: mapping, grounding: file-line}`. It does not aim to be a full YAML
    parser — only to recover name/description/allowed-tools/mahoraga.kind faithfully.
    """
    data: dict = {}
    lines = fm.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_-]+):[ \t]*(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).rstrip()
        if key != "mahoraga":
            data[key] = _unquote(val)
            continue
        mah: dict = {}
        inline = re.match(r"^\{(.*)\}$", val.strip())
        if inline:
            for pair in inline.group(1).split(","):
                if ":" in pair:
                    k, v = pair.split(":", 1)
                    mah[k.strip()] = _unquote(v)
        else:
            while i < len(lines) and (not lines[i].strip() or re.match(r"^\s+\S", lines[i])):
                sub = lines[i]
                i += 1
                sub_stripped = sub.strip()
                if not sub_stripped or sub_stripped.startswith("#"):
                    continue
                sm = re.match(r"^\s+([A-Za-z0-9_-]+):[ \t]*(.*)$", sub)
                if sm:
                    mah[sm.group(1)] = _unquote(sm.group(2))
        data["mahoraga"] = mah
    return data


def parse_frontmatter(fm: str):
    """Return (data_dict, error_message). data_dict is None only when parsing outright fails."""
    if _HAVE_YAML:
        try:
            data = yaml.safe_load(fm)
        except yaml.YAMLError as exc:  # type: ignore[union-attr]
            return None, f"invalid YAML frontmatter: {str(exc).splitlines()[0]}"
        if data is None:
            return {}, None
        if not isinstance(data, dict):
            return None, "frontmatter is not a YAML mapping"
        return data, None
    return _fallback_parse(fm), None


# ---- per-file checks -----------------------------------------------------------------------------

def _present(value) -> bool:
    if value is None:
        return False
    if isinstance(value, (list, tuple, dict)):
        return len(value) > 0
    return str(value).strip() != ""


def _body_line_count(body: str) -> int:
    b = body[:-1] if body.endswith("\n") else body
    return 0 if b == "" else b.count("\n") + 1


def check_file(path: str):
    """Return (violations, warnings) — both lists of human-readable strings."""
    violations: list[str] = []
    warnings: list[str] = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        return [f"cannot read file: {exc}"], warnings

    text = raw.lstrip("﻿").replace("\r\n", "\n").replace("\r", "\n")
    fm, body = split_frontmatter(text)
    if fm is None:
        return ["no YAML frontmatter (missing the '---' ... '---' header)"], warnings

    data, err = parse_frontmatter(fm)
    if err:
        return [err], warnings

    folder = os.path.basename(os.path.dirname(path))

    # name -----------------------------------------------------------------------------------------
    name = data.get("name")
    if not _present(name):
        violations.append("name: missing (required)")
    else:
        name = str(name).strip()
        if len(name) > NAME_MAX:
            violations.append(f'name: "{name}" is {len(name)} chars > {NAME_MAX}')
        if not NAME_RE.match(name):
            violations.append(f'name: "{name}" must match ^[a-z0-9-]+$')
        if name != folder:
            violations.append(f'name: "{name}" does not match its folder "{folder}"')
        hits = [w for w in RESERVED if w in name.lower()]
        if hits:
            violations.append(f'name: "{name}" contains reserved word(s) {hits} '
                              f'("anthropic"/"claude" are reserved)')

    # description ----------------------------------------------------------------------------------
    desc = data.get("description")
    if not _present(desc):
        violations.append("description: missing (required)")
    elif len(str(desc)) > DESC_MAX:
        violations.append(f"description: {len(str(desc))} chars > {DESC_MAX}")

    # mahoraga.kind (only when a mahoraga block exists) --------------------------------------------
    mah = data.get("mahoraga")
    kind = None
    if mah is not None:
        if not isinstance(mah, dict):
            violations.append("mahoraga: must be a block/mapping (kind, grounding, provenance)")
        else:
            kind = mah.get("kind")
            if kind is None:
                violations.append("mahoraga.kind: missing (required when a mahoraga block exists)")
            elif str(kind) not in VALID_KINDS:
                violations.append(f'mahoraga.kind: "{kind}" not in {{guard, mapping, spec, meta}}')

    # body budget ----------------------------------------------------------------------------------
    body_lines = _body_line_count(body)
    if body_lines > BODY_MAX:
        violations.append(f"body: {body_lines} lines > {BODY_MAX} (move depth into references/)")

    # allowed-tools on a guard skill — WARN only ---------------------------------------------------
    if str(kind) == "guard" and not _present(data.get("allowed-tools")):
        warnings.append("allowed-tools missing on a kind:guard skill "
                        "(recommended: declare least-privilege tools)")

    return violations, warnings


# ---- walk + report -------------------------------------------------------------------------------

def find_skill_files(root: str):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if "SKILL.md" in filenames:
            out.append(os.path.join(dirpath, "SKILL.md"))
    return sorted(out)


def main(argv: list[str]) -> int:
    root = (argv[1] if len(argv) > 1 else "skills").rstrip("/")
    if not os.path.isdir(root):
        print(f"skill-schema-lint: no '{root}/' directory — nothing to check, PASS.")
        return 0

    files = find_skill_files(root)
    if not files:
        print(f"skill-schema-lint: no SKILL.md under '{root}/' — nothing to check, PASS.")
        return 0

    engine = "PyYAML" if _HAVE_YAML else "stdlib fallback parser"
    caveat = "" if _HAVE_YAML else "  — install PyYAML to length-verify multi-line/block-scalar fields"
    print(f"skill-schema-lint: {len(files)} SKILL.md file(s) under {root}/  "
          f"(frontmatter via {engine}){caveat}")

    n_fail = 0
    n_warn = 0
    for path in files:
        violations, warnings = check_file(path)
        verdict = "FAIL" if violations else "PASS"
        if violations:
            n_fail += 1
        n_warn += len(warnings)
        print(f"  {verdict}  {path}")
        for msg in violations:
            print(f"          - {msg}")
        for msg in warnings:
            print(f"          - WARN: {msg}")

    print("-" * 70)
    warn_note = f", {n_warn} warning(s)" if n_warn else ""
    if n_fail:
        print(f"SKILL-SCHEMA FAIL: {n_fail} of {len(files)} file(s) violate the emitted-skill "
              f"schema{warn_note}.", file=sys.stderr)
        return 1
    print(f"SKILL-SCHEMA PASS: all {len(files)} file(s) conform to the emitted-skill schema"
          f"{warn_note}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
