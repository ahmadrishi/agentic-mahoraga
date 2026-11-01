#!/usr/bin/env bash
# tests/loop_insample_test.sh — `mahoraga loop insample` end to end, hermetic (no model, no $, no docker).
#
# Four merged units in ancestry order; fake-claude as implementer, editor and scorer (stub run). The
# fake arm marks its change when its always-on file carries an overlay and the fake scorer rewards
# the mark, so the run is a PLANTED POSITIVE: Rules A and B must pass, computed by code. Proves:
#   * prereg sealed as ledger row 0 (its sha), and a changed protocol on resume -> 6
#   * 45 rollouts planned = executed (pre 4x6 + 7 candidates x3), each scored
#   * post_U's editor sees its unit's SPEC/BR and three unlabelled attempts only (no human diff, no
#     statuses); post_P(u)'s editor sees only EARLIER units; units out of ancestry order -> 3
#   * the accepted overlay reaches the always-on file; a resume launches nothing
#   * editor (direct): an eval word is fed back WITH the task and fixed on retry; an identifier planted
#     in the workspace copy of repo/ does not count and repo/ is restored; a nonexistent identifier
#     twice -> fell_back; a no-op is `noop`; honey in the notes -> exit 2; a failed session -> exit 4
#     with no status written (never a silent fall-back)
#   * in the protocol: fell-back candidates get no post rollouts and count as Δ 0; 4 units are
#     required; a decision from a stub run is marked advisory
#   * the Codex scorer path prices its tokens and records family gpt
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
LOOP="$ROOT/core/loop/loop.py"
FAKE="$ROOT/tests/fixtures/fake-claude"
fail() { printf 'LOOP-INSAMPLE FAIL: %b\n' "$*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset ANTHROPIC_API_KEY MAHORAGA_ANTHROPIC_KEY_FILE MAHORAGA_TOKEN_FILE
export CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_OAUTH_TOKEN="$("$PY" -c 'import os; print("fake-credential-%d" % os.getpid())')"   # made up

echo "== fixture: a Java repo with four merged units in history order =="
P="$TMP/proj"; R="$P/app"; mkdir -p "$R/src"
git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'public class App {\n    public void runApplication() {}\n}\n' > "$R/src/App.java"
git -C "$R" add -A; git -C "$R" commit -qm init
U=()
for n in Billing Invoices Refunds Ledger; do
  git -C "$R" checkout -qb "f$n"
  printf 'public class %s {\n    public int compute%sTotal() { return 1; }\n}\n' "$n" "$n" > "$R/src/$n.java"
  git -C "$R" add -A; git -C "$R" commit -qm "$n"; git -C "$R" checkout -q main
  git -C "$R" merge -q --no-ff "f$n" -m "Merge $n"; U+=("$(git -C "$R" rev-parse HEAD)")
done
CFG="$TMP/PROJECT.yaml"
cat > "$CFG" <<EOF
project: {id: "fx", name: "fixture", root: "$P"}
repos:
  - name: "app"
    language: "java"
    verify:
      typecheck_cmd: "! grep -rq BROKEN src"
tracker: {adapter: none, config: {repo: "", base_branch: "main", merge_strategy: "merge"}}
spec: {adapter: none}
vcs: {adapter: git, base_branch: "main"}
skills: {source_dir: "/nonexistent", derived_skills: []}
decontamination: {exclusion: []}
EOF
inputs() {  # <dir> <scenario> [extra]
  for u in "${U[@]}"; do mkdir -p "$1/$u"
    printf 'Implement the change.\nSCENARIO=%s\n%s\n' "$2" "${3:-}" > "$1/$u/SPEC.md"; echo "The business wants it." > "$1/$u/BUSINESS_REQUIREMENT.md"; done
}
LR="$TMP/state"
run() {  # <campaign> <inputs> <units csv> [args...]
  c="$1" in="$2" units="$3"; shift 3
  "$PY" "$LOOP" insample --config "$CFG" --root "$LR" --campaign "$c" --inputs "$in" --units "$units" --runner local \
    --binary "$FAKE" --agent-bin "$FAKE" --scorer-bin "$FAKE" --editor-bin "$FAKE" --model fake-model \
    --per-job-usd 0.1 --scorer-per-job-usd 0.05 --editor-per-job-usd 0.1 --budget-usd 20 "$@"
}
CD() { echo "$LR/fx/c-$1"; }
ALL="$(IFS=,; echo "${U[*]}")"

echo "== planted positive: 4 units, pre k=6, 7 candidates x k=3 =="
inputs "$TMP/in" edit
OUT="$(run kt "$TMP/in" "$ALL" 2>&1)"; rc=$?
printf '%s\n' "$OUT" | grep -E 'editor|Rule|INVALID|DONE|FAIL|rror' | sed 's/^/    /'
[ "$rc" -eq 0 ] || { printf '%s\n' "$OUT" | tail -20; fail "kill test exited $rc"; }
C="$(CD kt)" U1="${U[0]}" U2="${U[1]}" U3="${U[2]}" U4="${U[3]}" "$PY" - <<'PY' || fail "kill-test assertions"
import glob, hashlib, json, os
c = os.environ["C"]; units = [os.environ["U%d" % i] for i in range(1, 5)]
rows = [json.loads(l) for l in open(os.path.join(c, "ledger.jsonl"))]
assert rows[0]["kind"] == "prereg" and rows[0]["runkey"] == hashlib.sha256(open(os.path.join(c, "prereg.json"), "rb").read()).hexdigest()
print("  ok: prereg.json sealed as ledger row 0 (sha matches)")
imp = [r for r in rows if r["kind"] == "implement"]
by = lambda arm: [r for r in imp if r["arm"] == arm]
assert len(imp) == 45 and len(by("pre")) == 24 and len(by("post_U")) == 12 and len(by("post_P")) == 9, len(imp)
summaries = [r for r in rows if r["kind"] == "score" and "of" in r]  # one per rollout; attempt rows have no "of"
assert all(r["status"] == "ok" for r in imp) and len(summaries) == 45 and all(r["status"] == "ok" for r in summaries), len(summaries)
print("  ok: 45 rollouts planned = executed (pre 24, post_U 12, post_P 9), all scored")
index = json.load(open(os.path.join(c, "propose", "index.json")))
st = lambda arm, u: json.load(open(os.path.join(c, "propose", index["%s-%s" % (arm, u[:12])], "status.json")))
assert all(u[:10] not in name for name in os.listdir(os.path.join(c, "propose")) for u in units)
for i, u in enumerate(units):
    s = st("post_U", u)
    assert s["evidence_units"] == [u[:12]] and s["evidence_files"] == [["BUSINESS_REQUIREMENT.md", "SPEC.md", "attempt-1.diff", "attempt-2.diff", "attempt-3.diff"]], s
    if i:
        s = st("post_P", u)
        assert s["evidence_units"] == [v[:12] for v in units[:i]], (i, s["evidence_units"])
        assert all(f == ["BUSINESS_REQUIREMENT.md", "SPEC.md", "attempt.diff", "criteria-status.json", "human.diff"] for f in s["evidence_files"]), s
assert "post_P-%s" % units[0][:12] not in index
print("  ok: post_U saw its own SPEC/BR + 3 unlabelled attempts; post_P(u) saw only earlier units, with statuses; dirs are opaque")
claude_md = open(os.path.join(c, "snapshots", "post_U-%s" % units[1][:12], "CLAUDE.md")).read()
assert "## Process habits for this codebase" in claude_md and "Read the existing service" in claude_md
assert "## Process habits" not in open(os.path.join(c, "snapshots", "pre-%s" % units[1][:12], "CLAUDE.md")).read()
print("  ok: the accepted overlay is in post arms' always-on file, not in pre's")
d = json.load(open(os.path.join(c, "decision.json")))
assert d["rule_a"]["verdict"] == "PASS" and d["rule_a"]["G"] == 0 and d["rule_a"]["delta"] == 12, d["rule_a"]
assert d["rule_b"]["verdict"] == "PASS" and d["rule_b"]["wins"] == 3, d["rule_b"]
assert "time" not in json.dumps(d) and d["prereg_sha"] == rows[0]["runkey"] and d["advisory"] is True and d["stub"] is True
print("  ok: Rules A and B computed by code: planted +12 -> PASS (G 0); decision.json has no timestamps")
PY
before=$(wc -l < "$(CD kt)/ledger.jsonl")
run kt "$TMP/in" "$ALL" >/dev/null 2>&1 || fail "resume exited non-zero"
[ "$(wc -l < "$(CD kt)/ledger.jsonl")" -eq "$before" ] || fail "resume launched jobs again"
ok "resume: same command, 0 new ledger rows"
run kt "$TMP/in" "$ALL" --editor-per-job-usd 0.2 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 6 ] || fail "a changed protocol on the same campaign exited $rc (want 6)"
ok "a changed prereg on the same campaign -> 6"

