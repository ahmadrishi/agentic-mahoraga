#!/usr/bin/env python3
"""oracle_extractors.py — the per-language behavioural-oracle extractors for the Mahoraga FORGE.

The extraction half of `oracle_scan.py`, split out so the engine stays under the per-file legibility
cap (the same split as `mapping_scan.py` / `mapping_extractors.py`). Each `extract_*` takes
`(rel, text)` — a repo-relative path (context only) and the test file's text — and returns a list of
`(oracle, expected, tier, lineno)` tuples, one per test found:

  * oracle   — the test name / id.
  * expected — the witnessed asserted literal / behaviour ("4200", "raises ValueError",
               "throws 'bad'"), or "—" for a STUB, or "<computed>" for a non-trivial assertion with
               no inline literal.
  * tier     — WITNESSED (a real assertion read at a file:line) or STUB (trivially-true /
               existence-only / empty). RUN and UNVERIFIED are stamped elsewhere, never here.
  * lineno   — 1-based line of the witnessed assertion (WITNESSED) or of the test decl (STUB).

This is a FLOOR: it emits ONLY what it read and NEVER infers "what a test proves". The classifier is
conservative — it errs toward STUB for the trivially-true / empty cases only, so the grounding
denominator computed by `oracle_scan` never over-counts real oracles.

Per-language extraction:
  * python — stdlib `ast`: `test*` functions + `test*` methods; asserts + unittest asserts
             (assertEqual / assertRaises / …) + `pytest.raises`; literal extraction via literal_eval.
  * ts/js  — regex over `it(...)` / `test(...)` blocks (brace-scanned bodies); jest/chai matchers.
  * java   — regex over `@Test` methods (brace-scanned bodies); JUnit assertEquals / assertThrows.
  * go     — regex over `Test*` funcs (brace-scanned bodies); testify Equal/Error + `t.Errorf`.

Stdlib only (`ast`, `re`), `py_compile`-clean, importable: `oracle_scan` re-exports these plus the
`EXTRACTORS` dispatch table so `scan_repo` (and the tests) can reach them.
"""
import ast
import re


def _trunc(s, n):
    s = str(s)
    return s if len(s) <= n else s[: n - 1] + "…"


# --------------------------------------------------------------------------------------------------
# shared: a brace-scanned block body + a first-real-signal scan (used by ts/js, java, go)
# --------------------------------------------------------------------------------------------------
def _brace_body(lines, start_idx):
    """Return (body, end_idx): the (lineno, text) lines of the block opened at/after start_idx, via
    brace counting. Handles a one-line `{}` body and a `{` on a following line."""
    depth = 0
    seen_open = False
    body = []
    i = start_idx
    while i < len(lines):
        line = lines[i]
        body.append((i + 1, line))
        opens = line.count("{")
        depth += opens - line.count("}")
        if opens:
            seen_open = True
        if seen_open and depth <= 0:
            break
        i += 1
    return body, i


def _scan_body(body, signal_fn):
    """First real signal (source order) wins -> WITNESSED at its line; else STUB at the decl line."""
    for lineno, text in body:
        sig = signal_fn(text)
        if sig is not None:
            return "WITNESSED", sig, lineno
    return "STUB", "—", (body[0][0] if body else 0)


# --------------------------------------------------------------------------------------------------
# python — stdlib ast (precise): test_* functions + Test-class methods
# --------------------------------------------------------------------------------------------------
_OPSYM = {ast.NotEq: "!=", ast.Lt: "<", ast.Gt: ">", ast.LtE: "<=", ast.GtE: ">=",
          ast.In: "in", ast.NotIn: "not in"}
_EQ_FAMILY = {
    "assertEqual", "assertEquals", "assertNotEqual", "assertIs", "assertIsNot", "assertDictEqual",
    "assertListEqual", "assertSetEqual", "assertTupleEqual", "assertMultiLineEqual",
    "assertSequenceEqual", "assertCountEqual", "assertAlmostEqual", "assertNotAlmostEqual",
    "assertGreater", "assertGreaterEqual", "assertLess", "assertLessEqual", "assertRegex",
    "assertNotRegex", "assertIn", "assertNotIn",
}
_RAISES_FAMILY = {"assertRaises", "assertRaisesRegex", "assertRaisesRegexp", "raises",
                  "assertWarns", "assertWarnsRegex"}


def _fmt_val(v):
    if isinstance(v, bool):
        return "True" if v else "False"
    if v is None:
        return "None"
    if isinstance(v, (int, float)):
        return repr(v)
    return _trunc(repr(v), 60)


def _py_lit(node):
    """Compact literal string for a pure-literal node, or None if it is not a literal."""
    try:
        return _fmt_val(ast.literal_eval(node))
    except Exception:
        return None


