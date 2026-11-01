#!/usr/bin/env bash
# tests/loop_stats_test.sh — the kill test's statistics are pure, None-aware functions.
#
#   * the exact one-sided sign-flip p equals an independent brute force, and is 1/1024 for ten positives
#   * None anywhere -> no p, no KEEP, and Rules A/B return INVALID (a missing score is never a 0)
#   * Rule A / Rule B truth table, including a fell-back candidate counting as Δ = 0
#   * rule v1's effect clauses keep a true null at most 6% of the time (10k seeded nulls)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$ROOT" "${PYTHON:-python3}" - <<'PY' || { echo "LOOP-STATS FAIL" >&2; exit 1; }
import os, random, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "core", "loop"))
import stats

def brute(ds):
    n, obs, hits = len(ds), sum(ds), 0
    for mask in range(2 ** n):
        if sum(abs(d) * (-1 if mask >> i & 1 else 1) for i, d in enumerate(ds)) >= obs - 1e-9:
            hits += 1
    return hits / 2 ** n
rng = random.Random(7)
for _ in range(300):
    ds = [round(rng.gauss(2, 10), 1) for _ in range(rng.randint(1, 11))]
    assert abs(stats.signflip_p(ds) - brute(ds)) < 1e-12, ds
assert stats.signflip_p([float(i) for i in range(1, 11)]) == 1 / 1024
print("  ok: exact sign-flip p = brute force over 300 random cases; ten positives -> 1/1024")

assert stats.signflip_p([1.0, None]) is None and not stats.keep_v1([10.0, None, 10.0]) and stats.mean([1, None]) is None
u = lambda pre, pu=None, pp=None, su="ok", sp="ok": {"pre": pre, "post_U": pu or [], "post_U_status": su, "post_P": pp or [], "post_P_status": sp}
assert stats.rule_a([u([80] * 5 + [None], [92] * 3)] * 4)["verdict"] == "INVALID"
assert stats.rule_b([u([80] * 6, [92] * 3, [None, 90, 90])] * 4)["verdict"] == "INVALID"
print("  ok: None anywhere -> no p, no KEEP, Rules A/B INVALID")

A = lambda units: stats.rule_a(units)["verdict"]
assert A([u([80] * 6, [92] * 3)] * 4) == "PASS"                                   # Δ 12 >= 10, G 0
assert A([u([80] * 6, [89] * 3)] * 4) == "underpowered-no-go"                     # Δ 9 < 10
assert A([u([60] * 3 + [80] * 3, [92] * 3)] * 4) == "underpowered-no-go"          # Δ 12 but G 20
assert A([u([80] * 6, [100] * 3)] * 2 + [u([80] * 6, su="fell_back")] * 2) == "PASS"        # (20+20+0+0)/4 = 10
assert A([u([80] * 6, [100] * 3)] + [u([80] * 6, su="fell_back")] * 3) == "underpowered-no-go"  # 5
B = lambda units: stats.rule_b(units)["verdict"]
first = u([80] * 6, [80] * 3, sp=None)
assert B([first] + [u([80] * 6, [80] * 3, [85] * 3)] * 3) == "PASS"               # Δ_P 5 > G 0, 3 wins
assert B([first, u([80] * 6, pp=[95] * 3), u([80] * 6, pp=[78] * 3), u([80] * 6, pp=[78] * 3)]) == "underpowered-no-go"  # 1 win
assert B([first] + [u([70] * 3 + [80] * 3, pp=[85] * 3)] * 3) == "underpowered-no-go"      # Δ_P 5 < G 10
print("  ok: Rule A and Rule B truth table (incl. fell-back = Δ 0 and the G bound)")

rng, keeps, sims = random.Random(20261023), 0, 10000
for _ in range(sims):
    keeps += stats.keep_v1([rng.gauss(0, 10) for _ in range(10)])
assert keeps / sims <= 0.06, keeps / sims
print("  ok: false-KEEP %.4f <= 0.06 over %d seeded nulls (n=10, σ=10)" % (keeps / sims, sims))
PY
echo
echo "LOOP-STATS PASS"
