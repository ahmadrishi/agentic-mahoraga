#!/usr/bin/env bash
# tests/loop_isolation_test.sh — the arm boundary holds, and the probe could tell if it didn't.
#
# Runs `mahoraga loop preflight` (free: no model, no $) with the model-free escape agent
# (tests/loop/escape_agent.sh) inside the REAL container config — internal network, egress-proxy
# sidecar, read-only root, dropped caps:
#   * POSITIVE: 0 of 4 escapes (host read, direct TCP, CONNECT to a non-allowlisted host, write
#     outside /work), the proxy log shows the refused CONNECT, and the planted symlink is caught
#   * NEGATIVE CONTROL: the same agent under the local (instructed) runner DOES read the host file —
#     so a clean result above means the container stopped it, not that the probe is blind
#   * SCORER RUNNER (fake Codex, same boundary): output read from -o, the view is read-only, a key the
#     scorer echoes is caught and redacted, and a hung scorer's container is removed on timeout
#   * no mh-* network or container is left behind
#
# Needs docker + the ubuntu:24.04 and python:3.12-alpine images. Docker absent → SKIP, unless
# MAHORAGA_REQUIRE_DOCKER=1 (CI's isolation job), where a skip is a failure. Run from the repo root.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
fail() { printf 'LOOP-ISOLATION FAIL: %b\n' "$*" >&2; exit 1; }
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  [ "${MAHORAGA_REQUIRE_DOCKER:-0}" = 1 ] && fail "docker unavailable but MAHORAGA_REQUIRE_DOCKER=1"
  echo "LOOP-ISOLATION SKIP: docker unavailable (set MAHORAGA_REQUIRE_DOCKER=1 to make this a failure)"; exit 0
fi
for img in ubuntu:24.04 python:3.12-alpine; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null || fail "cannot pull $img"
done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== POSITIVE: escape agent inside the real container config =="
OUT="$("$PY" "$ROOT/core/loop/loop.py" preflight --root "$TMP/root" --binary "$ROOT/tests/fixtures/fake-claude" 2>&1)"; rc=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
[ "$rc" -eq 0 ] || fail "preflight exited $rc (2 = boundary breach)"
printf '%s' "$OUT" | grep -q 'boundary held — 0/4 escapes, planted symlink caught' || fail "boundary verdict missing"
grep -q '^DENY example.com:443$' "$TMP"/root/proxy/*/proxy.log || fail "proxy log lacks the refused CONNECT"

echo "== NEGATIVE CONTROL: the same agent without the container =="
ROOT="$ROOT" TMP="$TMP" "$PY" - <<'PY' || fail "negative control: the probe could not see an escape"
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import executor
t = os.environ["TMP"]
decoy = os.path.join(t, "host-decoy.txt"); open(decoy, "w").write("decoy")
work = os.path.join(t, "nc-work"); os.makedirs(work)
job = {"runner": "local", "binary": "/nonexistent", "agent_bin": os.path.join(os.environ["ROOT"], "tests", "loop", "escape_agent.sh"),
       "work": work, "out": work + ".out", "prompt": json.dumps({"decoy": decoy, "proxy": "127.0.0.1:9", "deny_host": "example.com"}),
       "model": "none", "tools": ["Bash"], "max_turns": 1, "timeout_s": 60}
executor.run(job)
attempts = [json.loads(l) for l in open(os.path.join(work + ".out", "transcript.jsonl")) if l.startswith("{")]
hr = [a for a in attempts if a["attempt"] == "host-read"][0]
assert hr["escaped"] is True, attempts
print("  ok: without the container the host read succeeds (escaped: true) — the probe can see escapes")
PY

echo "== SCORER RUNNER: fake Codex in the same boundary =="
ROOT="$ROOT" TMP="$TMP" "$PY" - <<'PY' || fail "scorer runner assertions failed"
import json, os, subprocess, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import executor, preflight
t = os.environ["TMP"]
o = {"root": os.path.join(t, "sroot"), "proxy_image": "python:3.12-alpine", "allow": ["api.openai.com"]}
os.makedirs(o["root"])
os.environ["CODEX_API_KEY"] = os.environ["OPENAI_API_KEY"] = "fake-openai-%d" % os.getpid()  # made up
fake = os.path.join(os.environ["ROOT"], "tests", "fixtures", "fake-codex")
def score(scenario, **kw):
    view = os.path.join(t, "view-" + scenario); os.makedirs(view)
    open(os.path.join(view, "schema.json"), "w").write("{}")
    with preflight.arm_network(o, "st" + scenario[:4]) as (net, proxy, _log):
        job = {"binary": fake, "view": view, "out": os.path.join(t, "sout-" + scenario), "prompt": "SCENARIO=" + scenario,
               "model": "fake-model", "network": net, "proxy": proxy, "image": "ubuntu:24.04", "timeout_s": 60}
        job.update(kw)
        return executor.run_scorer(job, secrets=[os.environ["CODEX_API_KEY"]]), job
r, _ = score("ok")
assert r["status"] == "ok" and r["output"]["criteria"] == [{"id": "c1", "status": "full"}], r
assert r["output"]["view_writable"] is False and r["usage"] == {"input_tokens": 5, "output_tokens": 3}, r
print("  ok: scorer output read from -o; the view is read-only to the scorer")
r, job = score("leak")
assert r["status"] == "integrity_failed" and r["scan_hits"], r
assert os.environ["CODEX_API_KEY"] not in open(os.path.join(job["out"], "events.jsonl")).read()
print("  ok: a key echoed by the scorer -> integrity_failed, redacted on disk")
r, job = score("sleep", timeout_s=5)
assert (r["status"], r["reason"]) == ("infra_failed", "timeout"), r
left = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"], capture_output=True, text=True).stdout.split()
assert job["container"] not in left, left
print("  ok: a hung scorer times out and its container is removed (killing the client is not enough)")
PY

left=$(docker network ls --format '{{.Name}}' | grep -c '^mh-int-bp' || true)
cont=$(docker ps -a --format '{{.Names}}' | grep -c '^mh-proxy-bp' || true)
[ "$left" -eq 0 ] && [ "$cont" -eq 0 ] || fail "left behind: $left network(s), $cont proxy container(s)"
echo "  ok: no mh-* network or proxy container left behind"
echo
echo "LOOP-ISOLATION PASS"
