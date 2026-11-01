"""report.py — what a prove run measured: calib.json, the console table, and final/.

Every number here is None-aware: an unscored rollout is "not measured", never 0 and never "no
defect". final/ is a PROVE RUN_DIR rendered by the unchanged aggregate_scores.py and build_report.py
(the `pre` arm as "harness", `bare` as "baseline"); no decision passes through them, and a score
the scorer failed to produce is left out of final/ rather than rendered as a clean one.
"""
import collections
import glob
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess

import executor

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib")
OK = ("ok", "truncated", "empty")
FAILED = ("infra_failed", "aborted", "integrity_failed")
FINAL_NAMES = {"pre": ("score.json", "harness"), "bare": ("score.baseline.json", "baseline")}


def _mean(xs):
    return round(statistics.mean(xs), 3) if xs else None


def _rate(n, d):
    return round(n / d, 3) if d else None


def defect(v):
    """True / False, or None when not measured."""
    if v is None:
        return None
    s = str(v).strip().lower()
    return not (not s or re.match(r"none\b", s) or s in ("n/a", "na", "-", "parity"))


def arm_stats(items):
    """items: [(unit, rep, row, score|None)] for one arm."""
    rows = [r for _, _, r, _ in items]
    ran = [r for r in rows if r["status"] in OK]
    scored = [(u, s) for u, _, _, s in items if s and isinstance(s.get("business_req_pct"), (int, float))]
    by_unit = collections.defaultdict(list)
    for u, s in scored:
        by_unit[u].append(s["business_req_pct"])
    num = lambda k: [r[k] for r in rows if isinstance(r.get(k), (int, float))]  # noqa: E731
    out = {"n": len(rows), "status": dict(collections.Counter(r["status"] for r in rows)), "n_scored": len(scored),
           "mean_pct": _mean([s["business_req_pct"] for _, s in scored]),
           "unit_means": {u[:12]: _mean(v) for u, v in sorted(by_unit.items())},
           "sd_within": _mean([statistics.stdev(v) for v in by_unit.values() if len(v) > 1]),
           "usd_mean": _mean(num("usd")), "usd_max": max(num("usd"), default=None),
           "wall_mean": _mean(num("wall_s")), "turns_mean": _mean(num("turns")),
           "truncation_rate": _rate(sum(r["status"] == "truncated" for r in rows), len(rows)),
           "skill_rate": _rate(sum(bool(r.get("skill_calls")) for r in ran), len(ran)),
           "floor_rate": _rate(sum(bool(r.get("floor_reads")) for r in ran), len(ran)),
           "compile_ok": "%d/%d" % (sum(r.get("compile") == "BUILD_SUCCESS" for r in ran),
                                    sum(str(r.get("compile", "")).startswith("BUILD_") for r in ran))}
    for k in ("hallucination", "overeng", "lost_context"):
        flags = [s[k + "_present"] if isinstance(s.get(k + "_present"), bool) else defect(s.get(k))
                 for _, _, _, s in items if s and s.get("status") == "ok"]
        out[k] = {"defects": sum(bool(f) for f in flags), "measured": len(flags)}
    return out


def collect(ledger, plan):
    per = collections.defaultdict(list)
    for unit, arm, rep, rk in plan:
        row = ledger.done(rk)
        if row:
            sp = os.path.join(ledger.run_dir(rk), "score.json")
            per[arm].append((unit, rep, row, json.load(open(sp)) if os.path.isfile(sp) else None))
    return per


def write_final(ctx, per, cfg):
    fdir = os.path.join(ctx["cdir"], "final")
    shutil.rmtree(fdir, ignore_errors=True)
    os.makedirs(fdir)
    tasks = {}
    for arm, items in sorted(per.items()):
        fname, label = FINAL_NAMES.get(arm, ("score.%s.json" % arm, arm))
        for unit, rep, row, s in items:
            tid, udir = "%s-r%d" % (unit[:10], rep), os.path.join(ctx["units_dir"], unit)
            d = os.path.join(fdir, tid)
            if tid not in tasks:
                os.makedirs(d)
                tasks[tid] = {"unit": unit, "rep": rep}
                for p in glob.glob(os.path.join(udir, "human_*.diff")) + [os.path.join(udir, f) for f in ("SPEC.md", "BUSINESS_REQUIREMENT.md")]:
                    shutil.copyfile(p, os.path.join(d, os.path.basename(p)))
            for p in glob.glob(os.path.join(ctx["ledger"].run_dir(row["runkey"]), "ai_*.diff")):
                name = os.path.basename(p) if arm == "pre" else "%s_%s" % (arm, os.path.basename(p)[3:])
                shutil.copyfile(p, os.path.join(d, name))
            if s and s.get("status") == "ok":
                with open(os.path.join(d, fname), "w") as fh:
                    json.dump(dict(s, id=tid, title="%s rep %d" % (unit[:10], rep), arm=label, loop_arm=arm,
                                   rollout_status=row["status"]), fh, indent=2)
    with open(os.path.join(fdir, "state.json"), "w") as fh:
        json.dump({"tasks": tasks}, fh, indent=2)
    for script in ("aggregate_scores.py", "build_report.py"):
        r = subprocess.run(["python3", os.path.join(LIB, script), fdir], capture_output=True, text=True,
                           env=dict(os.environ, PROJECT_CONFIG=cfg))
        if r.returncode:
            raise executor.LoopError(3, "%s failed on final/: %s" % (script, (r.stderr or r.stdout).strip()[-300:]))
    return fdir


