"""stats.py — the kill test's quantities and rules as pure functions (docs/LOOP.md).

Every input is a per-rollout score or None (not measured). A mean over anything containing None is
None, and a rule whose inputs include None returns INVALID: a missing score is never a 0.

  G       = mean_u |m(pre 1-3) - m(pre 4-6)|        the noise of one unit's k=3 mean, measured
  Δ_U     = mean_u (m(post_U) - m(pre 4-6))         a fell-back candidate contributes 0
  Δ_P     = the same over u2..u4 for post_P
  Rule A  Δ_U >= 10 and Δ_U > G                     else: an underpowered no-go, never "no effect"
  Rule B  Δ_P > max(G, 0) and post_P > pre 4-6 on >= 2 of 3 units
"""
import itertools
import statistics


def mean(xs):
    xs = list(xs)
    return None if not xs or any(x is None for x in xs) else statistics.mean(xs)


def gap(units):
    """G over units: [{pre: [k=6 scores]}]."""
    diffs = [None if mean(u["pre"][:3]) is None or mean(u["pre"][3:6]) is None
             else abs(mean(u["pre"][:3]) - mean(u["pre"][3:6])) for u in units]
    return mean(diffs)


def deltas(units, arm):
    """Per-unit m(post) - m(pre 4-6); 0 for a candidate that fell back or was a no-op."""
    out = []
    for u in units:
        if u.get(arm + "_status") != "ok":
            out.append(0.0)
        else:
            post, base = mean(u.get(arm) or []), mean(u["pre"][3:6])
            out.append(None if post is None or base is None else post - base)
    return out


def rule_a(units, min_delta=10):
    G, ds = gap(units), deltas(units, "post_U")
    d = mean(ds)
    if G is None or d is None:
        return {"rule": "A", "verdict": "INVALID", "G": G, "delta": d, "per_unit": ds}
    ok = d >= min_delta and d > G
    return {"rule": "A", "verdict": "PASS" if ok else "underpowered-no-go", "G": G, "delta": d, "per_unit": ds}


def rule_b(units, min_wins=2):
    later = units[1:]
    G, ds = gap(units), deltas(later, "post_P")
    d = mean(ds)
    if G is None or d is None:
        return {"rule": "B", "verdict": "INVALID", "G": G, "delta": d, "per_unit": ds}
    wins = sum(x > 0 for x in ds)
    ok = d > max(G, 0) and wins >= min_wins
    return {"rule": "B", "verdict": "PASS" if ok else "underpowered-no-go", "G": G, "delta": d, "wins": wins, "per_unit": ds}


def signflip_p(ds):
    """Exact one-sided sign-flip p: the share of the 2^n sign patterns whose sum is >= the observed one."""
    if not ds or any(d is None for d in ds) or len(ds) > 20:
        return None
    obs, mags = sum(ds), [abs(d) for d in ds]
    hits = sum(1 for signs in itertools.product((1, -1), repeat=len(ds))
               if sum(s * m for s, m in zip(signs, mags)) >= obs - 1e-9)
    return hits / 2 ** len(ds)


def keep_v1(ds, delta_min=5, alpha=0.05):
    """The effect clauses of rule v1 (clauses 1–4 in docs/LOOP.md); validity and compile/defect clauses are
    the caller's. None anywhere is not a KEEP."""
    if not ds or any(d is None for d in ds) or mean(ds) < delta_min:
        return False
    p = signflip_p(ds)
    return p is not None and p <= alpha and min(ds) > -20 and sum(d < -1 for d in ds) <= sum(d > 1 for d in ds)
