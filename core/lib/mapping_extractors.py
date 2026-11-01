#!/usr/bin/env python3
"""mapping_extractors.py — the per-language definition extractors for the Mahoraga mapping FORGE.

The extraction half of `mapping_scan.py`, split out so the engine stays under the per-file legibility
cap. Each `extract_*` takes `(rel, text)` — a repo-relative path (for context only) and the file's
text — and returns a list of `(name, kind, lineno)` tuples for every defined system noun (class /
function / method / constant / enum / enum-member / type / interface …) with a 1-based line number.

Per-language extraction:
  * python      — stdlib `ast` (precise line numbers): top-level + class-level ClassDef /
                  FunctionDef / AsyncFunctionDef, module-level UPPER_CASE assignments (constants),
                  and Enum members (a class whose bases include Enum/IntEnum/StrEnum/Flag → its
                  member assignments). A SyntaxError propagates; the scanner skips + reports it.
  * typescript/ — regex: `export (class|function|const|interface|type|enum) <Name>` (+ default
    javascript    exports), plus members inside an exported enum.
  * java        — regex: public/protected class|interface|enum declarations, public method
                  signatures, and enum constants.
  * go          — regex: `func (recv) <Name>`, `type <Name> struct|interface`, exported
                  (Capitalized) const/var (single and grouped blocks).
  * fallback    — a keyword-filtered definition grep (def/fun/class/type/enum/…), run only behind
                  mapping_scan --allow-generic over the language's own extensions; low precision.

Stdlib only (`ast`, `re`), `py_compile`-clean, and importable: `mapping_scan` re-exports these plus
the `EXTRACTORS` dispatch table so `scan_repo` (and the tests) can reach them.
"""
import ast
import re


# --------------------------------------------------------------------------------------------------
# python — stdlib ast (precise line numbers)
# --------------------------------------------------------------------------------------------------
_PY_ENUM_BASES = {"Enum", "IntEnum", "StrEnum", "IntFlag", "Flag", "ReprEnum"}


def _py_is_upper_const(name):
    return len(name) >= 2 and name.isupper() and re.fullmatch(r"[A-Z_][A-Z0-9_]*", name) is not None


def _py_name_targets(target):
    """[(name, lineno)] for an assignment target — each Name's OWN line, so a multi-line unpacking
    (`(\n  A,\n  B,\n) = ...`) cites the line the name is on, not the statement's opening paren."""
    if isinstance(target, ast.Name):
        return [(target.id, target.lineno)]
    if isinstance(target, (ast.Tuple, ast.List)):
        return [(e.id, e.lineno) for e in target.elts if isinstance(e, ast.Name)]
    return []


def extract_python(rel, text):
    """Return [(name, kind, lineno)] for a Python source file. A syntax error propagates: the scanner
    skips and reports the file rather than mapping it with a low-precision fallback."""
    tree = ast.parse(text)

    out = []

    def base_names(cls):
        names = set()
        for b in cls.bases:
            if isinstance(b, ast.Name):
                names.add(b.id)
            elif isinstance(b, ast.Attribute):
                names.add(b.attr)
        return names

    def handle_class(cls):
        is_enum = bool(base_names(cls) & _PY_ENUM_BASES)
        out.append((cls.name, "enum" if is_enum else "class", cls.lineno))
        for node in cls.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                out.append((node.name, "method", node.lineno))
            elif isinstance(node, ast.ClassDef):
                handle_class(node)
            elif is_enum and isinstance(node, ast.Assign):
                for t in node.targets:
                    for nm, ln in _py_name_targets(t):
                        if not nm.startswith("_"):
                            out.append((nm, "enum-member", ln))
            elif is_enum and isinstance(node, ast.AnnAssign) and node.value is not None:
                if isinstance(node.target, ast.Name) and not node.target.id.startswith("_"):
                    out.append((node.target.id, "enum-member", node.lineno))

    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            handle_class(node)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            out.append((node.name, "function", node.lineno))
        elif isinstance(node, ast.Assign):
            for t in node.targets:
                for nm, ln in _py_name_targets(t):
                    if _py_is_upper_const(nm):
                        out.append((nm, "constant", ln))
        elif isinstance(node, ast.AnnAssign) and node.value is not None:
            if isinstance(node.target, ast.Name) and _py_is_upper_const(node.target.id):
                out.append((node.target.id, "constant", node.lineno))
    return out


