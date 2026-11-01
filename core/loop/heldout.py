"""heldout.py — `mahoraga loop gate`: the held-out gate (docs/LOOP.md).

  split    frozen once per campaign (split.py); re-checked on every real run against units another
           campaign has scored or reserved (exit 6 on a clash)
  freeze   the candidate is copied and hashed (a later edit to its source is exit 6), validated
           against the C_split tree, tripwired (exit 2), and refused if it equals its parent
  reserve  the val units, under a lock, before anything launches: reserved = spent for everyone else
  prereg   rule sha, split, candidate/parent sha, every val unit's frozen-criteria sha, the
           calibration relied on, veto list, k — ledger row 0
  stage    pre = parent, post = parent + candidate; a post leak-gate hit REJECTS the candidate (no
           retry, no feedback: the gate output is not even logged) — the val units stay spent
  measure  val × {pre, post} × k interleaved; a seeded share of model-graded rollouts re-scored
  decide   the sealed rule (decide.RULE) → decision.json; a resume may rewrite it only with the same verdict
"""
import glob
import hashlib
import json
import os
import random

import campaign
import decide
import egress_proxy
import executor
import insample
import ledger as ledger_mod
import propose
import report
import score
import snapshot
import split
import stats

HERE = os.path.dirname(os.path.abspath(__file__))
R = decide.RULE
REFUSED_TRACKERS = ("jira", "file")  # their merge dates disagree (jira) or are absent (file): no honest order


def _score(ctx, rk, name="score.json"):
    return campaign._json(os.path.join(ctx["ledger"].run_dir(rk), name), {})


def _pct(s):
    return s.get("business_req_pct") if s.get("status") == "ok" else None


def rescore(ctx, o, plan, crit, dropped):
    """Re-score a seeded share of MODEL-graded rollouts in a fresh session and directory; return
    (mean |Δpct|, per-criterion agreement), or (None, None) when nothing could be checked."""
    L = ctx["ledger"]
    items = [p for p in plan if p[0] not in dropped and _score(ctx, p[3]).get("scored_by") == "model" and _pct(_score(ctx, p[3])) is not None]
    pick = sorted(random.Random(o["seed"] + ":rescore").sample(items, max(1, round(R["double_frac"] * len(items))))) if items else []
    pairs = []
    for i, (u, arm, rep, rk) in enumerate(pick):
        srk = ledger_mod.runkey({"rescore": rk, "criteria": crit[u], "model": o["scorer_model"]})
        if not L.done(srk):
            L.check({"score": (len(pick) - i, o["scorer_per_job_usd"])})
            s2 = score.grade(dict(ctx, seed=ctx["seed"] + ":rescore"), rk, srk, u, crit[u], L.done(rk), tag="rescore")
            with open(os.path.join(L.run_dir(rk), "score2.json"), "w") as fh:
                json.dump(s2, fh, indent=2)
            L.append({"kind": "rescore", "runkey": srk, "of": rk, "status": s2["status"], "usd": None})
        pairs.append((_score(ctx, rk), _score(ctx, rk, "score2.json")))
        if _pct(pairs[-1][1]) is None:
            return None, None
    return decide.agreement(pairs) if pairs else (None, None)


def _calibration(o):
    """The calibration this campaign relies on: same model, binary, scorer model and stub-ness, from
    a calibrating run (gates never write one). {path, sha} or None — recorded in the prereg."""
    for path in sorted(glob.glob(os.path.join(o["root"], o["project"], "calib", "*", "calib.json"))):
        c = campaign._json(path, {})
        if (c.get("model"), c.get("binary_sha"), c.get("scorer_model"), bool(c.get("stub"))) == \
                (o["model"], o["binary_sha"], o["scorer_model"], bool(o["stub"])):
            return {"path": path, "sha": campaign._sha(path)}
    return None


def validity(ctx, o, plan, n_val, used, dropped, drift, calib):
    L = ctx["ledger"]
    rows = [L.done(p[3]) for p in plan if p[0] not in dropped]
    breaches = [b for log, allow in campaign.proxy_logs(ctx) for b in egress_proxy.classify(log, allow)["allow_breach"]]
    return {"executed_equals_planned": all(rows),  # every job of every kept unit has a terminal row
            "init_assertions_passed": not any((r or {}).get("status") == "integrity_failed" for r in rows),
            "isolation_enforced": o["runner"] == "docker" or o["stub"],
            "scorer_family_differs": ctx["scorer_family"] != "claude" or o["stub"],
            "calibration_exists": bool(calib) and campaign._sha(calib["path"]) == calib["sha"],
            "k_matches_rule": all(len(x["pre"]) == len(x["post"]) == R["k"] for x in used) or o["stub"],
            "units_dropped_ok": n_val - len(used) <= max(1, int(R["drop_max_frac"] * n_val)) and len(used) >= R["n_min"],
            "scorer_consistent": None not in drift and drift[0] <= R["rescore_max_abs_delta"] and drift[1] >= R["rescore_min_agreement"],
            "one_org_sha_across_measurement": len({(r or {}).get("org_sha") for r in rows}) <= 1,
            "egress_within_allowlist": not breaches}


