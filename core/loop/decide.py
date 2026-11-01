"""decide.py — the sealed rule (v2; v1 kept) as a pure function (docs/LOOP.md; clause 6 was amended after the kill test).

The rule is sealed: RULE's sha256 (rule_sha) is recorded in docs/LOOP.md and in every held-out
campaign's prereg, and a test fails if the two disagree. Inputs are per-unit k-run scores (None =
not measured) plus the validity facts the caller measured; the output is KEEP, REVERT (labelled
no-resolved-effect or regression) or INVALID, with every reason.

  0  validity (else INVALID): every fact in `validity` true (v2: the double-scoring agreement is
     weighted like the score — full 1, partial 0.5, none 0)
  1  mean d >= delta_min                   2  exact one-sided sign-flip p <= alpha
  3  min d > min_d                         4  #(d < -1) <= #(d > 1)
  5  compile successes post >= pre; hallucination + lost_context post <= pre
  6  always-on growth <= always_on_max_bytes; post $/rollout <= cost_ratio_max x pre
"""
import hashlib
import json
import os
import random
import sys

import stats

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from score_hygiene import status_weight  # noqa: E402

RULE_V1 = {"version": "v1", "delta_min": 5, "alpha": 0.05, "min_d": -20, "n_min": 8, "drop_max_frac": 0.1,
           "always_on_max_bytes": 8192, "cost_ratio_max": 1.15, "k": 3,
           "double_frac": 0.2, "rescore_max_abs_delta": 10, "rescore_min_agreement": 0.8}
# v2 (sealed 2026-10-23, after v1's A/A came out INVALID-SCORER): scorer agreement is WEIGHTED the way
# the score itself is (full 1, partial 0.5, none 0), so a full<->partial flip is a half disagreement.
# Every other value is v1's. v1 stays recorded in docs/LOOP.md with its result.
RULE = dict(RULE_V1, version="v2", rescore_agreement="weighted")


def rule_sha(rule=RULE):
    return hashlib.sha256(json.dumps(rule, sort_keys=True).encode()).hexdigest()


def agreement(pairs, rule=RULE):
    """(mean |Δpct|, per-criterion agreement) of double-scored gradings [(s1, s2)]: exact status
    match in v1, weighted like the score in v2 (full<->partial agrees 0.5); statuses are normalised as
    the score normalises them, and one that is not a status is a disagreement."""
    weighted, per = rule.get("rescore_agreement") == "weighted", []
    for s1, s2 in pairs:
        for a, b in zip(s1["business_criteria"], s2["business_criteria"]):
            wa, wb = status_weight(a), status_weight(b)
            per.append(0.0 if None in (wa, wb) else 1 - abs(wa - wb) if weighted else float(wa == wb))
    return stats.mean([abs(s1["business_req_pct"] - s2["business_req_pct"]) for s1, s2 in pairs]), stats.mean(per)


def decide(units, validity, extras, rule=RULE):
    """units: [{u, pre: [k], post: [k]}]; validity: {fact: bool}; extras: {compile: {pre, post},
    defects: {pre, post}, always_on_delta: bytes, usd: {pre, post}} (per-rollout means)."""
    failed = sorted(k for k, ok in validity.items() if not ok)
    ds = [None if stats.mean(u["pre"]) is None or stats.mean(u["post"]) is None else stats.mean(u["post"]) - stats.mean(u["pre"])
          for u in units]
    out = {"rule": rule["version"], "rule_sha": rule_sha(rule), "per_unit": [dict(u, d=d) for u, d in zip(units, ds)],
           "n_used": len(units), "validity": validity}
    if failed or any(d is None for d in ds) or not ds:
        return dict(out, verdict="INVALID", reasons=failed or ["a unit's mean is not measured"])
    mean_d, p = stats.mean(ds), stats.signflip_p(ds)
    clauses = _clauses(ds, mean_d, p, extras, rule)
    out.update(mean_d=mean_d, p_signflip=p, min_d=min(ds), wtl=[sum(d > 1 for d in ds), sum(abs(d) <= 1 for d in ds),
               sum(d < -1 for d in ds)], clauses=clauses, extras=extras)
    if all(clauses.values()):
        return dict(out, verdict="KEEP", reasons=[])
    label = "regression" if mean_d <= -rule["delta_min"] or min(ds) <= rule["min_d"] else "no-resolved-effect"
    return dict(out, verdict="REVERT", label=label, reasons=sorted(k for k, ok in clauses.items() if not ok))


def _clauses(ds, mean_d, p, extras, rule):
    usd = extras.get("usd") or {}
    cost_ok = None not in (usd.get("pre"), usd.get("post")) and usd["post"] <= rule["cost_ratio_max"] * usd["pre"]
    return {"1_mean_d": mean_d >= rule["delta_min"], "2_signflip_p": p is not None and p <= rule["alpha"],
            "3_min_d": min(ds) > rule["min_d"], "4_balance": sum(d < -1 for d in ds) <= sum(d > 1 for d in ds),
            "5_compile": extras["compile"]["post"] >= extras["compile"]["pre"],
            "5_defects": extras["defects"]["post"] <= extras["defects"]["pre"],
            "6_always_on": extras["always_on_delta"] <= rule["always_on_max_bytes"], "6_cost": cost_ok}


def power(sigma_w, n=10, k=3, deltas=(0, 5, 10, 15, 20), sims=2000, seed=7, unit_sd=5.0, rule=RULE):
    """P(KEEP) under the effect clauses (1–4) — a model, not data: Gaussian per-rollout noise
    sigma_w, a per-unit treatment effect ~ N(delta, unit_sd), scores clipped to [0, 100]."""
    rng, out = random.Random(seed), {}
    clip = lambda x: min(100.0, max(0.0, x))  # noqa: E731
    for delta in deltas:
        keeps = 0
        for _ in range(sims):
            ds = []
            for _u in range(n):
                base, eff = rng.uniform(40, 80), rng.gauss(delta, unit_sd)
                pre = [clip(rng.gauss(base, sigma_w)) for _ in range(k)]
                post = [clip(rng.gauss(base + eff, sigma_w)) for _ in range(k)]
                ds.append(sum(post) / k - sum(pre) / k)
            keeps += stats.keep_v1(ds, rule["delta_min"], rule["alpha"])
        out[delta] = round(keeps / sims, 3)
    return out