echo "== order, unit count =="
run order "$TMP/in" "${U[1]},${U[0]},${U[2]},${U[3]}" --dry-run >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || fail "units out of ancestry order exited $rc (want 3)"
ok "units out of ancestry order -> 3"
run three "$TMP/in" "${U[0]},${U[1]},${U[2]}" --dry-run >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || fail "three units exited $rc (want 3)"
ok "anything but 4 units -> 3"

echo "== fell-back candidates in the protocol: no post rollouts, Δ 0 =="
inputs "$TMP/in-fb" edit
printf 'Implement the change.\nSCENARIO=editor_ghost\n' > "$TMP/in-fb/${U[0]}/SPEC.md"   # post_U(u1) and every post_P see u1 first
OUT="$(run fb "$TMP/in-fb" "$ALL" 2>&1)" || { printf '%s\n' "$OUT" | tail -10; fail "fell-back campaign failed"; }
C="$(CD fb)" "$PY" - <<'PY' || fail "fell-back assertions"
import json, os
c = os.environ["C"]
rows = [json.loads(l) for l in open(os.path.join(c, "ledger.jsonl"))]
imp = [r for r in rows if r["kind"] == "implement"]
assert sum(r["arm"] == "post_P" for r in imp) == 0 and sum(r["arm"] == "post_U" for r in imp) == 9, len(imp)
d = json.load(open(os.path.join(c, "decision.json")))
assert d["rule_a"]["per_unit"][0] == 0.0 and d["rule_b"]["per_unit"] == [0.0, 0.0, 0.0], (d["rule_a"], d["rule_b"])
assert d["rule_a"]["delta"] == 9.0 and d["rule_a"]["verdict"] == "underpowered-no-go"   # (0+12+12+12)/4
PY
ok "4 fell-back candidates measured nothing and count as Δ 0 (Δ_U 9 -> no-go, Δ_P 0)"

