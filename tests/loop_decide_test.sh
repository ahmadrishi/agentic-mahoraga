#!/usr/bin/env bash
# tests/loop_decide_test.sh — the rule (v2; v1 kept) is a sealed, pure function.
#
#   * docs/LOOP.md records exactly the code's rule and its sha256 (the rule cannot change silently)
#   * truth table: every clause flips KEEP to REVERT and is named; every validity fact flips it to
#     INVALID; a None score is INVALID, never 0; REVERT is labelled regression or no-resolved-effect
#   * p = 1/1024 for ten positive units; the power model keeps a null at most 6% of the time
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$ROOT" "${PYTHON:-python3}" - <<'PY' || { echo "LOOP-DECIDE FAIL" >&2; exit 1; }
import json, os, re, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import decide
doc = open(os.path.join(os.environ["ROOT"], "docs", "LOOP.md")).read()
assert decide.rule_sha() in doc, "docs/LOOP.md does not record the code's rule sha"
assert json.loads(re.search(r"```json\n(.*?)\n```", doc, re.S).group(1)) == decide.RULE, "docs/LOOP.md's rule JSON differs from decide.RULE"
assert decide.rule_sha(decide.RULE_V1) in doc, "docs/LOOP.md lost the superseded rule v1's sha"
print("  ok: docs/LOOP.md records the current rule and its sha256 exactly as the code has them (and v1's sha)")

g = lambda pct, *st: {"business_req_pct": pct, "business_criteria": [{"status": s} for s in st]}
pairs = [(g(100, "full", "full"), g(75, "partial", "full")), (g(50, "none", "full"), g(50, "none", "full"))]
assert decide.agreement(pairs, decide.RULE_V1) == (12.5, 0.75), decide.agreement(pairs, decide.RULE_V1)
assert decide.agreement(pairs) == (12.5, 0.875), decide.agreement(pairs)
assert decide.agreement([(g(100, "full"), g(0, "none"))]) == (100, 0.0)
print("  ok: scorer agreement — v1 counts full<->partial as a miss (0.75), v2 as half (0.875); none<->full is 0 in both")
import score_hygiene
assert score_hygiene.STATUS_SCORE == {"full": 1.0, "partial": 0.5, "none": 0.0}, \
    "rule v2's agreement weights are the score's own: changing them changes sealed v2"
h = lambda *st: {"business_req_pct": 50, "business_criteria": [{"status": s} for s in st]}
assert decide.agreement([(h("Partial", " full"), h("partial", "FULL"))]) == (0, 1.0)
assert decide.agreement([(h(None, "n/a"), h("none", "n/a"))]) == (0, 0.0)
assert score_hygiene.recompute({"business_criteria": [{"status": None, "weight": 1}]})["business_req_pct"] is None
print("  ok: v2's weights are pinned; statuses normalised as the score does; a missing status is never a silent 0")

units = [{"u": "v%d" % i, "pre": [60, 60, 60], "post": [70, 70, 70]} for i in range(10)]
valid = {k: True for k in ("executed_equals_planned", "init_assertions_passed", "isolation_enforced", "scorer_family_differs",
                           "calibration_exists", "units_dropped_ok", "scorer_consistent", "one_org_sha_per_phase", "egress_within_allowlist")}
ex = lambda **kw: dict({"compile": {"pre": 30, "post": 30}, "defects": {"pre": 2, "post": 2}, "always_on_delta": 2400,
                        "usd": {"pre": 0.18, "post": 0.19}}, **kw)
d = decide.decide(units, valid, ex())
assert d["verdict"] == "KEEP" and d["p_signflip"] == 1 / 1024 and d["mean_d"] == 10, d
print("  ok: +10 on all ten units -> KEEP, p = 1/1024")
flips = {"1_mean_d": (lambda u: [dict(x, post=[63, 63, 63]) for x in u], {}),
         # four at +30, six at ±2: mean 11.6 and balance 6:4 hold, but p = 57/1024 ≈ 0.056
         "2_signflip_p": (lambda u: [dict(x, post=[60 + dd] * 3) for x, dd in zip(u, [30, 30, 30, 30, -2, -2, -2, 2, 2, -2])], {}),
         "3_min_d": (lambda u: [dict(x, post=[35] * 3) if i == 0 else dict(x, post=[90] * 3) for i, x in enumerate(u)], {}),
         "4_balance": (lambda u: [dict(x, post=[100] * 3 if i < 4 else [55] * 3) for i, x in enumerate(u)], {}),
         "5_compile": (lambda u: u, {"compile": {"pre": 30, "post": 29}}),
         "5_defects": (lambda u: u, {"defects": {"pre": 2, "post": 3}}),
         "6_always_on": (lambda u: u, {"always_on_delta": 8193}),
         "6_cost": (lambda u: u, {"usd": {"pre": 0.18, "post": 0.21}})}
for clause, (f, extra) in flips.items():
    d = decide.decide(f(units), valid, ex(**extra))
    assert d["verdict"] == "REVERT" and clause in d["reasons"], (clause, d["verdict"], d.get("reasons"))
print("  ok: each of clauses 1-6 (8 checks) alone turns KEEP into REVERT and is named")
for fact in valid:
    d = decide.decide(units, dict(valid, **{fact: False}), ex())
    assert d["verdict"] == "INVALID" and d["reasons"] == [fact], (fact, d)
assert decide.decide([dict(units[0], post=[70, None, 70])] + units[1:], valid, ex())["verdict"] == "INVALID"
assert decide.decide(units, valid, ex(usd={"pre": None, "post": 0.2}))["clauses"]["6_cost"] is False
print("  ok: each validity fact alone -> INVALID; a None score -> INVALID; an unpriced arm fails the cost clause")
assert decide.decide([dict(x, post=[50] * 3) for x in units], valid, ex())["label"] == "regression"
assert decide.decide([dict(x, post=[62] * 3) for x in units], valid, ex())["label"] == "no-resolved-effect"
print("  ok: REVERT labelled regression (mean d <= -5) or no-resolved-effect")
pw = decide.power(16.0, sims=400)
assert pw[0] <= 0.06 and pw[0] < pw[5] < pw[10] < pw[15], pw
print("  ok: power model at σ 16: %s (null <= 0.06, increasing)" % pw)
PY
echo
echo "LOOP-DECIDE PASS"
