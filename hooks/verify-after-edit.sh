#!/usr/bin/env bash
# verify-after-edit.sh — PostToolUse hook for Write|Edit (GUARD: verification-before-advance).
#
# WHAT IT DOES: after a file is written/edited, runs ONE fast, offline, per-file syntax check chosen by
# extension and SURFACES the verdict on stderr, so a syntactically broken file is caught immediately
# instead of at the next build. It is a magnifying glass, not a gate.
#
#   .py            -> python3 -m py_compile
#   .sh            -> bash -n
#   .json          -> python3 -c 'json.load(...)'
#   .mjs/.js/.cjs  -> node --check   (only if node is present; otherwise UNVERIFIED)
#   anything else  -> UNVERIFIED (no fast offline check for that extension) — e.g. .ts, .md, .yaml
#
# HOOK CONTRACT (Claude Code docs): PostToolUse CANNOT block — exit 2 is IGNORED. So this hook is
# HONEST about being surfacing-only: it ALWAYS exits 0 and never pretends to gate. A failed check is
# reported loudly on stderr (transcript), but the edit already happened and is not reverted. Parsing
# uses python3 (stdlib json), NOT jq. It fails OPEN on any malformed input or missing tooling.
set -u

# python3 owns the JSON parse and resolves file_path (against cwd if relative). Prints the path or
# nothing. Always exits 0; a missing/broken python3 makes $() fail -> empty target -> we skip.
target="$(python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
ti = d.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(0)
fp = ti.get("file_path") or ""
if not fp:
    sys.exit(0)
cwd = d.get("cwd") or ""
if not os.path.isabs(fp) and cwd:
    fp = os.path.join(cwd, fp)
print(fp)
' 2>/dev/null)" || target=""

if [ -z "$target" ]; then
  echo "verify-after-edit: no file_path in stdin; nothing to check (fail-open)." >&2
  exit 0
fi
if [ ! -e "$target" ]; then
  echo "verify-after-edit: '$target' not found after edit; skipping (fail-open)." >&2
  exit 0
fi

base="$(basename "$target")"
case "$base" in
  *.*) ext="${base##*.}"; ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')" ;;
  *)   ext="" ;;                       # extensionless file: no fast check
esac

report() {  # <verdict-line> [<detail...>]  — always to stderr; verify surfaces, it does not gate
  echo "verify-after-edit: $1" >&2
  shift || true
  [ "$#" -gt 0 ] && printf '%s\n' "$*" >&2
  return 0
}

case "$ext" in
  py)
    if out="$(python3 -m py_compile "$target" 2>&1)"; then
      report "VERIFIED (py_compile) $base"
    else
      report "FAILED py_compile — $base" "$out"
    fi ;;
  sh)
    if out="$(bash -n "$target" 2>&1)"; then
      report "VERIFIED (bash -n) $base"
    else
      report "FAILED bash -n — $base" "$out"
    fi ;;
  json)
    if out="$(python3 -c 'import sys, json; json.load(open(sys.argv[1], encoding="utf-8"))' "$target" 2>&1)"; then
      report "VERIFIED (json.load) $base"
    else
      report "FAILED json.load — $base" "$out"
    fi ;;
  mjs|js|cjs)
    if command -v node >/dev/null 2>&1; then
      if out="$(node --check "$target" 2>&1)"; then
        report "VERIFIED (node --check) $base"
      else
        report "FAILED node --check — $base" "$out"
      fi
    else
      report "UNVERIFIED (node not present; no fast offline check for .$ext) $base"
    fi ;;
  "")
    report "UNVERIFIED (no fast offline check for an extensionless file) $base" ;;
  *)
    report "UNVERIFIED (no fast offline check for .$ext) $base" ;;
esac

exit 0   # PostToolUse cannot block — always exit 0 (honest: this hook surfaces, it does not gate)
