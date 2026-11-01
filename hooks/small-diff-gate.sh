#!/usr/bin/env bash
# small-diff-gate.sh — PreToolUse hook for Write|Edit (GUARD: small-diff / surgical change).
#
# WHAT IT DOES: reads the Claude Code hook stdin JSON and measures how many lines THIS single tool
# call would add. If that exceeds a cap it either warns (default) or hard-blocks the tool call.
#
#   change size =  Edit                       -> line count of tool_input.new_string (the added text)
#                  Write over an EXISTING file -> line count of tool_input.content (a full overwrite)
#                  Write of a NEW file         -> ALLOWED unconditionally (creating a file is not
#                                                 drive-by sprawl into existing code)
#
# CONTROLS (env):
#   MAHORAGA_MAX_EDIT_LINES  cap on the change size            (default 300; non-numeric -> 300)
#   MAHORAGA_SMALL_DIFF_MODE  warn | block                     (default warn)
#     warn  -> over the cap: surface a note on stderr, exit 0 (does NOT gate)
#     block -> over the cap: print a clear stderr message, exit 2 (PreToolUse exit 2 BLOCKS the call)
#
# HOOK CONTRACT (Claude Code docs): PreToolUse exit 2 blocks the tool unconditionally; exit 0 allows.
# A human-readable message goes to stderr. This hook parses stdin with python3 (stdlib json) — NOT jq
# (jq is not in the deps allowlist). It MUST fail OPEN: any parse/tooling error exits 0 (allow), so a
# broken hook can never wedge the session. Only a genuine over-cap change in block mode ever exits 2.
set -u

MAX="${MAHORAGA_MAX_EDIT_LINES:-300}"
case "$MAX" in ''|*[!0-9]*) MAX=300 ;; esac        # fail-open: garbage cap -> default, never block on it
MODE="${MAHORAGA_SMALL_DIFF_MODE:-warn}"

# python3 owns the JSON parse + the new-vs-existing-file decision, and prints ONE verdict line we read
# here. It always exits 0 (we decide the gate); a missing/broken python3 makes the $() fail -> failopen.
verdict="$(python3 -c '
import sys, json, os
try:
    data = json.load(sys.stdin)
except Exception:
    print("failopen parse-error"); sys.exit(0)
if not isinstance(data, dict):
    print("failopen not-object"); sys.exit(0)
tool = data.get("tool_name", "")
ti = data.get("tool_input")
if not isinstance(ti, dict):
    print("failopen no-tool-input"); sys.exit(0)
cwd = data.get("cwd") or ""
fp = ti.get("file_path") or ""

def nlines(s):
    if not isinstance(s, str) or s == "":
        return 0
    n = s.count("\n")
    if not s.endswith("\n"):
        n += 1
    return n

if tool == "Edit":
    print("size %d" % nlines(ti.get("new_string", "")))
elif tool == "Write":
    path = fp
    if path and not os.path.isabs(path) and cwd:
        path = os.path.join(cwd, path)
    try:
        exists = bool(path) and os.path.exists(path)
    except Exception:
        exists = False
    if exists:
        print("size %d" % nlines(ti.get("content", "")))   # overwrite of an existing file
    else:
        print("allow-new")                                 # creating a new file: allowed
else:
    print("allow-other")                                   # not a Write/Edit: not ours, allow
' 2>/dev/null)" || verdict="failopen python-missing"
[ -n "$verdict" ] || verdict="failopen empty-verdict"

# shellcheck disable=SC2086
set -- $verdict
action="${1:-failopen}"
lines="${2:-0}"

case "$action" in
  allow-new|allow-other)
    exit 0 ;;
  failopen)
    echo "small-diff-gate: could not read stdin (${2:-unknown}); failing open (allow)." >&2
    exit 0 ;;
  size)
    if [ "$lines" -le "$MAX" ]; then
      exit 0
    fi
    if [ "$MODE" = "block" ]; then
      echo "small-diff-gate: BLOCKED — this single edit changes $lines lines > cap $MAX. Split it into surgical edits, or set MAHORAGA_SMALL_DIFF_MODE=warn to downgrade to a warning." >&2
      exit 2
    fi
    echo "small-diff-gate: NOTE — this single edit changes $lines lines (> cap $MAX). Prefer smaller, surgical edits. (warn mode; set MAHORAGA_SMALL_DIFF_MODE=block to enforce.)" >&2
    exit 0 ;;
  *)
    exit 0 ;;   # unknown verdict: fail open
esac
