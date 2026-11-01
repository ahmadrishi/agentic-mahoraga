#!/usr/bin/env python3
"""check-deps-allowlist.py — fail if the core imports a dependency outside deps-allowlist.txt.

The core is under a hard dependency budget: the ONLY third-party thing it may import is
what is listed in deps-allowlist.txt (Python: PyYAML; Node: none). This checker walks the scanned
roots, extracts every import, and flags any that is neither a standard-library module, a first-party
(in-repo/relative) module, nor an allow-listed third-party name.

Stdlib-only (no third-party imports of its own). Python 3.8+.

Usage:  scripts/check-deps-allowlist.py [ROOT ...]
        (default roots: core, scripts — the budgeted engine plus this repo's own tooling)
Exit:   0 = clean · 1 = a disallowed import was found · 2 = usage/environment error
"""
from __future__ import annotations

import ast
import os
import re
import sys

# --- known Node built-in modules (so `require('fs')` etc. are allowed; only npm deps are flagged) ---
NODE_BUILTINS = {
    "assert", "async_hooks", "buffer", "child_process", "cluster", "console", "constants",
    "crypto", "dgram", "diagnostics_channel", "dns", "domain", "events", "fs", "http", "http2",
    "https", "inspector", "module", "net", "os", "path", "perf_hooks", "process", "punycode",
    "querystring", "readline", "repl", "stream", "string_decoder", "sys", "timers", "tls",
    "trace_events", "tty", "url", "util", "v8", "vm", "wasi", "worker_threads", "zlib", "test",
}

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def stdlib_names() -> set[str]:
    """Authoritative on 3.10+ via sys.stdlib_module_names; a conservative fallback below that."""
    names = set(getattr(sys, "stdlib_module_names", set()))
    if names:
        return set(names)
    return {
        "__future__", "abc", "argparse", "ast", "asyncio", "base64", "bisect", "collections",
        "configparser", "contextlib", "copy", "csv", "dataclasses", "datetime", "decimal",
        "difflib", "enum", "errno", "fnmatch", "functools", "glob", "gzip", "hashlib", "heapq",
        "hmac", "html", "http", "importlib", "inspect", "io", "ipaddress", "itertools", "json",
        "logging", "math", "mimetypes", "multiprocessing", "operator", "os", "pathlib", "pickle",
        "platform", "pprint", "queue", "random", "re", "secrets", "shlex", "shutil", "signal",
        "socket", "sqlite3", "ssl", "stat", "string", "struct", "subprocess", "sys", "tarfile",
        "tempfile", "textwrap", "threading", "time", "traceback", "types", "typing", "unicodedata",
        "unittest", "urllib", "uuid", "warnings", "weakref", "xml", "zipfile", "zlib",
    }


def parse_allowlist(path: str) -> tuple[set[str], set[str]]:
    """Return (python_import_names, node_import_names) from deps-allowlist.txt."""
    py: set[str] = set()
    node: set[str] = set()
    section = None
    if not os.path.exists(path):
        print(f"check-deps: allowlist not found at {path}", file=sys.stderr)
        sys.exit(2)
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            low = line.lower()
            if low == "[python]":
                section = py
                continue
            if low == "[node]":
                section = node
                continue
            if section is not None:
                section.add(line.split()[0])
    return py, node


_FP_SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build"}


def first_party_python(roots: list[str]) -> set[str]:
    """Top-level import names satisfiable by an in-repo (first-party) module or package.

    A bare `import X` / `from X import ...` is FIRST-PARTY when a module file `X.py` OR a package
    `X/__init__.py` exists anywhere under the repo — an in-repo sibling module is always allowed
    (deps-allowlist.txt documents this). So we build the set of in-repo python module basenames by
    walking the repo (plus the scanned roots) recursively: every `.py` file contributes its basename,
    and every directory holding an `__init__.py` contributes its package name. A genuinely third-party
    import (no matching in-repo file) is still not first-party and stays subject to the allowlist."""
    names: set[str] = set()
    bases = [REPO_ROOT]
    for r in roots:
        bases.append(r if os.path.isabs(r) else os.path.join(REPO_ROOT, r))
    for base in bases:
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in _FP_SKIP_DIRS]
            for fn in filenames:
                if fn.endswith(".py"):
                    names.add(fn[:-3])
            for d in dirnames:
                if os.path.isfile(os.path.join(dirpath, d, "__init__.py")):
                    names.add(d)
    return names


def iter_files(roots: list[str], exts: tuple[str, ...]):
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in
                           {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build"}]
            for fn in filenames:
                if fn.endswith(exts):
                    yield os.path.join(dirpath, fn)


def python_imports(path: str) -> set[str]:
    try:
        tree = ast.parse(open(path, encoding="utf-8", errors="replace").read(), filename=path)
    except SyntaxError as exc:
        print(f"check-deps: {path}: syntax error ({exc}) — skipped", file=sys.stderr)
        return set()
    out: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                out.add(a.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            if node.level and node.level > 0:      # relative import => first-party, always allowed
                continue
            if node.module:
                out.add(node.module.split(".")[0])
    return out


NODE_IMPORT_RE = re.compile(
    r"""(?:require\(\s*|import\s+(?:[^'"]*\s+from\s+)?)['"]([^'"]+)['"]""")


def node_imports(path: str) -> set[str]:
    out: set[str] = set()
    for m in NODE_IMPORT_RE.finditer(open(path, encoding="utf-8", errors="replace").read()):
        spec = m.group(1)
        if spec.startswith(".") or spec.startswith("/"):
            continue                                  # relative/absolute => first-party
        if spec.startswith("node:"):
            spec = spec[len("node:"):]
        top = spec.split("/")[0] if not spec.startswith("@") else "/".join(spec.split("/")[:2])
        out.add(top)
    return out


def main(argv: list[str]) -> int:
    roots = argv[1:] or ["core", "scripts"]
    roots = [r for r in roots]
    py_allow, node_allow = parse_allowlist(os.path.join(REPO_ROOT, "deps-allowlist.txt"))
    std = stdlib_names()
    local = first_party_python(roots)

    violations: list[str] = []
    n_py = n_node = 0

    for f in iter_files(roots, (".py",)):
        n_py += 1
        for name in sorted(python_imports(f)):
            if name in std or name in local or name in py_allow:
                continue
            violations.append(f"{f}: python import '{name}' is not stdlib, not first-party, "
                              f"and not in deps-allowlist.txt [python]")

    for f in iter_files(roots, (".js", ".mjs", ".cjs")):
        n_node += 1
        for name in sorted(node_imports(f)):
            if name in NODE_BUILTINS or name in node_allow:
                continue
            violations.append(f"{f}: node import '{name}' is not a built-in "
                              f"and not in deps-allowlist.txt [node]")

    print(f"check-deps: scanned {n_py} python file(s), {n_node} node file(s) under {roots}")
    if not violations:
        print("DEPS-ALLOWLIST PASS: every import is stdlib/built-in, first-party, or allow-listed.")
        return 0
    print("----------------------------------------------------------------------")
    for v in violations:
        print(f"DISALLOWED-DEP {v}", file=sys.stderr)
    print(f"DEPS-ALLOWLIST FAIL: {len(violations)} disallowed import(s). Add the dependency to "
          f"deps-allowlist.txt (with justification) in the same change, or drop the import.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
