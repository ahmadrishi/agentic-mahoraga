"""rollout.py — one (unit, arm, rep), in this fixed order:

  stage → strip → launch → artifact checks → extract → filter → compile → scan

Nothing reaches a scorer before the scan. The leak gate's verdict is parsed from staging's output
(pinned by a contract test), never assumed from the exit code. That output names the tokens it hit,
so it goes to a host-private log only and is never relayed to a model.

ctx (built by campaign.py): cdir, units_dir, sandbox_root, ledger, cfg{(arm, unit): yaml},
repos{unit: [names]}, expect{arm: …}, secrets, honey, prompt, job (the executor defaults).
"""
import hashlib
import json
import os
import re
import shutil
import subprocess

import executor
import scan
import snapshot

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib")
GATE_NOTHING = "NOTHING CHECKED"                               # leak_gate.sh: no tokens = not verified
GATE_PASS = re.compile(r"0 hits across (\d+) answer token")    # leak_gate.sh: the only clean verdict
LEAK_LINE = re.compile(r"^LEAK\[[^\]]+\] (.+): /", re.M)
STAGED = re.compile(r"^STAGED \S+ \(.*\): (.*)$", re.M)


def lib(script, args, cfg, log=None):
    r = subprocess.run(["bash", os.path.join(LIB, script)] + args, capture_output=True, text=True,
                       env=dict(os.environ, PROJECT_CONFIG=cfg))
    if log:
        os.makedirs(os.path.dirname(log), mode=0o700, exist_ok=True)
        with open(log, "a") as fh:
            fh.write("== %s %s rc=%d\n%s%s" % (script, " ".join(args), r.returncode, r.stdout, r.stderr))
    return r


def gate(out, rc):
    """{ok, reason, n_tokens, hits} from staging's stdout+stderr."""
    g = {"ok": False, "n_tokens": None, "hits": LEAK_LINE.findall(out)}
    m = GATE_PASS.search(out)
    if rc:
        g["reason"] = "stage-exit-%d" % rc
    elif GATE_NOTHING in out:
        g["reason"] = "nothing-checked"
    elif not m:
        g["reason"] = "no-gate-verdict"
    else:
        g.update(ok=True, reason="0-hits", n_tokens=int(m.group(1)))
    return g


def stage(ctx, unit, slug, cfg):
    quiet = ctx.get("quiet_gate")  # held-out staging: no per-token LEAK lines anywhere a session could read them
    r = lib("stage_sandbox.sh", [ctx["units_dir"], unit, slug], cfg, None if quiet else os.path.join(ctx["cdir"], "private", "stage.log"))
    g = gate(r.stdout + r.stderr, r.returncode)
    if quiet:
        g["hits"] = ["#"] * len(g["hits"])
    m = STAGED.search(r.stdout)
    g["staged"] = sorted(x for x in (m.group(1) if m else "").split(",") if x)
    return g


def strip(sb, repos):
    """Remove each staged repo's own .claude/ and CLAUDE.md, which would ride along in every arm (F-F),
    and the gate-scanned copy of the arm's always-on file (it is staged to the sandbox root as well)."""
    removed, dup = [], os.path.join(sb, ".claude", "skills", "CLAUDE.md")
    if os.path.isfile(dup):
        os.remove(dup)
    for repo in repos:
        for rel in (".claude", "CLAUDE.md"):
            p = os.path.join(sb, repo, rel)
            if os.path.isdir(p) and not os.path.islink(p):
                removed.append({"path": "%s/%s" % (repo, rel), "sha": snapshot.tree_hash(p)})
                shutil.rmtree(p)
            elif os.path.lexists(p):
                removed.append({"path": "%s/%s" % (repo, rel), "sha": None})
                os.remove(p)
    return removed


def _diff_path(header):
    """The new-side path of a `diff -ruN … A B` header; GNU diff quotes a path with spaces."""
    m = re.search(r'"((?:[^"\\]|\\.)*)"\s*$', header)
    return m.group(1) if m else header.split()[-1]


def filter_diff(text, sb, repo):
    """Drop the stripped files' sections and the sandbox path (it carries the opaque slug)."""
    sections, keep = re.split(r"(?m)^(?=diff )", text.replace(sb.rstrip("/") + "/", "")), []
    for s in sections:
        path = _diff_path(s.split("\n", 1)[0]) if s.startswith("diff ") else ""
        rel = path[len(repo) + 1:] if path.startswith(repo + "/") else path
        if not (rel == "CLAUDE.md" or rel.startswith(".claude/")):
            keep.append(s)
    return "".join(keep)


def extract(ctx, unit, slug, rk, out, sb, cfg):
    """[ai_<repo>.diff paths], or None when extraction failed (never read as an empty change)."""
    variant = "v" + rk[:15]
    r = lib("extract_ai_diff.sh", [ctx["units_dir"], unit, slug, variant], cfg)
    srcs = [os.path.join(ctx["units_dir"], unit, "%s_%s.diff" % (variant, repo)) for repo in ctx["repos"][unit]]
    if r.returncode or not all(os.path.isfile(s) for s in srcs):
        return None
    paths = []
    for repo, src in zip(ctx["repos"][unit], srcs):
        text = open(src, errors="replace").read()
        os.remove(src)
        paths.append(os.path.join(out, "ai_%s.diff" % repo))
        with open(paths[-1], "w") as fh:
            fh.write(filter_diff(text, sb, repo))
    return paths


