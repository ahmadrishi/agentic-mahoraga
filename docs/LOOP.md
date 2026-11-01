# The closed improve loop: the sealed rule

`mahoraga loop gate` keeps an overlay edit only when it measurably helps on **held-out** units:
tickets the edit was never derived from. This page holds the decision rule that judges it. The rule
is sealed: its sha256 is recorded here and in every held-out campaign's `prereg.json` (ledger row 0),
and `tests/loop_decide_test.sh` fails if the code's rule and this record disagree. Changing the rule
means a new version, a new sha and a new entry below. A rule is never edited after a held-out
score exists.

How the loop runs, and what it needs, is in [`core/loop/README.md`](../core/loop/README.md).

## Rule v2 (current, sealed 2026-10-23)

**sha256 (of the JSON below, keys sorted):** `e3fb8566054803776a44fb1f95d579ee9c10ca20a7870e25e10f7c5b9fb2a6c5`

```json
{"alpha": 0.05, "always_on_max_bytes": 8192, "cost_ratio_max": 1.15, "delta_min": 5, "double_frac": 0.2, "drop_max_frac": 0.1, "k": 3, "min_d": -20, "n_min": 8, "rescore_agreement": "weighted", "rescore_max_abs_delta": 10, "rescore_min_agreement": 0.8, "version": "v2"}
```

Every threshold the gate uses is in this JSON. The one value outside it is v2's agreement weights,
which are by definition the score's own (`core/lib/score_hygiene.py` `STATUS_SCORE`: full 1, partial
0.5, none 0); `tests/loop_decide_test.sh` pins them, so they cannot change silently either. v2 is v1
with one change: the double-scoring **agreement is weighted the way the score is**, so two gradings
that differ by full↔partial on a criterion agree 0.5 on it, not 0. Every number is v1's.

**Why.** v1 counted a full↔partial disagreement as a full miss, although the score counts it as half. On a
re-scored A/A run every disagreement sat on the `partial` boundary, so v1 declared the run INVALID on
`scorer_consistent` for a difference the score itself treats as small. v2 was chosen after seeing that result, so
it is a post-hoc change. What keeps it honest: it is sealed before any campaign uses it, the 10-point drift limit
is unchanged, v1 and its sha stay on this page, and v2 runs on fresh held-out units.

## Rule v1 (superseded 2026-10-23)

**sha256:** `ab5b64a840ad4378c496bf2148b667a517558884a5ba6a212ede4e2b1e08d7de`

```
{"alpha": 0.05, "always_on_max_bytes": 8192, "cost_ratio_max": 1.15, "delta_min": 5, "double_frac": 0.2, "drop_max_frac": 0.1, "k": 3, "min_d": -20, "n_min": 8, "rescore_max_abs_delta": 10, "rescore_min_agreement": 0.8, "version": "v1"}
```

Agreement was exact status match. Resealed once before any held-out score, when review found the
double-scoring thresholds and the drop allowance outside the seal.

## The clauses (both versions)

Per held-out unit, `d = mean(post) − mean(pre)` over k = 3 runs each. `pre` is the parent overlay and
`post` is parent + candidate, run interleaved and graded blind.

| # | Clause |
|---|---|
| 0 | **Validity**, otherwise INVALID (exit 5; the held-out units stay spent). All of: every planned job of every kept unit has a terminal row; every rollout's init assertions passed; isolation enforced; the scorer's family differs from the implementer's and editor's; a calibration, recorded in the prereg, exists for the identity (model, binary sha, scorer model); every kept unit has exactly k scores per arm; at most max(1, ⌊drop_max_frac·n⌋) units dropped and n_used ≥ n_min; the double-scored `double_frac` of model-graded rollouts agree (mean \|Δpct\| ≤ `rescore_max_abs_delta`, per-criterion agreement ≥ `rescore_min_agreement`, weighted in v2); one org-settings hash across the measurement; egress within the allowlist in every session of the campaign. |
| 1 | mean d ≥ 5 points |
| 2 | exact one-sided sign-flip p ≤ 0.05 (all 2ⁿ patterns; the minimum p at n = 10 is 1/1024) |
| 3 | min d > −20 |
| 4 | #(d < −1) ≤ #(d > 1) |
| 5 | compile successes post ≥ pre; hallucination + lost-context defects post ≤ pre |
| 6 | always-on growth ≤ 8 KB, **and** post $/rollout ≤ 1.15 × pre (amended after the kill test: an initial 512 B limit forbade every overlay the test produced) |

**Verdicts.** KEEP if every clause holds. Otherwise REVERT, labelled `regression` (mean d ≤ −5 or
min d ≤ −20) or `no-resolved-effect`. A candidate that trips any held-out unit's leak gate is
REJECTED before anything runs: no retry, no feedback and no held-out spend.

**Power** (a model, not data: Gaussian per-rollout noise σ_w, per-unit treatment SD 5, n = 10, k = 3,
clauses 1–4). It is printed by `loop gate --dry-run` at the calibrated σ before any held-out score.

| σ_w | P(KEEP) at true Δ = 0 | +5 | +10 | +15 | +20 |
|---|---|---|---|---|---|
| 16 (measured in the kill test) | .045 | .27 | .62 | .89 | .97 |

Expect most campaigns to REVERT. A REVERT is "no resolved effect at this power", never "no effect".
