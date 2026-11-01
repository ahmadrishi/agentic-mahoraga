#!/usr/bin/env bash
# tests/guard_hooks_test.sh — the GUARD-pack hook SCRIPTS behave per the contract.
#
# Exercises the two Claude Code hook scripts DIRECTLY by piping crafted stdin JSON — the exact shape
# Claude Code feeds a hook: { session_id, cwd, hook_event_name, tool_name, tool_use_id, tool_input }.
# For Write, tool_input = { file_path, content }; for Edit, { file_path, old_string, new_string }.
#
#   hooks/small-diff-gate.sh  (PreToolUse, Write|Edit) — the ONE enforceable GUARD row:
#     * BLOCK mode + an Edit whose new_string exceeds the cap        -> exit 2 (blocked) + stderr note
#     * BLOCK mode + a small Edit                                    -> exit 0 (allowed)
#     * BLOCK mode + a NEW-file Write of many lines                  -> exit 0 (creating a file != sprawl)
#     * BLOCK mode + an OVERWRITE Write of an existing file, > cap   -> exit 2 (blocked)
#     * malformed stdin                                              -> exit 0 (fail-open, never wedge)
#     * WARN mode + the same over-cap Edit                           -> exit 0 (warns, does not block)
#
#   hooks/verify-after-edit.sh (PostToolUse, Write|Edit) — SURFACES, cannot block (docs: PostToolUse
#   exit 2 is ignored). So EVERY case exits 0; the verdict is asserted on stderr:
#     * a .py with a syntax error   -> surfaces a failure on stderr, but exit 0 (honest: can't block)
#     * a clean .py                 -> exit 0, no SyntaxError surfaced
#     * a .ts (no fast offline check) -> prints UNVERIFIED, exit 0
#     * a clean .sh                 -> exit 0
#     * malformed stdin             -> exit 0 (fail-open)
#
# Asserts exit codes AND key stderr strings. Threshold/mode are pinned via the contract's env vars
# (MAHORAGA_MAX_EDIT_LINES / MAHORAGA_SMALL_DIFF_MODE) so the test is fast and independent of defaults.
#
# Hermetic: own temp dir, cleaned up on exit; touches no repo files. Needs only bash + python3 (no jq —
# JSON is built with python3 stdlib, matching the deps allowlist). Depends on: hooks/** —
# authored against the documented contract.
#
# Run from the repo root:  bash tests/guard_hooks_test.sh   (exit 0 = pass, non-zero = failure)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_DIR="$ROOT/hooks"
SMALL_DIFF="$HOOK_DIR/small-diff-gate.sh"
VERIFY="$HOOK_DIR/verify-after-edit.sh"
HOOKS_JSON="$HOOK_DIR/hooks.json"