# --------------------------------------------------------------------------------------------------
# typescript / javascript — regex over exported declarations
# --------------------------------------------------------------------------------------------------
_TS_KIND = {
    "class": "class", "function": "function", "const": "constant",
    "interface": "interface", "type": "type", "enum": "enum",
}
_TS_DECL = re.compile(
    r"^\s*export\s+(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?"
    r"(class|function|const\s+enum|const|interface|type|enum)\s+([A-Za-z_$][\w$]*)"
)
_TS_ENUM_MEMBER = re.compile(r"^\s*([A-Za-z_$][\w$]*)\s*(?:=|,|\s|$)")


def extract_ts_js(rel, text):
    """Return [(name, kind, lineno)] for a TS/JS source file via export-declaration regexes, plus
    members inside an exported enum (a small brace-depth state machine)."""
    out = []
    in_enum = False
    depth = 0
    for idx, line in enumerate(text.split("\n"), start=1):
        if in_enum:
            depth += line.count("{") - line.count("}")
            m = _TS_ENUM_MEMBER.match(line)
            if m:
                out.append((m.group(1), "enum-member", idx))
            if depth <= 0:
                in_enum = False
            continue
        dm = _TS_DECL.match(line)
        if dm:
            kw, name = dm.group(1).split()[-1], dm.group(2)  # `const enum` is an enum
            out.append((name, _TS_KIND[kw], idx))
            if kw == "enum":
                depth = line.count("{") - line.count("}")
                if line.count("{") > 0 and depth > 0:
                    in_enum = True
    return out


# --------------------------------------------------------------------------------------------------
# java — regex over public/protected type & method declarations + enum constants
# --------------------------------------------------------------------------------------------------
_JAVA_TYPE = re.compile(r"^\s*(?:public|protected)\b[^;{]*\b(class|interface|enum)\s+([A-Za-z_$][\w$]*)")
# Everything between the access modifier and the FIRST '(' (no '=', ';', or paren in between, so a
# field initializer is rejected); the method name is the last identifier in that segment.
_JAVA_METHOD = re.compile(r"^\s*(?:public|protected)\b([^=;(){}]*)\(")
_JAVA_IDENT = re.compile(r"[A-Za-z_$][\w$]*")
_JAVA_ENUM_CONST = re.compile(r"^\s*([A-Z][A-Z0-9_]+)\s*(?:\([^)]*\))?\s*(?:,|;|$)")


def _java_method_name(line):
    """The method name declared on a public/protected line (the identifier just before the first
    '('), or None if the line is not a method declaration."""
    m = _JAVA_METHOD.match(line)
    if not m:
        return None
    idents = _JAVA_IDENT.findall(m.group(1))
    return idents[-1] if idents else None


def extract_java(rel, text):
    """Return [(name, kind, lineno)] for a Java source file."""
    out = []
    in_enum = False
    depth = 0
    seen_semi = False
    for idx, line in enumerate(text.split("\n"), start=1):
        if in_enum:
            depth += line.count("{") - line.count("}")
            if not seen_semi:
                m = _JAVA_ENUM_CONST.match(line)
                if m:
                    out.append((m.group(1), "enum-member", idx))
                if ";" in line:
                    seen_semi = True
            elif not _JAVA_TYPE.match(line):
                nm = _java_method_name(line)
                if nm:
                    out.append((nm, "method", idx))
            if depth <= 0:
                in_enum = False
            continue
        tm = _JAVA_TYPE.match(line)
        if tm:
            out.append((tm.group(2), tm.group(1), idx))
            if tm.group(1) == "enum":
                depth = line.count("{") - line.count("}")
                if line.count("{") > 0 and depth > 0:
                    in_enum = True
                    seen_semi = False
            continue
        nm = _java_method_name(line)
        if nm:
            out.append((nm, "method", idx))
    return out


# --------------------------------------------------------------------------------------------------
# go — regex over func / type / exported const|var
# --------------------------------------------------------------------------------------------------
_GO_FUNC = re.compile(r"^\s*func\s+(\([^)]*\)\s*)?([A-Za-z_]\w*)\s*\(")
_GO_TYPE = re.compile(r"^\s*type\s+([A-Za-z_]\w*)\s+(struct|interface)\b")
_GO_TYPE_OTHER = re.compile(r"^\s*type\s+([A-Za-z_]\w*)\s+\S")
_GO_CONSTVAR = re.compile(r"^\s*(const|var)\s+([A-Z]\w*)\b")
_GO_BLOCK = re.compile(r"^\s*(const|var)\s*\(\s*$")
_GO_BLOCK_ITEM = re.compile(r"^\s*([A-Z]\w*)\b")
_GO_BLOCK_END = re.compile(r"^\s*\)")


