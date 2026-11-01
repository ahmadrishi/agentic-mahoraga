#!/usr/bin/env bash
# tests/loop_rollout_test.sh — `mahoraga loop prove` end to end, hermetic (no model, no $, no docker).
#
# A throwaway Java git fixture (two merged units), fake-claude as implementer AND scorer (stub run),
# the instructed local runner. Proves every guard in the rollout order:
#   * the gate contract: both pinned leak_gate.sh strings, parsed (never assumed from the exit code)
#   * the staged repo's own .claude/ and CLAUDE.md are stripped, and filtered out of the diff
#   * the case-variant floor regression: a fork row `getUserID` is dropped when the answer adds `getUserId`
#   * a planted symlink or FIFO -> integrity_failed, nothing extracted, run INVALID (5)
#   * a credential or honey string in a rollout's output -> exit 2, redacted on disk
#   * the scorer view holds five files and no arm, unit id or slug; scorer_failed -> None, never 0
#   * an empty change is code-scored 0; final/ renders through aggregate_scores + build_report
#   * budget exit 4 before any launch; resume skips DONE; identity change and corrupt ledger -> 6;
#     loop.root inside a git work tree -> 3
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
LOOP="$ROOT/core/loop/loop.py"
FAKE="$ROOT/tests/fixtures/fake-claude"
fail() { printf 'LOOP-ROLLOUT FAIL: %b\n' "$*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset ANTHROPIC_API_KEY MAHORAGA_ANTHROPIC_KEY_FILE MAHORAGA_TOKEN_FILE
export CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_OAUTH_TOKEN="$("$PY" -c 'import os; print("fake-credential-%d" % os.getpid())')"   # made up

echo "== gate contract: the two strings rollout.py parses are still what leak_gate.sh prints =="
grep -q 'WARN — NOTHING CHECKED' "$ROOT/core/lib/leak_gate.sh" || fail "leak_gate.sh no longer prints NOTHING CHECKED"
grep -q '0 hits across $ntok answer token(s) in sandbox skills' "$ROOT/core/lib/leak_gate.sh" || fail "leak_gate.sh pass line changed"
ROOT="$ROOT" "$PY" - <<'PY' || fail "gate()/filter_diff() contract"
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import rollout
g = rollout.gate("LEAK-GATE PASS (u): 0 hits across 7 answer token(s) in sandbox skills\n", 0)
assert g["ok"] and g["n_tokens"] == 7, g
assert rollout.gate("LEAK-GATE PASS (u): WARN — NOTHING CHECKED (no configured ...)\n", 0)["reason"] == "nothing-checked"
assert rollout.gate("STAGED x (u): r,\n", 0)["reason"] == "no-gate-verdict"
g = rollout.gate("LEAK[auto-derived] getUserId: /sb/m1/.claude/skills/x/names.md\n", 2)
assert not g["ok"] and g["hits"] == ["getUserId"] and g["reason"] == "stage-exit-2", g
d = ("diff -ruN app/src/A.java /sb/mabc/app/src/A.java\n--- app/src/A.java\n+++ /sb/mabc/app/src/A.java\n+x\n"
     "diff -ruN app/.claude/skills/s/SKILL.md /sb/mabc/app/.claude/skills/s/SKILL.md\n-gone\n"
     "diff -ruN app/CLAUDE.md /sb/mabc/app/CLAUDE.md\n-gone\n")
d += 'diff -ruN "app/.claude/a b" "/sb/mabc/app/.claude/a b"\n-gone too\n'
f = rollout.filter_diff(d, "/sb/mabc", "app")
assert "mabc" not in f and ".claude" not in f and "CLAUDE.md" not in f and "gone" not in f and "+x" in f, f
print("  ok: pass / nothing-checked / no-verdict / hit lines parsed; .claude (quoted too), CLAUDE.md and the slug filtered")
import score
crit = lambda src: score.valid_criteria({"criteria": [{"id": "c1", "criterion": "x", "source": src, "weight": 1}]},
                                        'Offer a **Fix by AI** action in "Ask the Code".')
assert crit('"Offer a **Fix by AI** action in "Ask the Code"."') and crit("\u201cOffer a Fix by AI action\u201d")
assert crit("Offer a Fix-by-AI button") is None
print("  ok: a criterion source wrapped in quotation marks (as Codex writes it) is still grounded; a paraphrase is not")
import time, campaign, executor
def work(i, item):
    time.sleep(0.05 if item == 4 else 0.3)
    raise executor.LoopError(item, "job %d" % item)
for items, jobs, want in (([4, 2], 3, 2), ([4, 9, 9, 9, 9], 2, 4)):
    try:
        campaign._pool({}, {"jobs": jobs}, items, work)
        raise AssertionError("no error raised")
    except executor.LoopError as e:
        assert e.code == want, (items, e.code)
print("  ok: --jobs: a budget stop (4) that comes first never masks a contamination exit (2); a stop with jobs"
      " still queued raises that stop, not CancelledError")
import os, signal, threading
def crash(i, item, ctx):
    if item == "crash":
        running.wait(5)  # fail only once the other job is running, so it meets the stop
        raise OSError(28, "No space left on device")
    running.set()
    time.sleep(0.1)
    if ctx.get("stop"):
        raise campaign.Stopped(4, "stopping: another job failed")
ctx, running = {}, threading.Event()
try:
    campaign._pool(ctx, {"jobs": 2}, ["crash", "late"], lambda i, item: crash(i, item, ctx))
    raise AssertionError("no error raised")
except OSError:
    pass
print("  ok: --jobs: a crash outranks the knock-on 'stopping' error it causes")
def launches(ctx, launched, fail_first):
    def work(i, item):
        if ctx.get("stop"):
            raise campaign.Stopped(4, "stopping: another job failed")
        launched.append(i)
        if fail_first and i == 0:
            raise executor.LoopError(2, "contaminated")
        time.sleep(0.3)
    return work
for _ in range(10):  # the failing worker must not launch the next queued job before the main thread reacts
    ctx, launched = {}, []
    try:
        campaign._pool(ctx, {"jobs": 2}, list(range(6)), launches(ctx, launched, True))
        raise AssertionError("no error raised")
    except executor.LoopError as e:
        assert e.code == 2 and set(launched) <= {0, 1}, (e.code, launched)
ctx, launched = {}, []
threading.Timer(0.1, lambda: os.kill(os.getpid(), signal.SIGINT)).start()
try:
    campaign._pool(ctx, {"jobs": 2}, list(range(8)), launches(ctx, launched, False))
    raise AssertionError("no interrupt")
except KeyboardInterrupt:
    assert len(launched) <= 3, launched
print("  ok: --jobs: after a failure nothing new launches; Ctrl-C launches nothing more (%d of 8 ran)" % len(launched))
import json, tempfile, jobs, ledger
R = tempfile.mkdtemp()
def camp(name, loop, lines):
    d = os.path.join(R, "proj", "c-" + name)
    os.makedirs(d)
    json.dump(loop, open(os.path.join(d, "loop.json"), "w"))
    open(os.path.join(d, "ledger.jsonl"), "w").write("".join(lines))
row = lambda kind, usd, est=None: json.dumps({"kind": kind, "usd": usd, "usd_estimate": est}) + "\n"
camp("a", {"model": "m", "scorer_model": "s"}, [row("implement", 0.2), row("implement", None, 1.0), row("score", 0.05),
                                               "\n", "[1]\n", '{"kind": "implement", "usd": 0.'])  # blank, non-object, torn
camp("b", {"model": "m", "scorer_model": "s", "stub": True}, [row("implement", 9.0)])
camp("c", {"model": "other", "scorer_model": "s"}, [row("implement", 7.0), row("score", 0.07)])
camp("self", {"model": "m", "scorer_model": "s"}, [row("implement", 5.0)])
pr = jobs._priors({"root": R, "project": "proj", "model": "m", "scorer_model": "s", "campaign": "self"})
assert sorted(pr["implement"]) == [0.2, 1.0] and sorted(pr["score"]) == [0.05, 0.07], pr
assert ledger.quantile95(list(range(1, 101))) == 96
L = ledger.Ledger(tempfile.mkdtemp(), 10, {"implement": [0.1] * 39})
assert L.p95("implement", 1.0) == 0.1 and L.p95("score", 0.3) == 0.3
L.rows.append({"kind": "implement", "usd": 0.8})
assert L.p95("implement", 1.0) == 0.1 and ledger.Ledger(tempfile.mkdtemp(), 10).p95("implement", 1.0) == 1.0
print("  ok: cost history: other non-stub campaigns of the same model only (own, stub and other-model rows left out),"
      " unpriced rows at their cap, torn/blank lines skipped; p95 pools it with the campaign's own rows")
import report
assert report.defect("Nonexistent method X") and report.defect("Nonessential retry layer") and not report.defect("none — parity")
assert report.defect(None) is None
print("  ok: 'Nonexistent …' is a defect, 'none — …' is not, None is not measured")
PY

echo "== fixture: a Java repo with two merged units =="
P="$TMP/proj"; R="$P/app"; mkdir -p "$R/src" "$R/.claude/skills/repo-skill"
git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'public class Users {\n    public String getUserID() { return "id"; }\n    public int countActiveUsers() { return 0; }\n}\n' > "$R/src/Users.java"
printf 'public class App {\n    public void runApplication() {}\n}\n' > "$R/src/App.java"
printf -- '---\nname: repo-skill\ndescription: in-repo skill that must not ride along\n---\nx\n' > "$R/.claude/skills/repo-skill/SKILL.md"
echo "repo notes that must not ride along" > "$R/CLAUDE.md"
git -C "$R" add -A; git -C "$R" commit -qm init
git -C "$R" checkout -qb f1
printf 'public class Accounts {\n    public String getUserId() { return linkAccountHolder(); }\n    public String linkAccountHolder() { return "a"; }\n}\n' > "$R/src/Accounts.java"
git -C "$R" add -A; git -C "$R" commit -qm "accounts"; git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff f1 -m "Merge f1"; U1="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -qb f2
printf 'public class Fees {\n    public int computeLateFee() { return 5; }\n}\n' > "$R/src/Fees.java"
git -C "$R" add -A; git -C "$R" commit -qm "fees"; git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff f2 -m "Merge f2"; U2="$(git -C "$R" rev-parse HEAD)"
LR="$TMP/state"; mkdir -p "$LR"
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
loop: {inputs_dir: "$TMP/inputs"}
EOF
inputs() {  # <dir> <scenario> [extra]
  for u in "$U1" "$U2"; do mkdir -p "$1/$u"
    printf 'Implement the change.\nSCENARIO=%s\n%s\n' "$2" "${3:-}" > "$1/$u/SPEC.md"; echo "The business wants it." > "$1/$u/BUSINESS_REQUIREMENT.md"; done
}
inputs "$TMP/inputs" edit
prove() {  # <campaign> [args...]
  c="$1"; shift
  "$PY" "$LOOP" prove --config "$CFG" --root "$LR" --campaign "$c" --runner local --binary "$FAKE" \
    --agent-bin "$FAKE" --scorer-bin "$FAKE" --model fake-model --per-job-usd 1 --scorer-per-job-usd 0.5 "$@"
}
CD() { echo "$LR/fx/c-$1"; }

echo "== happy path: 2 units x bare,pre x k=2 =="
OUT="$(prove ok --units "$U1,$U2" --k 2 --budget-usd 20 2>&1)"; rc=$?
printf '%s\n' "$OUT" | sed 's/^/    /' | tail -14
[ "$rc" -eq 0 ] || fail "happy path exited $rc"
printf '%s' "$OUT" | grep -q 'STUB RUN' || fail "a stub run must say so"
C="$(CD ok)"
[ -s "$C/final/report.html" ] && [ -s "$C/final/scores.json" ] || fail "final/ did not render"
C="$C" U1="$U1" U2="$U2" ROOT="$ROOT" "$PY" - <<'PY' || fail "happy-path assertions"
import glob, json, os, sys
c = os.environ["C"]
cal = json.load(open(os.path.join(c, "calib.json")))
pre, bare = cal["arms"]["pre"], cal["arms"]["bare"]
assert pre["n"] == bare["n"] == 4 and pre["n_scored"] == bare["n_scored"] == 4, cal["arms"]
assert pre["skill_rate"] == 1.0 and bare["skill_rate"] == 0.0, (pre["skill_rate"], bare["skill_rate"])
assert pre["mean_pct"] == 88 and pre["compile_ok"] == "4/4", pre      # c1 full (w3) + c2 partial (w1) = 87.5 -> 88
assert cal["builtin_skills"] == ["debug", "simplify"], cal["builtin_skills"]
print("  ok: 16 jobs ran; Skill rate pre 1.0 / bare 0.0; pct recomputed in code; built-ins pinned")
for u in (os.environ["U1"], os.environ["U2"]):
    crit = json.load(open(os.path.join(c, "units", u, "criteria.json")))
    gone = json.load(open(os.path.join(c, "units", u, "criteria.dropped.json")))
    assert [x["id"] for x in crit] == ["c1", "c2"] and [x["id"] for x in gone] == ["c3"], (crit, gone)
print("  ok: a criterion whose source is not quoted from SPEC/BR (a human design choice) is dropped and recorded")
f = cal["floor"][os.environ["U1"][:12]]
assert f["gate"]["ok"] and f["floor_dropped"] >= 1 and f["gate_hit_tokens"] >= 1, f
names = open(glob.glob(os.path.join(c, "snapshots", "pre-%s" % os.environ["U1"][:12], "fx-floor", "names.md"))[0]).read()
assert "getUserID" not in names and "countActiveUsers" in names, names
print("  ok: case-variant floor row getUserID dropped (answer adds getUserId); gate passes; other rows kept")
rows = [json.loads(l) for l in open(os.path.join(c, "ledger.jsonl"))]
imp = [r for r in rows if r["kind"] == "implement"]
assert all({x["path"] for x in r["stripped"]} == {"app/.claude", "app/CLAUDE.md"} for r in imp), imp[0]["stripped"]
for r in imp:
    d = open(os.path.join(c, "runs", r["runkey"][:16], "ai_app.diff")).read()
    assert "Change.java" in d and ".claude" not in d and "CLAUDE.md" not in d and r["runkey"][:15] not in d, d[:300]
print("  ok: the repo's .claude/ and CLAUDE.md were stripped before launch and are absent from every diff")
for r in imp:
    t = open(os.path.join(c, "runs", r["runkey"][:16], "transcript.jsonl")).read()
    want = "always_on=True dup=False" if r["arm"] == "pre" else "always_on=False dup=False"
    assert want in t, (r["arm"], want)
man = json.load(open(glob.glob(os.path.join(c, "snapshots", "pre-%s.manifest.json" % os.environ["U1"][:12]))[0]))
assert man["skills"] == ["fx-floor"] and man["always_on_bytes"] > 20000, man
print("  ok: pre has the always-on CLAUDE.md (GUARD text, %d bytes) at the sandbox root, once; bare has none" % man["always_on_bytes"])
views = glob.glob(os.path.join(c, "views", "*"))
assert len(views) == 8, len(views)
for v in views:
    assert sorted(os.listdir(v)) == ["BUSINESS_REQUIREMENT.md", "SPEC.md", "candidate.diff", "criteria.json", "reference.diff"]
    text = "".join(open(os.path.join(v, f)).read() for f in os.listdir(v))
    bad = [t for t in [os.environ["U1"], os.environ["U2"], os.environ["U1"][:10], os.environ["U2"][:10], "/sb/", "bare", '"arm"']
           + [r["runkey"][:15] for r in imp] if t in text]
    assert not bad, (v, bad)
print("  ok: 8 scorer views, 5 files each, none naming an arm, unit id or slug")
assert json.load(open(os.path.join(c, "final", "scores.json")))["aggregate"]["arms"]["baseline"]["n"] == 4
PY
prove reuse --units "$U1,$U2" --k 1 --budget-usd 20 >/dev/null 2>&1 || fail "reuse campaign exited non-zero"
! grep -q '"kind": "criteria"' "$(CD reuse)/ledger.jsonl" || fail "a second campaign on the same inputs re-ran a criteria session"
for u in "$U1" "$U2"; do cmp -s "$C/units/$u/criteria.json" "$(CD reuse)/units/$u/criteria.json" || fail "criteria differ across campaigns"; done
ok "a second campaign on the same inputs reuses the frozen criteria (0 criteria sessions, identical files)"
prove par --units "$U1,$U2" --k 2 --budget-usd 20 --jobs 3 >/dev/null 2>&1 || fail "--jobs 3 exited non-zero"
C="$C" P="$(CD par)" "$PY" - <<'PY' || fail "a parallel run differs from the sequential one"
import json, os
a, b = (json.load(open(os.path.join(d, "calib.json")))["arms"] for d in (os.environ["C"], os.environ["P"]))
for arm in ("bare", "pre"):
    assert (a[arm]["n"], a[arm]["n_scored"], a[arm]["mean_pct"], a[arm]["compile_ok"]) == (b[arm]["n"], b[arm]["n_scored"], b[arm]["mean_pct"], b[arm]["compile_ok"]), (a[arm], b[arm])
rows = [json.loads(l) for l in open(os.path.join(os.environ["P"], "ledger.jsonl"))]
assert sum(r["kind"] == "implement" for r in rows) == 8 and sum(r["kind"] == "score" and "of" in r for r in rows) == 8
PY
ok "--jobs 3: the same 8 rollouts and scores as the sequential run, ledger intact"
before=$(wc -l < "$C/ledger.jsonl")
prove ok --units "$U1,$U2" --k 2 --budget-usd 20 >/dev/null 2>&1 || fail "resume exited non-zero"
[ "$(wc -l < "$C/ledger.jsonl")" -eq "$before" ] || fail "resume re-ran DONE jobs"
ok "resume: same command, 0 new ledger rows"
prove ok --units "$U1,$U2" --k 2 --budget-usd 20 --model other-model >/dev/null 2>&1; rc=$?
[ "$rc" -eq 6 ] || fail "identity change exited $rc (want 6)"
ok "a changed model on the same campaign -> 6"
cp "$C/ledger.jsonl" "$TMP/ledger.bak"; echo '{"broken' >> "$C/ledger.jsonl"
prove ok --units "$U1,$U2" --k 2 --budget-usd 20 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 6 ] || fail "corrupt ledger exited $rc (want 6)"; cp "$TMP/ledger.bak" "$C/ledger.jsonl"
ok "a corrupt ledger row -> 6, never skipped"

