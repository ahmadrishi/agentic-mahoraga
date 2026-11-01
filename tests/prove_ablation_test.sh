#!/usr/bin/env bash
# tests/prove_ablation_test.sh — a mechanical TWO-ARM ablation prove on
# examples/py-service.
#
# Runs the deterministic half of a `/mahoraga-prove` run — everything EXCEPT the real blind LLM
# implement (a STUB implementer stands in, exactly as tests/e2e_ts_app_test.sh does for the single
# arm). The point is to exercise the trust machinery end to end:
#
#   setup-fixture.sh            build a throwaway git repo whose tip is the unit of work
#   tracker_fn list_units       discover the unit (github-pr pure-git fallback; no gh/network)
#   prepare_task.sh             fork-point + clean human_<repo>.diff + meta.lines (adapter dispatch)
#   stage_sandbox.sh  (x2)      TWO history-free sandboxes at the SAME fork-point:
#                                 harness  — staged with the project's FULL skills (money-cents-guard)
#                                 baseline — staged with EMPTY skills (no forged skills, no GUARD)
#   STUB implementers           write score.json (arm harness, business_req 95, lost_context none)
#                               and score.baseline.json (arm baseline, business_req 60, lost_context
#                               set), EACH carrying a cutoff_label (from core/lib/cutoff_label.py) +
#                               a decontam_confidence
#   selection.json              a sampling-frame disclosure (candidates / selected / excluded+reasons)
#   aggregate_scores.py         globs <UNIT>/score*.json, groups by `arm`, computes ablation_delta
#   build_report.py             -> report.html with the ablation panel + per-unit cutoff/decontam chips
#
# ASSERTS:
#   * scores.json.aggregate.ablation_delta.business_req_avg > 0 (harness beat baseline), and BOTH arms
#     are present under aggregate.arms;
#   * report.html contains an Ablation panel, a per-unit cutoff_label chip, and a decontam_confidence;
#   * core/lib/cutoff_label.py labels a PRIVATE repo "cutoff-clean" and a PUBLIC no-model_cutoff unit
#     "cutoff-unverified" (the policy the harness arm relies on).
#
# Hermetic: every path lives under one mktemp dir (the fixture is created there too), cleaned up on
# exit. Needs only git + python3 + PyYAML (the one allowed runtime dep) — no Node, no network.
#
# Depends on:
#   * core/lib/{aggregate_scores.py, build_report.py, cutoff_label.py}
#   * examples/py-service/** (runnable repo + setup-fixture + guard skill)
#
# Run from the repo root:  bash tests/prove_ablation_test.sh   (exit 0 = pass, non-zero = failure)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/core/lib"
EX="$ROOT/examples/py-service"
CUTOFF="$LIB/cutoff_label.py"

fail()   { printf 'PROVE-ABLATION FAIL: %b\n' "$*" >&2; exit 1; }
step()   { printf '\n== %s ==\n' "$*"; }
indent() { sed 's/^/  /'; }

# ---- required upstream artifacts ---------------
for f in "$LIB/adapters.sh" "$LIB/prepare_task.sh" "$LIB/stage_sandbox.sh" "$LIB/leak_gate.sh" \
         "$LIB/aggregate_scores.py" "$LIB/build_report.py" "$CUTOFF" \
         "$EX/setup-fixture.sh" "$EX/PROJECT.yaml"; do
  [ -e "$f" ] || fail "missing dependency: $f"
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SANDBOXES="$TMP/sandboxes"; RUN="$TMP/run"; LOGS="$TMP/logs"; FIXPARENT="$TMP/fixture"; EMPTY="$TMP/empty-skills"
mkdir -p "$SANDBOXES" "$RUN" "$LOGS" "$FIXPARENT" "$EMPTY"

# synthesize a hermetic runtime PROJECT_CONFIG from the example: keep its adapter/verify/decontam
# choices; point the runtime-location fields at the live fixture; force the single repo's name to the
# live checkout basename so prepare_task's repo == the sandbox subdir == PROJECT_ROOT/<name>; and pick
# the skills.source_dir per arm (full skills for harness, an EMPTY dir for baseline).
mkcfg() {   # <out-yaml> <skills-source-dir>
  OUT="$1" SKILLS_SRC="$2" FROOT="$FROOT" REPONAME="$(basename "$FREPO")" SB="$SANDBOXES" EXAMPLE="$EX/PROJECT.yaml" \
    python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["EXAMPLE"])) or {}
