#!/usr/bin/env python3
# aggregate_scores.py <RUN_DIR>
# Collect per-unit <RUN_DIR>/<UNIT>/score*.json into <RUN_DIR>/scores.json with an aggregate block.
# Project-agnostic: unit order = state.json order if present, else sorted dir names. Re-runnable:
# aggregates whatever score files currently exist. Metrics are the agent-weakness metrics under the
# dual spec + business-req probe (see core/schema/SCORE.schema.json). Stdlib only (+ optional PyYAML
# solely to read the project name from $PROJECT_CONFIG for a self-contained report).
#
# TWO-ARM ablation: each unit is scored in a harness arm (score.json, arm:"harness") and a
# baseline arm (score.baseline.json, arm:"baseline", skills stripped to empty). We glob score*.json,
# group by the `arm` field (absent => harness), and add aggregate.arms / ablation_delta /
# distributions / sampling_frame. The pre-existing single-arm summary fields stay, now computed over
# the HARNESS arm (identical to before for a harness-only run).
#
# N-ARM ablation: `arm` is now ANY string (e.g. "mapping+oracle" via score.mapping+oracle.json).
# aggregate.arms includes EVERY distinct arm present; ablation_delta stays harness − baseline exactly
# (compatible with the two-arm shape); a new aggregate.arm_deltas records EACH non-baseline arm's delta vs baseline (when
# a baseline arm exists). Single-arm + two-arm metric blocks are unchanged; the headline's
# provenance clause now comes from the scorer field (below).
#
# Provenance: the headline names WHO produced the scores, read from each score's `scorer` field —
# a stub run is labelled a stub run, and an unrecorded scorer is said to be unknown, never assumed.
#
# Hygiene (score_hygiene.py): business_req_pct is recomputed from business_criteria; a metric with no
# numeric score is None ("not measured"), never 0 — so an unscored arm cannot manufacture a delta;
# a scorer sharing the implementer's (or improver's) model family is flagged.
import os, json, glob, re, sys, statistics

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_hygiene import recompute, families  # noqa: E402

SCORER_CLAUSE = {
    "adversarial-review-loop": ("scored by adversarial review loops (reviewer → red-team → reconciling "
                                "verifier, every finding file:line-grounded)"),
    "stub": "given stub scores",
}

def is_no(v):
    # "none" as a WORD: "Nonexistent method X" / "Nonessential retry layer" are defects, not "none"
    s = str(v).strip().lower()
    return (not s) or bool(re.match(r"none\b", s)) or s in ("n/a", "na", "-", "parity")

def be(v, *prefixes):
    return str(v).lower().startswith(prefixes)

def arm_of(t):
    """The arm label, normalized (absent/empty => 'harness'). N-arm: any string is its own arm."""
    a = str(t.get("arm") or "harness").strip().lower()
    return a or "harness"

def arm_order(names):
    """Deterministic, readable arm order: harness, baseline, then every other arm sorted."""
    pref = [a for a in ("harness", "baseline") if a in names]
    rest = sorted(a for a in names if a not in ("harness", "baseline"))
    return pref + rest

def metrics(tasks):
    """The per-arm metric block (contract shape for aggregate.arms.<arm>); _-keys are internal."""
    be_tasks = [t for t in tasks if "SUCCESS" in str(t.get("compile", "")).upper()
                or "FAIL" in str(t.get("compile", "")).upper()]
    be_ok = [t for t in be_tasks if "SUCCESS" in str(t.get("compile", "")).upper()]
    brs = [t.get("business_req_pct") for t in tasks if isinstance(t.get("business_req_pct"), (int, float))]
    reuse_be = sum(1 for t in tasks if be((t.get("code_quality") or {}).get("reuse", ""), "better", "equal", "par"))
    hall = sum(1 for t in tasks if not is_no(t.get("hallucination")))
    over = sum(1 for t in tasks if not is_no(t.get("overeng")))
    lost = sum(1 for t in tasks if not is_no(t.get("lost_context")))
    sec_new = sum(1 for t in tasks if "net-new" in str((t.get("security") or {}).get("verdict", "")).lower()
                  or "net new" in str((t.get("security") or {}).get("verdict", "")).lower())
    return {"n": len(tasks), "n_scored": len(brs), "business_req_avg": round(sum(brs) / len(brs)) if brs else None,
            "reuse_better_equal": reuse_be, "hallucinations": hall, "overeng": over,
            "lost_context": lost, "security_net_new": sec_new,
            "compile": "{}/{}".format(len(be_ok), len(be_tasks)), "_be_ok": len(be_ok), "_be_n": len(be_tasks)}

