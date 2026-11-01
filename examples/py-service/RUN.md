# RUN — `py-service` mechanical two-arm prove (captured)

A committed, inspectable record of a **real mechanical run** of the prove loop on this fixture:
the exact commands, the resulting scoreboard, the **ablation delta** (harness vs baseline), and the
per-unit **cutoff_label** + **decontam_confidence**. Every number below was output by the committed
tools — this run is exactly what the gate `tests/prove_ablation_test.sh` exercises — but the two
score inputs are hard-coded stubs, so **no number here measures a model**.

> **What is real vs stubbed.** This is the *mechanical demo path* — no model session. The fixture,
> fork-point, the two history-free sandboxes, the leak gate, the cutoff labeler, the aggregate,
> and the report are all real and run end to end. The **blind LLM implement + adversarial score** is
> the one step stubbed: each arm carries the pipeline's canonical stub score (harness 95, baseline
> 60, n=1 per arm). So the genuinely tool-computed, captured outputs are the **aggregation, the ablation-delta
> arithmetic, the cutoff label, the decontam-confidence, and the (identifier-level) leak-gate pass — see the leak-gate row** — not the two
> score values. A real business-requirement % comes only from `/mahoraga-prove` with a live model.

## Commands run

Reproduce this exact two-arm run with the committed gate:

```bash
bash tests/prove_ablation_test.sh          # PROVE-ABLATION PASS
```

Which runs, from a clean checkout (paths under one `mktemp -d`; the live repo is untouched):

```bash
# 1. build the throwaway git fixture (git only; no gh/pip/network)
bash examples/py-service/setup-fixture.sh "$FIXPARENT"   # prints root=/repo=/skills=/unit=/fork=

# 2. tracker discovery (github-pr pure-git fallback) + fork-point
source core/lib/adapters.sh ; tracker_fn list_units ; tracker_fn fork_point "$UNIT"

# 3. the fork-point + clean human_py-service.diff + meta.lines
bash core/lib/prepare_task.sh "$RUN" "$UNIT"

# 4. stage TWO sandboxes at the SAME fork-point + SPEC.md + BUSINESS_REQUIREMENT.md
bash core/lib/stage_sandbox.sh "$RUN" "$UNIT" harness    # PROJECT_CONFIG -> full .claude/skills
bash core/lib/stage_sandbox.sh "$RUN" "$UNIT" baseline   # PROJECT_CONFIG -> EMPTY skills

# 5. stub implementers (stand in for the blind LLM) + canonical stub scores per arm

# 6. per-unit cutoff label (real labeler; py-service config: repo_visibility=private)
python3 core/lib/cutoff_label.py "" private "2024-10-01" # -> cutoff-clean

# 7. roll up both arms + render the report
python3 core/lib/aggregate_scores.py "$RUN"              # -> scores.json (arms + ablation_delta)
python3 core/lib/build_report.py "$RUN"                  # -> report.html (ablation panel + chips)
```

Fixture commit SHAs are regenerated on every `setup-fixture.sh` run — the SHAs below are from this
capture.

## Unit discovered

| field | value (this run) |
|---|---|
| repo | `py-service` (language: python) |
| unit (last non-merge commit) | `f0a6b9c` — adds `src/refund.py` (`compute_prorated_refund`) |
| fork-point (parent) | `52e4f4d` |
| human reference diff | `1 file changed, 21 insertions(+)` (a **reference**, never a match target) |
| harness arm skills staged | **1** (`money-cents-guard`) · baseline arm: **0** (empty) |
| leak gate | **passes, but not clean** — the skill names only pre-existing helpers (`Money`, `to_cents`, …), yet its worked example and anti-patterns paraphrase the unit's algorithm (scale by the unused fraction, round to whole cents, keep the payer's currency, return zero for a non-positive term). The identifier gate cannot see a paraphrase, so this harness arm is partly open-book. |

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
harness has fewer). Here the Δ is arithmetic on two constants (95 − 60, n=1 per arm), and the baseline's
lost-context defect — *"refund emitted in major units but the consumer reads whole cents"* — is a
hand-written stub illustrating the failure class the harness targets, not an observed failure. The
gate's `Δ > 0` assertion cannot fail on these inputs. On real model scores this is the number that
would matter.

## Cutoff + decontamination labels (per unit)

| label | value | why |
|---|---|---|
| **cutoff_label** | `cutoff-clean` | `PROJECT.yaml` declares `repo_visibility: private`, and the labeler short-circuits a private repo to clean regardless of dates. It trusts that declaration: this fixture ships with Mahoraga itself (an open-source demo fixture), so the label exercises the cutoff-clean path — it is not a guarantee. |
| **decontam_confidence** | `auto-only` | the leak gate **auto-derived** the snake_case answer symbol `compute_prorated_refund` from the human diff (absent at the fork-point → survives fork-subtraction); no manual answer-token curation. |

> **Honesty note.** `py-service` is *configured* as private → **cutoff-clean**: the deliberate
> counterpart to `examples/ts-app` (public → **cutoff-unverified**). Together the two fixtures
> exercise both outcomes. Only work that is *actually* private or post-cutoff may back a headline
> number — and this demo's harness arm is also partly open-book (see the leak-gate row).

Report rendered: `report.html` (~23 KB) — carries the Ablation panel, the per-unit `cutoff-clean`
chip, and the `auto-only` decontam-confidence chip.
