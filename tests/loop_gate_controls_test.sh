#!/usr/bin/env bash
# tests/loop_gate_controls_test.sh — the held-out gate's controls, end to end (stub, k=1).
#
# A 17-unit fixture (tests/loop/make_fixture.sh); every unit has hand-pinned criteria: the main
# change, "a release-notes fragment under DIR/" and "no fragment outside DIR/". The fake implementer
# follows a fragment rule only if its always-on overlay states one. Each control runs in its own
# loop root (spent units never cross), all through `mahoraga loop gate`:
#   * planted positive: DIR = changes everywhere, candidate states it        -> KEEP
#   * random negative:  DIR drawn per unit from three, candidate states one  -> REVERT
#   * A/A:              candidate identical to the parent (empty)           -> REVERT, Δ ≡ 0
#   * placebo:          relevant-sounding, content-free practice            -> REVERT
#   * resume rewrites decision.json byte-identically and launches nothing; a second campaign
#     cannot reuse spent val units (-> 6); every decision is stamped stub
# These are plumbing controls (stub). The real controls on a real repo are .
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
FAKE="$ROOT/tests/fixtures/fake-claude"
fail() { printf 'LOOP-GATE-CONTROLS FAIL: %b\n' "$*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset ANTHROPIC_API_KEY MAHORAGA_ANTHROPIC_KEY_FILE MAHORAGA_TOKEN_FILE
export CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_OAUTH_TOKEN="$("$PY" -c 'import os; print("fake-credential-%d" % os.getpid())')"   # made up; unique so the scan cannot hit by chance
U=($(bash "$ROOT/tests/loop/make_fixture.sh" "$TMP" 17 | awk '$1 != "side" {print $1}')) || fail "fixture"
UNITS="$(IFS=,; echo "${U[*]}")"
cat > "$TMP/PROJECT.yaml" <<YAML
project: {id: "fx", name: "fixture", root: "$TMP/proj"}
repos: [{name: "app", language: "java", verify: {typecheck_cmd: "true"}}]
tracker: {adapter: none, config: {repo: "", base_branch: "main", merge_strategy: "merge"}}
spec: {adapter: none}
vcs: {adapter: git, base_branch: "main"}
skills: {source_dir: "/nonexistent", derived_skills: []}
decontamination: {exclusion: [], cutoff_policy: {repo_visibility: private}}
YAML
for u in "${U[@]}"; do mkdir -p "$TMP/inputs/$u"; echo "Implement the change." > "$TMP/inputs/$u/SPEC.md"; echo "Wanted." > "$TMP/inputs/$u/BUSINESS_REQUIREMENT.md"; done
BSHA="$(sha256sum "$FAKE" | cut -c1-64)"
root() {  # <name> <mode: planted|random:<seed>> — a loop root with a stub calibration and pinned criteria
  r="$TMP/root-$1"; mkdir -p "$r/fx/calib/stub"
  printf '{"model": "fake-model", "binary_sha": "%s", "scorer_model": "fake-model", "stub": true, "arms": {"pre": {"sd_within": 10}}}' "$BSHA" \
    > "$r/fx/calib/stub/calib.json"
  MODE="$2" R="$r" UNITS="$UNITS" "$PY" - <<'PY'
import json, os, random
mode, units = os.environ["MODE"], os.environ["UNITS"].split(",")
rng = random.Random(mode)
for u in units:
    d = "changes" if mode == "planted" else rng.choice(["changes-a", "changes-b", "changes-c"])
    p = os.path.join(os.environ["R"], "fx", "criteria", u)
    os.makedirs(p, exist_ok=True)
    json.dump([{"id": "c1", "criterion": "does the main thing", "source": "Implement the change.", "weight": 3},
               {"id": "frag", "criterion": "adds a release-notes fragment under %s/" % d, "source": "pinned", "weight": 2},
               {"id": "stray", "criterion": "adds no release-notes fragment outside %s/" % d, "source": "pinned", "weight": 2}],
              open(os.path.join(p, "pinned.json"), "w"), indent=2)
PY
}
cand() {  # <name> <practice> <conventions>
  mkdir -p "$TMP/cand-$1"; printf '%s' "$2" > "$TMP/cand-$1/practice.md"; printf '%s' "$3" > "$TMP/cand-$1/conventions.md"
}
gate() {  # <root> <campaign> <candidate> [args...]
  r="$1" c="$2" k="$3"; shift 3
  "$PY" "$ROOT/core/loop/loop.py" gate --config "$TMP/PROJECT.yaml" --root "$TMP/root-$r" --campaign "$c" --inputs "$TMP/inputs" \
    --units "$UNITS" --candidate "$TMP/cand-$k" --runner local --binary "$FAKE" --agent-bin "$FAKE" --scorer-bin "$FAKE" \
    --model fake-model --k 1 --per-job-usd 0.1 --scorer-per-job-usd 0.05 --budget-usd 20 --control-fixture "$@"
}
verdict() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['verdict'], d.get('label',''), d['stub'], round(d.get('mean_d') or 0, 1))" \
  "$TMP/root-$1/fx/c-$2/decision.json"; }

