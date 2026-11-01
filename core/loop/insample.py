"""insample.py — `mahoraga loop insample`: the kill test.

  prereg   protocol, units, k, seeds and models sealed as ledger row 0 before anything launches
  pre      every unit at S0 (always-on GUARD text + floor), k=6, scored
  edit     post_U(u): an editor sees u's SPEC/BR and pre attempts 1–3, unlabelled;
           post_P(u), u2..u4: an editor sees only EARLIER units (SPEC/BR, human diff, one attempt and
           its criteria statuses). Units must be in ancestry order, so post_P only sees history.
  post     each accepted candidate is staged through the unit's leak gate, run k=3 and scored
  decide   G, Δ_U, Δ_P and Rules A/B by code (stats.py) → decision.json, no timestamps
"""
import hashlib
import json
import os
import re
import subprocess

import campaign
import executor
import ledger as ledger_mod
import propose
import report
import score
import snapshot
import stats

HERE = os.path.dirname(os.path.abspath(__file__))
K_PRE, K_POST = 6, 3
MODE = {"post_U": "Each evidence/<dir>/ holds a task (SPEC.md, BUSINESS_REQUIREMENT.md) and three attempts at it "
                  "(attempt-*.diff). The attempts are not graded: judge them against the task yourself.",
        "post_P": "Each evidence/<dir>/ holds an earlier task (SPEC.md, BUSINESS_REQUIREMENT.md), the change a human "
                  "shipped for it (human.diff), one attempt (attempt.diff) and how that attempt fared on each "
                  "acceptance criterion (criteria-status.json). Evidence dirs are in the order the tasks shipped."}


def _sha_text(text):
    return hashlib.sha256(text.encode()).hexdigest()


def seal(ctx, o):
    """prereg.json, hashed into ledger row 0 (exit 6 if either disagrees on a resume)."""
    p = {k: o[k] for k in ("units", "seed", "model", "editor_model", "scorer", "scorer_model", "per_job_usd",
                           "editor_per_job_usd", "scorer_per_job_usd")}
    p.update(protocol="insample-v1", k_pre=K_PRE, k_post=K_POST, rule_a={"min_delta": 10}, rule_b={"min_wins": 2})
    return campaign.seal_prereg(ctx, p)


def check_order(ctx, units):
    for prev, nxt in zip(units, units[1:]):
        repo = os.path.join(ctx["root"], ctx["repos"][nxt][0])
        fork = campaign._fork_of(repo, nxt)
        if subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", prev, fork]).returncode:
            raise executor.LoopError(3, "units are not in ancestry order: %s is not an ancestor of %s's fork" % (prev[:10], nxt[:10]))


def _strip(text, units):
    for u in units:
        text = re.sub(re.escape(u[:7]) + "[0-9a-f]*", "", text)
    return text


def _diff(ctx, rk):
    run = ctx["ledger"].run_dir(rk)
    return "".join(open(os.path.join(run, f)).read() for f in sorted(os.listdir(run)) if f.startswith("ai_"))


def _unit_files(ctx, unit, names=("SPEC.md", "BUSINESS_REQUIREMENT.md")):
    udir = os.path.join(ctx["units_dir"], unit)
    return {n: open(os.path.join(udir, n)).read() for n in names}


def evidence(ctx, o, arm, unit, pre):
    """The editor's evidence for (arm, unit): only what the protocol allows it to see."""
    if arm == "post_U":
        files = _unit_files(ctx, unit)
        files.update({"attempt-%d.diff" % rep: _diff(ctx, rk) for (u, _, rep, rk) in pre if u == unit and rep <= 3})
        return [{k: _strip(v, o["units"]) for k, v in files.items()}]
    return history(ctx, o["units"][:o["units"].index(unit)], pre, o["units"])


