#!/usr/bin/env bash
# tests/loop_campaign_test.sh — the whole loop, end to end (stub, k=1), and promote.
#
# `mahoraga loop run` on fixtures whose merges carry a release-notes fragment (tests/loop/make_fixture.sh):
#   * planted (always changes/): train evidence -> the fake editor learns the convention from the
#     train units' human diffs ONLY -> the gate KEEPs a candidate whose origin is `proposer`
#   * random (changes-a/b/c per unit): the learned rule misfires on val -> REVERT
#   * an editor that falls back -> FELL_BACK, and no val unit is reserved (nothing was spent on val)
#   * promote: refuses a stub, a session-written candidate, instructed isolation, REVERT and INVALID;
#     on a valid KEEP writes both overlay files and PROVENANCE.json with learned_through = C_split
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
FAKE="$ROOT/tests/fixtures/fake-claude"
fail() { printf 'LOOP-CAMPAIGN FAIL: %b\n' "$*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset ANTHROPIC_API_KEY MAHORAGA_ANTHROPIC_KEY_FILE MAHORAGA_TOKEN_FILE
export CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_OAUTH_TOKEN="$("$PY" -c 'import os; print("fake-credential-%d" % os.getpid())')"   # made up
BSHA="$(sha256sum "$FAKE" | cut -c1-64)"
setup() {  # <name> <FRAG mode> [spec scenario] — a fixture repo, config, inputs, pinned criteria, stub calibration
  d="$TMP/$1"; mkdir -p "$d"
  FRAG="$2" bash "$ROOT/tests/loop/make_fixture.sh" "$d" 17 | awk '$1 != "side"' > "$d/units.txt" || fail "fixture $1"
  cat > "$d/PROJECT.yaml" <<YAML
project: {id: "fx", name: "fixture", root: "$d/proj"}
repos: [{name: "app", language: "java", verify: {typecheck_cmd: "true"}}]
tracker: {adapter: none, config: {repo: "", base_branch: "main", merge_strategy: "merge"}}
spec: {adapter: none}
vcs: {adapter: git, base_branch: "main"}
skills: {source_dir: "/nonexistent", derived_skills: []}
decontamination: {exclusion: [], cutoff_policy: {repo_visibility: private}}
loop: {overlay_dir: "$d/overlay"}
YAML
  mkdir -p "$d/root/fx/calib/stub"
  printf '{"model": "fake-model", "binary_sha": "%s", "scorer_model": "fake-model", "stub": true}' "$BSHA" > "$d/root/fx/calib/stub/calib.json"
  while read -r sha name frag; do
    mkdir -p "$d/inputs/$sha" "$d/root/fx/criteria/$sha"
    printf 'Add the %s total.\n%s\n' "$name" "${3:+SCENARIO=$3}" > "$d/inputs/$sha/SPEC.md"; echo "Wanted." > "$d/inputs/$sha/BUSINESS_REQUIREMENT.md"
    printf '[{"id": "c1", "criterion": "does the main thing", "source": "Add the total.", "weight": 3},
 {"id": "frag", "criterion": "adds a release-notes fragment under %s/", "source": "pinned", "weight": 2},
 {"id": "stray", "criterion": "adds no release-notes fragment outside %s/", "source": "pinned", "weight": 2}]' "$frag" "$frag" \
      > "$d/root/fx/criteria/$sha/pinned.json"
  done < "$d/units.txt"
}
run() {  # <name> <campaign>
  d="$TMP/$1"
  "$PY" "$ROOT/core/loop/loop.py" run --config "$d/PROJECT.yaml" --root "$d/root" --campaign "$2" --inputs "$d/inputs" \
    --units "$(awk '{print $1}' "$d/units.txt" | paste -sd,)" --runner local --binary "$FAKE" --agent-bin "$FAKE" --scorer-bin "$FAKE" \
    --editor-bin "$FAKE" --model fake-model --k 1 --per-job-usd 0.1 --scorer-per-job-usd 0.05 --editor-per-job-usd 0.1 \
    --budget-usd 20 --control-fixture --jobs 3
}
dec() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['verdict'], d.get('origin'), d.get('label',''))" "$TMP/$1/root/fx/c-$2/decision.json"; }

echo "== loop run: planted, random and a falling-back editor, in parallel =="
setup planted planted; setup random random:3; setup ghost planted editor_ghost
for n in planted random ghost; do run "$n" c1 > "$TMP/$n.log" 2>&1 & done
wait
grep -E 'proposer|^GATE' "$TMP/planted.log" | sed 's/^/    /'
[ "$(dec planted c1)" = "KEEP proposer " ] || { tail -15 "$TMP/planted.log"; fail "planted loop run did not KEEP a proposer candidate ($(dec planted c1))"; }
grep -q 'release-notes fragment under changes/' "$TMP/planted/root/fx/c-c1/candidate/overlay/conventions.md" || fail "the proposer did not write the convention"
"$PY" -c "import json,sys; s=json.load(open(sys.argv[1])); assert len(s['evidence_files']) == 6 and all('human.diff' in f for f in s['evidence_files']), s" \
  "$TMP/planted/root/fx/c-c1/propose/status.json" || fail "the proposer's evidence was not the 6 train units"
