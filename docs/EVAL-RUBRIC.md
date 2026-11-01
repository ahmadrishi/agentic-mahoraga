<!-- Identity is defined once in branding.yaml; this file mirrors it. -->

# Eval rubric & methodology — how a Prove number is constructed and defended

This is the construct-validity account of the Prove eval: **what** the headline number measures,
**how** it is graded so it survives an adversary, and **what** we disclose so a reader can weight it.
The whole value of Agentic Mahoraga rests on the number meaning what it claims — a blind, attributable,
decontaminated measurement of a project's agentic setup against the humans who shipped the work.

Companion docs: `docs/DECONTAMINATION.md` (blindness — the leak controls and the cutoff holdout) and
`docs/ADAPTER-CONTRACT.md` (where the units and specs come from). The machine-readable per-unit shape is
`core/schema/SCORE.schema.json`; the roll-up is `core/lib/aggregate_scores.py` → the report is
`core/lib/build_report.py`.

The scoring discipline (reviewer → red-team → reconciling verifier, `file:line`-grounded) lives in the
[`adversarial-review-loop`](../skills/prove/adversarial-review-loop/SKILL.md) skill; the driver that
runs it in two arms and discloses the frame lives in [`blind-eval`](../skills/prove/blind-eval/SKILL.md).
This doc is the **methodology those skills implement** — read it to understand *why* the numbers are
shaped the way they are. On that slash-command path most of it is model-instructed: grading, arm
staging and labelling are done by the orchestrating model following those skills, and the scripts
aggregate and render what it writes. That path has not been run end to end with a model in this
repo; the committed example runs use stub scores.

**`mahoraga loop` runs a simpler version of it in code**: criteria
are written once per unit from SPEC, BR and the human diff and then frozen across campaigns; one
blind, schema-constrained session per rollout grades them `full`/`partial`/`none`, citing a line
quoted from the candidate's added code (not a live-repo `file:line`), with no red-team or verifier
pass; the roll-up is recomputed in code; and a sealed, paired rule decides on held-out units
([`LOOP.md`](LOOP.md)). That path has run with real models on private repos. The summary table at
the end says which parts are code on each path.

---

## 1. The business-requirement-achieved rubric (the headline construct)

The headline number is **`business_req_pct`** — the percentage of the *real business ask* achieved, not
spec-line coverage and **not** similarity to the human diff. It is built from a rubric, never eyeballed.

