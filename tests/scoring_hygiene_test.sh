#!/usr/bin/env bash
# tests/scoring_hygiene_test.sh — the numbers PROVE reports cannot be manufactured by bookkeeping.
#
# Asserts (core/lib/score_hygiene.py + aggregate_scores.py + the report):
#   1. An arm with no numeric business_req_pct is "not measured" (None), never 0: its average, the
#      ablation delta and the report all say so, instead of a fabricated harness-minus-zero delta.
#   2. business_req_pct is recomputed from business_criteria: a grader's tampered value is
#      overridden (and kept as business_req_pct_reported, with a WARN); invalid criteria → not measured.
#   3. Arm blinding: `score_hygiene.py blind` stages each arm's diffs under seeded opaque labels — no
#      arm name in any path the scorer reads, the key kept outside blind/, deterministic per seed —
#      and `unblind` maps the scorer's files back to score.json / score.baseline.json with arm stamped.
#   4. A scorer from the implementer's model family is flagged SAME-FAMILY SCORING in the headline.
#
# Hermetic: own temp dir, cleaned up on exit. Needs bash + python3. Run from the repo root:
#     bash tests/scoring_hygiene_test.sh          # exit 0 = pass, non-zero = failure
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/core/lib"
PY="${PYTHON:-python3}"

fail() { printf 'SCORING-HYGIENE FAIL: %b\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# score <file> <json> — write one score file
score() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
agg() { "$PY" "$LIB/aggregate_scores.py" "$1" > "$TMP/agg.out" 2>&1 || { cat "$TMP/agg.out" >&2; fail "aggregate_scores exited non-zero on $1"; }; }
field() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1]))["aggregate"]
for k in sys.argv[2].split("."): d = d.get(k) if isinstance(d, dict) else None
print("None" if d is None else d)' "$1/scores.json" "$2"; }

BASE='"scorer": "stub", "compile": "n/a", "code_quality": {"overall": "equal"}, "security": {"verdict": "none"}'

# ---- 1. an unscored arm is not measured ---------------------------------------------------------
step "1. an arm with no numeric score is 'not measured', never 0"
R1="$TMP/r1"
score "$R1/U1/score.json"          "{\"id\": \"U1\", \"arm\": \"harness\", \"business_req_pct\": 80, $BASE}"
score "$R1/U1/score.baseline.json" "{\"id\": \"U1\", \"arm\": \"baseline\", $BASE}"
agg "$R1"
[ "$(field "$R1" arms.baseline.business_req_avg)" = None ] || fail "unscored baseline arm averaged to a number, not None"
[ "$(field "$R1" ablation_delta.business_req_avg)" = None ] || fail "ablation delta computed against an unscored arm"
grep -q 'WARN arm baseline: 1 of 1 unit(s) have no business_req_pct' "$TMP/agg.out" || fail "no WARN for the unscored arm"
"$PY" "$LIB/build_report.py" "$R1" >/dev/null 2>&1 || fail "build_report failed on an unscored arm"
grep -q 'not measured' "$R1/report.html" || fail "report does not say 'not measured'"
echo "  ok: baseline avg None, delta None, WARN printed, report says 'not measured'"

