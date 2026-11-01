# RUN — `ts-app` mechanical two-arm prove (captured)

A committed, inspectable record of a **real mechanical run** of the prove loop on this fixture:
the exact commands, the resulting scoreboard, the **ablation delta** (harness vs baseline), and the
per-unit **cutoff_label** + **decontam_confidence**. Every number below was output by the committed
tools — but the two score inputs are hard-coded stubs, so **no number here measures a model**.

> **What is real vs stubbed.** This is the *mechanical demo path* — no model session. The fixture,
> fork-point, the two history-free sandboxes, the leak gate, the cutoff labeler, the aggregate,
> and the report are all real and run end to end. The **blind LLM implement + adversarial score** is
> the one step stubbed: each arm carries the pipeline's canonical stub score (harness 95, baseline
> 60, n=1 per arm — the same stubs the gate `tests/prove_ablation_test.sh` uses). So the genuinely
> tool-computed, captured outputs are the **aggregation, the ablation-delta arithmetic, the cutoff
> label, the decontam-confidence, and the clean leak-gate pass** — not the two score values. A real
> business-requirement % comes only from `/mahoraga-prove` with a live model. See `README.md` (Quickstart).

## Commands run

From a clean checkout (paths under one `mktemp -d`; the live repo is untouched):

```bash
# 1. build the throwaway git fixture (git only; no gh/npm/network)
bash examples/ts-app/setup-fixture.sh "$FIXPARENT"      # prints root=/repo=/skills=/unit=/fork=

# 2. tracker discovery (github-pr pure-git fallback) + fork-point
source core/lib/adapters.sh ; tracker_fn list_units ; tracker_fn fork_point "$UNIT"

# 3. the fork-point + clean human_ts-app.diff + meta.lines
bash core/lib/prepare_task.sh "$RUN" "$UNIT"

# 4. stage TWO sandboxes at the SAME fork-point + SPEC.md + BUSINESS_REQUIREMENT.md
bash core/lib/stage_sandbox.sh "$RUN" "$UNIT" harness   # PROJECT_CONFIG -> full .claude/skills
bash core/lib/stage_sandbox.sh "$RUN" "$UNIT" baseline  # PROJECT_CONFIG -> EMPTY skills

# 5. stub implementers (stand in for the blind LLM) + canonical stub scores per arm

# 6. per-unit cutoff label (real labeler; ts-app config: repo_visibility=public, no model_cutoff)
python3 core/lib/cutoff_label.py "" public ""           # -> cutoff-unverified

# 7. roll up both arms + render the report
python3 core/lib/aggregate_scores.py "$RUN"             # -> scores.json (arms + ablation_delta)
python3 core/lib/build_report.py "$RUN"                 # -> report.html (ablation panel + chips)
```

The committed CI gate `tests/e2e_ts_app_test.sh` runs the single-arm mechanical loop on this fixture;
`tests/prove_ablation_test.sh` runs the two-arm ablation gate on `py-service`. Fixture commit SHAs
are regenerated on every `setup-fixture.sh` run — the SHAs below are from this capture.

## Unit discovered

| field | value (this run) |
|---|---|
| repo | `ts-app` (language: typescript) |
| unit (last non-merge commit) | `2fb5726` — adds `src/refund.ts` (`computeProratedRefund`) |
| fork-point (parent) | `4b9a7d8` |
| human reference diff | `1 file changed, 20 insertions(+)` (a **reference**, never a match target) |
| harness arm skills staged | **1** (`money-formatting`) · baseline arm: **0** (empty) |
| leak gate | **clean pass** — the staged skill names only pre-existing helpers |

## Scoreboard (harness arm, n=1)

| metric | value |
|---|---|
| units scored (n) | 1 |
| business-requirement achieved (avg) | **95%** |
| reuse ≥ human | **1/1** |
| hallucinations | 0 |
| over-engineering | 0 |
| lost-context | 0 |
| net-new security threats | 0 |
| distribution (business_req) | min 95 / median 95 / max 95 |

## Ablation delta (harness − baseline)

| arm | business_req_avg | reuse ≥ human | lost_context |
|---|:--:|:--:|:--:|
| **harness** (1 project skill, no GUARD pack; stub score) | 95 | 1/1 | 0 |
| **baseline** (empty skills; stub score) | 60 | 0/1 | 1 |
| **Δ (stub arithmetic)** | **+35** | +1 | **−1 defect** |

`aggregate.ablation_delta`: `business_req_avg +35`, `lost_context +1` (baseline − harness, positive =
harness has fewer). Here the Δ is arithmetic on two constants (95 − 60, n=1 per arm): it shows the
two-arm aggregation works and measures nothing — the gate's `Δ > 0` assertion cannot fail on these
inputs. On real model scores for the same fork-point, SPEC and business requirement, this is the number
that would matter.

## Cutoff + decontamination labels (per unit)

| label | value | why |
|---|---|---|
| **cutoff_label** | `cutoff-unverified` | **public** example repo, no `model_cutoff` configured — could be in public pretraining, so it MUST NOT back a headline number. |
| **decontam_confidence** | `auto-only` | the leak gate **auto-derived** the answer symbol `computeProratedRefund` from the human diff (absent at the fork-point → survives fork-subtraction); no manual answer-token curation. |

> **Honesty note.** `ts-app` is a **public** fixture → **cutoff-unverified**: it exercises the loop
> and the labeler, but it can never be a headline result. Its deliberate counterpart is
> `examples/py-service`, *configured* as private to exercise the **cutoff-clean** path (it ships with
> Mahoraga itself as an open-source demo fixture); together the two fixtures exercise both outcomes. A dependable headline comes only from **private / post-cutoff** work.

Report rendered: `report.html` (~22 KB) — carries the Ablation panel, the per-unit `cutoff-unverified`
chip, and the `auto-only` decontam-confidence chip.
