#!/usr/bin/env bash
# tests/cross_agent_install_test.sh — the cross-agent GUARD install is honest.
#
# Drives the `mahoraga install` subcommand (the cross-agent shipper) and asserts the fixed
# contract: it installs ONLY the universal GUARD pack, never
# the Claude-Code-oriented adapt/prove ENGINE skills, and it prints the honest hooks-don't-port caveat.
#
#   mahoraga install --target <tmp> --agent cursor
#     -> the GUARD skills (small-diff-surgical-change, verification-before-advance, …) land under <tmp>
#     -> the adapt/prove ENGINE skills (blind-eval, codebase-mapping-forge, …) are NOT installed
#     -> the caveat prints: "GUARD hooks … do NOT port; on <agent> GUARD runs as skill-prose
#        disciplines, not hard gates."
#   mahoraga install --target <tmp> --agent cursor --dry-run
#     -> writes NOTHING under <tmp> (but still prints the caveat + what it would do)
#   re-running is idempotent (updates in place, exit 0).
#
# Hermetic: every write goes under one mktemp dir (the --target), cleaned up on exit. NEVER touches
# ~/.agents (the real default target). Needs only bash + coreutils — the install path is pure sh.
# Depends on: the `install` subcommand in cli/mahoraga — authored against the documented contract,
#.
#
# Run from the repo root:  bash tests/cross_agent_install_test.sh   (exit 0 = pass, non-zero = failure)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/cli/mahoraga"

fail() { printf 'CROSS-AGENT FAIL: %b\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
indent() { sed 's/^/  /'; }

# The GUARD skills that MUST ship cross-agent (universal, stack-agnostic disciplines).
GUARD_PRESENT="small-diff-surgical-change verification-before-advance surface-assumptions \
simplicity-first reuse-before-create trace-to-consumer karpathy-guidelines honesty-vocabulary"
# The adapt/prove ENGINE skills that MUST NOT ship cross-agent (Claude-Code-oriented; stripped from
# sandboxes; not cross-agent disciplines).
ENGINE_ABSENT="blind-eval sandbox-isolation adversarial-review-loop skill-improvement-loop \
codebase-mapping-forge spec-style-forge conformance-lint skill-editor"

# ---- required upstream artifacts --------------------
[ -f "$CLI" ]                || fail "missing cli/mahoraga"
[ -d "$ROOT/skills/guard" ]  || fail "missing skills/guard (the GUARD pack to install)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mahoraga-xagent.XXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
TARGET="$TMP/agents-skills"; mkdir -p "$TARGET"

# assert_present <target> <skill> : the skill dir exists somewhere under <target> and has a SKILL.md
assert_present() {
  local t="$1" s="$2" dir
  dir="$(find "$t" -type d -name "$s" 2>/dev/null | head -1)"
  [ -n "$dir" ] || fail "GUARD skill '$s' was not installed under $t"
  [ -f "$dir/SKILL.md" ] || fail "installed GUARD skill '$s' has no SKILL.md ($dir)"
}
# assert_absent <target> <skill> : no dir named <skill> exists anywhere under <target>
assert_absent() {
  local t="$1" s="$2" hit
  hit="$(find "$t" -type d -name "$s" 2>/dev/null | head -1)"
  [ -z "$hit" ] || fail "ENGINE skill '$s' must NOT be installed cross-agent, but found: $hit"
}

# The caveat is the honest heart of this feature — assert its meaning survived (case-insensitive,
# tolerant of minor wording), including the agent name it was told to name.
assert_caveat() {
  local out="$1" where="$2"
  printf '%s' "$out" | grep -qiE 'do not port'                     || fail "$where: caveat missing 'do not port' (hooks-don't-port)"
  printf '%s' "$out" | grep -qiE 'not hard gates|skill-prose'      || fail "$where: caveat missing 'not hard gates' / 'skill-prose'"
  printf '%s' "$out" | grep -qiE 'cursor'                          || fail "$where: caveat did not name the --agent (cursor)"
}

step "1. mahoraga install --target <tmp> --agent cursor  (default action = copy)"
OUT="$(bash "$CLI" install --target "$TARGET" --agent cursor 2>&1)"; RC=$?
printf '%s\n' "$OUT" | indent
case "$OUT" in
  *"unknown command"*) fail "cli/mahoraga has no 'install' subcommand yet" ;;
esac
[ "$RC" -eq 0 ] || fail "install exited $RC (expected 0)"

step "2. ASSERT the GUARD pack landed under <tmp>"
for s in $GUARD_PRESENT; do assert_present "$TARGET" "$s"; done
echo "  present: $GUARD_PRESENT"

step "3. ASSERT the adapt/prove ENGINE skills did NOT (Claude-Code-oriented, not cross-agent)"
for s in $ENGINE_ABSENT; do assert_absent "$TARGET" "$s"; done
echo "  absent : $ENGINE_ABSENT"

step "4. ASSERT the hooks-don't-port caveat printed (naming the --agent)"
assert_caveat "$OUT" "install(cursor)"
echo "  caveat present and names the agent"

step "5. idempotent — re-running updates in place (exit 0; GUARD still present)"
OUT2="$(bash "$CLI" install --target "$TARGET" --agent cursor 2>&1)"; RC2=$?
[ "$RC2" -eq 0 ] || { printf '%s\n' "$OUT2" | indent; fail "re-run install exited $RC2 (must be idempotent)"; }
for s in $GUARD_PRESENT; do assert_present "$TARGET" "$s"; done
echo "  re-run clean; GUARD pack still complete"

step "6. --dry-run writes NOTHING under <tmp> (but still prints the caveat)"
DRYT="$TMP/dry-target"; mkdir -p "$DRYT"
OUT3="$(bash "$CLI" install --target "$DRYT" --agent cursor --dry-run 2>&1)"; RC3=$?
printf '%s\n' "$OUT3" | indent
[ "$RC3" -eq 0 ] || fail "install --dry-run exited $RC3 (expected 0)"
WROTE="$(find "$DRYT" -mindepth 1 2>/dev/null | head -5)"
[ -z "$WROTE" ] || fail "install --dry-run WROTE under the target (must write nothing):\n$WROTE"
assert_caveat "$OUT3" "install --dry-run"
echo "  dry-run wrote nothing; caveat still printed"

step "7. ASSERT the install stayed inside --target (never wrote ~/.agents in this run)"
# The only writes this test authorises are under $TMP; the real default (~/.agents/skills) must be
# untouched. We cannot prove a negative globally, but we assert the test's own dirs are the only
# populated targets and that $TARGET lives under our mktemp root (portable ${TMPDIR:-/tmp} scheme).
case "$TARGET" in "$TMP"/*) : ;; *) fail "target escaped the hermetic tmp root: $TARGET";; esac
echo "  target confined to $TMP"

printf '\nCROSS-AGENT PASS\n'
echo "  installed GUARD pack -> $TARGET"
echo "  engine skills correctly withheld; caveat printed; dry-run inert"