fail() { printf 'GUARD-HOOKS FAIL: %b\n' "$*" >&2; exit 1; }
ok()   { printf '  ok: %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

# ---- required upstream artifacts --------------------
[ -f "$SMALL_DIFF" ]  || fail "missing $SMALL_DIFF"
[ -f "$VERIFY" ]      || fail "missing $VERIFY"
[ -f "$HOOKS_JSON" ]  || fail "missing $HOOKS_JSON"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$ROOT"   # harmless; the scripts are invoked by path here

# ---- helpers -------------------------------------------------------------------------------------
# mk_lines N -> prints N lines to stdout (used as an over-/under-cap change body).
mk_lines() { local n="$1" i; for ((i=1; i<=n; i++)); do printf 'content line %d\n' "$i"; done; }

# mkpayload -> emits the hook stdin JSON to stdout, driven entirely by env (no jq; python3 stdlib):
#   EVENT (hook_event_name), TOOL (Write|Edit), FILE_PATH; for Write PAYLOAD=content,
#   for Edit PAYLOAD=new_string and OLD=old_string.
mkpayload() {
  python3 - <<'PY'
import json, os, sys
tool = os.environ["TOOL"]
ti = {"file_path": os.environ["FILE_PATH"]}
if tool == "Write":
    ti["content"] = os.environ.get("PAYLOAD", "")
else:  # Edit
    ti["old_string"] = os.environ.get("OLD", "")
    ti["new_string"] = os.environ.get("PAYLOAD", "")
obj = {
    "session_id": "guard-hooks-test",
    "cwd": os.getcwd(),
    "hook_event_name": os.environ["EVENT"],
    "tool_name": tool,
    "tool_use_id": "tu-test",
    "tool_input": ti,
}
sys.stdout.write(json.dumps(obj))
PY
}

J="$TMP/payload.json"          # rebuilt per case
BLOCK_RE='surgical|MAHORAGA_SMALL_DIFF_MODE|> *cap|split|exceed|too (big|large)'

CAP=10
export MAHORAGA_MAX_EDIT_LINES="$CAP"

# =================================================================================================
# small-diff-gate.sh — PreToolUse (Write|Edit)
# =================================================================================================
step "small-diff-gate: BLOCK mode (cap=$CAP)"
export MAHORAGA_SMALL_DIFF_MODE=block

# (A) over-cap Edit -> exit 2 + block note on stderr
EXISTING="$TMP/existing.py"; printf 'x = 0\n' > "$EXISTING"
EVENT=PreToolUse TOOL=Edit FILE_PATH="$EXISTING" OLD="x = 0" PAYLOAD="$(mk_lines 20)" mkpayload > "$J"
OUT="$(bash "$SMALL_DIFF" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "(A) over-cap Edit: expected exit 2 (blocked), got $RC\n$OUT"
printf '%s\n' "$OUT" | grep -iqE "$BLOCK_RE" \
  || fail "(A) over-cap Edit: exit 2 but no recognizable block note on stderr:\n$OUT"
ok "over-cap Edit blocked (exit 2, block note surfaced)"

# (B) small Edit -> exit 0
EVENT=PreToolUse TOOL=Edit FILE_PATH="$EXISTING" OLD="x = 0" PAYLOAD="$(mk_lines 3)" mkpayload > "$J"
OUT="$(bash "$SMALL_DIFF" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(B) small Edit: expected exit 0 (allowed), got $RC\n$OUT"
ok "small Edit allowed (exit 0)"

# (C) NEW-file Write of many lines -> exit 0 (creating a file is not drive-by sprawl)
NEWFILE="$TMP/brand_new_$$.py"; rm -f "$NEWFILE"; [ ! -e "$NEWFILE" ] || fail "(C) setup: $NEWFILE exists"
EVENT=PreToolUse TOOL=Write FILE_PATH="$NEWFILE" PAYLOAD="$(mk_lines 50)" mkpayload > "$J"
OUT="$(bash "$SMALL_DIFF" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(C) NEW-file Write (50 lines): expected exit 0 (allowed), got $RC\n$OUT"
ok "NEW-file Write of many lines allowed (exit 0)"

# (D) OVERWRITE Write of an EXISTING file, over cap -> exit 2 (overwrite counts as a big change)
OVERW="$TMP/overwrite.py"; printf 'old = 1\n' > "$OVERW"
EVENT=PreToolUse TOOL=Write FILE_PATH="$OVERW" PAYLOAD="$(mk_lines 20)" mkpayload > "$J"
OUT="$(bash "$SMALL_DIFF" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "(D) overwrite Write (20 lines, existing): expected exit 2 (blocked), got $RC\n$OUT"
printf '%s\n' "$OUT" | grep -iqE "$BLOCK_RE" \
  || fail "(D) overwrite Write: exit 2 but no recognizable block note:\n$OUT"
ok "over-cap overwrite of existing file blocked (exit 2)"

# (E) malformed stdin -> exit 0 (fail-open: a hook must never wedge the session)
printf 'this is not json {{{ ][' > "$J"
OUT="$(bash "$SMALL_DIFF" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(E) malformed stdin: expected exit 0 (fail-open), got $RC\n$OUT"
ok "malformed stdin fails open (exit 0)"

step "small-diff-gate: WARN mode (default) does NOT block"
export MAHORAGA_SMALL_DIFF_MODE=warn
# (F) same over-cap Edit as (A), but in warn mode -> exit 0 (warns, does not block)
EVENT=PreToolUse TOOL=Edit FILE_PATH="$EXISTING" OLD="x = 0" PAYLOAD="$(mk_lines 20)" mkpayload > "$J"
OUT="$(bash "$SMALL_DIFF" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(F) warn mode over-cap Edit: expected exit 0 (warn, not block), got $RC\n$OUT"
[ -n "$OUT" ]   || fail "(F) warn mode over-cap Edit: expected a warn note on output, got nothing"
ok "warn mode over-cap Edit warns but does not block (exit 0, note surfaced)"
unset MAHORAGA_SMALL_DIFF_MODE

# =================================================================================================
# verify-after-edit.sh — PostToolUse (Write|Edit): SURFACES only, ALWAYS exit 0 (cannot block)
# =================================================================================================
step "verify-after-edit: surfaces a verdict, never blocks (always exit 0)"

# (G) a .py with a syntax error -> failure surfaced on stderr, but exit 0
BADPY="$TMP/broken.py"; printf 'def oops(:\n    return\n' > "$BADPY"
EVENT=PostToolUse TOOL=Write FILE_PATH="$BADPY" PAYLOAD="$(cat "$BADPY")" mkpayload > "$J"
OUT="$(bash "$VERIFY" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(G) broken .py: PostToolUse cannot block — expected exit 0, got $RC\n$OUT"
printf '%s\n' "$OUT" | grep -iqE 'fail|error|invalid|syntax' \
  || fail "(G) broken .py: expected a surfaced failure on stderr, got:\n$OUT"
ok "broken .py surfaces a failure but exits 0 (honest: can't block)"

# (H) a clean .py -> exit 0, no SyntaxError surfaced
GOODPY="$TMP/clean.py"; printf 'x = 1\nprint(x)\n' > "$GOODPY"
EVENT=PostToolUse TOOL=Write FILE_PATH="$GOODPY" PAYLOAD="$(cat "$GOODPY")" mkpayload > "$J"
OUT="$(bash "$VERIFY" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(H) clean .py: expected exit 0, got $RC\n$OUT"
printf '%s\n' "$OUT" | grep -iqE 'syntaxerror|traceback' \
  && fail "(H) clean .py: unexpected syntax failure surfaced:\n$OUT"
ok "clean .py verifies cleanly (exit 0, no failure surfaced)"

# (I) a .ts (no fast offline check) -> prints UNVERIFIED, exit 0
TSFILE="$TMP/widget.ts"; printf 'const n: number = 1;\nexport default n;\n' > "$TSFILE"
EVENT=PostToolUse TOOL=Write FILE_PATH="$TSFILE" PAYLOAD="$(cat "$TSFILE")" mkpayload > "$J"
OUT="$(bash "$VERIFY" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(I) .ts: expected exit 0, got $RC\n$OUT"
printf '%s\n' "$OUT" | grep -q 'UNVERIFIED' \
  || fail "(I) .ts: expected UNVERIFIED on output, got:\n$OUT"
ok ".ts prints UNVERIFIED, exits 0"

# (J) a clean .sh -> exit 0 (bonus: exercises a second fast check without over-coupling to the branch)
SHFILE="$TMP/hello.sh"; printf '#!/usr/bin/env bash\necho hi\n' > "$SHFILE"
EVENT=PostToolUse TOOL=Write FILE_PATH="$SHFILE" PAYLOAD="$(cat "$SHFILE")" mkpayload > "$J"
OUT="$(bash "$VERIFY" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(J) clean .sh: expected exit 0, got $RC\n$OUT"
ok "clean .sh exits 0"

# (K) malformed stdin -> exit 0 (fail-open)
printf 'not json at all ][}{' > "$J"
OUT="$(bash "$VERIFY" < "$J" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(K) verify malformed stdin: expected exit 0 (fail-open), got $RC\n$OUT"
ok "verify malformed stdin fails open (exit 0)"

printf '\nGUARD-HOOKS PASS (small-diff-gate block/warn/fail-open + verify surfaces-not-blocks)\n'
