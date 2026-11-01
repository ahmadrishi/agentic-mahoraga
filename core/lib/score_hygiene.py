#!/usr/bin/env python3
"""score_hygiene.py — the scoring discipline PROVE's numbers stand on (stdlib only).

Three checks, after Harness² (arXiv:2610.14224; google-research/harness2 — ideas ported, no code
copied): a score that does not exist is NOT a zero, the scorer does not know which arm it scores,
and a scorer from the implementer's own model family is flagged (self-preference risk).

  * recompute(task)  — business_req_pct is recomputed in code from business_criteria (the
    EVAL-RUBRIC roll-up: full=1, partial=0.5, none=0, weight-normalised), so a grader's arithmetic
    can never be the headline. Records business_req_source = criteria | grader | invalid-criteria |
    missing, and the grader's own value as business_req_pct_reported when it disagreed.
  * families(tasks)  — which model families scored / implemented / improved, and whether any overlap.
  * blind / unblind  — stage each arm's AI diffs under seeded, opaque labels (A, B, …) for the scorer,
    with the label→arm key kept outside the blind dir; then map the scorer's files back to arms.

CLI:
    python3 core/lib/score_hygiene.py blind <RUN_DIR> <UNIT> --seed S --arm harness=ai --arm baseline=baseline
    python3 core/lib/score_hygiene.py unblind <RUN_DIR> <UNIT>
"""
import argparse
import glob
import json
import os
import random
import shutil
import sys

STATUS_SCORE = {"full": 1.0, "partial": 0.5, "none": 0.0}
KEY_FILE = ".blind-key.json"  # in <UNIT>/, never inside <UNIT>/blind/ (the scorer's view)


def status_weight(c):
    """The score weight of criterion c's status (full 1, partial 0.5, none 0); None when it is not
    one of those, including a missing status (never silently 0)."""
    s = c.get("status") if isinstance(c, dict) else None
    return STATUS_SCORE.get(s.strip().lower()) if isinstance(s, str) else None


def recompute(task):
    """Return `task` with business_req_pct taken from its criteria when they are valid (see module doc)."""
    t, crit, reported = dict(task), task.get("business_criteria"), task.get("business_req_pct")
    if not crit:
        t["business_req_source"] = "grader" if isinstance(reported, (int, float)) else "missing"
        return t
    num = den = 0.0
    for c in crit if isinstance(crit, list) else [None]:
        c = c if isinstance(c, dict) else {}
        w, s = c.get("weight", 1), status_weight(c)
        if s is None or isinstance(w, bool) or not isinstance(w, (int, float)) or w < 0:
            t["business_req_pct"], t["business_req_source"] = None, "invalid-criteria"
            return t
        num, den = num + w * s, den + w
    if den <= 0:
        t["business_req_pct"], t["business_req_source"] = None, "invalid-criteria"
        return t
    t["business_req_pct"], t["business_req_source"] = int(round(100 * num / den)), "criteria"
    if reported != t["business_req_pct"]:
        t["business_req_pct_reported"] = reported
    return t


def families(tasks):
    """{scorer, implementer, improver: sorted families, same_family: bool | None (None = not recorded)}."""
    fam = lambda key: sorted({str(t[key]).strip().lower() for t in tasks if str(t.get(key) or "").strip()})
    out = {"scorer": fam("scorer_family"), "implementer": fam("implementer_family"), "improver": fam("improver_family")}
    out["same_family"] = (bool(set(out["scorer"]) & (set(out["implementer"]) | set(out["improver"])))
                          if out["scorer"] and (out["implementer"] or out["improver"]) else None)
    return out


def blind(run_dir, unit, arms, seed):
    """Copy each arm's <variant>_<repo>.diff to <UNIT>/blind/<label>/candidate_<repo>.diff under a
    seeded shuffle of labels; write the label→arm key to <UNIT>/.blind-key.json. Returns the labels."""
    udir = os.path.join(run_dir, unit)
    order = sorted(arms)
    random.Random("%s:%s" % (seed, unit)).shuffle(order)
    bdir = os.path.join(udir, "blind")
    shutil.rmtree(bdir, ignore_errors=True)
    key = {}
    for i, arm in enumerate(order):
        label = chr(ord("A") + i)
        os.makedirs(os.path.join(bdir, label))
        diffs = sorted(glob.glob(os.path.join(udir, "%s_*.diff" % arms[arm])))
        if not diffs:
            raise SystemExit("score_hygiene: no %s_*.diff for arm %s in %s" % (arms[arm], arm, udir))
        for d in diffs:
            repo = os.path.basename(d)[len(arms[arm]) + 1:]
            shutil.copyfile(d, os.path.join(bdir, label, "candidate_" + repo))
        key[label] = arm
    json.dump({"seed": str(seed), "labels": key}, open(os.path.join(udir, KEY_FILE), "w"), indent=2)
    return sorted(key)


def unblind(run_dir, unit):
    """Map <UNIT>/blind/<label>/score.json back to score.json (harness), score.baseline.json, or
    score.<arm>.json, stamping arm + blind_label. Returns the files written."""
    udir = os.path.join(run_dir, unit)
    key = json.load(open(os.path.join(udir, KEY_FILE)))["labels"]
    written = []
    for label, arm in sorted(key.items()):
        src = os.path.join(udir, "blind", label, "score.json")
        if not os.path.isfile(src):
            raise SystemExit("score_hygiene: missing scorer output %s (arm left unscored)" % src)
        score = dict(json.load(open(src)), arm=arm, blind_label=label)
        dst = os.path.join(udir, "score.json" if arm == "harness" else "score.%s.json" % arm)
        json.dump(score, open(dst, "w"), indent=2)
        written.append(dst)
    return written


def main(argv):
    p = argparse.ArgumentParser(prog="score_hygiene.py", description="Blind / unblind PROVE arms for scoring.")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("blind")
    b.add_argument("run_dir"); b.add_argument("unit"); b.add_argument("--seed", required=True)
    b.add_argument("--arm", action="append", required=True, help="<arm>=<diff variant>, e.g. baseline=baseline")
    u = sub.add_parser("unblind")
    u.add_argument("run_dir"); u.add_argument("unit")
    a = p.parse_args(argv)
    if a.cmd == "blind":
        arms = dict(x.split("=", 1) for x in a.arm if "=" in x)
        if len(arms) != len(a.arm):
            p.error("--arm takes <arm>=<diff variant>")
        print(" ".join(blind(a.run_dir, a.unit, arms, a.seed)))
    else:
        for f in unblind(a.run_dir, a.unit):
            print(f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