ok "planted: the proposer learned the convention from the 6 train units' history -> KEEP (origin proposer)"
[ "$(dec random c1 | cut -d' ' -f1)" = REVERT ] || { tail -15 "$TMP/random.log"; fail "random loop run did not REVERT ($(dec random c1))"; }
ok "random directories: the learned rule misfires on val -> $(dec random c1)"
[ "$(dec ghost c1 | cut -d' ' -f1)" = FELL_BACK ] || { tail -15 "$TMP/ghost.log"; fail "a falling-back editor gave $(dec ghost c1)"; }
[ ! -f "$TMP/ghost/root/fx/reserved.json" ] || fail "val units were reserved although nothing was measured"
ok "an editor that falls back -> FELL_BACK, no val unit reserved"

echo "== promote =="
"$PY" "$ROOT/core/loop/loop.py" promote --config "$TMP/planted/PROJECT.yaml" --root "$TMP/planted/root" --campaign c1 --dry-run > "$TMP/p.log" 2>&1; rc=$?
[ "$rc" -eq 3 ] && grep -q 'REFUSED: a stub run' "$TMP/p.log" || fail "promote did not refuse a stub run (rc $rc)"
ok "promote refuses a stub run (and there is no override flag)"
ROOT="$ROOT" C="$TMP/planted/root/fx/c-c1" O="$TMP/planted/overlay" R="$TMP/planted/proj/app" "$PY" - <<'PY' || fail "promote assertions"
import json, os, shutil, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import promote
c, o, r = os.environ["C"], os.environ["O"], os.environ["R"]
d, p = json.load(open(os.path.join(c, "decision.json"))), json.load(open(os.path.join(c, "prereg.json")))
assert any("control-fixture" in x for x in promote.refusals(d, p))
for patch, why in (({"verdict": "REVERT"}, "not KEEP"), ({"verdict": "INVALID"}, "not KEEP")):
    assert any(why in x for x in promote.refusals(dict(d, stub=False, control_fixture=False, **patch), dict(p, isolation="enforced", control_fixture=False))), patch
assert any("contained proposer" in x for x in promote.refusals(dict(d, stub=False), dict(p, origin="session", isolation="enforced")))
assert any("isolation" in x for x in promote.refusals(dict(d, stub=False), dict(p, isolation="instructed")))
print("  ok: promote refuses REVERT, INVALID, a session-written candidate, instructed isolation and a control fixture")
assert promote.chain(c, d, o) == [], promote.chain(c, d, o)
print("  ok: the untouched campaign's records agree: prereg = decision = ledger row 0, candidate frozen = measured, KEEP logged")
json.dump(dict(p, isolation="enforced"), open(os.path.join(c, "prereg.json"), "w"))
assert any("disagree" in x for x in promote.chain(c, d, o))
open(os.path.join(c, "prereg.json"), "w").write(json.dumps(p, indent=2, sort_keys=True))  # the sealed bytes, restored
cand = os.path.join(c, "candidate", "overlay", "practice.md")
keep = open(cand).read(); open(cand, "w").write(keep + "Also do X.\n")
assert any("not the one that was frozen" in x for x in promote.chain(c, d, o))
open(cand, "w").write(keep)
print("  ok: an edited prereg.json, or edited candidate bytes, break the chain (editing records is not an override)")
import subprocess
real = (promote.refusals, promote.chain)
promote.refusals = promote.chain = lambda *a: []  # past the refusals: only the re-validation at HEAD is under test
open(cand, "w").write(keep + "New totals mirror computeAlphaTotal.\n")
assert promote.plan(c, o, r, "java")[0] == [], promote.plan(c, o, r, "java")[0]
git = lambda *a: subprocess.run(["git", "-C", r] + list(a), check=True, capture_output=True)
git("rm", "-q", "src/Alpha.java"); git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "drop Alpha")
e = promote.plan(c, o, r, "java")[0]
assert any(x.startswith("at HEAD: ") and "computeAlphaTotal" in x for x in e), e
git("reset", "-q", "--hard", "HEAD~1"); open(cand, "w").write(keep); promote.refusals, promote.chain = real
print("  ok: promote re-validates at the repo's HEAD: an identifier HEAD no longer has is refused")
prov = promote.write(c, o)
split = json.load(open(os.path.join(c, "split.json")))
assert sorted(os.listdir(o)) == ["PROVENANCE.json", "conventions.md", "practice.md"] and prov["learned_through"] == split["c_split"], prov
assert any("not the parent it was measured against" in x for x in promote.chain(c, d, o))
print("  ok: promote writes both files + PROVENANCE (learned_through = C_split); the same campaign cannot then overwrite its own result")
PY
"$PY" "$ROOT/core/loop/loop.py" promote --config "$TMP/ghost/PROJECT.yaml" --root "$TMP/ghost/root" --campaign c1 --dry-run > "$TMP/p2.log" 2>&1; rc=$?
[ "$rc" -eq 3 ] && grep -q 'REFUSED' "$TMP/p2.log" || fail "promote on a FELL_BACK campaign exited $rc (want 3, no traceback)"
ok "promote on a campaign with no frozen candidate -> 3, not a traceback"
echo
echo "LOOP-CAMPAIGN PASS"