def extras(ctx, plan, used_units, val):
    """Clause 5/6 inputs over the units the decision uses, and only their ok scores."""
    L = ctx["ledger"]
    kept = [p for p in plan if p[0] in used_units]
    def per(arm, f):
        return sum(f(L.done(p[3]) or {}, _score(ctx, p[3])) for p in kept if p[1] == arm)
    def usd(arm):
        xs = [(L.done(p[3]) or {}).get("usd") for p in kept if p[1] == arm]
        return stats.mean([x for x in xs if isinstance(x, (int, float))] or [None])
    ok = lambda s: s.get("status") == "ok"  # noqa: E731
    return {"compile": {a: per(a, lambda r, s: r.get("compile") == "BUILD_SUCCESS") for a in ("pre", "post")},
            "defects": {a: per(a, lambda r, s: ok(s) * (bool(s.get("hallucination_present")) + bool(s.get("lost_context_present"))))
                        for a in ("pre", "post")},
            "always_on_delta": max(ctx["manifest"][("post", u)]["always_on_bytes"] - ctx["manifest"][("pre", u)]["always_on_bytes"]
                                   for u in val), "usd": {a: usd(a) for a in ("pre", "post")}}


def _candidate(ctx, o, sp):
    """Freeze, validate and tripwire the candidate; refuse a NOOP unless it is a declared A/A control."""
    wdir, src_sha = os.path.join(ctx["cdir"], "candidate"), snapshot.tree_hash(o["candidate"])
    if os.path.isdir(wdir):
        if open(os.path.join(wdir, "source.sha")).read() != src_sha:
            raise executor.LoopError(6, "the candidate changed since this campaign froze it; start a new --campaign")
    else:
        os.makedirs(os.path.join(wdir, "overlay"))
        for name in propose.FILES:
            src = os.path.join(o["candidate"], name)
            with open(os.path.join(wdir, "overlay", name), "w") as fh:
                fh.write(open(src).read() if os.path.isfile(src) else "")
        open(os.path.join(wdir, "source.sha"), "w").write(src_sha)
    units = sp["train"] + sp["val"]
    if propose.tripwire(wdir, [x for u in units for x in (u, u[:10], u[:7])] + list(ctx["honey"])):
        raise executor.LoopError(2, "the candidate names a unit id, honey string or score field")
    errors = propose.validate(wdir, o.get("parent"), ctx["floor"][sp["c_split"]][2], ctx["c_split_tree"])
    if errors:
        raise executor.LoopError(3, "the candidate fails the validator: " + "; ".join(errors)[:600])
    text = lambda d: [open(os.path.join(d, n)).read() if d and os.path.isfile(os.path.join(d, n)) else "" for n in propose.FILES]  # noqa: E731
    if text(os.path.join(wdir, "overlay")) == text(o.get("parent")) and not o.get("allow_noop"):
        raise executor.LoopError(3, "the candidate equals its parent (NOOP): nothing to measure (--allow-noop runs it as an A/A control)")
    return os.path.join(wdir, "overlay")


def _dry_report(ctx, o, sp):
    print("split: train %d · gap %d · val %d · %d dropped · %d unlisted first-parent commits in the span"
          % (len(sp["train"]), len(sp["gap"]), len(sp["val"]), len(sp["drops"]), len(sp["unlisted"])))
    for u, why in sorted(sp["drops"].items()):
        print("  drop %s: %s" % (u[:10], why))
    n, prior = len(sp["val"]) * 2 * o["k"], ctx["ledger"].p95("implement", None)
    t = 0 if o.get("candidate") else len(sp["train"])  # `loop run` adds train evidence and up to two editor sessions
    rs, sc = round(R["double_frac"] * n), ctx["ledger"].p95("score", o["scorer_per_job_usd"])
    est = (n + t) * prior + (n + t + rs) * sc + (2 * o.get("editor_per_job_usd", 0.5) if t else 0) if prior else None
    print("jobs: %d rollouts + %d scores (+%d re-scores)%s; expected ≈ %s (the launch check also reserves every job in "
          "flight at its cap, so it asks for more)" % (n + t, n + t, rs, " + 2 editor sessions" if t else "",
                                                       "$%.2f" % est if est else "not measured"))
    sigmas = [a.get("sd_within") for p in glob.glob(os.path.join(o["root"], o["project"], "calib", "*", "calib.json"))
              for a in campaign._json(p, {}).get("arms", {}).values() if isinstance(a.get("sd_within"), (int, float))]
    sigma = max(sigmas) if sigmas else 15.0
    print("power of rule %s at σ_w %.1f (model): P(KEEP | true Δ) = %s" % (R["version"], sigma, decide.power(sigma, k=o["k"], sims=500)))


