#!/usr/bin/env python3
"""loc-budget.py — the "nanochat-shaped" legibility gate.

Replaces the un-runnable v1 goal of "a newcomer reads the core in <1hr" with a real, mechanical
check: a per-file line cap over all core/ source, and a total-lines cap over core/lib (the engine a
newcomer must actually read). Generous but real — the point is to keep the core small enough to read,
and to make a PR that balloons it fail loudly.

"Lines" are counted as SOURCE lines: total lines minus blank lines and whole-line comments. This is
language-aware for the file types the core uses (Python/# , shell/# , JS-family and YAML handled),
so a heavily-commented file is not penalised for being well-documented.

Stdlib-only. Python 3.8+.

Usage:  scripts/loc-budget.py [CORE_ROOT]        (default: core)
Env:    LOC_PER_FILE   (default 400)   per-file source-line cap, applied to every core/ source file
        LOC_CORE_LIB   (default 3000)  total source-line cap for core/lib
        LOC_CORE_LOOP  (default 3060)  total source-line cap for core/loop (raised only with a written reason)
Exit:   0 = within budget · 1 = a budget was exceeded · 2 = usage/environment error
"""
from __future__ import annotations

import os
import sys

PER_FILE = int(os.environ.get("LOC_PER_FILE", "400"))
# The per-file cap (400) is the real legibility lever; the total is a backstop. Raise it only with a written
# reason in the same change. The closed improve loop does not count here: it has core/loop/ and its own cap.
CORE_LIB_TOTAL = int(os.environ.get("LOC_CORE_LIB", "3000"))
# core/loop (the closed improve loop) has its OWN total. Raise it only with a written reason in the same
# change; the per-file cap and the blocking complexity ceiling stay intact. Cap: 3,060.
CORE_LOOP_TOTAL = int(os.environ.get("LOC_CORE_LOOP", "3060"))

SOURCE_EXTS = (".py", ".sh", ".bash", ".js", ".mjs", ".cjs")
LINE_COMMENT = "#"           # py / sh / yaml; JS-family '//' handled explicitly below
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build"}


def source_lines(path: str) -> int:
    """Count non-blank, non-whole-line-comment lines."""
    js_like = path.endswith((".js", ".mjs", ".cjs"))
    n = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                s = raw.strip()
                if not s:
                    continue
                if js_like and s.startswith("//"):
                    continue
                if not js_like and s.startswith(LINE_COMMENT):
                    continue
                n += 1
    except OSError as exc:
        print(f"loc-budget: cannot read {path}: {exc}", file=sys.stderr)
    return n


def iter_source(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn.endswith(SOURCE_EXTS):
                yield os.path.join(dirpath, fn)


def main(argv: list[str]) -> int:
    core = argv[1] if len(argv) > 1 else "core"
    core = core.rstrip("/")
    if not os.path.isdir(core):
        print(f"loc-budget: no '{core}/' directory yet — nothing to check, PASS "
              f"(the engine is built by another workstream).")
        return 0

    lib_prefix = os.path.join(core, "lib") + os.sep
    loop_prefix = os.path.join(core, "loop") + os.sep
    loop_total = 0
    over_file: list[tuple[str, int]] = []
    lib_total = 0
    n_files = 0
    biggest: list[tuple[int, str]] = []

    for path in iter_source(core):
        n_files += 1
        loc = source_lines(path)
        biggest.append((loc, path))
        if loc > PER_FILE:
            over_file.append((path, loc))
        if path.replace("/", os.sep).startswith(lib_prefix):
            lib_total += loc
        if path.replace("/", os.sep).startswith(loop_prefix):
            loop_total += loc

    print(f"loc-budget: {n_files} source file(s) under {core}/  "
          f"(per-file cap {PER_FILE}, core/lib total cap {CORE_LIB_TOTAL})")
    for loc, path in sorted(biggest, reverse=True)[:5]:
        print(f"  {loc:5d}  {path}")
    print(f"core/lib total source lines: {lib_total}")
    print(f"core/loop total source lines: {loop_total} (cap {CORE_LOOP_TOTAL})")

    failed = False
    if over_file:
        failed = True
        print("----------------------------------------------------------------------")
        for path, loc in sorted(over_file, key=lambda t: -t[1]):
            print(f"OVER-BUDGET (per-file): {path} = {loc} lines > {PER_FILE}", file=sys.stderr)
    if lib_total > CORE_LIB_TOTAL:
        failed = True
        print(f"OVER-BUDGET (core/lib total): {lib_total} lines > {CORE_LIB_TOTAL}", file=sys.stderr)
    if loop_total > CORE_LOOP_TOTAL:
        failed = True
        print(f"OVER-BUDGET (core/loop total): {loop_total} lines > {CORE_LOOP_TOTAL}", file=sys.stderr)

    if failed:
        print("LOC-BUDGET FAIL: split the file(s), or justify raising the cap in the same change.",
              file=sys.stderr)
        return 1
    print("LOC-BUDGET PASS: core is within the legibility budget.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