def _callee_name(call):
    f = call.func
    if isinstance(f, ast.Attribute):
        return f.attr
    if isinstance(f, ast.Name):
        return f.id
    return None


def _dotted(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        base = _dotted(node.value)
        return ("%s.%s" % (base, node.attr)) if base else node.attr
    return None


def _first_lit_arg(args):
    for a in args:
        lit = _py_lit(a)
        if lit is not None:
            return lit
    return None


def _py_compare_expected(cmp):
    if len(cmp.ops) != 1:
        return "<computed>"
    op = cmp.ops[0]
    ll, rl = _py_lit(cmp.left), _py_lit(cmp.comparators[0])
    if isinstance(op, (ast.Eq, ast.Is)):
        lit = rl if rl is not None else ll
        return lit if lit is not None else "<computed>"
    if isinstance(op, (ast.IsNot, ast.NotEq)) and "None" in (ll, rl):
        return None  # `x is not None` / `x != None`: existence-only, not a concrete value -> STUB (never over-count)
    sym = _OPSYM.get(type(op))
    if sym and rl is not None:
        return "%s %s" % (sym, rl)
    return rl or ll or "<computed>"


def _py_assert_expected(test):
    if isinstance(test, ast.Compare):
        return _py_compare_expected(test)
    if isinstance(test, ast.Constant):
        return None  # assert True / assert 1 — trivially true
    if isinstance(test, (ast.Name, ast.Attribute)):
        return None  # existence / truthiness only
    if isinstance(test, ast.UnaryOp) and isinstance(test.operand, ast.Constant):
        return None
    return "<computed>"  # a call / boolop / other non-trivial assertion


def _py_call_expected(call):
    name = _callee_name(call)
    if name in _EQ_FAMILY:
        return _first_lit_arg(call.args[:2]) or "<computed>"
    if name in _RAISES_FAMILY:
        exc = _dotted(call.args[0]) if call.args else None
        return "raises %s" % exc if exc else "raises"
    if name in ("assertTrue", "assertFalse"):
        if call.args and isinstance(call.args[0], ast.Compare):
            return _py_compare_expected(call.args[0])
        return None  # assertTrue(True) trivial / assertTrue(x) existence
    return None


def _py_test_oracle(func):
    signals = []
    for node in ast.walk(func):
        if isinstance(node, ast.Assert):
            exp = _py_assert_expected(node.test)
        elif isinstance(node, ast.Call):
            exp = _py_call_expected(node)
        else:
            continue
        if exp is not None:
            signals.append((node.lineno, node.col_offset, exp))
    if signals:
        signals.sort()
        return (func.name, signals[0][2], "WITNESSED", signals[0][0])
    return (func.name, "—", "STUB", func.lineno)


def extract_python(rel, text):
    """Return [(oracle, expected, tier, line)] for a Python test file (via ast)."""
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError):
        return []
    out = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test"):
            out.append(_py_test_oracle(node))
        elif isinstance(node, ast.ClassDef):
            for sub in node.body:
                if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)) and \
                        sub.name.startswith("test"):
                    out.append(_py_test_oracle(sub))
    return out


# --------------------------------------------------------------------------------------------------
# javascript / typescript — regex over it()/test() blocks (brace-scanned bodies)
# --------------------------------------------------------------------------------------------------
_JS_TEST = re.compile(r"""\b(?:it|test)(?:\.\w+)?\s*\(\s*(['"`])(.*?)\1""")
_JS_LIT = re.compile(
    r"\s*(-?\d+(?:\.\d+)?|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`[^`]*`|true|false|null|\[|\{)")
_JS_EQ = re.compile(
    r"\.(?:toBe|toEqual|toStrictEqual|toContain|toContainEqual|toMatchObject|toHaveLength|"
    r"toBeCloseTo|toBeGreaterThan|toBeGreaterThanOrEqual|toBeLessThan|toBeLessThanOrEqual|"
    r"toHaveBeenCalledWith)\s*\(([^)]*)")
_JS_ASSERTLIB = re.compile(
    r"\b(?:assert|expect)\b.*?\.(?:strictEqual|deepStrictEqual|deepEqual|eql|equal)\s*\(([^)]*)")
_JS_THROW = re.compile(r"\.(?:rejects\.)?(?:toThrow|toThrowError)\s*\(([^)]*)")
_JS_TOK = re.compile(
    r"(-?\d+(?:\.\d+)?|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`[^`]*`|[A-Za-z_$][\w$.]*)")


def _js_lit(s):
    m = _JS_LIT.match(s)
    if not m:
        return "<computed>"
    tok = m.group(1)
    return {"[": "[...]", "{": "{...}"}.get(tok, tok)