cand planted "" "Every change adds a release-notes fragment under changes/."
cand random "" "Every change adds a release-notes fragment under changes-a/."
cand aa "" ""
cand placebo "Write clean, well-structured code, and keep each change small and easy to review." ""

echo "== four controls, in parallel (separate roots) =="
root planted planted; root random random:1; root aa planted; root placebo planted
gate planted g0 planted --dry-run >/dev/null 2>&1 || fail "the early dry run failed"   # B2: a split made before g1 spends its units
for c in planted random placebo; do gate "$c" g1 "$c" > "$TMP/$c.log" 2>&1 & done
gate aa g1 aa --allow-noop > "$TMP/aa.log" 2>&1 &
( root nocal planted; rm -rf "$TMP/root-nocal/fx/calib"; gate nocal g1 planted > "$TMP/nocal.log" 2>&1; echo $? > "$TMP/nocal.rc" ) &
wait
[ "$(verdict planted g1 | cut -d' ' -f1)" = KEEP ] || { tail -15 "$TMP/planted.log"; fail "planted positive did not KEEP"; }
grep -E '^GATE KEEP' "$TMP/planted.log" | sed 's/^/    /'
ok "planted positive -> KEEP ($(verdict planted g1))"
[ "$(verdict random g1 | cut -d' ' -f1)" = REVERT ] || fail "random negative did not REVERT ($(verdict random g1))"
ok "random-mode negative -> REVERT ($(verdict random g1))"
v="$(verdict aa g1)"; [ "$(echo "$v" | cut -d' ' -f1)" = REVERT ] && [ "$(echo "$v" | awk '{print $NF}')" = 0 ] || fail "A/A did not REVERT with Δ 0 ($v)"
ok "A/A (candidate = parent) -> REVERT, mean d 0 ($v)"
[ "$(verdict placebo g1 | cut -d' ' -f1)" = REVERT ] || fail "placebo did not REVERT ($(verdict placebo g1))"
ok "placebo overlay -> REVERT ($(verdict placebo g1))"

[ "$(cat "$TMP/nocal.rc")" = 5 ] && [ "$(verdict nocal g1 | cut -d' ' -f1)" = INVALID ] || fail "no calibration did not INVALIDATE ($(cat "$TMP/nocal.rc"))"
gate nocal g1 planted >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && [ "$(verdict nocal g1 | cut -d' ' -f1)" = INVALID ] || fail "a rerun turned INVALID into $(verdict nocal g1) (rc $rc)"
ok "no calibration -> INVALID, and a rerun stays INVALID (a gate never calibrates itself)"
grep -q 'reasons' "$TMP/root-nocal/fx/c-g1/decision.json" && ! ls "$TMP/root-nocal/fx/calib" >/dev/null 2>&1 || fail "the gate wrote a calibration"

echo "== resume and spent units =="
cp "$TMP/root-planted/fx/c-g1/decision.json" "$TMP/d1.json"; rows=$(wc -l < "$TMP/root-planted/fx/c-g1/ledger.jsonl")
gate planted g1 planted >/dev/null 2>&1 || fail "resume exited non-zero"
cmp -s "$TMP/d1.json" "$TMP/root-planted/fx/c-g1/decision.json" || fail "resume did not rewrite decision.json byte-identically"
[ "$(wc -l < "$TMP/root-planted/fx/c-g1/ledger.jsonl")" -eq "$rows" ] || fail "resume launched jobs"
ok "resume: decision.json byte-identical, 0 new ledger rows"
gate planted g2 planted --dry-run >/dev/null 2>&1; rc=$?
[ "$rc" -eq 6 ] || fail "a second campaign on spent val units exited $rc (want 6)"
ok "a second campaign cannot reuse the spent val units -> 6"
gate planted g0 planted >/dev/null 2>&1; rc=$?
[ "$rc" -eq 6 ] || fail "a campaign whose split predates g1 measured g1's val units (rc $rc, want 6)"
ok "a split made (dry run) before another campaign spent its val units is refused on its real run -> 6"
cand nonoop "" ""; root noop planted; gate noop g1 nonoop --dry-run >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || fail "a NOOP candidate without --allow-noop exited $rc (want 3)"
ok "a candidate identical to its parent is refused (3) unless declared an A/A control"
grep -q '"protocol": "heldout-v1"' "$TMP/root-planted/fx/campaigns.jsonl" || fail "campaigns.jsonl does not record the campaign"
ok "every campaign recorded in campaigns.jsonl; every decision stamped stub"
echo
echo "LOOP-GATE-CONTROLS PASS"
