"""split.py — held-out units (docs/LOOP.md).

  order   position in `git rev-list --first-parent <base>`: topology, never commit dates
  vet     deterministic and model-free; every drop carries its reason
  spent   a unit is spent the moment any campaign of the project wrote its first score: read from
          every campaign's ledger, so there is no registry to forget and no file drawer
  split   train = the earliest n_train vetted units (spent ones allowed), then a gap, then val = the
          next n_val vetted units that are not spent and whose fork has every train merge as an
          ancestor (else dropped as fork-precedes-train; the next unit refills). Infeasible → exit 6.
"""
import glob
import json
import os
import subprocess

import campaign
import executor
import ledger
import rollout
import scan


def _git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)


def order(repo, base, units):
    """(units oldest-first by first-parent position, {unit: drop reason})."""
    r = _git(repo, "rev-list", "--first-parent", base)
    if r.returncode:
        raise executor.LoopError(3, "cannot list the first-parent history of %s in %s" % (base, repo))
    pos = {sha: i for i, sha in enumerate(r.stdout.split())}
    full = sorted({_git(repo, "rev-parse", u).stdout.strip() or u for u in units})  # a sha listed twice is one unit
    listed = sorted((u for u in full if u in pos), key=lambda u: -pos[u])
    return listed, {u: "not-on-first-parent-history" for u in full if u not in pos}


def spent(root, project, campaign=None):
    """Units another campaign has scored or holds a held-out reservation on (`campaign` excluded)."""
    out = {u for u, c in ledger.reserved(root, project).items() if c != campaign}
    for path in glob.glob(os.path.join(root, project, "c-*", "ledger.jsonl")):
        if campaign and os.path.basename(os.path.dirname(path)) == "c-" + campaign:
            continue
        for line in open(path):
            row = json.loads(line) if line.strip() else {}
            if row.get("kind") == "score" and row.get("unit"):
                out.add(row["unit"])
    return out


def _escapes(tree):
    """Symlinks in the fork tree that point outside it (the host-side diff would follow them)."""
    bad = []
    for rel, entry in scan.census(tree).items():
        if entry.startswith("link->"):
            target = os.path.realpath(os.path.join(tree, os.path.dirname(rel), entry[6:]))
            if not target.startswith(os.path.realpath(tree) + os.sep):
                bad.append(rel)
    return bad


def _reference_builds(ctx, unit, cfg):
    """Does the human's tip build in the image? Cached per unit: it costs a container build."""
    cache = os.path.join(ctx["units_dir"], unit, "reference_build.txt")
    if not os.path.isfile(cache):
        meta = open(os.path.join(ctx["units_dir"], unit, "meta.lines")).read().strip().split("|")
        tip = dict(x.split("=", 1) for x in meta[1:] if "=" in x)["endpoint"]
        tree = os.path.join(ctx["cdir"], "trees", "tip-" + tip)
        repo_tree = os.path.join(tree, meta[0])
        if not os.path.isdir(repo_tree):
            os.makedirs(repo_tree)
            subprocess.run("git -C '%s' archive %s | tar -x -C '%s'" % (os.path.join(ctx["root"], meta[0]), tip, repo_tree),
                           shell=True, check=True)
        r = rollout.lib("compile_gate.sh", [repo_tree, os.path.join(tree, "build.log")], cfg)
        with open(cache, "w") as fh:
            fh.write((r.stdout.strip().splitlines() or ["BUILD_FAILURE no-verdict"])[-1])
    return open(cache).read().startswith("BUILD_SUCCESS")  # "n/a" verifies nothing: not vetted


def vet(ctx, o, unit, base_cfg):
    """None if the unit may be used, else the reason it is dropped."""
    if unit in o.get("veto", ()):
        return "vetoed"
    os.makedirs(os.path.join(ctx["units_dir"], unit), exist_ok=True)
    try:
        forks = campaign.prepare(ctx, unit, base_cfg)
    except executor.LoopError as exc:
        return "prepare: " + str(exc)[:120]
    if o.get("visibility") != "private":
        return "cutoff-unverified (only private repos are cutoff-clean without a date check)"
    try:
        reason = campaign.arm_setup(ctx, o, unit, forks)
        if reason:
            return reason
        if _escapes(ctx["forks"][unit]):
            return "fork-symlink-escape"
        return None if _reference_builds(ctx, unit, base_cfg) else "env-cannot-build-reference"
    except (executor.LoopError, subprocess.CalledProcessError) as exc:  # a unit that cannot be vetted is dropped, not fatal
        return "vetting failed: " + str(exc)[:120]


def make(ctx, o, units, base_cfg, n_train=6, gap=1, n_val=10):
    """The frozen split (split.json): computed once per campaign, then only read."""
    path = os.path.join(ctx["cdir"], "split.json")
    if os.path.isfile(path):
        return campaign._json(path)
    repo = os.path.join(ctx["root"], o["repo"])
    ordered, drops = order(repo, o["base"], units)
    used, train, val, gapped = spent(o["root"], o["project"], o["campaign"]), [], [], []
    for u in ordered:
        if len(val) == n_val:
            break
        reason = vet(ctx, o, u, base_cfg)
        if reason:
            drops[u] = reason
        elif len(train) < n_train:
            train.append(u)
        elif len(gapped) < gap:
            gapped.append(u)
        elif u in used:
            drops[u] = "spent"
        elif any(_git(repo, "merge-base", "--is-ancestor", t, campaign._fork_of(repo, u)).returncode for t in train):
            drops[u] = "fork-precedes-train"
        else:
            val.append(u)
    if len(train) < n_train or len(val) < n_val:
        raise executor.LoopError(6, "infeasible split: %d train, %d val vetted (need %d + %d); drops: %s"
                                 % (len(train), len(val), n_train, n_val, json.dumps(drops)[:600]))
    span = _git(repo, "rev-list", "--first-parent", "%s^..%s" % (ordered[0], val[-1])).stdout.split()
    out = {"train": train, "gap": gapped, "val": val, "c_split": train[-1], "drops": drops, "order": ordered,
           "unlisted": sorted(set(span) - set(ordered))}  # first-parent commits in the span nobody offered as units
    with open(path, "w") as fh:
        json.dump(out, fh, indent=2)
    return out
