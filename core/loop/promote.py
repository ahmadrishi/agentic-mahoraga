"""promote.py — `mahoraga loop promote`: the one way a measured edit reaches the project.

Refused unless the campaign's decision is a VALID KEEP of a candidate the contained proposer wrote
(origin `proposer`), measured with enforced isolation and not a stub. There is no override flag.
The overlay is re-validated against the repo's HEAD, the diff against the project's current overlay
is shown, and the write needs a typed confirmation at a terminal. It writes the two overlay files
plus PROVENANCE.json (campaign, prereg and decision hashes, learned_through = the split's last train
merge): later campaigns use the overlay as their parent only for forks that descend from it.
"""
import difflib
import json
import os
import shutil
import subprocess
import sys

import campaign
import executor
import propose
import snapshot


def refusals(d, prereg):
    out = []
    if (d or {}).get("verdict") != "KEEP":
        out.append("the decision is %s, not KEEP" % (d or {}).get("verdict"))
    if (d or {}).get("stub"):
        out.append("a stub run")
    if (prereg or {}).get("origin") != "proposer":
        out.append("the candidate was not written by the contained proposer (origin %s)" % (prereg or {}).get("origin"))
    if (prereg or {}).get("isolation") != "enforced":
        out.append("isolation was not enforced")
    if (prereg or {}).get("control_fixture") or (d or {}).get("control_fixture"):
        out.append("a control-fixture campaign (hand-pinned criteria)")
    return out


def chain(cdir, d, overlay_dir):
    """The campaign's records must agree with each other and with the bytes on disk: the prereg hash
    (decision, ledger row 0), the frozen candidate (decision, ledger), a KEEP line in campaigns.jsonl,
    and the parent it was measured against = the overlay it would now replace."""
    out, prereg_path = [], os.path.join(cdir, "prereg.json")
    rows = [json.loads(ln) for ln in open(os.path.join(cdir, "ledger.jsonl"))] if os.path.isfile(os.path.join(cdir, "ledger.jsonl")) else []
    first = next((r for r in rows if r.get("kind") != "criteria"), {})
    if not (campaign._sha(prereg_path) == d.get("prereg_sha") == first.get("runkey")):
        out.append("prereg.json, the decision and ledger row 0 disagree")
    frozen = [r.get("candidate_sha") for r in rows if r.get("kind") == "candidate"]
    if propose.overlay_sha(os.path.join(cdir, "candidate", "overlay")) != d.get("candidate_sha") or frozen[-1:] != [d.get("candidate_sha")]:
        out.append("the candidate on disk is not the one that was frozen and measured")
    log = os.path.join(os.path.dirname(cdir), "campaigns.jsonl")
    lines = [json.loads(ln) for ln in open(log)] if os.path.isfile(log) else []
    if not any(x.get("campaign") == os.path.basename(cdir)[2:] and x.get("status") == "KEEP" and x.get("prereg_sha") == d.get("prereg_sha")
               for x in lines):
        out.append("campaigns.jsonl does not record this KEEP")
    if campaign._json(prereg_path, {}).get("parent_sha") != propose.overlay_sha(overlay_dir if os.path.isdir(overlay_dir or "") else None):
        out.append("the overlay it would replace is not the parent it was measured against")
    return out


def plan(cdir, overlay_dir, repo_dir, lang):
    """(refusals, diff text) for promoting campaign `cdir` into `overlay_dir`."""
    d, prereg = campaign._json(os.path.join(cdir, "decision.json")), campaign._json(os.path.join(cdir, "prereg.json"))
    cand = os.path.join(cdir, "candidate")
    if not d or not os.path.isdir(os.path.join(cand, "overlay")):
        return ["no decided campaign with a frozen candidate at %s" % cdir], ""
    out = refusals(d, prereg) or chain(cdir, d, overlay_dir)
    if not out:
        sha = subprocess.run(["git", "-C", repo_dir, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        head = os.path.join(cdir, "trees", "head-" + sha)
        if not os.path.isdir(head):  # extract beside it, then rename: a failed archive never leaves a half tree
            shutil.rmtree(head + ".part", ignore_errors=True)
            os.makedirs(head + ".part")
            r = subprocess.run("git -C '%s' archive HEAD | tar -x -C '%s.part'" % (repo_dir, head), shell=True)
            if r.returncode or not sha:
                return ["cannot extract the repo's HEAD for re-validation"], ""
            os.replace(head + ".part", head)
        out += ["at HEAD: " + e for e in propose.validate(cand, overlay_dir if os.path.isdir(overlay_dir or "") else None, lang, head)]
    diff = "".join("".join(difflib.unified_diff(
        (open(os.path.join(overlay_dir, n)).read() if overlay_dir and os.path.isfile(os.path.join(overlay_dir, n)) else "").splitlines(True),
        open(os.path.join(cand, "overlay", n)).read().splitlines(True), "current/" + n, "promoted/" + n)) for n in propose.FILES)
    return out, diff


def write(cdir, overlay_dir):
    os.makedirs(overlay_dir, exist_ok=True)
    for n in propose.FILES:
        with open(os.path.join(overlay_dir, n), "w") as fh:
            fh.write(open(os.path.join(cdir, "candidate", "overlay", n)).read())
    d, split = campaign._json(os.path.join(cdir, "decision.json")), campaign._json(os.path.join(cdir, "split.json"))
    prov = {"campaign": os.path.basename(cdir)[2:], "prereg_sha": d.get("prereg_sha"), "rule_sha": d.get("rule_sha"),
            "decision_sha": campaign._sha(os.path.join(cdir, "decision.json")), "learned_through": split["c_split"],
            "candidate_sha": snapshot.tree_hash(os.path.join(cdir, "candidate", "overlay")), "mean_d": d.get("mean_d")}
    with open(os.path.join(overlay_dir, "PROVENANCE.json"), "w") as fh:
        json.dump(prov, fh, indent=2, sort_keys=True)
    return prov


def cmd(a):
    o = {"config": os.path.abspath(a.config)}
    cfgd, loopc = campaign._config(o)
    cdir = os.path.join(os.path.abspath(a.root), o["project"], "c-" + a.campaign)
    overlay_dir = os.path.expanduser(loopc.get("overlay_dir") or "")
    if not overlay_dir:
        raise executor.LoopError(3, "PROJECT.yaml has no loop.overlay_dir to promote into")
    repo_dir = os.path.join(os.path.expanduser(cfgd["project"]["root"]), o["repo"])
    out, diff = plan(cdir, overlay_dir, repo_dir, o["langs"].get(o["repo"], ""))
    print(diff or "(no change)")
    if out:
        for r in out:
            print("REFUSED: " + r, file=sys.stderr)
        return 3
    if a.dry_run:
        print("promote --dry-run: every check passed; nothing written")
        return 0
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise executor.LoopError(3, "promote is interactive: run it at a terminal")
    if input("Type 'promote' to write these files into %s: " % overlay_dir).strip() != "promote":
        print("not promoted")
        return 0
    prov = write(cdir, overlay_dir)
    print("promoted (learned through %s); later campaigns use it as their parent only for forks that descend from it"
          % prov["learned_through"][:10])
    return 0