d.setdefault("project", {})["root"] = os.environ["FROOT"]
repos = d.get("repos") or [{}]
repos[0]["name"] = os.environ["REPONAME"]      # == the live checkout basename
d["repos"] = repos[:1]                          # single-repo fixture
d.setdefault("tracker", {}).setdefault("config", {})["repo"] = ""   # force the pure-git fallback
d.setdefault("skills", {})["source_dir"] = os.environ["SKILLS_SRC"]
d["skills"]["derived_skills"] = []
d["skills"].pop("index_file", None)
d.setdefault("decontamination", {})["exclusion"] = []
d.setdefault("output", {})["sandbox_root"] = os.environ["SB"]
yaml.safe_dump(d, open(os.environ["OUT"], "w"), sort_keys=False)
PY
}

step "1. setup-fixture.sh — build the throwaway git fixture (git only; no gh/pip/network)"
FIX_OUT="$(bash "$EX/setup-fixture.sh" "$FIXPARENT" 2>"$LOGS/setup.err")" \
  || { cat "$LOGS/setup.err" >&2; fail "setup-fixture.sh exited non-zero"; }
printf '%s\n' "$FIX_OUT" | indent
kv() { printf '%s\n' "$FIX_OUT" | sed -n "s/^$1=//p" | head -1; }
FROOT="$(kv root)"; FREPO="$(kv repo)"; FSKILLS="$(kv skills)"; UNIT="$(kv unit)"; FORK_EXPECTED="$(kv fork)"
[ -n "$FROOT" ] && [ -d "$FROOT" ]      || fail "setup-fixture printed no usable root= ($FROOT)"
[ -n "$FREPO" ] && [ -d "$FREPO/.git" ] || fail "setup-fixture printed no git repo= ($FREPO)"
[ -n "$FSKILLS" ] && [ -d "$FSKILLS" ]  || fail "setup-fixture printed no skills dir= ($FSKILLS) — the harness arm needs a skills library"
printf '%s' "$UNIT" | grep -qE '^[0-9a-f]{7,40}$' || fail "setup-fixture printed no unit sha ($UNIT)"
[ "$(find "$FSKILLS" -name SKILL.md 2>/dev/null | grep -c .)" -ge 1 ] \
  || fail "the fixture skills library has no SKILL.md — the ablation contrast would not be real"

step "2. hermetic PROJECT_CONFIGs — harness (full skills) + baseline (EMPTY skills)"
CFG_H="$TMP/PROJECT.harness.yaml"; CFG_B="$TMP/PROJECT.baseline.yaml"
mkcfg "$CFG_H" "$FSKILLS"
mkcfg "$CFG_B" "$EMPTY"
[ -f "$CFG_H" ] && [ -f "$CFG_B" ] || fail "could not synthesize the runtime PROJECT_CONFIGs"
export MAHORAGA_REPO_DIR="$FREPO"   # the github-pr adapter honours this directly (repo:"" => pure-git)

step "3. tracker discovery via adapters.sh (tracker_fn list_units / fork_point)"
export PROJECT_CONFIG="$CFG_H"
# shellcheck source=/dev/null
source "$LIB/adapters.sh" || fail "could not source adapters.sh"
declare -F tracker_fn >/dev/null 2>&1 || fail "adapters.sh defined no tracker_fn"
LU="$(tracker_fn list_units 2>"$LOGS/list.err")" || { cat "$LOGS/list.err" >&2; fail "tracker_fn list_units failed"; }
printf '%s\n' "$LU" | indent
printf '%s\n' "$LU" | grep -qF "$UNIT" || fail "tracker_fn list_units did not surface the unit $UNIT"
FORK_GOT="$(tracker_fn fork_point "$UNIT" 2>"$LOGS/fork.err")" || { cat "$LOGS/fork.err" >&2; fail "tracker_fn fork_point failed"; }
printf '%s' "$FORK_GOT" | grep -qE '^[0-9a-f]{40}$' || fail "fork_point is not a full sha: $FORK_GOT"
if [ -n "$FORK_EXPECTED" ]; then case "$FORK_GOT" in "$FORK_EXPECTED"*) : ;; *) fail "fork_point ($FORK_GOT) != fixture fork ($FORK_EXPECTED)";; esac; fi
echo "  fork_point($UNIT) = ${FORK_GOT:0:12}"

