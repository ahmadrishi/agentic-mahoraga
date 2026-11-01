---
name: adversarial-review-loop
description: Score or review an implementation adversarially against a reference. Use when grading how much of a business requirement an implementation actually achieved and how its code quality compares to a human (or baseline) reference — a spec-vs-human eval, a "how good is this PR really" review, or any grading that must resist a too-generous first pass. Runs reviewer → red-team → reconciling verifier, keeps only findings grounded in a confirmable file:line, and emits a scorecard covering business-req-achieved %, code quality (better/equal/worse vs the reference), net-new reachable security, and weakness flags. Triggers "score this implementation", "review adversarially", "grade business req achieved", "did it really meet the requirement", "red-team this diff", "code quality vs the human reference". Reusable well beyond eval. Do NOT use to stage the sandbox (that is sandbox-isolation) or to drive the whole eval (that is blind-eval).
allowed-tools: [Read, Grep, Glob, Bash]
license: MIT
mahoraga:
  kind: meta
  grounding: none
---

# Adversarial review loop

A single reviewer scores too generously: it reads the implementation, sees plausible code, and
rubber-stamps a "requirement met" that a hostile reader would puncture in one grep. This protocol
makes grading survive an adversary. Three roles run in sequence — a reviewer that scores, a red-team
that argues the opposite, and a reconciling verifier that throws out every claim not nailed to a
`file:line` — so the final score is only what survives a confirmable challenge. It grades against a
**reference** (the human diff in an eval, or any baseline PR), and the reference is a **comparison
baseline, never a match target**.

## When to use

- Scoring a blind implementation in an eval against the human who shipped the unit of work.
- Any "did this really meet the requirement, or just look like it?" review where the first read felt
  too kind.
- Grading two implementations of the same ask against each other.
- You have the implementation's diff, the business requirement + spec, and (usually) a reference diff
  to compare to.

## The three roles

Run them in order; each writes its own transcript (keep all three). One agent can play all three
passes sequentially, or an orchestrator can fan them out as separate subagents — but the **verifier's
pass is mandatory and last**.