def _prepare(ctx, o, sp, base):
    """Prepare + floor every split unit (a resume reads split.json without vetting) and stage pre at
    S0 first, so case-variant floor rows are pruned before the parent is staged. Also extract the
    tree AT C_split (after the last train merge): what the editor sees and what candidates are
    validated against."""
    for u in sp["train"] + sp["val"]:
        campaign._floor(ctx, o, u, campaign.prepare(ctx, u, base))
        campaign.stage_arm(ctx, o, u, "pre")
    ctx["c_split_tree"] = snapshot.fork_tree(os.path.join(ctx["root"], o["repo"]), sp["c_split"],
                                             os.path.join(ctx["cdir"], "trees", "csplit-" + sp["c_split"]))
    learned = campaign._json(os.path.join(o.get("parent") or "", "PROVENANCE.json"), {}).get("learned_through")
    repo = os.path.join(ctx["root"], o["repo"])
    late = [u for u in sp["val"] if learned and split._git(repo, "merge-base", "--is-ancestor", learned, campaign._fork_of(repo, u)).returncode]
    if late:  # the parent was learned through a merge some val fork does not contain
        raise executor.LoopError(3, "the parent overlay was learned through %s, which %d val unit fork(s) precede" % (learned[:10], len(late)))


def _propose(ctx, o, sp):
    """`loop run`: train evidence (pre k=1 on the train units, scored, against the parent), then the
    contained editor writes the candidate from that history alone. Returns its status dict; the
    overlay is in cdir/propose/overlay when status is ok."""
    out = os.path.join(ctx["cdir"], "propose")
    if os.path.isfile(os.path.join(out, "status.json")):
        return campaign._json(os.path.join(out, "status.json"))
    n_val = len(sp["val"]) * 2 * o["k"]
    later = {"propose": (2, ctx["editor_job"]["max_budget_usd"]), "implement": (n_val, o["per_job_usd"]), "score": (n_val, o["scorer_per_job_usd"])}
    for u in sp["train"] if o.get("parent") else []:
        campaign.stage_arm(ctx, o, u, "pre", o["parent"])
    dropped = {}
    plan, crit = campaign.make_plan(ctx, dict(o, arms=["pre"], k=1), sp["train"], dropped)
    campaign.implement(ctx, o, plan, dropped, later)
    campaign.score_all(ctx, o, plan, dropped, {u: c for u, c in crit.items() if c}, later)
    units = sp["train"] + sp["val"]
    ev = insample.history(ctx, sp["train"], plan, units)
    rk = ledger_mod.runkey({"propose": "loop-run", "evidence": hashlib.sha256(json.dumps(ev, sort_keys=True).encode()).hexdigest(),
                            "model": ctx["editor_job"]["model"], "prompt": campaign._sha(os.path.join(HERE, "prompts", "propose.md"))})
    ctx["ledger"].check(later)
    os.makedirs(out, exist_ok=True)
    prompt = open(os.path.join(HERE, "prompts", "propose.md")).read() % {"mode": insample.MODE["post_P"]}
    wires = [x for u in units for x in (u, u[:10], u[:7])] + list(ctx["honey"])
    res = propose.edit(ctx, out, rk, prompt, o.get("parent"), ctx["c_split_tree"], ev, ctx["floor"][sp["c_split"]][2], wires)
    res["evidence_files"] = [sorted(e) for e in ev]
    propose.write_status(out, res)
    print("  proposer: %s after %d attempt(s)" % (res["status"], res["attempts"]), flush=True)
    return res


