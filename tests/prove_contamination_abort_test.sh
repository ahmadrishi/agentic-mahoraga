#!/usr/bin/env bash
# tests/prove_contamination_abort_test.sh — (second half): a contaminated SOURCE skill
# must ABORT staging.
#
# The leak machinery, exercised in the prove/staging context: if a skill in the project's staged
# library names the unit's ANSWER symbol (the fix the blind implementer is supposed to produce), the
# sandbox is contaminated and must never reach an implementer. This test proves stage_sandbox.sh /
# leak_gate.sh catch that and FAIL CLOSED — non-zero exit AND the sandbox directory removed.
#
#   setup-fixture.sh            build the throwaway py-service git fixture (base + prorated-refund unit)
#   prepare_task.sh             produce the human_<repo>.diff whose added lines introduce the answer
#   (derive)                    read the answer symbol straight out of that diff (robust to renames)
#   (plant)                     author a leaky skill whose prose NAMES that symbol -> skills.source_dir
#   stage_sandbox.sh            stage the fork-point + the leaky skill; the internal leak gate fires
#
# ASSERTS: stage_sandbox.sh exits NON-ZERO, prints a leak/abort diagnostic, and the sandbox directory
# it began building is GONE (staging is fail-closed — a partial contaminated sandbox never survives).
#
# The symbol is derived from the ACTUAL human diff (not hard-coded), so the test tracks whatever the
# fixture's feature commit introduces — the same real-answer tracking the auto-derived leak gate
# does. The fork-point tree does NOT contain the symbol (the feature commit added it), so it survives
# fork-subtraction and is a genuine leak, not pre-existing vocabulary.
#
# Hermetic: own temp dirs only, cleaned up on exit; touches no repo files. Needs git + python3 +
# PyYAML. Depends on: examples/py-service/** — authored against the documented contract.
#
# Run from the repo root:  bash tests/prove_contamination_abort_test.sh  (exit 0 = pass, non-zero = fail)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/core/lib"
EX="$ROOT/examples/py-service"

fail()   { printf 'CONTAM-ABORT FAIL: %b\n' "$*" >&2; exit 1; }
step()   { printf '\n== %s ==\n' "$*"; }
indent() { sed 's/^/  /'; }

# ---- required upstream artifacts ---------------
for f in "$LIB/adapters.sh" "$LIB/prepare_task.sh" "$LIB/stage_sandbox.sh" "$LIB/leak_gate.sh" \
         "$EX/setup-fixture.sh" "$EX/PROJECT.yaml"; do
  [ -e "$f" ] || fail "missing dependency: $f"
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SANDBOXES="$TMP/sandboxes"; RUN="$TMP/run"; LOGS="$TMP/logs"; FIXPARENT="$TMP/fixture"; SKILLSRC="$TMP/leaky-skills"
mkdir -p "$SANDBOXES" "$RUN" "$LOGS" "$FIXPARENT" "$SKILLSRC"

step "1. setup-fixture.sh — build the throwaway git fixture"
FIX_OUT="$(bash "$EX/setup-fixture.sh" "$FIXPARENT" 2>"$LOGS/setup.err")" \
  || { cat "$LOGS/setup.err" >&2; fail "setup-fixture.sh exited non-zero"; }
printf '%s\n' "$FIX_OUT" | indent
kv() { printf '%s\n' "$FIX_OUT" | sed -n "s/^$1=//p" | head -1; }
FROOT="$(kv root)"; FREPO="$(kv repo)"; UNIT="$(kv unit)"
[ -n "$FROOT" ] && [ -d "$FROOT" ]      || fail "setup-fixture printed no usable root= ($FROOT)"
[ -n "$FREPO" ] && [ -d "$FREPO/.git" ] || fail "setup-fixture printed no git repo= ($FREPO)"
printf '%s' "$UNIT" | grep -qE '^[0-9a-f]{7,40}$' || fail "setup-fixture printed no unit sha ($UNIT)"

step "2. hermetic PROJECT_CONFIG — skills.source_dir points at the LEAKY skill library"
CFG="$TMP/PROJECT.yaml"
OUT="$CFG" SKILLS_SRC="$SKILLSRC" FROOT="$FROOT" REPONAME="$(basename "$FREPO")" SB="$SANDBOXES" EXAMPLE="$EX/PROJECT.yaml" \
  python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["EXAMPLE"])) or {}
d.setdefault("project", {})["root"] = os.environ["FROOT"]
repos = d.get("repos") or [{}]
repos[0]["name"] = os.environ["REPONAME"]
d["repos"] = repos[:1]
d.setdefault("tracker", {}).setdefault("config", {})["repo"] = ""   # pure-git fallback
d.setdefault("skills", {})["source_dir"] = os.environ["SKILLS_SRC"]
d["skills"]["derived_skills"] = []
d["skills"].pop("index_file", None)
d.setdefault("decontamination", {})["exclusion"] = []
d.setdefault("output", {})["sandbox_root"] = os.environ["SB"]
yaml.safe_dump(d, open(os.environ["OUT"], "w"), sort_keys=False)
PY
[ -f "$CFG" ] || fail "could not synthesize the runtime PROJECT_CONFIG"
export PROJECT_CONFIG="$CFG"
export MAHORAGA_REPO_DIR="$FREPO"