KEY="$UNIT"

step "4. prepare_task.sh — the fork-point + clean human reference diff + meta.lines"
export PROJECT_CONFIG="$CFG_H"
PREP_OUT="$(bash "$LIB/prepare_task.sh" "$RUN" "$KEY" 2>&1)"; PREP_RC=$?
printf '%s\n' "$PREP_OUT" | indent
[ "$PREP_RC" -eq 0 ]           || fail "prepare_task.sh exited $PREP_RC"
[ -s "$RUN/$KEY/meta.lines" ]  || fail "prepare_task produced no meta.lines"
grep -q '|fork=[0-9a-f]' "$RUN/$KEY/meta.lines" || fail "meta.lines has no fork= sha"
REPO_NAME="$(cut -d'|' -f1 "$RUN/$KEY/meta.lines" | head -1)"
[ -n "$REPO_NAME" ] || fail "could not read the repo name from meta.lines"
[ -s "$RUN/$KEY/human_${REPO_NAME}.diff" ] || fail "no human_${REPO_NAME}.diff produced"
grep -qi 'refund' "$RUN/$KEY/human_${REPO_NAME}.diff" || fail "human diff does not look like the prorated-refund unit"

# the orchestrator supplies SPEC.md + BUSINESS_REQUIREMENT.md into the task dir (stage_sandbox needs both)
for doc in SPEC.md BUSINESS_REQUIREMENT.md; do
  if [ -f "$EX/$doc" ]; then cp "$EX/$doc" "$RUN/$KEY/$doc"; else printf '# %s\n(placeholder)\n' "$doc" > "$RUN/$KEY/$doc"; fi
done

step "5. stage TWO sandboxes at the SAME fork-point — harness (full skills) + baseline (empty)"
SLUG_H="prove-harness-sbx"; SLUG_B="prove-baseline-sbx"
case "$SLUG_H" in *"$KEY"*) SLUG_H="h-$$";; esac
case "$SLUG_B" in *"$KEY"*) SLUG_B="b-$$";; esac

export PROJECT_CONFIG="$CFG_H"
SH_OUT="$(bash "$LIB/stage_sandbox.sh" "$RUN" "$KEY" "$SLUG_H" 2>&1)"; SH_RC=$?
printf '%s\n' "$SH_OUT" | indent
[ "$SH_RC" -eq 0 ] || fail "harness stage_sandbox exited $SH_RC (the benign guard skill must leak-gate clean)"
SB_H="$SANDBOXES/$SLUG_H/$REPO_NAME"
[ -d "$SB_H" ] || fail "harness sandbox repo not staged at $SB_H"

export PROJECT_CONFIG="$CFG_B"
SB_OUT="$(bash "$LIB/stage_sandbox.sh" "$RUN" "$KEY" "$SLUG_B" 2>&1)"; SB_RC=$?
printf '%s\n' "$SB_OUT" | indent
[ "$SB_RC" -eq 0 ] || fail "baseline stage_sandbox exited $SB_RC"
SB_B="$SANDBOXES/$SLUG_B/$REPO_NAME"
[ -d "$SB_B" ] || fail "baseline sandbox repo not staged at $SB_B"

# the ablation contrast must be REAL: the harness arm carries skills, the baseline arm none.
H_SKILLS_N="$(find "$SANDBOXES/$SLUG_H/.claude/skills" -name SKILL.md 2>/dev/null | grep -c .)"
B_SKILLS_N="$(find "$SANDBOXES/$SLUG_B/.claude/skills" -name SKILL.md 2>/dev/null | grep -c .)"
[ "$H_SKILLS_N" -ge 1 ] || fail "harness arm staged NO skills — the ablation contrast is not real"
[ "$B_SKILLS_N" -eq 0 ] || fail "baseline arm should stage EMPTY skills, found $B_SKILLS_N SKILL.md"
echo "  harness skills=$H_SKILLS_N  baseline skills=$B_SKILLS_N"

