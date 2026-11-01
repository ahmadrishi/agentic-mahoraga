#!/usr/bin/env bash
# tests/loop_executor_test.sh — core/loop/executor.py classifies every run, and lies to no one.
#
# Drives the executor's local runner with tests/fixtures/fake-claude (no model, no $, no docker):
#   * terminal classification: ok / truncated (max turns) / infra_failed (api error, no result,
#     timeout) / auth (infra_failed, reason auth)
#   * init-event assertions: an extra skill, a non-built-in plugin, an MCP server, a hook event, a tool
#     outside --tools, or model drift each make the run integrity_failed
#   * the prompt never reaches argv; Skill calls and cost are parsed; a cost cap with no reported
#     cost exits 3; a token echoed into the transcript is a scan hit and is redacted on disk
#   * `mahoraga loop` usage errors exit 64 (2 is reserved for contamination)
#
# Hermetic: own temp dir, cleaned up on exit. Needs bash + python3. Run from the repo root.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
fail() { printf 'LOOP-EXECUTOR FAIL: %b\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ROOT="$ROOT" TMP="$TMP" "$PY" - <<'PY' || fail "executor assertions failed"
import json, os, shutil, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import executor
os.environ[executor.TOKEN_ENV] = "fake-credential-%d" % os.getpid()  # made up; never a real token

fake = os.path.join(os.environ["ROOT"], "tests", "fixtures", "fake-claude")
TOOLS = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "Skill"]
EXPECT = {"skills": ["mh-sentinel"], "builtin_skills": ["debug", "simplify"], "tools": TOOLS,
          "model": "fake-model", "version": "9.9.9-fake"}
tok = os.environ["CLAUDE_CODE_OAUTH_TOKEN"]

def run(scenario, n=[0], **kw):
    n[0] += 1
    work = os.path.join(os.environ["TMP"], "w%d" % n[0])
    os.makedirs(os.path.join(work, ".claude", "skills", "mh-sentinel"))
    job = {"runner": "local", "binary": "/nonexistent", "agent_bin": fake, "work": work,
           "out": work + ".out", "prompt": "do the task\nSCENARIO=%s\n" % scenario, "model": "fake-model",
           "tools": TOOLS, "max_turns": 4, "timeout_s": kw.pop("timeout_s", 20)}
    job.update(kw)
    r = executor.run(job, expect=EXPECT, secrets=[tok])
    return r, work

table = {"ok": ("ok", "completed"), "max_turns": ("truncated", None), "api_error": ("infra_failed", None),
         "auth": ("infra_failed", "auth"), "noresult": ("infra_failed", None)}
for sc, (status, reason) in table.items():
    r, _ = run(sc)
    assert r["status"] == status, (sc, r)
    assert reason is None or r["reason"] == reason, (sc, r)
r, _ = run("sleep", timeout_s=2)
assert (r["status"], r["reason"]) == ("infra_failed", "timeout"), r
print("  ok: terminal classification (ok, truncated, api error, auth, no result, timeout)")

for sc, needle in (("extra_skill", "skill:+user-skill-leaked"), ("plugin", "plugin:mahoraga"), ("mcp", "mcp:jira"),
                   ("hook", "hook:hook_response"), ("tool_drift", "tools:+WebSearch"), ("model_drift", "model:some-other-model")):
    r, _ = run(sc)
    assert r["status"] == "integrity_failed" and any(b.startswith(needle) for b in r["breaches"]), (sc, r)
print("  ok: each init breach -> integrity_failed")

r, work = run("ok")
argv = json.load(open(os.path.join(work, "argv.json")))
assert not any("do the task" in a for a in argv), argv
assert r["skill_calls"] == ["mh-sentinel"] and r["usd"] == 0.0123 and r["isolation"] == "instructed", r
assert not os.path.exists(os.path.join(work + ".out", os.path.basename(work)))  # no stray cfg dir left
assert not [d for d in os.listdir(work + ".out") if d.startswith("cfg-")], os.listdir(work + ".out")
print("  ok: prompt never on argv; Skill calls + cost parsed; per-job config dir removed")

try:
    run("missing_cost", max_budget_usd=0.5)
    raise AssertionError("missing cost under a cap did not raise")
except executor.LoopError as exc:
    assert exc.code == 3, exc
print("  ok: cost cap with no reported cost -> exit 3")

r, work = run("leak_token")
assert r["status"] == "integrity_failed" and ("secret", "credential#0") in [tuple(h) for h in r["scan_hits"]], r
assert tok not in open(os.path.join(work + ".out", "transcript.jsonl")).read()
print("  ok: token echoed into the transcript -> scan hit, redacted on disk")
PY

"$PY" "$ROOT/core/loop/loop.py" bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 64 ] || fail "usage error exited $rc, expected 64"
echo "  ok: usage error -> 64"
echo
echo "LOOP-EXECUTOR PASS"