**Step 1 — atomize.** Decompose the business requirement **and** the spec into **atomic acceptance
criteria**: the smallest independently-checkable statements of what "done" means (e.g. "a refund issued
mid-cycle is prorated by unused days", "the prorated amount is persisted where the billing consumer
reads it", "a zero-day refund returns 0, not an error"). One criterion = one thing that can be
`full`, `partial`, or `none` on its own.

**Step 2 — weight.** Give each criterion a relative `weight` reflecting how much of the business
outcome it carries. The core acceptance behaviour outweighs an edge case; a nice-to-have outweighs
nothing. Weights are relative, not required to sum to 1 (the roll-up normalizes).

**Step 3 — grade each criterion with `file:line` evidence.**

| Status | Meaning | Score |
|---|---|---|
| `full` | The criterion is met, confirmed at a `file:line` in the implementation | 1.0 |
| `partial` | Attempted and partly correct — right place, wrong range; happy-path only; guarded but incomplete | 0.5 |
| `none` | Absent, or present but the consumer never reads it / the value can never satisfy the condition | 0.0 |

Every verdict cites a **confirmable `file:line`**, grep-verified against the **live/merged** repo (not
the fork-point sandbox diff) — the adversarial-review-loop discards any verdict it cannot ground.

**Step 4 — weighted roll-up.** The per-unit percentage is the weight-normalized mean of the criterion
scores:

    business_req_pct = round( 100 × Σ(weightᵢ × scoreᵢ) / Σ(weightᵢ) )

The criteria, weights, statuses, and evidence are emitted as the `business_criteria` array in
`score.json`, and `aggregate_scores.py` **recomputes** the percentage from them
(`core/lib/score_hygiene.py`): a grader value that disagrees is overridden (kept as
`business_req_pct_reported`, with a WARN), invalid statuses or weights make it **not measured**, and a
unit with no criteria keeps the grader's value, labelled `business_req_source: grader`. A metric with
no numeric score is `None` — "not measured" in the report — never 0, so an unscored arm cannot
produce a delta. Nothing yet validates the rest of `score.json` against `core/schema/SCORE.schema.json`.

**Blinding and model families.** The scorer grades opaque candidates (`score_hygiene.py blind`: each
arm's diff under a seeded label, the key kept outside the scorer's view; `unblind` maps scores back).
Every score records `scorer_model`/`scorer_family` and `implementer_model`/`implementer_family`; the
report flags SAME-FAMILY SCORING when they match (self-preference risk). Using `blind` is
model-instructed — the scorer is still an LLM — but no arm name reaches its inputs when it is used.

**Grade against the real ask, not the reference.** A human reference that itself missed a criterion
does not make the miss acceptable; a reference that over-built does not make the extra work required.
Code quality is graded `better|equal|worse` **vs the human reference as a comparison baseline** — there
is deliberately **no "human-match %"**, because a different-but-equal-or-better solution is not a
defect.

## 2. Distributions, not just means

A single mean hides the shape of the result — three 100s and a 20 average the same as four 70s, but they
are different stories (one catastrophic miss vs uniform mediocrity). Every report therefore shows the
**distribution**, not just the mean, for the headline metrics over the harness arm:

- **`distributions.business_req`** — `{min, median, max}` (median via `statistics.median`, integers).
- **`distributions.spec_fidelity`** — `{min, median, max}`.

The **min** is load-bearing: the eval exists to catch lost business context on the largest / most
ambiguous units, and that failure shows up as a low `min` a mean would launder away. Read the min first.

## 3. The ablation arm — attribution (why a bare number is unfalsifiable)

Decontamination (`docs/DECONTAMINATION.md`) makes a score *blind*; the **ablation arm** makes it
*attributable*. A harness score of 90% is meaningless on its own — the base model might score 88%
without any of the project's skills, making the harness's contribution ~2 points, not 90. So the
`blind-eval` protocol runs **every unit in two arms** on the same fork-point + same SPEC+BR,
decontaminated identically (on the slash-command path staging both arms is model-instructed;
`mahoraga loop` stages and runs both arms in code):

| Arm | Skills staged | Score file | `arm` |
|---|---|---|---|
| **harness** | the project's full skills (mapping + spec + GUARD pack) | `<UNIT>/score.json` | `harness` |
| **baseline** | **none** — the skills tree stripped to empty, no GUARD | `<UNIT>/score.baseline.json` | `baseline` |

`aggregate_scores.py` globs `<UNIT>/score*.json`, groups by `arm`, and emits the **`ablation_delta`**:

- `business_req_avg`: **harness − baseline** (positive = the harness beat the base model on the ask).
- `lost_context`, `hallucinations`, `overeng`: **baseline − harness** (positive = the harness had
  **fewer** of that defect).

This report delta is a difference of **per-arm means and counts, not paired per unit**: if the two
arms hold different units (one arm's score missing), the delta can mislead, and `aggregate_scores.py`
has no variance estimate or significance test. The decision the loop makes is paired: per-unit
differences over k = 3 runs per arm, an exact sign-flip test, a worst-unit floor and validity checks
on the scorer, sealed before any held-out score exists ([`LOOP.md`](LOOP.md)). On the slash-command
path the delta has only been computed over stub scores.

**The delta is the headline, not the absolute.** Reporting harness-alone invites the unfalsifiable
claim "our skills score 90%"; reporting the delta answers the only question that matters — *did the
harness add anything the base model didn't already do?* A single-arm (harness-only) run is still valid
for a quick look, but it carries **no delta** and the report says so rather than implying attribution.

## 4. Sampling-frame disclosure

Selection is a claim about representativeness, so it is disclosed, never fabricated. The driver writes
`<RUN_DIR>/selection.json`:

    {"candidates": <considered from the tracker>, "selected": <evaluated>,
     "excluded": [{"unit": "<slug>", "reason": "<why>"}, …]}

The report renders a **sampling-frame** line: N selected from M candidates, with each exclusion + its
reason (restore-noop, over-captured range, untranscribable spec, agentic-system label, …). If the file
is absent the report prints **"sampling frame not recorded"** — it never invents a frame. Selection is
deliberately weighted toward storage/integration and coordinated producer↔consumer, multi-repo units
(`selection.require_multi_repo`), because that is where lost-context surfaces; the frame makes that
weighting visible so a reader can judge whether the batch was cherry-picked easy.

## 5. Pretraining-cutoff labels

A "blind" reimplementation of a **public** repo the model saw at pretraining is recall, not reasoning.
Each unit therefore carries a **`cutoff_label`** + **`cutoff_reason`**, computed deterministically by
`core/lib/cutoff_label.py` from the unit's `merged_at` (tracker metadata) and the project's
`decontamination.cutoff_policy` (`repo_visibility`, `model_cutoff`). The `blind-eval` skill instructs
the model to run the script and copy its output into `score.json`; no pipeline script calls it:

| Condition (in order) | `cutoff_label` | `cutoff_reason` |
|---|---|---|
| `repo_visibility == private` | `cutoff-clean` | private repo — not in public pretraining |
| `model_cutoff` set **and** `merged_at` set **and** `merged_at > model_cutoff` | `cutoff-clean` | merged `<merged_at>` after model cutoff `<model_cutoff>` |
| otherwise | `cutoff-unverified` | the specific reason: no `model_cutoff` configured / merged ≤ cutoff / `merged_at` unknown / public repo |

**The honesty rule:** when `cutoff_policy.require_post_cutoff_for_headline` is true (the default), a
**headline** number should be computed **only over `cutoff-clean` units**, with `cutoff-unverified`
units (public demos) shown but **never quoted as the headline**. This is a settled decision, but today
it is a reporting instruction: `aggregate_scores.py` does not filter by `cutoff_label`, and the report
only renders a per-unit chip. The label rule itself is the script's, so it is testable and identical
across runs.

## 6. Decontamination-confidence per unit

Orthogonal to the cutoff axis, each unit carries a **`decontam_confidence`** describing what the
in-run leak-gate (`docs/DECONTAMINATION.md` §4) actually checked — so a reader can weight a score by how
strong the blindness guarantee was. The model writes the value from the gate's output; no code
computes it:

| `decontam_confidence` | The leak-gate result |
|---|---|
| `auto+curated` | the language-aware auto heuristic **and** curated `answer_tokens` both ran, 0 hits — strongest |
| `auto-only` | only the auto heuristic ran (no curated tokens), 0 hits |
| `curated-only` | only curated tokens checked (no auto heuristic for this language yet), 0 hits |
| `hand-mitigated` | a hit was found and manually removed before the blind run — disclosed, not hidden |
| `nothing-checked` | nothing derivable and none curated → the score is **unverified for contamination** |

A `nothing-checked` unit is not a clean unit; it is an unmeasured one, and the report says so.

## 7. Human-adjudicated subsample + inter-rater plan *(plan only — no code)*

The machine verifier is the grader; its reliability must itself be measured, or the rubric is just an
opinion. Nothing below is implemented yet — no script samples units or computes κ. The plan:

1. **Adjudicated subsample.** A human re-grades the `business_criteria` for a **random subsample** of
   the run (target ≥ 20% of scored units, and ≥ 5 units on small runs), blind to the machine's status
   verdicts, using the same rubric (§1).
2. **Agreement metric.** Report machine-vs-human agreement on the `full/partial/none` verdicts —
   exact-agreement rate **and** Cohen's κ (κ corrects for agreement expected by chance across three
   ordered categories). Publish it as the eval's own reliability figure next to the headline.
3. **Two raters → inter-rater reliability.** Where two independent humans grade the same subsample,
   report **their** κ too. High machine-human disagreement but high human-human agreement ⇒ a machine
   grading problem; low human-human agreement ⇒ **ambiguous criteria** (a rubric problem) — fix the
   criteria/weights before trusting the headline.
4. **Threshold.** Below a pre-registered agreement floor (e.g. κ < 0.6, "moderate"), the run's headline
   is held as *provisional* and the criteria are revised — a low-reliability number is not shipped as a
   result.

This subsample is small by design (humans are the scarce resource); it calibrates the machine grader,
it does not replace it.

What exists instead, under `mahoraga loop` only: a seeded 20% of each held-out campaign's rollouts is
graded twice, and the campaign is INVALID unless the two gradings agree (weighted agreement ≥ 0.8,
mean drift ≤ 10 points; [`LOOP.md`](LOOP.md)). That measures the grader against itself, not against
a human.

## 8. Business-req-vs-spec-fidelity collinearity check *(plan only — no code)*

`business_req_pct` (the real ask) and `spec_fidelity` (adherence to the written spec) are **meant to be
distinct constructs** — the dual-input probe's whole point is that an agent can follow the spec's letter
and still miss the business outcome (lost context). If, across a run, the two move in near-perfect
lockstep, one of two things is true, and both are worth surfacing:

- the **spec was a faithful transcription** of the ask (good — but then `business_req_pct` is not adding
  independent signal on that batch, and the report should not sell it as if it were), or
- the grader is **collapsing the two constructs** — scoring "followed the spec" as "met the ask" (a
  construct-validity bug to fix).

The check: across the **harness-arm** units, compute the rank agreement between `business_req_pct` and
`spec_fidelity` (Spearman-style; small-n, so treat it as **directional, not a p-value**). When they are
nearly identical, flag it and lean on the §7 human subsample to confirm the criteria genuinely test the
outcome and not merely spec adherence. The lost-context findings — where `spec_fidelity` is high but
`business_req_pct` is low — are the **positive evidence** the two constructs are separable; a run that
produces some of those is a run whose headline is measuring the right thing.

---

## Summary — the invariants a defensible number satisfies

| Invariant | Status |
|---|---|
| Headline = weighted atomic-criteria roll-up, each `file:line`-grounded | ◐ grading is model-instructed (§1); the roll-up is ✓ code — recomputed from `business_criteria`, overriding the grader |
| A missing score is "not measured", never 0 | ✓ code (§1) — no delta against an unscored arm |
| Scorer blind to the arm; same-family scoring flagged | ◐ `score_hygiene.py blind`/`unblind` + family flag are code; using them is model-instructed on the skill path; ✓ code under `mahoraga loop` (opaque views; only another family's scorer may decide) |
| Distribution shown, not just the mean (read the min) | ✓ code (§2) — `distributions` |
| Number is the harness − baseline **delta**, not an absolute | ◐ delta computed in code (§3, unpaired); running both arms is model-instructed on the skill path, code under `mahoraga loop` |
| A keep/revert decision is paired, pre-registered and made on held-out units | ✓ code under `mahoraga loop gate` / `run` (sealed rule v2, [`LOOP.md`](LOOP.md)); not on the skill path |
| Sampling frame disclosed or "not recorded" — never fabricated | ✓ code renders it (§4); `selection.json` is written by the model |
| Headline from `cutoff-clean` units only; public demos labelled | ◐ labels computed by script when called (§5); the headline is **not** filtered in code |
| Contamination confidence stated per unit | ◐ field + chip (§6); the value is model-written |
| Machine grader's reliability measured against humans | ✗ plan only (§7); the loop measures only the grader's agreement with itself |
| Business-req and spec-fidelity confirmed as separable constructs | ✗ plan only (§8) |

If you find a way to game any of these, that is an in-scope security report — see
[`../SECURITY.md`](../SECURITY.md).