step "6. STUB implementers — a trivial edit in each sandbox (stands in for the blind LLM)"
stub_edit() {   # <sandbox repo dir> <arm>
  local sb="$1" arm="$2" t=""
  for f in "$sb"/src/*.py "$sb"/*.py; do [ -f "$f" ] && { t="$f"; break; }; done
  if [ -n "$t" ]; then
    printf '\n# mahoraga-prove: trivial no-op edit by the STUB %s implementer.\n' "$arm" >> "$t"
    echo "  [$arm] appended a comment to ${t#"$sb"/}"
  else
    mkdir -p "$sb"; printf '# mahoraga-prove stub (%s)\n' "$arm" > "$sb/mahoraga_stub.py"
    echo "  [$arm] created mahoraga_stub.py"
  fi
}
stub_edit "$SB_H" harness
stub_edit "$SB_B" baseline

step "7. cutoff label for the unit via core/lib/cutoff_label.py (py-service is a PRIVATE repo)"
CL_OUT="$(python3 "$CUTOFF" "" private "" 2>&1)"; CL_RC=$?
[ "$CL_RC" -eq 0 ] || fail "cutoff_label.py exited $CL_RC on the unit label"
CUT_LABEL="$(printf '%s' "$CL_OUT" | cut -f1)"; CUT_REASON="$(printf '%s' "$CL_OUT" | cut -f2-)"
[ "$CUT_LABEL" = "cutoff-clean" ] || fail "expected a PRIVATE repo -> cutoff-clean, got '$CUT_LABEL'"
echo "  unit cutoff_label=$CUT_LABEL ($CUT_REASON)"

step "8. STUB scores — arm harness (business_req 95) + arm baseline (business_req 60)"
HUMAN_STAT="$(sed -n 's/.*|stat=//p' "$RUN/$KEY/meta.lines" | head -1 | tr -d '"')"
KEY="$KEY" REPO="$REPO_NAME" CUT_LABEL="$CUT_LABEL" CUT_REASON="$CUT_REASON" HSTAT="${HUMAN_STAT:-n/a}" OUTDIR="$RUN/$KEY" \
  python3 - <<'PY'
import os, json
key = os.environ["KEY"]; repo = os.environ["REPO"]
cl = os.environ["CUT_LABEL"]; cr = os.environ["CUT_REASON"]; hstat = os.environ["HSTAT"]; outdir = os.environ["OUTDIR"]
harness = {
    "id": key, "title": "py-service prorated refund — harness arm (two-arm prove)",
    "arm": "harness", "scorer": "stub", "complexity": "small", "compile": "n/a",
    "business_req_pct": 95,
    "code_quality": {"overall": "equal", "reuse": "better",
                     "rationale": "followed the money-cents guard skill: reused the shared Money model instead of re-deriving cents"},
    "security": {"verdict": "none — parity/better", "severity": "none", "reachable": False},
    "hallucination": "none", "overeng": "none", "lost_context": "none", "spec_fidelity": 95,
    "cutoff_label": cl, "cutoff_reason": cr, "decontam_confidence": "auto-only",
    "verdict": "harness arm: business req 95, reused the shared money model, no lost-context",
    "eval_note": "STUB score for the two-arm prove (mechanical pipeline, not real scoring).",
    "human_stat": hstat, "ai_stat": "stub edit", "artifacts": {"repo": repo},
}
baseline = dict(harness)
baseline.update({
    "title": "py-service prorated refund — baseline arm (two-arm prove)",
    "arm": "baseline", "business_req_pct": 60,
    "code_quality": {"overall": "worse", "reuse": "worse",
                     "rationale": "no guard skill: re-derived cents inline and emitted the wrong currency unit"},
    "lost_context": "refund emitted in major units but the consumer reads whole cents — locally-correct output the caller never reads correctly",
    "spec_fidelity": 70,
    "verdict": "baseline arm: business req 60, a lost-context defect the harness avoided",
})
json.dump(harness,  open(os.path.join(outdir, "score.json"), "w"),          indent=2)
json.dump(baseline, open(os.path.join(outdir, "score.baseline.json"), "w"), indent=2)
print("wrote score.json (harness=95) + score.baseline.json (baseline=60)")
PY
[ -s "$RUN/$KEY/score.json" ]          || fail "no score.json written"
[ -s "$RUN/$KEY/score.baseline.json" ] || fail "no score.baseline.json written"

step "9. selection.json — the sampling-frame disclosure"
OUT="$RUN/selection.json" python3 - <<'PY'
import os, json
json.dump({
    "candidates": 3, "selected": 1,
    "excluded": [
        {"unit": "REFUND-DUP",   "reason": "duplicate of the selected refund unit"},
        {"unit": "REFUND-INFRA", "reason": "infra-stalled — the sandbox could not be provisioned"},
    ],
}, open(os.environ["OUT"], "w"), indent=2)
print("wrote selection.json (candidates=3 selected=1 excluded=2)")
PY
[ -s "$RUN/selection.json" ] || fail "no selection.json written"

step "10. aggregate_scores.py — reads BOTH arms (score*.json), groups by arm"
export PROJECT_CONFIG="$CFG_H"
AGG_OUT="$(python3 "$LIB/aggregate_scores.py" "$RUN" 2>&1)"; AGG_RC=$?
printf '%s\n' "$AGG_OUT" | indent
[ "$AGG_RC" -eq 0 ]        || fail "aggregate_scores exited $AGG_RC"
[ -s "$RUN/scores.json" ]  || fail "aggregate produced no scores.json"

step "11. build_report.py -> report.html"
BR_OUT="$(python3 "$LIB/build_report.py" "$RUN" 2>&1)"; BR_RC=$?
printf '%s\n' "$BR_OUT" | indent
[ "$BR_RC" -eq 0 ]         || fail "build_report exited $BR_RC"
[ -s "$RUN/report.html" ]  || fail "build_report produced no report.html"
echo "  report.html: $(wc -c < "$RUN/report.html") bytes"

step "12. ASSERT ablation delta > 0 (both arms present)"
ASSERT_OUT="$(SCORES="$RUN/scores.json" python3 - <<'PY' 2>&1
import os, json
s = json.load(open(os.environ["SCORES"]))
agg = s.get("aggregate", {})
ad = agg.get("ablation_delta")
assert isinstance(ad, dict), "aggregate.ablation_delta missing (two-arm aggregate did not fire)"
d = ad.get("business_req_avg")
assert isinstance(d, (int, float)), "ablation_delta.business_req_avg missing/not numeric: %r" % (d,)
assert d > 0, "ablation_delta.business_req_avg must be > 0 (harness > baseline), got %r" % (d,)
arms = agg.get("arms", {})
assert "harness" in arms and "baseline" in arms, "aggregate.arms missing an arm: %r" % (sorted(arms),)
# provenance: these are stub scores, so the headline must say so — never "scored by adversarial review"
hl = agg.get("headline", "")
assert hl.startswith("STUB RUN — 2/2 scores are fixture constants"), "stub run not labelled: %r" % hl[:120]
assert "adversarial review" not in hl, "stub headline claims adversarial review: %r" % hl[:160]
print("headline provenance: %s" % hl.split(".")[0])
print("ablation_delta.business_req_avg = %s  (harness=%s / baseline=%s)" % (
    d, arms["harness"].get("business_req_avg"), arms["baseline"].get("business_req_avg")))
PY
)"; ASSERT_RC=$?
printf '%s\n' "$ASSERT_OUT" | indent
[ "$ASSERT_RC" -eq 0 ] || fail "ablation-delta assertion failed:\n$ASSERT_OUT"

step "13. ASSERT report.html has the ablation panel + per-unit cutoff_label + decontam_confidence"
grep -qi 'ablation'      "$RUN/report.html" || fail "report.html has no Ablation panel (grep -i ablation)"
grep -q  "$CUT_LABEL"    "$RUN/report.html" || fail "report.html has no per-unit cutoff_label chip ($CUT_LABEL)"
grep -q  'auto-only'     "$RUN/report.html" || fail "report.html has no decontam_confidence chip (auto-only)"
echo "  report.html: Ablation panel + cutoff_label ($CUT_LABEL) + decontam_confidence present"

step "14. ASSERT cutoff_label.py: private -> cutoff-clean; public no-model_cutoff -> cutoff-unverified"
PUB_OUT="$(python3 "$CUTOFF" "2025-06-01" public "" 2>&1)"; PUB_RC=$?
[ "$PUB_RC" -eq 0 ] || fail "cutoff_label.py exited $PUB_RC on the public unit"
PUB_LABEL="$(printf '%s' "$PUB_OUT" | cut -f1)"
[ "$PUB_LABEL" = "cutoff-unverified" ] || fail "expected public no-model_cutoff -> cutoff-unverified, got '$PUB_LABEL'"
echo "  cutoff_label.py: private -> cutoff-clean ; public/no-cutoff -> cutoff-unverified"

printf '\nPROVE-ABLATION PASS\n'
echo "  unit=$UNIT"
echo "  report=$RUN/report.html"