def history(ctx, earlier, pre, all_units):
    """Labelled evidence from EARLIER units only, in the order they shipped: SPEC/BR, the human diff,
    one scored attempt and its per-criterion statuses (no percentages). Unit ids are stripped."""
    out = []
    for v in earlier:
        files = _unit_files(ctx, v)
        files["human.diff"] = "".join(open(os.path.join(ctx["units_dir"], v, f)).read()
                                      for f in sorted(os.listdir(os.path.join(ctx["units_dir"], v))) if f.startswith("human_") and f.endswith(".diff"))
        for (u, _, rep, rk) in sorted(p for p in pre if p[0] == v):
            s = campaign._json(os.path.join(ctx["ledger"].run_dir(rk), "score.json"), {})
            if s.get("status") == "ok":
                files["attempt.diff"] = _diff(ctx, rk)
                files["criteria-status.json"] = json.dumps([{"criterion": c["criterion"], "status": c["status"]}
                                                            for c in s["business_criteria"]], indent=2)
                break
        out.append({k: _strip(t, all_units) for k, t in files.items()})
    return out


def _wires(ctx, o):
    """Strings no editor may write: every unit and fork sha (whole, 10 and 7 chars) and the honey."""
    shas = list(o["units"]) + [campaign._fork_of(os.path.join(ctx["root"], ctx["repos"][u][0]), u) for u in o["units"]]
    return [x for s in shas for x in (s, s[:10], s[:7])] + list(ctx["honey"])


def _opaque(arm, unit):
    """The editor's directory name: its host path is visible inside the container, so it names neither."""
    return hashlib.sha256(("%s\0%s" % (arm, unit)).encode()).hexdigest()[:16]


def candidate(ctx, o, arm, unit, pre, later):
    """Run (or reload) the editor for (arm, unit); stage an accepted overlay; return its status."""
    out = os.path.join(ctx["cdir"], "propose", _opaque(arm, unit))
    sp = os.path.join(out, "status.json")
    if not os.path.isfile(sp):
        ev = evidence(ctx, o, arm, unit, pre)
        rk = ledger_mod.runkey({"propose": arm, "unit": unit, "evidence": _sha_text(json.dumps(ev, sort_keys=True)),
                                "model": ctx["editor_job"]["model"], "prompt": campaign._sha(os.path.join(HERE, "prompts", "propose.md"))})
        ctx["ledger"].check(later)
        os.makedirs(out, exist_ok=True)
        prompt = open(os.path.join(HERE, "prompts", "propose.md")).read() % {"mode": MODE[arm]}
        res = propose.edit(ctx, out, rk, prompt, None, ctx["forks"][unit], ev, ctx["floor"][unit][2], _wires(ctx, o))
        res["evidence_units"] = [v[:12] for v in o["units"][:o["units"].index(unit)]] if arm == "post_P" else [unit[:12]]
        res["evidence_files"] = [sorted(e) for e in ev]
        propose.write_status(out, res)
        index = os.path.join(ctx["cdir"], "propose", "index.json")
        with open(index + ".part", "w") as fh:
            json.dump(dict(campaign._json(index, {}), **{"%s-%s" % (arm, unit[:12]): _opaque(arm, unit)}), fh, indent=2)
        os.replace(index + ".part", index)
    res = campaign._json(sp)
    if res["status"] == "ok" and not campaign.stage_arm(ctx, o, unit, arm, os.path.join(out, "overlay"))["ok"]:
        res = dict(res, status="fell_back", errors=["the overlay failed the unit's leak gate (no feedback is given)"])
        propose.write_status(out, res)
    print("  editor %s %s: %s after %d attempt(s)%s" % (arm, unit[:10], res["status"], res["attempts"],
          "" if res["status"] != "fell_back" else " — " + "; ".join(res["errors"])[:200]), flush=True)
    return res["status"]


def scores(ctx, plan, unit, arm):
    out = []
    for (u, a, rep, rk) in sorted(p for p in plan if p[0] == unit and p[1] == arm):
        s = campaign._json(os.path.join(ctx["ledger"].run_dir(rk), "score.json"), {})
        out.append(s.get("business_req_pct") if s.get("status") == "ok" else None)
    return out


