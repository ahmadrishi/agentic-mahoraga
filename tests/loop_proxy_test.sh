#!/usr/bin/env bash
# tests/loop_proxy_test.sh — the egress proxy allows only its list, and its log says so.
#
# Runs core/loop/egress_proxy.py on 127.0.0.1 with a local echo server as the only allowed upstream
# (hermetic — no outside network):
#   * CONNECT to the allowed host tunnels bytes both ways (200, echo round-trips)
#   * CONNECT to any other host is refused (403) and logged DENY; a plain GET is DENY-NONCONNECT
#   * classify(): ALLOW is a subset of the allowlist; a pinned telemetry DENY is expected noise;
#     every other DENY is reported as a behaviour signal
# Needs bash + python3. Run from the repo root.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
fail() { printf 'LOOP-PROXY FAIL: %b\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT

ROOT="$ROOT" TMP="$TMP" "$PY" - <<'PY' || fail "proxy assertions failed"
import os, socket, socketserver, sys, threading, time
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import egress_proxy

class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        data = self.request.recv(1024)
        self.request.sendall(b"echo:" + data)

echo = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo)
threading.Thread(target=echo.serve_forever, daemon=True).start()
log = os.path.join(os.environ["TMP"], "proxy.log")
proxy = egress_proxy.Proxy("127.0.0.1:0", ["127.0.0.1"], log)
threading.Thread(target=proxy.serve_forever, daemon=True).start()
pport, eport = proxy.server_address[1], echo.server_address[1]

def ask(raw):
    s = socket.create_connection(("127.0.0.1", pport), timeout=5)
    s.sendall(raw)
    return s, s.recv(1024)

s, resp = ask(b"CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % eport)
assert resp.startswith(b"HTTP/1.1 200"), resp
s.sendall(b"hi"); assert s.recv(1024) == b"echo:hi"; s.close()
print("  ok: allowed host tunnels")
for raw in (b"CONNECT example.invalid:443 HTTP/1.1\r\n\r\n", b"CONNECT telemetry.example:443 HTTP/1.1\r\n\r\n",
            b"GET http://example.invalid/ HTTP/1.1\r\n\r\n"):
    s, resp = ask(raw); s.close()
    assert resp.startswith(b"HTTP/1.1 403"), (raw, resp)
print("  ok: other hosts and non-CONNECT refused with 403")
time.sleep(0.2)
lines = open(log).read().split("\n")
assert "ALLOW 127.0.0.1:%d" % eport in lines and "DENY example.invalid:443" in lines, lines
assert any(l.startswith("DENY-NONCONNECT GET") for l in lines), lines
c = egress_proxy.classify(log, ["127.0.0.1"], telemetry=["telemetry.example"])
assert c == {"allow_breach": [], "telemetry_denies": ["telemetry.example:443"],
             "other_denies": ["example.invalid:443", "GET http://example.invalid/ HTTP/1.1"]}, c
bad = os.path.join(os.environ["TMP"], "bad.log")
open(bad, "w").write("ALLOW evil.example:443\n")
assert egress_proxy.classify(bad, ["127.0.0.1"])["allow_breach"] == ["evil.example:443"]
print("  ok: log classified — ALLOW within allowlist, telemetry vs other DENY, a breach is caught")
PY
echo
echo "LOOP-PROXY PASS"