echo "== the editor, directly =="
ROOT="$ROOT" TMP="$TMP" FAKE="$FAKE" REPO="$R" "$PY" - <<'PY' || fail "editor assertions"
import json, os, shutil, subprocess, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import executor, ledger, propose
t, fake = os.environ["TMP"], os.environ["FAKE"]
tree = os.path.join(t, "fork"); os.makedirs(tree)
subprocess.run("git -C %s archive HEAD | tar -x -C %s" % (os.environ["REPO"], tree), shell=True, check=True)
honey = os.path.join(t, "honey"); os.makedirs(honey); open(os.path.join(honey, ".honey-x"), "w").write("mh-honey-abc")
prompt = open(os.path.join(os.environ["ROOT"], "core", "loop", "prompts", "propose.md")).read() % {"mode": "x"}
def edit(scenario, extra=""):
    out = os.path.join(t, "ed-" + scenario)
    ctx = {"ledger": ledger.Ledger(t, 99), "secrets": [],
           "editor_job": {"runner": "local", "binary": fake, "model": "m", "tools": propose.EDITOR_TOOLS, "max_turns": 5,
                          "max_budget_usd": 0.1, "timeout_s": 60},
           "expect": {"editor": {"skills": [], "builtin_skills": None, "tools": propose.EDITOR_TOOLS, "model": "m", "version": None}}}
    ev = [{"SPEC.md": "SCENARIO=%s\n%s\n" % (scenario, extra)}]
    return propose.edit(ctx, out, "rk-" + scenario, prompt, None, tree, ev, "java", ["mh-honey-abc"])
r = edit("editor_tell"); assert (r["status"], r["attempts"]) == ("ok", 2), r
print("  ok: an eval word is fed back with the task; the retry fixes it (ok after 2)")
r = edit("editor_plant"); assert (r["status"], r["attempts"]) == ("ok", 2) and not os.path.exists(os.path.join(tree, "src", "Ghost.java")), r
assert any("restored" in e for e in r["rejected"][0]) and any("fetchGhostRecords" in e for e in r["rejected"][0]), r
print("  ok: an identifier planted in the workspace repo/ does not count (checked on the pristine fork); repo/ restored")
r = edit("editor_ghost"); assert (r["status"], r["attempts"]) == ("fell_back", 2) and "fetchGhostRecords" in " ".join(r["errors"]), r
r = edit("editor_noop"); assert r["status"] == "noop", r
print("  ok: an absent identifier twice -> fell_back; an unchanged overlay -> noop")
try:
    edit("editor_honey", "HONEY_DIR=" + honey); raise AssertionError("no tripwire")
except executor.LoopError as e:
    assert e.code == 2, e
try:
    edit("editor_fail"); raise AssertionError("a failed session fell back")
except executor.LoopError as e:
    assert e.code == 4 and not os.path.isfile(os.path.join(t, "ed-editor_fail", "status.json")), e
print("  ok: honey in the notes -> exit 2; a failed editor session -> exit 4, nothing recorded as a fall-back")
PY

echo "== the Codex scorer path =="
ROOT="$ROOT" TMP="$TMP" "$PY" - <<'PY' || fail "codex scorer path"
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import executor, ledger, score
calls = []
def fake_run_scorer(job, secrets=()):
    calls.append(job)
    assert json.load(open(os.path.join(job["view"], "schema.json"))) == {"x": 1}
    return {"status": "ok", "reason": "completed", "usage": {"input_tokens": 1000, "cached_input_tokens": 0, "output_tokens": 100},
            "output": {"ok": True}, "scan_hits": [], "wall_s": 1.0, "model": job["model"]}
executor.run_scorer = fake_run_scorer
L = ledger.Ledger(os.environ["TMP"], 5)
ctx = {"scorer": "codex", "scorer_family": "gpt", "ledger": L, "secrets": [],
       "codex_job": {"model": "gpt-5.4-mini-2026-03-17", "max_budget_usd": 0.05}}
so = score._ask(ctx, os.path.join(os.environ["TMP"], "cx"), "prompt", {"x": 1}, "score", "rk", 1)
row = L.rows[-1]
assert so == {"ok": True} and row["usd"] == round((1000 * 0.75 + 100 * 4.50) / 1e6, 6) and row["family"]["value"] == "gpt", row
print("  ok: Codex output read from its result; usd priced from tokens (%s); family gpt" % row["usd"])
PY

echo
echo "LOOP-INSAMPLE PASS"