def dist(tasks, key):
    vals = [t.get(key) for t in tasks if isinstance(t.get(key), (int, float))]
    if not vals:
        return None
    return {"min": int(min(vals)), "median": int(round(statistics.median(vals))), "max": int(max(vals))}

def read_order(run_dir):
    st = os.path.join(run_dir, "state.json")
    if os.path.isfile(st):
        try:
            order = list((json.load(open(st)).get("tasks") or {}).keys())
            if order:
                return order
        except Exception:
            pass
    return sorted(set(os.path.basename(os.path.dirname(p))
                      for p in glob.glob(os.path.join(run_dir, "*", "score*.json"))))

def read_tasks(run_dir):
    """All score*.json per unit (harness score.json + baseline score.baseline.json), in unit order."""
    tasks = []
    for tid in read_order(run_dir):
        for p in sorted(glob.glob(os.path.join(run_dir, tid, "score*.json"))):
            if os.path.getsize(p) > 0:
                try:
                    tasks.append(recompute(json.load(open(p))))
                except Exception as e:
                    print("WARN bad json", tid, os.path.basename(p), e)
    return tasks

def read_selection(run_dir):
    sel = os.path.join(run_dir, "selection.json")
    if os.path.isfile(sel) and os.path.getsize(sel) > 0:
        try:
            return json.load(open(sel))
        except Exception:
            return None
    return None

def project_name_from_env():
    pc = os.environ.get("PROJECT_CONFIG")
    if pc and os.path.isfile(pc):
        try:
            import yaml
            return str((yaml.safe_load(open(pc)) or {}).get("project", {}).get("name", ""))
        except Exception:
            return ""
    return ""

def compute_arms(groups):
    """aggregate.arms — EVERY present arm (N-arm), metric block per arm, internal _-keys dropped."""
    arms = {}
    for name in arm_order(groups):
        group = groups.get(name) or []
        if group:
            arms[name] = {k: v for k, v in metrics(group).items() if not k.startswith("_")}
    return arms

def sub(x, y):
    """x − y, or None when either side was not measured (None is never a zero)."""
    return None if x is None or y is None else x - y

def shown(v, unit=""):
    return "not measured" if v is None else "%s%s" % (v, unit)

def compute_ablation(arms):
    """aggregate.ablation_delta — the canonical harness − baseline delta; only when BOTH arms have
    scores; else None. Unchanged (prove_ablation_test depends on this exact shape)."""
    if "harness" not in arms or "baseline" not in arms:
        return None
    h, b = arms["harness"], arms["baseline"]
    return {
        "business_req_avg": sub(h["business_req_avg"], b["business_req_avg"]),
        "lost_context": b["lost_context"] - h["lost_context"],
        "hallucinations": b["hallucinations"] - h["hallucinations"],
        "overeng": b["overeng"] - h["overeng"],
        "note": ("harness − baseline for business-req (positive = harness better); baseline − harness "
                 "for defect counts (positive = harness has fewer) — attributes the difference to the "
                 "harness arm's staged skills vs the baseline arm's empty skill set on the same "
                 "fork-point, SPEC and business requirement (per-arm means; unpaired)."),
    }