def _seal(ctx, o, sp, cand, dropped):
    """Freeze every val unit's criteria and the calibration relied on, then seal the prereg as ledger
    row 0 — before ANY spend of this campaign (a `loop run` candidate does not exist yet: None)."""
    missing = [u for u in sp["val"] if not os.path.isfile(os.path.join(ctx["units_dir"], u, "criteria.json"))]
    if missing:
        ctx["ledger"].check({"criteria": (2 * len(missing), o["scorer_per_job_usd"])})
    crit = {u: score.criteria(ctx, u) for u in sp["val"]}
    dropped.update({u: "criteria-failed" for u, c in crit.items() if c is None})
    calib = _calibration(o)
    sha = campaign.seal_prereg(ctx, {k: o.get(k) for k in ("seed", "model", "scorer", "scorer_model", "per_job_usd", "scorer_per_job_usd",
                                                         "k", "veto", "allow_noop", "control_fixture", "origin", "editor_model",
                                                         "editor_per_job_usd")}
                               | {"protocol": "heldout-v1", "rule_sha": decide.rule_sha(), "calibration": calib,
                                  "isolation": "enforced" if o["runner"] == "docker" else "instructed",
                                  "split": {k: sp[k] for k in ("train", "gap", "val")}, "candidate_sha": cand and propose.overlay_sha(cand),
                                  "parent_sha": propose.overlay_sha(o.get("parent")),
                                  "criteria": {u: campaign._sha(os.path.join(ctx["units_dir"], u, "criteria.json")) for u in sp["val"]}})
    return crit, calib, sha


def _measure(ctx, o, sp, cand, dropped, crit):
    """Reserve val, stage (a post gate hit REJECTS), run, score, re-score. Returns (plan, drift) or
    a REJECTED decision dict."""
    if o.get("parent") and not all(campaign.stage_arm(ctx, o, u, "pre", o["parent"])["ok"] for u in sp["val"]):
        raise executor.LoopError(3, "the parent overlay trips a held-out unit's leak gate")
    ctx["quiet_gate"] = True
    gates = [campaign.stage_arm(ctx, o, u, "post", cand) for u in sp["val"]]
    ctx["quiet_gate"] = False
    if any(not g["ok"] and not g["hits"] for g in gates):  # a gate that could not check found no leak: fail loud
        raise executor.LoopError(3, "held-out staging failed without a gate verdict (%s)" % sorted({g["reason"] for g in gates if not g["ok"]}))
    rejected = sum(not g["ok"] for g in gates)
    if rejected:  # the candidate names a held-out answer: no retry, no feedback, nothing reserved or spent
        return {"protocol": "heldout-v1", "verdict": "REJECTED", "reason": "rejected:heldout-token", "count": rejected}
    if ledger_mod.reserve(o["root"], o["project"], o["campaign"], sp["val"]):
        raise executor.LoopError(6, "a val unit is reserved by another campaign")
    plan, _ = campaign.make_plan(ctx, dict(o, arms=["pre", "post"]), [u for u in sp["val"] if u not in dropped], dropped)
    campaign.implement(ctx, o, plan, dropped)
    campaign.score_all(ctx, o, plan, dropped, {u: c for u, c in crit.items() if c})
    return plan, rescore(ctx, o, plan, crit, dropped)


def _loop(ctx, o, sp, dropped):
    """The network part: seal, (the proposer), freeze the candidate as a ledger row, measure."""
    proposer = not o.get("candidate")
    o["origin"] = "proposer" if proposer else "session"  # a handed-in candidate is measurable, never promotable
    cand = None if proposer else _candidate(ctx, o, sp)
    crit, calib, sha = _seal(ctx, o, sp, cand, dropped)
    if proposer:
        res = _propose(ctx, o, sp)
        if res["status"] != "ok":  # fell back or no-op: nothing to measure, no val unit reserved
            return {"protocol": "heldout-v1", "prereg_sha": sha, "verdict": res["status"].upper(), "origin": "proposer",
                    "reasons": res.get("errors") or []}, None
        o["candidate"] = os.path.join(ctx["cdir"], "propose", "overlay")
        cand = _candidate(ctx, o, sp)
        if not ctx["ledger"].done("candidate-" + sha):  # frozen and hashed before any val spend
            ctx["ledger"].append({"kind": "candidate", "runkey": "candidate-" + sha, "status": "frozen", "usd": None,
                                  "candidate_sha": propose.overlay_sha(cand)})
    frozen = (ctx["ledger"].done("candidate-" + sha) or {}).get("candidate_sha") if proposer else \
        campaign._json(os.path.join(ctx["cdir"], "prereg.json"))["candidate_sha"]
    if propose.overlay_sha(cand) != frozen:
        raise executor.LoopError(6, "the frozen candidate's bytes changed since it was sealed")
    o["candidate_sha"] = frozen
    m = _measure(ctx, o, sp, cand, dropped, crit)
    if isinstance(m, dict):
        return dict(m, prereg_sha=sha), None
    return None, (sha, m[0], m[1], calib)