| Role | Mandate | Produces |
|---|---|---|
| **Reviewer** | Read the implementation against the business requirement + spec. Decompose the ask into weighted **atomic criteria**; mark each **full / partial / none** with `file:line` evidence. Rate code quality vs the reference. Flag weaknesses. | First-pass scorecard with evidence |
| **Red-team** | Argue the **opposite** of every "full" and every "safe". Hunt a **reachable** exploit and unmet criteria; try to show the output never reaches its consumer, the value is one the producer never emits, or the "done" criterion is dead code. | A challenge list, each item pointing at code |
| **Reconciling verifier** | Take every claim from both — **keep only those grounded in a confirmable `file:line`**, discard the rest (including the reviewer's optimistic "full"s the red-team broke). Reconcile to one final scorecard. | The final `score.json` |

## The metrics

Emit exactly these; nothing is "met" without evidence.

| Metric | Definition | Scale |
|---|---|---|
| **business_req_pct** + **business_criteria** | Decompose the business requirement **+** spec into **weighted atomic criteria** and emit them as the `business_criteria` array (each `{criterion, weight, status: full\|partial\|none, evidence: file:line}`); `business_req_pct` is the **weighted roll-up** of their statuses (full=1, partial=0.5, none=0). This is the headline number — it measures the *real ask*, not spec-line coverage. **This is the construct rubric — the full methodology (how to atomize, weight, and roll up) is `${CLAUDE_PLUGIN_ROOT}/docs/EVAL-RUBRIC.md`.** | array + 0–100 % |
| **code_quality** | Reuse · architecture · patterns · maintainability — each **better \| equal \| worse vs the reference**, plus an overall. **Do NOT score "reference-match %"** — a different-but-equal-or-better solution is not a defect. | per-axis + overall verdict |
| **security** | **Net-new reachable threat vs the reference baseline** — a vulnerability the implementation introduces that the reference did not, with **severity + reachability + `file:line` evidence**. If none, say **"none — parity or better"**. A theoretical, unreachable issue is not a finding. | severity + reachability, or "none" |
| **weaknesses** | Flags: **hallucination** (invented symbol/API), **over-engineering** (scope the ask didn't need), **lost-context** (locally-correct output the consumer never reads, or a value the producer never emits) — plus **spec-fidelity**. | flags + one-line evidence each |

Grade **business_req** against the real ask even where the reference under- or over-shot it; a
reference that itself missed a criterion does not make the miss acceptable, and a reference that
over-built does not make the extra work required.

## Grounding rules (what makes a finding real)

- **file:line or it didn't happen.** Every criterion verdict, every red-team claim, every security
  finding must cite a confirmable `file:line` in the implementation (or reference). The verifier
  **discards any claim it cannot ground** — an ungrounded "this is wrong" scores nothing.
- **Grep-verify against the LIVE repo, not the sandbox diff.** Any claim that teaches a read/write
  path — "the consumer reads field X", "the producer emits Y", "helper Z already exists" — must be
  **grep-verified in the live/merged codebase**, because the implementation was written in a
  fork-point sandbox and the sandbox's approach ≠ the merged tree. A claim that only holds inside the
  sandbox is not a finding about the codebase. Verify each `file:line` still resolves before you rely
  on it.
- **Neutral prompts only.** The prompts that produced the implementation *and* the review must be
  **neutral** — no leading question that hands over the answer ("did they forget to write to the
  analysis field?"). Judge by the code result, not by a hint. **If a prompt leaked the answer, the run
  is void — re-stage and relaunch** rather than scoring a tainted result. (Staging/relaunch:
  [`sandbox-isolation`](../sandbox-isolation/SKILL.md).)
- **Separate measurement artifacts from real findings.** Before scoring "the human did far more",
  check the comparison isn't distorted — e.g. an inflated reference line-count because the diff range
  over-captured unrelated commits. An artifact of measurement is not an implementation defect; note it
  and correct the baseline instead of scoring against it.

## The lost-context finding (the one this eval exists to catch)

When both spec and business requirement were provided, the highest-value finding is rarely a
hallucination or a broken build — it is **locally-correct output the intended consumer never reads**,
or **a value the consumer's condition can never match**. Red-team every producer→consumer path
explicitly:

1. Name the consumer the business outcome depends on; **grep its actual read path in the live repo**.
2. Confirm the implementation's write lands on that path (not on a plausible-looking sibling field).
3. Confirm the emitted value's semantics/units/**sentinel/range** can satisfy the consumer's condition
   — grep the producer's write sites, state the exact range it can emit, confirm the consumer's tested
   value is inside it. A branch keyed off a value the producer never emits is **dead code** — a
   lost-context miss even though everything compiles. (If the project's forged mapping/spec skills ship
   a producer→consumer trace discipline, this is that discipline applied as a review check.)

## Output shape

The reconciling verifier writes one score file per unit conforming to
`${CLAUDE_PLUGIN_ROOT}/core/schema/SCORE.schema.json` — the required, machine-readable shape the aggregator/report consume
(`${CLAUDE_PLUGIN_ROOT}/core/lib/aggregate_scores.py`, `${CLAUDE_PLUGIN_ROOT}/core/lib/build_report.py`). It carries the **`business_criteria`**
array (the weighted atomic-criteria breakdown, each with its `file:line` evidence), `business_req_pct`
(their weighted roll-up — `aggregate_scores.py` recomputes it from the criteria, so grade every
criterion; a criterion with an invalid status makes the % "not measured"), the per-axis quality
verdicts, the security verdict, the weakness flags, `"scorer": "adversarial-review-loop"` — the report
headline states provenance from that field, and calls a score with no `scorer` "provenance unknown" —
and `scorer_model` + `scorer_family`. You score a blinded candidate (`blind/<label>/`): never ask
which arm it is, and never infer it. Do not free-form the output; fill the schema. When an orchestrator runs this in a two-arm ablation, `score_hygiene.py unblind`
sets the `arm` field (`harness` → `score.json`, `baseline` → `score.baseline.json`) and the driver stamps the
per-unit `cutoff_label` / `decontam_confidence`; those are the driver's concern
([`blind-eval`](../blind-eval/SKILL.md)), not this loop's — you just fill the criteria honestly.

## Using this outside an eval

Nothing here needs the harness. Point it at any diff + requirement + reference (or no reference — then
grade `business_req` absolutely and skip the comparative quality axes). The value is the discipline:
weighted atomic criteria, an adversary that argues the opposite, and a verifier that keeps only
`file:line`-grounded claims — the same protocol that keeps a self-review honest.

## Related skills

- [`blind-eval`](../blind-eval/SKILL.md) — the orchestrator that feeds this the AI diff, reference
  diff, spec+BR, and verify verdict per unit.
- [`sandbox-isolation`](../sandbox-isolation/SKILL.md) — where the implementation came from; re-stage
  here if a prompt leaked.
- [`skill-improvement-loop`](../skill-improvement-loop/SKILL.md) — consumes the weakness findings to
  propose and validate skill fixes.