def compute_arm_deltas(arms):
    """aggregate.arm_deltas — EACH non-baseline arm vs baseline (else None). Same signs as
    ablation_delta: +business_req = arm did better; +defect counts = arm has fewer than baseline."""
    if "baseline" not in arms:
        return None
    b = arms["baseline"]
    out = {}
    for name in arm_order(arms):
        if name == "baseline":
            continue
        a = arms[name]
        out[name] = {
            "business_req_avg": sub(a["business_req_avg"], b["business_req_avg"]),
            "lost_context": b["lost_context"] - a["lost_context"],
            "hallucinations": b["hallucinations"] - a["hallucinations"],
            "overeng": b["overeng"] - a["overeng"],
        }
    return out or None

def compute_distributions(harness):
    """aggregate.distributions over the HARNESS arm (min/median/max, not just the mean)."""
    out = {}
    for label, key in (("business_req", "business_req_pct"), ("spec_fidelity", "spec_fidelity")):
        d = dist(harness, key)
        if d:
            out[label] = d
    return out

def provenance(scored):
    """(prefix, clause) for the headline, from every scored unit's `scorer` (all arms count)."""
    counts = {}
    for t in scored:
        s = str(t.get("scorer") or "").strip() or "unrecorded"
        counts[s] = counts.get(s, 0) + 1
    if not counts:
        return "", "with no scored units"
    stubs = sum(c for s, c in counts.items() if s.lower() == "stub")
    total = sum(counts.values())
    prefix = (f"STUB RUN — {stubs}/{total} scores are fixture constants, not a measurement. "
              if stubs else "")
    if len(counts) != 1:
        return prefix, "scored by a mix of scorers (" + ", ".join(
            f"{s} ×{c}" for s, c in sorted(counts.items())) + ")"
    (s,) = counts
    if s == "unrecorded":
        return prefix, "scored by an unrecorded scorer (provenance unknown)"
    return prefix, SCORER_CLAUSE.get(s.lower(), f"scored by '{s}'")

def build_summary(harness, scored):
    """The pre-existing single-arm summary block, computed over the HARNESS arm (back-compat)."""
    hm = metrics(harness)
    n, be_ok, be_n = hm["n"], hm["_be_ok"], hm["_be_n"]
    br_avg, reuse_be = hm["business_req_avg"], hm["reuse_better_equal"]
    hall, over, lost, sec_new = hm["hallucinations"], hm["overeng"], hm["lost_context"], hm["security_net_new"]
    cq_be = sum(1 for t in harness if be((t.get("code_quality") or {}).get("overall", ""), "better", "equal", "par"))
    sfs = [t.get("spec_fidelity") for t in harness if isinstance(t.get("spec_fidelity"), (int, float))]
    prefix, clause = provenance(scored)
    fam = families(scored)
    if fam["same_family"]:
        prefix += ("SAME-FAMILY SCORING — the scorer shares a model family with the implementer or "
                   "improver (%s): self-preference risk. " % ", ".join(fam["scorer"]))
    return n, {
        "headline": (f"{prefix}{n} shipped units re-implemented blind from spec + business requirement, then "
                     f"{clause}. {be_ok}/{be_n} backends compile; avg business-requirement "
                     f"achieved {shown(br_avg, '%')}; reuse ≥ human on {reuse_be}/{n}; {hall} hallucinations, {over} "
                     f"over-engineering, {lost} lost-context, {sec_new} net-new security threats vs the human baseline."),
        "n_tasks": n,
        "compile_backend": f"{be_ok}/{be_n}",
        "business_req_avg": br_avg,
        "spec_fidelity_avg": round(sum(sfs) / len(sfs)) if sfs else None,
        "families": fam,
        "business_req_sources": {k: sum(1 for t in scored if t.get("business_req_source") == k)
                                 for k in ("criteria", "grader", "invalid-criteria", "missing")},
        "business_req_overridden": sum(1 for t in scored if "business_req_pct_reported" in t),
        "reuse_better_equal": f"{reuse_be}/{n}",
        "code_quality_better_equal": f"{cq_be}/{n}",
        "hallucinations": hall, "overeng": over, "lost_context": lost, "security_net_new": sec_new,
        "scoreboard_note": (f"Business-requirement-achieved % is scored against the original business ask "
                            f"(decomposed into weighted, code-grounded acceptance criteria). Code quality is graded "
                            f"vs the shipped human branch as a REFERENCE (better/equal/worse), never as a match target. "
                            f"Security asks only whether the AI introduced a net-new reachable threat the human did not. "
                            f"Across {n} scored units: {hall} hallucinations, {over} over-engineering, {lost} "
                            f"lost-context, {sec_new} net-new security threats."),
    }