def write(ctx, o, plan, dropped, cfg, n_planned, calibrate=True):
    """calib.json + final/ + the console table; return the exit code (5 = INVALID). n_planned counts
    every rollout of every unit that passed vetting, so a unit dropped later (criteria failed, infra)
    and an unscored rollout both count as failures."""
    L, per = ctx["ledger"], collect(ctx["ledger"], [p for p in plan if p[0] not in dropped])
    rows = [r for items in per.values() for _, _, r, _ in items]
    scored = sum(bool(s and s.get("status") == "ok") for items in per.values() for _, _, _, s in items)
    failed = n_planned - scored
    calib = {"campaign": o["campaign"], "model": o["model"], "scorer_model": o["scorer_model"], "binary_sha": o["binary_sha"],
             "isolation": "enforced" if o["runner"] == "docker" else "instructed", "stub": o["stub"],
             "same_family": ctx["scorer_family"] == "claude", "scorer_family": ctx["scorer_family"], "spent_usd": round(L.spent(), 4), "planned": n_planned, "ran": len(rows),
             "scored": scored, "failure_rate": _rate(failed, n_planned), "dropped_units": dropped, "builtin_skills": ctx["builtins"],
             "floor": {u[:12]: {k: m.get(k) for k in ("floor_rows", "floor_dropped", "gate_hit_tokens", "gate", "always_on_bytes")}
                       for (a, u), m in ctx["manifest"].items() if a == "pre"},
             "arms": {arm: arm_stats(items) for arm, items in sorted(per.items())}}
    ident = hashlib.sha256(open(os.path.join(ctx["cdir"], "loop.json"), "rb").read()).hexdigest()[:12]
    targets = [os.path.join(ctx["cdir"], "calib.json")]  # a held-out gate never calibrates anything (it would validate itself)
    for path in targets + ([os.path.join(o["root"], o["project"], "calib", ident, "calib.json")] if calibrate else []):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            json.dump(calib, fh, indent=2)
    fdir = write_final(ctx, per, cfg)
    invalid = any((L.done(p[3]) or {}).get("status") == "integrity_failed" for p in plan) or not scored \
        or calib["failure_rate"] > 0.25
    return _console(ctx, o, calib, fdir, invalid)


def _console(ctx, o, calib, fdir, invalid):
    for arm, st in calib["arms"].items():
        print("  %-6s n=%d scored=%d mean_pct=%s sd_within=%s compile=%s $/rollout=%s wall=%ss trunc=%s skill_rate=%s "
              "floor_rate=%s %s" % (arm, st["n"], st["n_scored"], st["mean_pct"], st["sd_within"], st["compile_ok"],
                                    st["usd_mean"], st["wall_mean"], st["truncation_rate"], st["skill_rate"],
                                    st["floor_rate"], st["status"]))
    print("  spent $%.4f · failures %s · calib %s · report %s" % (calib["spent_usd"], calib["failure_rate"],
                                                                 os.path.join(ctx["cdir"], "calib.json"), os.path.join(fdir, "report.html")))
    label = o.get("label", "PROVE")
    if invalid:
        print(label + " INVALID — an integrity failure, nothing scored, or > 25% of planned rollouts unscored; "
              "the numbers above are not evidence.")
        return 5
    family = "descriptive: same-family scorer" if calib["same_family"] else "scorer family: " + ctx["scorer_family"]
    print("%s DONE (%s%s)" % (label, family, ", STUB RUN" if o["stub"] else ""))
    return 0