echo "== budget: the cap is checked before any launch =="
prove budget --units "$U1" --k 3 --budget-usd 0.5 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] || fail "budget exited $rc (want 4)"
! grep -qE '"(implement|criteria)"' "$(CD budget)/ledger.jsonl" 2>/dev/null || fail "a job launched past the cap"
ok "every phase projected up front: over the cap -> 4 before the first (criteria) launch"
"$PY" -c "import fcntl,sys,time; f=open(sys.argv[1],'w'); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(20)" "$(CD ok)/.lock" & LOCKPID=$!
sleep 1; prove ok --units "$U1,$U2" --k 2 --budget-usd 20 >/dev/null 2>&1; rc=$?; kill $LOCKPID 2>/dev/null
[ "$rc" -eq 6 ] || fail "a second process on a locked campaign exited $rc (want 6)"
ok "a campaign already running in another process -> 6"

echo "== the always-on file is leak-gated like a skill =="
sed 's/^decontamination: {exclusion: \[\]}$/decontamination: {exclusion: [], answer_tokens: {"'"$U2"'": ["Honesty Vocabulary"]}}/' "$CFG" > "$TMP/gated.yaml"
grep -q 'answer_tokens' "$TMP/gated.yaml" || fail "could not build the gated config"
OUT="$("$PY" "$LOOP" prove --config "$TMP/gated.yaml" --root "$LR" --campaign gated --runner local --binary "$FAKE" \
  --agent-bin "$FAKE" --units "$U2" --budget-usd 5 --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && printf '%s' "$OUT" | grep -q 'gate:pre:stage-exit-2' || { printf '%s\n' "$OUT"; fail "a token in the always-on text was not caught ($rc)"; }
