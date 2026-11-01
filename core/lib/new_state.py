#!/usr/bin/env python3
# new_state.py — tiny resumable run-state store. Stdlib json only.
#   new_state.py init <state_file> <run_id> <UNIT...>
#   new_state.py set  <state_file> <UNIT> <dotted.field> <value>
#   new_state.py get  <state_file> [<UNIT>]
# Phases a unit moves through: prepared -> staged -> implemented -> compiled -> reviewed -> scored
# (or infra-stalled). A unit row: {phase, slug, forks:{}, scores:null, notes}.
#
# CONCURRENCY-SAFE: the engine runs implementer/reviewer waves in parallel, all updating this one
# file. Each write is done under an exclusive file lock, and saved atomically (tmp + os.replace),
# so concurrent `set`s cannot lose updates or leave a half-written/corrupt state.json.
import json, os, sys, tempfile, fcntl

PHASES = ["prepared", "staged", "implemented", "compiled", "reviewed", "scored", "infra-stalled"]


def _lockfile(p):
    os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
    lf = open(p + ".lock", "w")
    fcntl.flock(lf, fcntl.LOCK_EX)   # released when the process exits / lf is GC'd
    return lf


def load(p):
    if os.path.isfile(p) and os.path.getsize(p) > 0:
        try:
            return json.load(open(p))
        except (ValueError, OSError):
            # corrupt file — preserve it for inspection, start fresh so resume still works
            try: os.replace(p, p + ".corrupt")
            except OSError: pass
    return {"run_id": None, "tasks": {}}


def save(p, d):
    d_dir = os.path.dirname(p) or "."
    os.makedirs(d_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2)
        os.replace(tmp, p)   # atomic on POSIX
    finally:
        if os.path.exists(tmp):
            try: os.unlink(tmp)
            except OSError: pass


def coerce(v):
    # keep git hashes / slugs / leading-zero ids as strings; only cast clean integers
    if isinstance(v, str) and v.isdigit() and not (len(v) > 1 and v[0] == "0"):
        return int(v)
    if v == "true":
        return True
    if v == "false":
        return False
    if v == "null":
        return None
    return v


def _new_row():
    return {"phase": "prepared", "slug": None, "forks": {}, "scores": None, "notes": ""}


def main(a):
    if not a:
        sys.exit("usage: new_state.py init|set|get ...")
    op, p = a[0], a[1]
    if op == "get":
        d = load(p)   # read-only, no lock needed
        if len(a) > 2:
            print(json.dumps(d["tasks"].get(a[2], {}), indent=2))
        else:
            print(json.dumps(d, indent=2))
        return
    # init / set mutate: lock the whole read-modify-write
    lf = _lockfile(p)
    try:
        d = load(p)
        if op == "init":
            d["run_id"] = a[2]
            for t in a[3:]:
                d["tasks"].setdefault(t, _new_row())
            save(p, d)
            print("init %s: %d units" % (a[2], len(d["tasks"])))
        elif op == "set":
            t, field, val = a[2], a[3], a[4]
            row = d["tasks"].setdefault(t, _new_row())
            cur = row
            keys = field.split(".")
            for k in keys[:-1]:
                cur = cur.setdefault(k, {})
            cur[keys[-1]] = coerce(val)
            save(p, d)
            print("set %s.%s = %s" % (t, field, val))
        else:
            sys.exit("unknown op %r" % op)
    finally:
        fcntl.flock(lf, fcntl.LOCK_UN)
        lf.close()


if __name__ == "__main__":
    main(sys.argv[1:])
