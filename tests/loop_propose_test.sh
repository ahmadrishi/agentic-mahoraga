#!/usr/bin/env bash
# tests/loop_propose_test.sh — 1: the proposer's validator and the held-out rejection (stub).
#
#   * validator v0, rule by rule: surface (exactly the two files, regular), caps (4 KB each, 80 changed
#     lines), content (no file:line, eval tells or environment advice), fork-stable identifiers (an absent
#     one is quoted back); a grep that cannot search the fork is exit 3, never "identifier absent"
#   * tripwire: a wire string in the overlay or notes.md, or a score-file name -> labelled, never quoted
#   * held-out rejection: a hit -> REJECTED, nothing reserved; a gate with no verdict -> exit 3, not REJECTED
#   * end to end (`mahoraga loop gate`): a candidate naming a held-out unit's answer token is REJECTED
#     before any val spend or reservation, and the token is in no output the run writes
# The retry with feedback and fell_back are in loop_insample_test.sh; the proposer's KEEP and FELL_BACK
# through `loop run` are in loop_campaign_test.sh.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
FAKE="$ROOT/tests/fixtures/fake-claude"
fail() { printf 'LOOP-PROPOSE FAIL: %b\n' "$*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset ANTHROPIC_API_KEY MAHORAGA_ANTHROPIC_KEY_FILE MAHORAGA_TOKEN_FILE
export CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_OAUTH_TOKEN="$("$PY" -c 'import os; print("fake-credential-%d" % os.getpid())')"   # made up; unique so the scan cannot hit by chance

echo "== validator v0 and the tripwire, rule by rule =="
ROOT="$ROOT" TMP="$TMP" "$PY" - <<'PY' || fail "validator assertions"
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import executor, propose
t = os.environ["TMP"]
fork = os.path.join(t, "fork", "src"); os.makedirs(fork)
open(os.path.join(fork, "Alpha.java"), "w").write("public class Alpha {\n    public int computeAlphaTotal() { return 1; }\n}\n")
fork = os.path.dirname(fork)
n = [0]
def ws(practice="", conventions="", extra=None, link=False, notes=None):
    n[0] += 1
    w = os.path.join(t, "w%d" % n[0]); o = os.path.join(w, "overlay"); os.makedirs(o)
    open(os.path.join(o, "conventions.md"), "w").write(conventions)
    if link:
        open(os.path.join(w, "real.md"), "w").write(practice); os.symlink(os.path.join(w, "real.md"), os.path.join(o, "practice.md"))
    else:
        open(os.path.join(o, "practice.md"), "w").write(practice)
    if extra:
        open(os.path.join(o, extra), "w").write("x\n")
    if notes is not None:
        open(os.path.join(w, "notes.md"), "w").write(notes)
    return w
def errs(w, f=fork):
    return propose.validate(w, None, "java", f)
def has(e, *words):
    return any(all(x in m for x in words) for m in e)

assert errs(ws("Mirror computeAlphaTotal when adding a total.\n")) == []
print("  ok: a clean candidate that names an identifier the fork has passes")
assert has(errs(ws("a\n", extra="extra.md")), "exactly practice.md and conventions.md")
assert has(errs(ws("a\n", link=True)), "regular files")
print("  ok: surface — a third file, or a symlink in place of a file, is refused")
e = errs(ws("word " * 820 + "\n")); assert has(e, "bytes; the limit is 4096"), e
e = errs(ws("".join("line %d\n" % i for i in range(81)))); assert has(e, "81 lines changed; the limit is 80"), e
assert not has(errs(ws("".join("line %d\n" % i for i in range(80)))), "lines changed")
print("  ok: caps — over 4 KB, or over 80 changed lines, is refused (80 is allowed)")
assert has(errs(ws("See src/Alpha.java:2 first.\n")), "no file:line", "src/Alpha.java:2")
assert has(errs(ws("This benchmark rewards small diffs.\n")), "how this work is measured", "benchmark")
assert has(errs(ws("Build it in docker before you stop.\n")), "this environment", "docker")
print("  ok: content — a file:line, an eval tell or environment advice is quoted back")
e = errs(ws("Reuse fetchGhostRecords for lookups.\n")); assert has(e, "fetchGhostRecords", "does not exist"), e
print("  ok: an identifier the pristine fork lacks is quoted back")
try:
    errs(ws("Reuse fetchGhostRecords for lookups.\n"), os.path.join(t, "no-such-fork")); raise AssertionError("no exit 3")
except executor.LoopError as x:
    assert x.code == 3 and "cannot search the fork" in str(x), x
print("  ok: a grep that cannot search the fork is exit 3, not \"identifier absent\"")
w = ws("Keep it small.\n", notes="see mh-honey-zz\n")
assert propose.tripwire(w, ["", "mh-honey-zz"]) == ["wire#1"]
assert propose.tripwire(ws("Watch business_req_pct.\n"), []) == ["score-field"]
assert propose.tripwire(ws("Keep it small.\n", notes="fine\n"), ["mh-honey-zz"]) == []
print("  ok: tripwire — a wire in notes.md or a score-file name is labelled, never quoted")
PY

echo "== the held-out decision: a hit vs a gate that gave no verdict =="
ROOT="$ROOT" "$PY" - <<'PY' || fail "held-out rejection assertions"
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import campaign, executor, heldout
def never(*a, **k):
    raise AssertionError("val units were reserved")
heldout.ledger_mod.reserve = never
sp = {"val": ["u1", "u2", "u3"]}
def stage(results):
    it = iter(results)
    campaign.stage_arm = lambda ctx, o, u, arm, overlay=None: next(it)
okg = {"ok": True, "reason": "0-hits", "hits": []}
stage([okg, {"ok": False, "reason": "stage-exit-2", "hits": ["#", "#"]}, okg])
ctx = {}
d = heldout._measure(ctx, {}, sp, "cand", {}, {})
assert (d["verdict"], d["reason"], d["count"]) == ("REJECTED", "rejected:heldout-token", 1) and ctx["quiet_gate"] is False, d
print("  ok: a leak-gate hit on one held-out unit -> REJECTED (count 1), nothing reserved, quiet gate reset")
for broken in ({"ok": False, "reason": "stage-exit-3", "hits": []}, {"ok": False, "reason": "no-gate-verdict", "hits": []},
               {"ok": False, "reason": "nothing-checked", "hits": []}):
    stage([okg, broken, {"ok": False, "reason": "stage-exit-2", "hits": ["#"]}])
    try:
        heldout._measure({}, {}, sp, "cand", {}, {}); raise AssertionError("no exit 3 for %s" % broken["reason"])
    except executor.LoopError as x:
        assert x.code == 3 and broken["reason"] in str(x), x
print("  ok: a held-out gate that could not check (exit 3, no verdict, nothing checked) -> exit 3, even beside a hit")
PY

echo "== end to end: a candidate naming a held-out answer, through \`mahoraga loop gate\` =="
U=($(bash "$ROOT/tests/loop/make_fixture.sh" "$TMP/fx" 17 | awk '$1 != "side" {print $1}')) || fail "fixture"
UNITS="$(IFS=,; echo "${U[*]}")"
VAL="${U[9]}"   # 6 train, 1 gap, then val: unit 10 is held out
TOKEN=runApplication   # in every fork (App.java), so the candidate passes the fork-stable check; curated for one val unit
cat > "$TMP/PROJECT.yaml" <<YAML
project: {id: "fx", name: "fixture", root: "$TMP/fx/proj"}
repos: [{name: "app", language: "java", verify: {typecheck_cmd: "true"}}]
tracker: {adapter: none, config: {repo: "", base_branch: "main", merge_strategy: "merge"}}
spec: {adapter: none}
vcs: {adapter: git, base_branch: "main"}
skills: {source_dir: "/nonexistent", derived_skills: []}
decontamination: {exclusion: [], answer_tokens: {"$VAL": ["$TOKEN"]}, cutoff_policy: {repo_visibility: private}}
YAML
for u in "${U[@]}"; do mkdir -p "$TMP/inputs/$u"; echo "Implement the change." > "$TMP/inputs/$u/SPEC.md"; echo "Wanted." > "$TMP/inputs/$u/BUSINESS_REQUIREMENT.md"; done
R="$TMP/root"; mkdir -p "$R/fx/calib/stub"
printf '{"model": "fake-model", "binary_sha": "%s", "scorer_model": "fake-model", "stub": true, "arms": {"pre": {"sd_within": 10}}}' \
  "$(sha256sum "$FAKE" | cut -c1-64)" > "$R/fx/calib/stub/calib.json"
for u in "${U[@]}"; do
  mkdir -p "$R/fx/criteria/$u"
  echo '[{"id": "c1", "criterion": "does the main thing", "source": "Implement the change.", "weight": 1}]' > "$R/fx/criteria/$u/pinned.json"
done
mkdir -p "$TMP/cand"; printf 'Keep each change small.\n' > "$TMP/cand/practice.md"
printf 'New entry points start the way %s does in App.\n' "$TOKEN" > "$TMP/cand/conventions.md"
"$PY" "$ROOT/core/loop/loop.py" gate --config "$TMP/PROJECT.yaml" --root "$R" --campaign leak --inputs "$TMP/inputs" \
  --units "$UNITS" --candidate "$TMP/cand" --runner local --binary "$FAKE" --agent-bin "$FAKE" --scorer-bin "$FAKE" \
  --model fake-model --k 1 --per-job-usd 0.1 --scorer-per-job-usd 0.05 --budget-usd 20 --control-fixture > "$TMP/leak.log" 2>&1; rc=$?
C="$R/fx/c-leak"
[ "$rc" -eq 0 ] && [ -f "$C/decision.json" ] || { tail -20 "$TMP/leak.log"; fail "the leaking gate exited $rc without a decision"; }
C="$C" VAL="$VAL" R="$R" "$PY" - <<'PY' || { tail -20 "$TMP/leak.log"; fail "REJECTED assertions"; }
import json, os
c = os.environ["C"]
d = json.load(open(os.path.join(c, "decision.json")))
assert (d["verdict"], d["reason"], d["count"]) == ("REJECTED", "rejected:heldout-token", 1), d
rows = [json.loads(l) for l in open(os.path.join(c, "ledger.jsonl")) if l.strip()]
assert not [r for r in rows if r.get("kind") in ("implement", "score", "rescore")], [r.get("kind") for r in rows]
res = os.path.join(os.environ["R"], "fx", "reserved.json")
assert "leak" not in (json.load(open(res)).values() if os.path.isfile(res) else []), "val units were reserved"
split = json.load(open(os.path.join(c, "split.json")))
assert os.environ["VAL"] in split["val"], "the fixture's unit 10 is not held out"
PY
ok "a candidate naming a held-out unit's answer token -> REJECTED, no rollout, no score, nothing reserved"
grep -rlF "$TOKEN" "$TMP/leak.log" "$C/decision.json" "$C/private" 2>/dev/null && fail "the run wrote the answer token back out"
ok "no feedback: the token is in neither the console output, the decision nor the private logs"
mkdir -p "$TMP/clean"; cp "$TMP/cand/practice.md" "$TMP/clean/"; printf 'New entry points start the way App does.\n' > "$TMP/clean/conventions.md"
"$PY" "$ROOT/core/loop/loop.py" gate --config "$TMP/PROJECT.yaml" --root "$R" --campaign clean --inputs "$TMP/inputs" \
  --units "$UNITS" --candidate "$TMP/clean" --runner local --binary "$FAKE" --agent-bin "$FAKE" --scorer-bin "$FAKE" \
  --model fake-model --k 1 --per-job-usd 0.1 --scorer-per-job-usd 0.05 --budget-usd 20 --control-fixture > "$TMP/clean.log" 2>&1
v="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$R/fx/c-clean/decision.json" 2>/dev/null)"
[ -n "$v" ] && [ "$v" != REJECTED ] || { tail -20 "$TMP/clean.log"; fail "the same candidate without the token gave '$v' (want a measured verdict)"; }
ok "control: the same candidate without the token is measured ($v), so the rejection came from the token"
echo
echo "LOOP-PROPOSE PASS"