# ---- 2. business_req_pct is recomputed from the criteria ----------------------------------------
step "2. a tampered grader pct is overridden by the criteria roll-up; invalid criteria are not measured"
R2="$TMP/r2"
score "$R2/U2/score.json" "{\"id\": \"U2\", \"arm\": \"harness\", \"business_req_pct\": 95, $BASE,
  \"business_criteria\": [{\"criterion\": \"refund prorated\", \"weight\": 2, \"status\": \"full\"},
                          {\"criterion\": \"currency kept\", \"weight\": 1, \"status\": \"none\"}]}"
score "$R2/U3/score.json" "{\"id\": \"U3\", \"arm\": \"harness\", \"business_req_pct\": 90, $BASE,
  \"business_criteria\": [{\"criterion\": \"x\", \"status\": \"mostly\"}]}"
agg "$R2"
"$PY" - "$R2/scores.json" <<'PY' || fail "criteria recompute assertions failed"
import json, sys
t = {x["id"]: x for x in json.load(open(sys.argv[1]))["tasks"]}
assert t["U2"]["business_req_pct"] == 67, t["U2"]          # round(100 * 2 / 3)
assert t["U2"]["business_req_pct_reported"] == 95, t["U2"]
assert t["U2"]["business_req_source"] == "criteria", t["U2"]
assert t["U3"]["business_req_pct"] is None and t["U3"]["business_req_source"] == "invalid-criteria", t["U3"]
print("  ok: U2 95 -> 67 (recomputed), U3 invalid criteria -> not measured")
PY
grep -q 'WARN U2: grader business_req_pct 95 != 67' "$TMP/agg.out" || fail "no WARN for the overridden grader pct"
[ "$(field "$R2" business_req_overridden)" = 1 ] || fail "aggregate does not count the override"

# ---- 3. blinding ---------------------------------------------------------------------------------
step "3. arms are blinded under seeded labels and unblinded back"
R3="$TMP/r3"; mkdir -p "$R3/U4"
printf 'diff -ruN a/x.py b/x.py\n+harness change\n' > "$R3/U4/ai_svc.diff"
printf 'diff -ruN a/x.py b/x.py\n+baseline change\n' > "$R3/U4/baseline_svc.diff"
"$PY" "$LIB/score_hygiene.py" blind "$R3" U4 --seed 7 --arm harness=ai --arm baseline=baseline > "$TMP/labels" \
  || fail "blind exited non-zero"
[ "$(cat "$TMP/labels")" = "A B" ] || fail "expected labels 'A B', got '$(cat "$TMP/labels")'"
find "$R3/U4/blind" | grep -Eiq 'harness|baseline|ai_' && fail "an arm name leaks into a blind path"
[ ! -e "$R3/U4/blind/.blind-key.json" ] && [ -f "$R3/U4/.blind-key.json" ] || fail "the key must live outside blind/"
cat "$R3/U4/blind"/*/candidate_svc.diff | sort > "$TMP/blinded"
cat "$R3/U4"/ai_svc.diff "$R3/U4"/baseline_svc.diff | sort > "$TMP/orig"
cmp -s "$TMP/blinded" "$TMP/orig" || fail "blinded candidates are not the arms' diffs"
cp "$R3/U4/.blind-key.json" "$TMP/key1"
"$PY" "$LIB/score_hygiene.py" blind "$R3" U4 --seed 7 --arm harness=ai --arm baseline=baseline >/dev/null
cmp -s "$R3/U4/.blind-key.json" "$TMP/key1" || fail "the same seed gave a different label mapping"
seen=""
for s in 1 2 3 4 5 6 7 8; do
  "$PY" "$LIB/score_hygiene.py" blind "$R3" U4 --seed "$s" --arm harness=ai --arm baseline=baseline >/dev/null
  seen="$seen $("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["labels"]["A"])' "$R3/U4/.blind-key.json")"
done
case "$seen" in *harness*baseline*|*baseline*harness*) ;; *) fail "the shuffle never varied across 8 seeds:$seen" ;; esac
"$PY" "$LIB/score_hygiene.py" blind "$R3" U4 --seed 7 --arm harness=ai --arm baseline=baseline >/dev/null
for L in A B; do printf '{"id": "U4", "business_req_pct": 50, "scorer": "stub"}\n' > "$R3/U4/blind/$L/score.json"; done
"$PY" "$LIB/score_hygiene.py" unblind "$R3" U4 >/dev/null || fail "unblind exited non-zero"
"$PY" - "$R3/U4" <<'PY' || fail "unblind assertions failed"
import json, os, sys
u = sys.argv[1]; key = json.load(open(os.path.join(u, ".blind-key.json")))["labels"]
h, b = json.load(open(os.path.join(u, "score.json"))), json.load(open(os.path.join(u, "score.baseline.json")))
assert h["arm"] == "harness" and b["arm"] == "baseline", (h, b)
assert key[h["blind_label"]] == "harness" and key[b["blind_label"]] == "baseline", (key, h, b)
print("  ok: no arm name under blind/, key outside it, deterministic per seed, shuffle varies, unblind maps back")
PY

# ---- 4. same-family scoring is flagged -----------------------------------------------------------
step "4. a scorer sharing the implementer's model family is flagged"
R4="$TMP/r4"
score "$R4/U5/score.json" "{\"id\": \"U5\", \"arm\": \"harness\", \"business_req_pct\": 70, $BASE,
  \"scorer_family\": \"claude\", \"implementer_family\": \"claude\"}"
agg "$R4"
field "$R4" headline | grep -q 'SAME-FAMILY SCORING' || fail "same-family scorer not flagged in the headline"
R5="$TMP/r5"
score "$R5/U6/score.json" "{\"id\": \"U6\", \"arm\": \"harness\", \"business_req_pct\": 70, $BASE,
  \"scorer_family\": \"gemini\", \"implementer_family\": \"claude\"}"
agg "$R5"
field "$R5" headline | grep -q 'SAME-FAMILY' && fail "a different-family scorer was flagged"
[ "$(field "$R5" families.same_family)" = False ] || fail "families.same_family should be False"
echo "  ok: same family flagged; different family not"

echo
echo "SCORING-HYGIENE PASS"