KEY="$UNIT"

step "3. prepare_task.sh — the human reference diff that introduces the answer symbol"
PREP_OUT="$(bash "$LIB/prepare_task.sh" "$RUN" "$KEY" 2>&1)"; PREP_RC=$?
printf '%s\n' "$PREP_OUT" | indent
[ "$PREP_RC" -eq 0 ]          || fail "prepare_task.sh exited $PREP_RC"
[ -s "$RUN/$KEY/meta.lines" ] || fail "prepare_task produced no meta.lines"
REPO_NAME="$(cut -d'|' -f1 "$RUN/$KEY/meta.lines" | head -1)"
[ -n "$REPO_NAME" ] || fail "could not read the repo name from meta.lines"
DIFF="$RUN/$KEY/human_${REPO_NAME}.diff"
[ -s "$DIFF" ] || fail "no human_${REPO_NAME}.diff produced"

step "4. derive the ANSWER symbol from the human diff's added lines"
# prefer a Python def the feature introduces; fall back to any distinctive snake_case identifier.
ANSWER_SYM="$(grep '^+' "$DIFF" | grep -v '^+++' | grep -oE 'def [a-z_][a-z0-9_]{3,}' | head -1 | awk '{print $2}')"
[ -n "$ANSWER_SYM" ] || ANSWER_SYM="$(grep '^+' "$DIFF" | grep -v '^+++' | grep -oE '[a-z][a-z0-9]*(_[a-z0-9]+){2,}' | head -1)"
[ -n "$ANSWER_SYM" ] || fail "could not derive an answer symbol from $DIFF (feature diff shape unexpected)"
echo "  answer symbol = $ANSWER_SYM"
# sanity: the symbol must NOT already exist at the fork-point tree, or it is pre-existing vocabulary,
# not a leak (the gate would correctly subtract it and this test would prove nothing).
if git -C "$FREPO" grep -qwF "$ANSWER_SYM" "$(git -C "$FREPO" rev-parse HEAD~1)" -- . 2>/dev/null; then
  fail "answer symbol '$ANSWER_SYM' already exists at the fork-point — cannot prove a leak abort"
fi

step "5. plant a CONTAMINATED skill whose prose names the answer symbol"
ANSWER_SYM="$ANSWER_SYM" DST="$SKILLSRC/leaky-refund/SKILL.md" python3 - <<'PY'
import os
sym = os.environ["ANSWER_SYM"]; dst = os.environ["DST"]
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, "w").write(
    "---\n"
    "name: leaky-refund\n"
    "description: A deliberately CONTAMINATED skill used only by this test — it names the unit's "
    "answer symbol in prose so the decontamination gate must abort staging. Do NOT ship it.\n"
    "allowed-tools: [Read, Grep]\n"
    "---\n\n"
    "# Refund proration (contaminated fixture)\n\n"
    "Always compute the refund with `" + sym + "(paid, total_days, used_days)` — do not reimplement\n"
    "the proration inline. Naming that symbol here is exactly the answer leak the gate must catch.\n"
)
print("wrote leaky skill naming:", sym)
PY
[ -f "$SKILLSRC/leaky-refund/SKILL.md" ] || fail "could not author the leaky skill"
grep -qF "$ANSWER_SYM" "$SKILLSRC/leaky-refund/SKILL.md" || fail "leaky skill does not name the answer symbol"

# the orchestrator supplies SPEC.md + BUSINESS_REQUIREMENT.md (stage_sandbox requires both to exist
# BEFORE it reaches the leak gate — so the abort we assert is the LEAK abort, not a missing-doc abort).
for doc in SPEC.md BUSINESS_REQUIREMENT.md; do
  if [ -f "$EX/$doc" ]; then cp "$EX/$doc" "$RUN/$KEY/$doc"; else printf '# %s\n(placeholder)\n' "$doc" > "$RUN/$KEY/$doc"; fi
done

step "6. stage_sandbox.sh — must ABORT (leak gate fires on the contaminated skill)"
SLUG="contam-sbx"; case "$SLUG" in *"$KEY"*) SLUG="c-$$";; esac
SB="$SANDBOXES/$SLUG"
STAGE_OUT="$(bash "$LIB/stage_sandbox.sh" "$RUN" "$KEY" "$SLUG" 2>&1)"; STAGE_RC=$?
printf '%s\n' "$STAGE_OUT" | indent

[ "$STAGE_RC" -ne 0 ] || fail "stage_sandbox SUCCEEDED (rc=0) but a leaky SOURCE skill MUST abort staging"
printf '%s\n' "$STAGE_OUT" | grep -qiE 'leak|abort' || fail "staging aborted (rc=$STAGE_RC) but printed no leak/abort diagnostic"
[ ! -d "$SB" ] || fail "staging aborted (rc=$STAGE_RC) but the sandbox dir SURVIVED at $SB (must be removed — fail-closed)"

echo "  staging aborted (rc=$STAGE_RC), leak diagnostic emitted, sandbox removed — contamination caught"

printf '\nCONTAM-ABORT PASS\n'
echo "  unit=$UNIT  answer_symbol=$ANSWER_SYM"