def decide(ctx, o, sha, pre, post, status):
    units = [{"pre": scores(ctx, pre, u, "pre"), "post_U": scores(ctx, post, u, "post_U"),
              "post_U_status": status.get(("post_U", u)), "post_P": scores(ctx, post, u, "post_P"),
              "post_P_status": status.get(("post_P", u))} for u in o["units"]]
    family = ctx["scorer_family"]
    d = {"protocol": "insample-v1", "prereg_sha": sha, "rule_a": stats.rule_a(units), "rule_b": stats.rule_b(units),
         "units": [dict(x, u="u%d" % i) for i, x in enumerate(units, 1)], "scorer_family": family, "stub": o["stub"],
         "isolation": "enforced" if o["runner"] == "docker" else "instructed",
         "advisory": family == "claude" or o["stub"] or o["runner"] != "docker"}
    with open(os.path.join(ctx["cdir"], "decision.json"), "w") as fh:
        json.dump(d, fh, indent=2, sort_keys=True)
    for r in (d["rule_a"], d["rule_b"]):
        print("  Rule %s: %s (Δ=%s, G=%s)%s" % (r["rule"], r["verdict"], r["delta"] if r["delta"] is None else round(r["delta"], 2),
                                              r["G"] if r["G"] is None else round(r["G"], 2),
                                              " — ADVISORY (same-family scorer, stub or instructed run)" if d["advisory"] else ""))
    return d


def run(o):
    if len(o["units"]) != 4:
        raise executor.LoopError(3, "the kill test takes exactly 4 units in ancestry order (Rule B needs 2 wins of 3)")
    if not o.get("builtins") and not o["stub"]:
        raise executor.LoopError(3, "the kill test needs --builtins <canary.json> from a passed `loop preflight --paid`")
    o.update(arms=["pre"], k=K_PRE, label="INSAMPLE")
    ctx = campaign.setup(o)
    sha = seal(ctx, o)
    empty = os.path.join(ctx["cdir"], "snapshots", "empty")
    os.makedirs(empty, exist_ok=True)
    base = snapshot.derive_config(o["config"], os.path.join(ctx["cdir"], "base.yaml"), empty, ctx["sandbox_root"], o["build"])
    dropped = campaign.setup_units(ctx, o, base)
    if dropped:
        raise executor.LoopError(3, "every unit must stage cleanly for the kill test: %s" % dropped)
    check_order(ctx, o["units"])
    n_cand, n_post = 2 * len(o["units"]) - 1, (2 * len(o["units"]) - 1) * K_POST
    print("insample: %d units × pre k=%d, %d candidates × k=%d; cap $%.2f" % (len(o["units"]), K_PRE, n_cand, K_POST, o["budget_usd"]))
    if o["dry_run"]:
        return 0
    with campaign._network(ctx, o):
        pre, crit = campaign.make_plan(ctx, o, o["units"], dropped)
        later = {"propose": (n_cand, ctx["editor_job"]["max_budget_usd"]), "implement": (n_post, o["per_job_usd"]),
                 "score": (n_post, o["scorer_per_job_usd"])}
        campaign.implement(ctx, o, pre, dropped, later)
        campaign.score_all(ctx, o, pre, dropped, crit, later)
        if dropped or stats.gap([{"pre": scores(ctx, pre, u, "pre")} for u in o["units"]]) is None:
            raise executor.LoopError(5, "the pre phase is incomplete (%s): the kill test is INVALID before any editor runs"
                                     % (dropped or "a pre rollout has no score"))
        later = {"implement": (n_post, o["per_job_usd"]), "score": (n_post, o["scorer_per_job_usd"])}
        cands = [(arm, u) for u in o["units"] for arm in ("post_U", "post_P") if arm == "post_U" or u != o["units"][0]]
        status = {}
        for i, (arm, u) in enumerate(cands):  # each remaining editor may take two sessions
            status[(arm, u)] = candidate(ctx, o, arm, u, pre, campaign._plus(
                later, {"propose": (2 * (len(cands) - i), ctx["editor_job"]["max_budget_usd"])}))
        post = [(u, arm, rep, campaign._rk(ctx, o, u, arm, rep)) for rep in range(1, K_POST + 1)
                for (arm, u), st in sorted(status.items()) if st == "ok"]
        campaign.implement(ctx, o, post, dropped)
        campaign.score_all(ctx, o, post, dropped, crit)
    d = decide(ctx, o, sha, pre, post, status)
    code = report.write(ctx, o, pre + post, dropped, base, len(pre) + len(post))
    invalid = any(r["verdict"] == "INVALID" for r in (d["rule_a"], d["rule_b"]))
    return 5 if invalid else code