def extract_go(rel, text):
    """Return [(name, kind, lineno)] for a Go source file."""
    out = []
    block_kind = None  # None, or "constant"/"variable" while inside a const(/var( ... ) block
    for idx, line in enumerate(text.split("\n"), start=1):
        if block_kind is not None:
            if _GO_BLOCK_END.match(line):
                block_kind = None
                continue
            bm = _GO_BLOCK_ITEM.match(line)
            if bm:
                out.append((bm.group(1), block_kind, idx))
            continue
        fm = _GO_FUNC.match(line)
        if fm:
            out.append((fm.group(2), "method" if fm.group(1) else "function", idx))
            continue
        tm = _GO_TYPE.match(line)
        if tm:
            out.append((tm.group(1), "interface" if tm.group(2) == "interface" else "type", idx))
            continue
        tmo = _GO_TYPE_OTHER.match(line)
        if tmo:
            out.append((tmo.group(1), "type", idx))
            continue
        bo = _GO_BLOCK.match(line)
        if bo:
            block_kind = "constant" if bo.group(1) == "const" else "variable"
            continue
        cv = _GO_CONSTVAR.match(line)
        if cv:
            out.append((cv.group(2), "constant" if cv.group(1) == "const" else "variable", idx))
    return out


# --------------------------------------------------------------------------------------------------
# generic fallback — keyword-filtered definition grep (only behind mapping_scan --allow-generic)
# --------------------------------------------------------------------------------------------------
_GEN_KEYS = {
    "def": "function", "fun": "function", "function": "function", "func": "function", "fn": "function",
    "sub": "function", "class": "class", "object": "class", "interface": "interface",
    "trait": "interface", "type": "type", "struct": "type", "enum": "enum", "module": "type",
    "const": "constant", "val": "constant", "let": "variable", "var": "variable",
}
# A chain of keywords ("enum class", "const val") then a name that is NOT itself a keyword; the kind
# comes from the chain's first keyword. `package`/namespace lines are deliberately not definitions.
# Modifiers and primitive types that may sit inside the chain (`let mut x`, `const int Max`,
# `def self.open`) — skipped, never emitted as the name.
_GEN_MODS = ("mut|self|static|final|readonly|lateinit|inline|extern|volatile|unsigned|signed|int|long|"
             "short|char|float|double|bool|string|void")
_GEN_KW = "|".join(sorted(_GEN_KEYS, key=len, reverse=True))
_GEN = re.compile(r"\b((?:(?:%s|%s)(?:\s+|\.))*(?:%s)\s+(?:(?:%s)(?:\s+|\.))*)(?!(?:%s|%s)\b)([A-Za-z_][A-Za-z0-9_]*)"
                  % (_GEN_KW, _GEN_MODS, _GEN_KW, _GEN_MODS, _GEN_KW, _GEN_MODS))
_GEN_CONST = re.compile(r"^\s*([A-Z][A-Z0-9_]{2,})\s*[:=]")


def extract_generic(rel, text):
    """Return [(name, kind, lineno)] for a language with no extractor: a best-effort, keyword-filtered
    definition grep — low precision by design, so every row must be audited."""
    out = []
    for idx, line in enumerate(text.split("\n"), start=1):
        if len(line) > 2000:  # minified / generated: skip (and bound the regex's backtracking)
            continue
        m = _GEN.search(line)
        if m:
            kw = next(w for w in re.split(r"[\s.]+", m.group(1)) if w in _GEN_KEYS)
            out.append((m.group(2), _GEN_KEYS[kw], idx))
        cm = _GEN_CONST.match(line)
        if cm:
            out.append((cm.group(1), "constant", idx))
    return out


# Dispatch table: language -> extractor. `scan_repo` looks a language up here; a language with no
# entry falls through to `extract_generic` (the CLI allows that only with --allow-generic).
EXTRACTORS = {
    "python": extract_python,
    "typescript": extract_ts_js,
    "javascript": extract_ts_js,
    "java": extract_java,
    "go": extract_go,
}
