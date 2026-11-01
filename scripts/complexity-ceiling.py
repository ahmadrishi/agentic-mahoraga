#!/usr/bin/env python3
"""complexity-ceiling.py — a simple, dependency-free complexity gate over core/lib Python.

Uses only the standard-library `ast`. For every function/method it computes three cheap proxies for
"is this hard to read?" and fails if any function crosses a generous-but-real ceiling:

  * cyclomatic       — 1 + count of branch points (if / for / while / except / with-item / boolean
                       operator / comprehension-clause / ternary / match-case / assert). A rough
                       McCabe-style number; the classic "keep it under ~10-15" heuristic.
  * max nesting      — deepest nesting of control structures inside the function body.
  * function length  — source lines from `def` to the function's last line.

These are proxies, not a proof of quality; the ceiling exists to make a function that has quietly
grown a tangle fail loudly so it gets split. Thresholds are constants below, overridable via env.

Stdlib-only. Python 3.8+.

Usage:  scripts/complexity-ceiling.py [ROOT]      (default: core/lib)
Env:    MAX_CYCLOMATIC (default 20) · MAX_NESTING (default 6) · MAX_FUNC_LINES (default 120)
Exit:   0 = within ceiling · 1 = a ceiling was exceeded · 2 = usage/environment error
"""
from __future__ import annotations

import ast
import os
import sys

# Generous-but-real defaults. NOTE: core/lib still has a few monolithic main()/parser functions
# above these ceilings; the CI job runs this gate NON-BLOCKING while that debt is worked off. Once
# core/lib main()s are split into named steps, flip the CI
# step to blocking and tighten toward cyclomatic~15 / nesting~4 / length~80.
MAX_CYCLOMATIC = int(os.environ.get("MAX_CYCLOMATIC", "20"))
MAX_NESTING = int(os.environ.get("MAX_NESTING", "6"))
MAX_FUNC_LINES = int(os.environ.get("MAX_FUNC_LINES", "120"))

SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build"}

# nodes that add a decision path (cyclomatic complexity)
BRANCH = (ast.If, ast.For, ast.AsyncFor, ast.While, ast.ExceptHandler, ast.With, ast.AsyncWith,
          ast.IfExp, ast.Assert, ast.comprehension)
# nodes that open a new nesting level
NEST = (ast.If, ast.For, ast.AsyncFor, ast.While, ast.With, ast.AsyncWith, ast.Try, ast.ExceptHandler)
# a nested scope: measured as its OWN unit, so a parent must NOT absorb its complexity/lines
SCOPE = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)
DEF = (ast.FunctionDef, ast.AsyncFunctionDef)
# match/case exist only on 3.10+
_MATCH = getattr(ast, "Match", None)
_CASE = getattr(ast, "match_case", None)


def analyze(fn: ast.AST) -> tuple[int, int, int]:
    """Return (cyclomatic, max_nesting, own_lines) for fn, EXCLUDING nested function scopes.

    Nested defs/lambdas are separate units (visited on their own by the module-level walk), so their
    branches, nesting and line spans are attributed to them, not to the enclosing function. Without
    this a `main()` that defines N helper closures reports the sum of all N — a measurement artifact.
    """
    branches = 0
    max_depth = 0
    nested_span = 0

    def descend(node: ast.AST, level: int) -> None:
        nonlocal branches, max_depth, nested_span
        for child in ast.iter_child_nodes(node):
            if isinstance(child, SCOPE):
                if isinstance(child, DEF) and getattr(child, "end_lineno", None) and getattr(child, "lineno", None):
                    nested_span += child.end_lineno - child.lineno + 1
                continue                                   # do not descend into a nested scope
            if isinstance(child, BRANCH):
                branches += 1
            elif isinstance(child, ast.BoolOp):
                branches += max(1, len(child.values) - 1)  # each extra and/or is a branch
            elif _MATCH is not None and isinstance(child, _CASE):
                branches += 1
            step = 1 if isinstance(child, NEST) or (_MATCH is not None and isinstance(child, _MATCH)) else 0
            nd = level + step
            if nd > max_depth:
                max_depth = nd
            descend(child, nd)

    descend(fn, 0)
    start = getattr(fn, "lineno", None)
    end = getattr(fn, "end_lineno", None)
    own_lines = (end - start + 1 - nested_span) if (start and end) else 0
    return branches + 1, max_depth, max(0, own_lines)


def iter_py(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn.endswith(".py"):
                yield os.path.join(dirpath, fn)


def main(argv: list[str]) -> int:
    root = argv[1] if len(argv) > 1 else os.path.join("core", "lib")
    if not os.path.isdir(root):
        print(f"complexity-ceiling: no '{root}/' directory yet — nothing to check, PASS "
              f"(the engine is built by another workstream).")
        return 0

    violations: list[str] = []
    n_files = n_funcs = 0
    worst = (0, "")

    for path in iter_py(root):
        n_files += 1
        try:
            tree = ast.parse(open(path, encoding="utf-8", errors="replace").read(), filename=path)
        except SyntaxError as exc:
            violations.append(f"{path}: does not parse ({exc})")
            continue
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            n_funcs += 1
            cc, nest, length = analyze(node)
            if cc > worst[0]:
                worst = (cc, f"{path}:{node.lineno} {node.name}()")
            where = f"{path}:{node.lineno} {node.name}()"
            if cc > MAX_CYCLOMATIC:
                violations.append(f"{where}: cyclomatic {cc} > {MAX_CYCLOMATIC}")
            if nest > MAX_NESTING:
                violations.append(f"{where}: nesting depth {nest} > {MAX_NESTING}")
            if length > MAX_FUNC_LINES:
                violations.append(f"{where}: length {length} lines > {MAX_FUNC_LINES}")

    print(f"complexity-ceiling: {n_funcs} function(s) in {n_files} file(s) under {root}/  "
          f"(cyclomatic<= {MAX_CYCLOMATIC}, nesting<= {MAX_NESTING}, length<= {MAX_FUNC_LINES})")
    if worst[1]:
        print(f"  highest cyclomatic: {worst[0]} at {worst[1]}")
    if not violations:
        print("COMPLEXITY-CEILING PASS: every function is within the ceiling.")
        return 0
    print("----------------------------------------------------------------------")
    for v in violations:
        print(f"OVER-CEILING {v}", file=sys.stderr)
    print(f"COMPLEXITY-CEILING FAIL: {len(violations)} finding(s). Split the function(s), or justify "
          f"raising the ceiling in the same change.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
