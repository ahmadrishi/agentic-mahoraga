#!/usr/bin/env bash
# tests/leak_gate_snake_test.sh — (language-aware decontamination) acceptance test.
#
# Asserts core/lib/leak_gate.sh on a PYTHON repo:
#
#   POSITIVE — a snake_case answer symbol the human diff INTRODUCES, ABSENT from the fork-point tree,
#              but named in a sandbox skill's prose -> the gate CATCHES the leak -> exit 2.
#   NEGATIVE — the same candidate symbols are PRESENT at the fork-point tree -> pre-existing
#              vocabulary the human merely referenced, not a leak -> the gate does NOT flag -> exit 0.
#
# The pair differs ONLY in the staged fork-point tree, so it isolates the fork-subtraction step and
# proves the snake_case (python) heuristic fires (the whole point of vs the old camelCase-only net).
#
# Inputs come from the py-service fixture (examples/py-service/fixture/): the human diff that
# introduces the snake_case answer symbol (compute_prorated_refund) and the leaky skill whose prose
# names it. The PROJECT_CONFIG is a hermetic TEMP config for that python fixture — sandbox_root points
# at this test's own temp tree, and the repo is named to match the fixture diff filename so the
# human_<repo>.diff -> repos[].language(=python) mapping resolves.
#
# Hermetic: own temp dirs, cleaned up on exit. Touches no repo files. Run from the repo root:
#     bash tests/leak_gate_snake_test.sh          # exit 0 = pass, non-zero = failure
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEAK_GATE="$ROOT/core/lib/leak_gate.sh"
FIXTURE_DIR="$ROOT/examples/py-service/fixture"

fail() { printf 'LEAK-SNAKE-TEST FAIL: %b\n' "$*" >&2; exit 1; }

# ---- required upstream artifacts --------------
[ -f "$LEAK_GATE" ]   || fail "missing $LEAK_GATE"
[ -d "$FIXTURE_DIR" ] || fail "missing $FIXTURE_DIR"

# the fixture human diff + the repo token derived from its filename (human_<repo>.diff)
DIFF=""
for d in "$FIXTURE_DIR"/human_*.diff; do [ -f "$d" ] && { DIFF="$d"; break; }; done
[ -n "$DIFF" ] || fail "no fixture human_*.diff under $FIXTURE_DIR"
_b="$(basename "$DIFF")"; REPO="${_b#human_}"; REPO="${REPO%.diff}"
[ -n "$REPO" ] || fail "could not derive a repo name from $(basename "$DIFF")"

# the leaky skill dir (contract: fixture/leaky-skill/SKILL.md names the answer symbol in prose)
SKILL_SRC="$FIXTURE_DIR/leaky-skill"
if [ ! -f "$SKILL_SRC/SKILL.md" ]; then
  _md=""
  for m in $(find "$FIXTURE_DIR" -type f -name SKILL.md 2>/dev/null); do _md="$m"; break; done
  [ -n "$_md" ] && SKILL_SRC="$(dirname "$_md")"
fi
[ -f "$SKILL_SRC/SKILL.md" ] || fail "no leaky-skill SKILL.md under $FIXTURE_DIR"

echo "fixture: diff=$(basename "$DIFF") repo=$REPO leaky-skill=$SKILL_SRC"

# ---- hermetic scaffold --------------------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SB="$TMP/sandboxes"                 # SANDBOX_ROOT
RUN="$TMP/run"                      # RUN_DIR holding the human diff
SLUG="decon-probe"                  # opaque sandbox slug
KEY="LEAKTEST-UNIT"                 # opaque unit key (no answer_tokens configured for it)
SKILLS="$SB/$SLUG/.claude/skills"
FORKTREE="$SB/$SLUG/$REPO"          # the staged fork-point tree the gate subtracts against
mkdir -p "$SKILLS" "$FORKTREE" "$RUN/$KEY" "$TMP/root"

# a hermetic TEMP PROJECT_CONFIG for the python fixture: a single python repo whose name matches the
# fixture diff filename (so leak_gate's human_<repo>.diff -> language lookup resolves to python), and a
# sandbox_root under this test's temp tree. Flow YAML — cfgquery reads it with PyYAML at runtime.
CFG="$TMP/PROJECT.yaml"
cat > "$CFG" <<YAML
project: {id: py-service, name: py-service, root: $TMP/root}
repos: [{name: $REPO, language: python}]
decontamination: {exclusion: []}
output: {sandbox_root: $SB}
YAML
export PROJECT_CONFIG="$CFG"

# stage the leaky skill + the fixture human diff (named human_<repo>.diff as the gate expects)
cp -R "$SKILL_SRC" "$SKILLS/leaky-skill"
cp "$DIFF" "$RUN/$KEY/human_${REPO}.diff"

# ================= POSITIVE — answer symbol NOT present at fork-point =================
# a benign fork-point tree with NO answer symbols, so every distinctive candidate from the diff
# survives subtraction and (being named in the skill) trips the gate.
printf '# fork-point base tree (no answer symbols)\nx = 1\n' > "$FORKTREE/base.py"
OUT_POS="$(bash "$LEAK_GATE" "$SLUG" "$KEY" "$RUN" 2>&1)"; RC_POS=$?
printf '%s\n' "$OUT_POS" | sed 's/^/  /'
[ "$RC_POS" -eq 2 ] || fail "POSITIVE: expected exit 2 (snake_case leak caught), got $RC_POS"
printf '%s\n' "$OUT_POS" | grep -q 'LEAK\[auto-derived\]' \
  || fail "POSITIVE: exit 2 but no auto-derived LEAK line — expected the diff symbol to be reported"
echo "POSITIVE: PASS (snake_case answer symbol caught; exit 2)"

# ================= NEGATIVE — same symbols PRESENT at fork-point =================
# plant every added-line token from the diff into the fork-point tree: now each candidate is
# pre-existing vocabulary and is subtracted, so the gate flags nothing (exit 0) even though the skill
# still names it. (grep only needs the text present; python validity is irrelevant to the gate.)
grep '^+' "$DIFF" | grep -v '^+++' | sed 's/^+//' > "$FORKTREE/base.py"
OUT_NEG="$(bash "$LEAK_GATE" "$SLUG" "$KEY" "$RUN" 2>&1)"; RC_NEG=$?
printf '%s\n' "$OUT_NEG" | sed 's/^/  /'
[ "$RC_NEG" -eq 0 ] || fail "NEGATIVE: expected exit 0 (symbol present at fork-point, not flagged), got $RC_NEG"
echo "NEGATIVE: PASS (fork-point symbol not flagged; exit 0)"

echo "LEAK-SNAKE-TEST PASS"