def main(argv):
    if not argv:
        sys.exit("usage: aggregate_scores.py <RUN_DIR>")
    run_dir = os.path.abspath(argv[0])

    tasks = read_tasks(run_dir)
    scored = [t for t in tasks if not t.get("documented_only")]
    groups = {}
    for t in scored:
        groups.setdefault(arm_of(t), []).append(t)
    harness = groups.get("harness", [])

    arms = compute_arms(groups)
    ablation_delta = compute_ablation(arms)
    arm_deltas = compute_arm_deltas(arms)
    distributions = compute_distributions(harness)

    n, agg = build_summary(harness, scored)
    agg["project_name"] = project_name_from_env()
    agg["arms"] = arms
    agg["sampling_frame"] = read_selection(run_dir)
    if ablation_delta is not None:
        agg["ablation_delta"] = ablation_delta
    if arm_deltas:
        agg["arm_deltas"] = arm_deltas
    if distributions:
        agg["distributions"] = distributions
    # project_name first for readability of the emitted file
    agg = {"project_name": agg.pop("project_name"), **agg}

    dst = os.path.join(run_dir, "scores.json")
    json.dump({"aggregate": agg, "tasks": tasks}, open(dst, "w"), indent=2)
    print(f"aggregated {n} scored harness unit(s) ({len(tasks)} score file(s) total) -> {dst}")
    print(f"  compile {agg['compile_backend']} | br_avg {shown(agg['business_req_avg'])} | "
          f"specfid {shown(agg['spec_fidelity_avg'])} | reuse>=human {agg['reuse_better_equal']} | "
          f"hall {agg['hallucinations']} over {agg['overeng']} lost {agg['lost_context']} "
          f"sec_new {agg['security_net_new']}")
    for t in scored:
        if "business_req_pct_reported" in t:
            print(f"  WARN {t.get('id')}: grader business_req_pct {t['business_req_pct_reported']} != "
                  f"{t['business_req_pct']} recomputed from business_criteria (the recomputed value is used)")
        elif t.get("business_req_source") == "invalid-criteria":
            print(f"  WARN {t.get('id')}: business_criteria invalid (status/weight) — business_req_pct not measured")
    for a, m in arms.items():
        if m["n_scored"] < m["n"]:
            print(f"  WARN arm {a}: {m['n'] - m['n_scored']} of {m['n']} unit(s) have no business_req_pct (not measured)")
    if len(arms) > 1:
        print(f"  arms ({len(arms)}): " + ", ".join(f"{a} n={arms[a]['n']}" for a in arm_order(arms)))
    if ablation_delta is not None:
        d = ablation_delta['business_req_avg']
        print(f"  ablation Δ business_req_avg {shown(d) if d is None else format(d, '+d')} "
              f"(harness n={arms['harness']['n']} vs baseline n={arms['baseline']['n']})")
    if arm_deltas:
        for a, d in arm_deltas.items():
            dv = d['business_req_avg']
            print(f"  arm_delta[{a}] Δ business_req_avg {shown(dv) if dv is None else format(dv, '+d')} "
                  f"lost_context {d['lost_context']:+d}")

if __name__ == "__main__":
    main(sys.argv[1:])
