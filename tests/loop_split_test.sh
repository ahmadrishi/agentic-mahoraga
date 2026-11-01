#!/usr/bin/env bash
# tests/loop_split_test.sh — the held-out split is chronological, vetted and spent-aware.
#
# On a fixture whose commit dates run BACKWARDS (tests/loop/make_fixture.sh), via `loop gate --dry-run`:
#   * order = first-parent topology, not dates; train = the earliest 6 vetted, then 1 gap, then 10 val
#   * every drop is recorded with its reason: missing inputs, vetoed, not on first-parent history,
#     a val unit whose fork precedes a train merge (refilled by the next unit)
#   * a unit already scored by another campaign is never val (spent) but may still be train
#   * too few units -> 6 (infeasible); a jira tracker -> 3
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
FAKE="$ROOT/tests/fixtures/fake-claude"
fail() { printf 'LOOP-SPLIT FAIL: %b\n' "$*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset ANTHROPIC_API_KEY MAHORAGA_ANTHROPIC_KEY_FILE MAHORAGA_TOKEN_FILE
FX="$(bash "$ROOT/tests/loop/make_fixture.sh" "$TMP" 21 late)" || fail "fixture"
U=($(printf '%s\n' "$FX" | awk '$1 != "side" && $1 != "late" {print $1}')); SIDE="$(printf '%s\n' "$FX" | awk '$1=="side"{print $2}')"
LATE="$(printf '%s\n' "$FX" | awk '$1=="late"{print $2}')"
mkcfg() {  # <out> <tracker>
  cat > "$1" <<YAML
project: {id: "fx", name: "fixture", root: "$TMP/proj"}
repos: [{name: "app", language: "java", verify: {typecheck_cmd: "true"}}]
tracker: {adapter: $2, config: {repo: "", base_branch: "main", merge_strategy: "merge"}}
spec: {adapter: none}
vcs: {adapter: git, base_branch: "main"}
skills: {source_dir: "/nonexistent", derived_skills: []}
decontamination: {exclusion: [], cutoff_policy: {repo_visibility: private}}
YAML
}
mkcfg "$TMP/PROJECT.yaml" none; mkcfg "$TMP/jira.yaml" jira
IN="$TMP/inputs"
for u in "${U[@]}" "$SIDE" "$LATE"; do mkdir -p "$IN/$u"; echo "Implement the change." > "$IN/$u/SPEC.md"; echo "Wanted." > "$IN/$u/BUSINESS_REQUIREMENT.md"; done
rm -rf "$IN/${U[8]}"                                  # unit 9: no SPEC/BR -> dropped
mkdir -p "$TMP/cand"; echo "Read the existing service first." > "$TMP/cand/practice.md"; : > "$TMP/cand/conventions.md"
gate() {  # <campaign> <units csv> [args...]
  c="$1" units="$2"; shift 2
  CLAUDE_CODE_OAUTH_TOKEN=x "$PY" "$ROOT/core/loop/loop.py" gate --config "$TMP/PROJECT.yaml" --root "$TMP/state" --campaign "$c" \
    --inputs "$IN" --units "$units" --candidate "$TMP/cand" --runner local --binary "$FAKE" --agent-bin "$FAKE" --scorer-bin "$FAKE" \
    --model fake-model --budget-usd 5 --dry-run "$@"
}
# a previous campaign scored unit 3 (would be train) and unit 13 (would be val)
mkdir -p "$TMP/state/fx/c-old"
printf '{"kind": "score", "runkey": "a", "status": "ok", "unit": "%s"}\n{"kind": "score", "runkey": "b", "status": "ok", "unit": "%s"}\n' \
  "${U[2]}" "${U[12]}" > "$TMP/state/fx/c-old/ledger.jsonl"
SHUF="$(printf '%s\n' "${U[@]}" "$SIDE" "$LATE" | "$PY" -c 'import random,sys; l=sys.stdin.read().split(); random.Random(5).shuffle(l); print(",".join(l))')"
OUT="$(gate s1 "$SHUF" --veto "${U[10]}" 2>&1)" || { printf '%s\n' "$OUT" | tail -20; fail "dry-run exited non-zero"; }
printf '%s\n' "$OUT" | grep -E '^(split|  drop|power)' | sed 's/^/    /'
S="$TMP/state/fx/c-s1/split.json" U="$(IFS=,; echo "${U[*]}")" SIDE="$SIDE" LATE="$LATE" "$PY" - <<'PY' || fail "split assertions"
import json, os
s = json.load(open(os.environ["S"])); u = os.environ["U"].split(",")
assert s["order"][:3] == u[:3], "order is not first-parent topology (dates run backwards)"
assert s["train"] == u[:6] and s["c_split"] == u[5], s["train"]
print("  ok: order follows first-parent topology although every date runs backwards; train = the first 6 (incl. the spent unit 3)")
assert s["gap"] == [u[6]], s["gap"]
d = s["drops"]
assert d[os.environ["SIDE"]] == "not-on-first-parent-history" and d[u[8]].startswith("prepare: missing") and d[u[10]] == "vetoed"
assert d[u[12]] == "spent" and d[os.environ["LATE"]] == "fork-precedes-train", d
print("  ok: drops recorded: side-branch commit, missing SPEC/BR, vetoed, spent (never val), late fork (fork-precedes-train)")
want = [x for i, x in enumerate(u) if i >= 7 and i not in (8, 10, 12)][:10]
assert s["val"] == want and len(s["val"]) == 10, (s["val"], want)
print("  ok: val = the next 10 vetted, unspent units in order; dropped ones refilled")
PY
gate s2 "$(IFS=,; echo "${U[*]:0:12}")" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 6 ] || fail "an infeasible split exited $rc (want 6)"
ok "too few units for 6 + 1 + 10 -> 6 (infeasible)"
CLAUDE_CODE_OAUTH_TOKEN=x "$PY" "$ROOT/core/loop/loop.py" gate --config "$TMP/jira.yaml" --root "$TMP/state" --campaign s3 --inputs "$IN" \
  --units "${U[0]}" --candidate "$TMP/cand" --runner local --binary "$FAKE" --agent-bin "$FAKE" --budget-usd 5 --dry-run >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || fail "a jira tracker exited $rc (want 3)"
ok "a jira tracker -> 3 (its dates cannot order units honestly)"
echo
echo "LOOP-SPLIT PASS"