def run(o):
    o.update(arms=["pre"], label="GATE")
    if not o["stub"] and o["k"] != R["k"]:
        raise executor.LoopError(3, "rule %s is sealed with k=%d" % (R["version"], R["k"]))
    ctx = campaign.setup(o)
    if o.get("parent") is None and o.get("overlay_dir") and os.path.isdir(o["overlay_dir"]):
        o["parent"] = o["overlay_dir"]  # the promoted overlay is the parent every later campaign builds on
    ctx["control_fixture"] = o.get("control_fixture")
    if o["tracker"] in REFUSED_TRACKERS:
        raise executor.LoopError(3, "tracker %r cannot order units for a held-out split; use none, gitea or github-pr" % o["tracker"])
    empty = os.path.join(ctx["cdir"], "snapshots", "empty")
    os.makedirs(empty, exist_ok=True)
    base = snapshot.derive_config(o["config"], os.path.join(ctx["cdir"], "base.yaml"), empty, ctx["sandbox_root"], o["build"])
    sp = split.make(ctx, o, o["units"], base)
    if set(sp["val"]) & split.spent(o["root"], o["project"], o["campaign"]):
        raise executor.LoopError(6, "a val unit was scored or reserved by another campaign since this split was made")
    _prepare(ctx, o, sp, base)
    ctx["honey"] = campaign._honey([ctx["cdir"]] + [os.path.join(ctx["units_dir"], u) for u in sp["val"]])
    if o["dry_run"]:
        if o.get("candidate"):
            _candidate(ctx, o, sp)
        _dry_report(ctx, o, sp)
        return 0
    ledger_mod.log_campaign(o["root"], o["project"], {"campaign": o["campaign"], "protocol": "heldout-v1", "status": "running"})
    dropped = {}
    with campaign._network(ctx, o):
        early, m = _loop(ctx, o, sp, dropped)
    return _finish(ctx, o, early, None, None) if early else _decide(ctx, o, sp, m, dropped)


def _decide(ctx, o, sp, m, dropped):
    """Per-unit scores → kept units (a unit with any unscored rollout is dropped, within the allowance) → rule v1."""
    sha, plan, drift, calib = m
    units = {u: {a: [_pct(_score(ctx, p[3])) for p in sorted(plan) if p[0] == u and p[1] == a] for a in ("pre", "post")}
             for u in sp["val"] if u not in dropped}
    used = {u: x for u, x in units.items() if x["pre"] and x["post"] and None not in x["pre"] + x["post"]}
    dropped.update({u: "unscored" for u in units if u not in used})
    label = lambda u: "v%d" % (sp["val"].index(u) + 1)  # noqa: E731
    d = decide.decide([dict(x, u=label(u)) for u, x in used.items()],
                      validity(ctx, o, plan, len(sp["val"]), list(used.values()), dropped, drift, calib),
                      extras(ctx, plan, set(used), [u for u in sp["val"] if u not in dropped] or sp["val"]))
    d.update(protocol="heldout-v1", prereg_sha=sha, rescore={"mean_abs_delta": drift[0], "agreement": drift[1]},
             dropped={label(u): why for u, why in dropped.items()}, stub=o["stub"], origin=o["origin"],
             isolation="enforced" if o["runner"] == "docker" else "instructed", c_split=sp["c_split"],
             candidate_sha=o["candidate_sha"], control_fixture=bool(o.get("control_fixture")))
    return _finish(ctx, o, d, plan, None)


def _finish(ctx, o, d, plan, base):
    path = os.path.join(ctx["cdir"], "decision.json")
    old = campaign._json(path)
    if old and old.get("verdict") != d["verdict"]:  # a resume must never turn one verdict into another
        raise executor.LoopError(6, "this campaign already decided %s; a rerun produced %s" % (old["verdict"], d["verdict"]))
    with open(path, "w") as fh:
        json.dump(d, fh, indent=2, sort_keys=True)
    ledger_mod.log_campaign(o["root"], o["project"], {"campaign": o["campaign"], "protocol": "heldout-v1",
                                                      "prereg_sha": d.get("prereg_sha"), "status": d["verdict"], "stub": o["stub"]})
    print("GATE %s%s%s — %s" % (d["verdict"], (" (%s)" % d["label"]) if d.get("label") else "", " · STUB RUN" if o["stub"] else "",
                               "; ".join(d.get("reasons") or []) or "mean d %s, p %s" % (d.get("mean_d"), d.get("p_signflip"))))
    code = report.write(ctx, o, plan, {}, os.path.join(ctx["cdir"], "base.yaml"), len(plan), calibrate=False) if plan else 0
    return 5 if d["verdict"] == "INVALID" else code