def compile_all(ctx, unit, sb, out, cfg):
    verdicts = []
    for repo in ctx["repos"][unit]:
        r = lib("compile_gate.sh", [os.path.join(sb, repo), os.path.join(out, "compile_%s.txt" % repo)], cfg)
        verdicts.append((r.stdout.strip().splitlines() or ["BUILD_FAILURE no-verdict rc=%d" % r.returncode])[-1])
    if all(v.startswith("BUILD_SUCCESS") for v in verdicts):
        return "BUILD_SUCCESS"
    return "n/a" if all(v.startswith("n/a") for v in verdicts) else "BUILD_FAILURE"


def scan_outputs(ctx, out):
    """Secret + honey scan over everything the rollout produced; hits are redacted in place."""
    hits = []
    for name in sorted(os.listdir(out)):
        p = os.path.join(out, name)
        if not os.path.isfile(p):
            continue
        text = open(p, errors="replace").read()
        h = scan.find(text, secrets=ctx["secrets"], honey=ctx["honey"])
        if h:
            hits += [list(x) + [name] for x in h]
            with open(p, "w") as fh:
                fh.write(scan.redact(text, list(ctx["secrets"]) + list(ctx["honey"])))
    return hits


def _tool_counts(transcript):
    """(tool calls, calls whose input names the floor index): whether the floor reached the work."""
    n = floor = 0
    for line in open(transcript):
        ev = json.loads(line) if line.startswith("{") else {}
        for b in (ev.get("message") or {}).get("content") or [] if ev.get("type") == "assistant" else []:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                n, floor = n + 1, floor + ("names.md" in json.dumps(b.get("input")))
    return n, floor


def _size_mb(path):
    r = subprocess.run(["du", "-sm", path], capture_output=True, text=True)
    return int((r.stdout.split() or ["0"])[0])


def _launch(ctx, arm, sb, out, row):
    """Run the arm; return (status, reason) after the artifact checks."""
    before = scan.census(sb)
    job = dict(ctx["job"], work=sb, out=out, prompt=ctx["prompt"])
    r = executor.run(job, expect=ctx["expect"][arm], secrets=ctx["secrets"])
    row.update({k: r[k] for k in ("usd", "usage", "turns", "wall_s", "model", "version", "isolation", "init_sha",
                                  "org_sha", "skill_calls", "breaches", "scan_hits", "rate")})
    row["usd_estimate"] = None if r["usd"] is not None else job["max_budget_usd"]  # launched, unpriced: charge the cap
    row["tool_uses"], row["floor_reads"] = _tool_counts(os.path.join(out, "transcript.jsonl"))
    planted = scan.census_breaches(before, scan.census(sb))
    if planted:  # a planted link or FIFO would be followed (or hang) in the host-side diff (F-A); its
        # name is arm-chosen (it can spell the credential), so only a count and a hash are recorded
        row["planted_sha"] = hashlib.sha256("\0".join(planted).encode()).hexdigest()
        return "integrity_failed", "artifacts:%d" % len(planted)
    if r["status"] != "ok" and r["status"] != "truncated":
        return r["status"], r["reason"]
    if _size_mb(sb) > ctx["max_sandbox_mb"]:
        return "empty", "oversize"
    return r["status"], r["reason"]


def run(ctx, unit, arm, rep, rk):
    """Execute one rollout; return its ledger row (the caller appends it)."""
    out = ctx["ledger"].run_dir(rk)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    slug, cfg = "m" + rk[:15], ctx["cfg"][(arm, unit)]
    sb = os.path.join(ctx["sandbox_root"], slug)
    row = {"kind": "implement", "unit": unit, "arm": arm, "rep": rep, "runkey": rk, "usd": None}
    g = stage(ctx, unit, slug, cfg)
    row["gate"] = {"reason": g["reason"], "n_tokens": g["n_tokens"], "n_hits": len(g["hits"])}
    if not g["ok"] or g["staged"] != sorted(ctx["repos"][unit]):
        shutil.rmtree(sb, ignore_errors=True)
        return dict(row, status="aborted", reason="gate:%s staged=%s" % (g["reason"], g["staged"]))
    row["stripped"] = strip(sb, g["staged"])
    status, reason = _launch(ctx, arm, sb, out, row)
    paths = extract(ctx, unit, slug, rk, out, sb, cfg) if status in ("ok", "truncated") else []
    if paths is None:
        status, reason = "infra_failed", "extract-failed"
    elif paths:
        row["compile"] = compile_all(ctx, unit, sb, out, cfg)
        row["diff_lines"] = sum(1 for p in paths for ln in open(p) if ln[:1] in "+-" and ln[:3] not in ("+++", "---"))
        if row["diff_lines"] == 0 and status == "ok":
            status, reason = "empty", "no-change"
    hits = scan_outputs(ctx, out)
    if hits:
        status, reason, row["scan_hits"] = "integrity_failed", "scan", (row.get("scan_hits") or []) + hits
    shutil.rmtree(sb, ignore_errors=True)
    with open(os.path.join(out, "job.json"), "w") as fh:
        json.dump({"arm": arm, "unit": unit, "rep": rep, "runkey": rk}, fh)
    return _clean(ctx, dict(row, status=status, reason=reason))


def _clean(ctx, row):
    """The row itself carries arm-chosen strings (Skill names); a secret or honey in it is redacted
    before the ledger or the console sees it, and the rollout becomes integrity_failed."""
    text = json.dumps(row)
    hits = scan.find(text, secrets=ctx["secrets"], honey=ctx["honey"])
    if not hits:
        return row
    row = json.loads(scan.redact(text, list(ctx["secrets"]) + list(ctx["honey"])))
    return dict(row, status="integrity_failed", reason="scan", scan_hits=(row.get("scan_hits") or []) + [list(h) + ["row"] for h in hits])