def _js_signal(text):
    m = _JS_THROW.search(text)
    if m:
        tok = _JS_TOK.match(m.group(1).strip())
        return "throws %s" % tok.group(1) if tok else "throws"
    for rx in (_JS_EQ, _JS_ASSERTLIB):
        m = rx.search(text)
        if m:
            return _js_lit(m.group(1))
    return None  # existence-only (toBeTruthy/toBeDefined/...) or no assertion


def extract_ts_js(rel, text):
    lines = text.split("\n")
    out = []
    i, n = 0, len(lines)
    while i < n:
        m = _JS_TEST.search(lines[i])
        if m:
            body, end = _brace_body(lines, i)
            tier, exp, ln = _scan_body(body, _js_signal)
            out.append((m.group(2), exp, tier, ln))
            i = end + 1
            continue
        i += 1
    return out


# --------------------------------------------------------------------------------------------------
# java — regex over @Test methods (brace-scanned bodies)
# --------------------------------------------------------------------------------------------------
_JAVA_ANNO = re.compile(r"^\s*@Test\b")
_JAVA_NAME = re.compile(r"([A-Za-z_$][\w$]*)\s*\(")
_JAVA_CTRL = {"if", "for", "while", "switch", "catch", "synchronized", "return", "new"}
_JAVA_LIT = re.compile(
    r"(-?\d+(?:\.\d+)?[LlFfDd]?|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|true|false|null)")
_JAVA_EQCALL = re.compile(
    r"\b(?:assertEquals|assertArrayEquals|assertSame|assertThat|assertIterableEquals|"
    r"assertLinesMatch)\s*\(")
_JAVA_THROWS = re.compile(r"\bassertThrows\s*\(\s*([A-Za-z_$][\w$.]*)\.class")


def _first_lit(rx, s):
    m = rx.search(s)
    return m.group(1) if m else None


def _java_mname(line):
    m = _JAVA_NAME.search(line)
    if not m or m.group(1) in _JAVA_CTRL:
        return None
    return m.group(1)


def _java_signal(text):
    m = _JAVA_THROWS.search(text)
    if m:
        return "throws %s" % m.group(1)
    if _JAVA_EQCALL.search(text):
        return _first_lit(_JAVA_LIT, text) or "<computed>"
    return None


def extract_java(rel, text):
    lines = text.split("\n")
    out = []
    i, n = 0, len(lines)
    while i < n:
        if _JAVA_ANNO.search(lines[i]):
            j = i + 1
            while j < n and (not lines[j].strip() or lines[j].lstrip().startswith("@")):
                j += 1
            name = _java_mname(lines[j]) if j < n else None
            if name:
                body, end = _brace_body(lines, j)
                tier, exp, ln = _scan_body(body, _java_signal)
                out.append((name, exp, tier, ln))
                i = end + 1
                continue
        i += 1
    return out


# --------------------------------------------------------------------------------------------------
# go — regex over Test* functions (brace-scanned bodies)
# --------------------------------------------------------------------------------------------------
_GO_TEST = re.compile(r"^\s*func\s+(Test[A-Za-z0-9_]*)\s*\(")
_GO_LIT = re.compile(r"(-?\d+(?:\.\d+)?|\"(?:[^\"\\]|\\.)*\"|`[^`]*`|true|false|nil)")
_GO_EQ = re.compile(r"\b(?:assert|require)\.(?:Equal|EqualValues|Exactly|JSONEq)\s*\(")
_GO_ERR = re.compile(r"\b(?:assert|require)\.(?:Error|EqualError|ErrorContains|ErrorIs)\b")
_GO_TFAIL = re.compile(r"\bt\.(?:Errorf|Error|Fatalf|Fatal)\b")


def _go_signal(text):
    if _GO_ERR.search(text):
        return "returns error"
    m = _GO_EQ.search(text)
    if m:
        return _first_lit(_GO_LIT, text[m.end():]) or "<computed>"
    if _GO_TFAIL.search(text):
        return "<computed>"  # a real failing check; the expected lives in a `want` var, not inline
    return None


def extract_go(rel, text):
    lines = text.split("\n")
    out = []
    i, n = 0, len(lines)
    while i < n:
        m = _GO_TEST.search(lines[i])
        if m:
            body, end = _brace_body(lines, i)
            tier, exp, ln = _scan_body(body, _go_signal)
            out.append((m.group(1), exp, tier, ln))
            i = end + 1
            continue
        i += 1
    return out


# Dispatch table: language -> extractor. `scan_repo` looks a language up here.
EXTRACTORS = {
    "python": extract_python, "typescript": extract_ts_js, "javascript": extract_ts_js,
    "java": extract_java, "go": extract_go,
}