ok "a curated answer token inside the always-on CLAUDE.md fails the pre arm's gate (unit dropped)"

echo "== refused configurations =="
for args in "--scorer codex" "--arms bare,pree" "--builtins $TMP/failed-canary.json"; do
  echo '{"passed": false, "builtin_skills": []}' > "$TMP/failed-canary.json"
  prove "refuse" --units "$U1" --budget-usd 5 --dry-run $args >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || fail "'$args' exited $rc (want 3)"
done
ok "Codex on the local runner, an unknown arm, and a canary that did not pass -> 3"

echo "== loop.root inside a git work tree =="
"$PY" "$LOOP" prove --config "$CFG" --root "$R/state" --campaign wt --runner local --binary "$FAKE" --agent-bin "$FAKE" \
  --units "$U1" --budget-usd 5 --dry-run >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || fail "root in a work tree exited $rc (want 3)"
ok "loop.root inside a work tree -> 3"

scenario() {  # <name> <want-rc> [extra spec line]
  inputs "$TMP/in-$1" "$1" "${3:-}"
  OUT="$(prove "s-$1" --units "$U2" --arms pre --k 1 --budget-usd 5 --inputs "$TMP/in-$1" 2>&1)"; rc=$?
  [ "$rc" -eq "$2" ] || { printf '%s\n' "$OUT" | tail -8; fail "scenario $1 exited $rc (want $2)"; }
}
echo "== artifact checks, scans and scorer failure =="
for s in symlink fifo; do
  scenario "$s" 5
  grep -q '"status": "integrity_failed"' "$(CD "s-$s")/ledger.jsonl" || fail "$s not integrity_failed"
  ! ls "$(CD "s-$s")"/runs/*/ai_app.diff >/dev/null 2>&1 || fail "$s: a diff was extracted after a planted artifact"
  ok "$s planted -> integrity_failed, nothing extracted, run INVALID (5)"
done
scenario leak_token 2
! grep -rqF "$CLAUDE_CODE_OAUTH_TOKEN" "$(CD s-leak_token)" || fail "the credential is still on disk"
ok "credential echoed by the arm -> exit 2, redacted on disk"
scenario honey 2 "HONEY_DIR=$(CD s-honey)"
H="$(cat "$(CD s-honey)"/.honey-*)"; grep -rlF "$H" "$(CD s-honey)/runs" >/dev/null 2>&1 && fail "honey string still on disk"
ok "honey string read by the arm -> exit 2, redacted"
scenario scorer_break 5
grep -q '"status": "scorer_failed"' "$(CD s-scorer_break)"/runs/*/score.json || fail "scorer_failed not recorded"
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['arms']['pre']['mean_pct'] is None and d['arms']['pre']['n_scored']==0, d['arms']" \
  "$(CD s-scorer_break)/calib.json" || fail "scorer_failed was counted as a number"
