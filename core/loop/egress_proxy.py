#!/usr/bin/env python3
"""egress_proxy.py — the arm's only way out: an HTTP CONNECT proxy that allows a fixed host list.

Runs as a sidecar container bridging the arm's `--internal` Docker network and the outside.
Every request is logged as one line: `ALLOW host:port`, `DENY host:port`, or
`DENY-NONCONNECT <request line>`; the first line is `READY <listen>` once it accepts connections. Stdlib only.

    python3 egress_proxy.py --listen 0.0.0.0:3128 --allow api.anthropic.com --log /log/proxy.log
"""
import argparse
import select
import socket
import socketserver
import threading

_lock = threading.Lock()


def _log(path, line):
    with _lock, open(path, "a") as fh:
        fh.write(line + "\n")


def _pipe(a, b):
    try:
        while True:
            ready, _, _ = select.select([a, b], [], [], 300)
            if not ready:
                return
            for s in ready:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        return


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        c, srv = self.request, self.server
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 8192:
            chunk = c.recv(4096)
            if not chunk:
                return
            head += chunk
        line = head.split(b"\r\n", 1)[0].decode("latin-1")
        parts = line.split(" ")
        if len(parts) < 2 or parts[0] != "CONNECT":
            _log(srv.log, "DENY-NONCONNECT " + line[:200])
            c.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            return
        host, _, port = parts[1].rpartition(":")
        if host not in srv.allow or not port.isdigit():
            _log(srv.log, "DENY " + parts[1][:200])
            c.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            return
        try:
            upstream = socket.create_connection((host, int(port)), timeout=30)
        except OSError as exc:
            _log(srv.log, "ERR %s %s" % (parts[1], exc.__class__.__name__))
            c.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        _log(srv.log, "ALLOW " + parts[1])
        c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        _pipe(c, upstream)
        upstream.close()


class Proxy(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, listen, allow, log):
        host, _, port = listen.rpartition(":")
        self.allow, self.log = set(allow), log
        super().__init__((host, int(port)), _Handler)


def classify(log_path, allow, telemetry=()):
    """{allow_breach, telemetry_denies, other_denies} from a proxy log. ALLOW must be a subset of the
    allowlist; telemetry DENYs are expected noise; any other DENY is a per-arm behaviour signal."""
    out = {"allow_breach": [], "telemetry_denies": [], "other_denies": []}
    for line in open(log_path):
        kind, _, target = line.strip().partition(" ")
        host = target.rpartition(":")[0]
        if kind == "ALLOW" and host not in allow:
            out["allow_breach"].append(target)
        elif kind.startswith("DENY"):
            out["telemetry_denies" if host in telemetry else "other_denies"].append(target)
    return out


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--listen", default="127.0.0.1:3128")
    p.add_argument("--allow", required=True, help="comma-separated hosts")
    p.add_argument("--log", required=True)
    a = p.parse_args()
    proxy = Proxy(a.listen, [h for h in a.allow.split(",") if h], a.log)
    _log(a.log, "READY " + a.listen)  # arm_network waits for this before launching anything
    proxy.serve_forever()