! ls "$(CD s-scorer_break)"/final/*/score.json >/dev/null 2>&1 || fail "a failed score was rendered into final/"
ok "an incomplete grade twice -> scorer_failed, pct None (not 0), kept out of final/; nothing scored -> INVALID"
scenario skill_token 2
! grep -rqF "$CLAUDE_CODE_OAUTH_TOKEN" "$(CD s-skill_token)" || fail "a credential used as a Skill name reached disk"
ok "credential as a Skill name -> exit 2, absent from ledger and result.json"
scenario planted_token 5
! grep -rqF "$CLAUDE_CODE_OAUTH_TOKEN" "$(CD s-planted_token)" || fail "a credential used as a planted file name reached disk"
grep -q '"reason": "artifacts:1"' "$(CD s-planted_token)/ledger.jsonl" || fail "planted entries not recorded as a count"
ok "credential as a planted file name -> integrity_failed, recorded as a count + hash only"
scenario defect_none 0
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); a=d['arms']['pre']; assert a['lost_context']=={'defects':1,'measured':1}, a" \
  "$(CD s-defect_none)/calib.json" || fail "a present defect whose note starts with 'None' was not counted"
grep -q '"lost_context": "defect: None of the new fields is read"' "$(CD s-defect_none)"/runs/*/score.json || fail "the report text reads as no defect"
ok "a defect with present=true counts even when its note starts with 'None'; its text cannot read as 'none'"
scenario scorer_infra 4
! grep -q '"of": ' "$(CD s-scorer_infra)/ledger.jsonl" || fail "a transient scorer failure was recorded as a final score"
ok "a transient scorer failure -> exit 4 with no final score row (a resume regrades it)"
scenario noop 0
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); a=d['arms']['pre']; assert a['status']=={'empty':1} and a['mean_pct']==0, a" \
  "$(CD s-noop)/calib.json" || fail "empty change not code-scored 0"
ok "no change -> empty, code-scored 0 without a scorer session"
scenario api_error 5
[ "$(grep -c '"infra_failed"' "$(CD s-api_error)/ledger.jsonl")" -eq 2 ] || fail "infra_failed was not retried exactly once"
ok "infra_failed retried once, then the unit dropped; run INVALID"

echo
echo "LOOP-ROLLOUT PASS"
