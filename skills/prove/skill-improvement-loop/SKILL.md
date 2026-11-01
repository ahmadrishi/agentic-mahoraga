---
name: skill-improvement-loop
description: Turn eval findings into skill edits or new skills, then check the fix with a decontaminated retest. Use when improving a project's skills from eval weaknesses — proposing and validating a new or edited skill, closing lost-context misses, or deciding whether a miss is even fixable by a skill. Fans out planners to propose EDIT-vs-NEW skills, adversarially reviews them for best practice, applies + re-checksums the set, then re-runs the FAILED units under a mandatory leak-gate and has you compute the before/after delta by hand (same units, not a held-out test; a held-out verdict is `mahoraga loop run`), and classifies each surviving miss as skill-gap vs spec-gap. Triggers "improve the skills from the findings", "propose a new skill", "validate this skill edit", "did the fix actually work", "did the harness self-improve", "is this a skill problem or a spec problem". Do NOT use to run the eval itself (that is blind-eval) or to score an implementation (that is adversarial-review-loop).
allowed-tools: [Read, Grep, Glob, Edit, Bash, Task]
license: MIT
mahoraga:
  kind: meta
  grounding: none
---

# Skill improvement loop — findings → fix → decontaminated retest

A finding is worth only the fix it produces, and a fix is worth only what a **retest proves in code** —
not a skill that now "reads better". This is the improve-and-validate half of the eval: findings →
proposed skill changes → adversarial best-practice review → apply + re-checksum → **validation by
re-running the failed units decontaminated**. The trap it exists to avoid is declaring victory on a
skill edit that was never re-tested, or hardening a skill forever against a miss the **spec** — not the
skill — is causing.

Everything project-specific comes from **`PROJECT.yaml`** (`${CLAUDE_PLUGIN_ROOT}/core/schema/PROJECT.schema.yaml`).

## When to use

- After an eval produces weakness findings (lost-context, hallucination, over-engineering,
  spec-fidelity) and you want to close them.
- When proposing a brand-new skill or an edit to an existing one, and it must be validated before you
  trust it.
- When a miss keeps recurring and you need to decide whether more skill-hardening can even fix it.

## Phase 8 — findings → proposed skills

### Step 1 — fan out planners (EDIT vs NEW)

Cluster the findings; for each cluster, launch a planning agent that proposes **one** of:

- **EDIT an existing skill** (preferred) — extend the skill that already owns the concern with the
  missing method/guardrail. Reuse before creating.
- **NEW skill** — only when no existing skill owns the concern. Its **`description` IS its trigger** —
  it must state *when* to fire and carry natural trigger phrases, or it will never activate. It must
  conform to `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md` (name matches folder, third-person description ending in a
  "Do NOT use for…" router where a sibling exists, least-privilege `allowed-tools`).

**Deconflict overlaps.** If two proposals touch the same concern, do **not** ship two skills that
half-cover it — cross-reference them: one owns the method, the other links to it (`../<name>/SKILL.md`).
Duplicated skills with fuzzy triggers are worse than one sharp skill.

Edits to a **forged mapping/spec skill** are surgical maintenance — route those through
[`skill-editor`](../../adapt/skill-editor/SKILL.md) so the minimal-diff + conformance discipline holds.

### Step 2 — adversarial best-practice review of every proposed skill

Review each proposal the way [`adversarial-review-loop`](../adversarial-review-loop/SKILL.md) reviews
code — hunt for what's wrong, ground it:

| Check | Pass bar |
|---|---|
| **Triggering description** | States *when* to fire + trigger phrases + a "Do NOT use for…" boundary; a fresh agent would actually match it |
| **Right altitude** | Teaches the method + guardrails, not a wall of prose; scannable (short imperative steps, tables) |
| **No bloat** | No restating another skill; every section earns its place; SKILL.md < 500 lines / < 5k tokens |
| **Valid frontmatter** | `name` matches the directory; `description` present; YAML parses; `allowed-tools` least-privilege (deny net/shell unless required) |
| **Resolved cross-links** | Every `../<name>/SKILL.md` resolves; siblings cross-referenced, not duplicated |
| **Grep-verified examples** | **Every grep-teaching claim or worked example is grep-verified against the LIVE repo**, not a sandbox diff — an example that doesn't resolve in the merged tree is a bug in the skill. Before a retest, also check it at the retested units' fork-point: a symbol that exists only in the merged tree may be a later unit's answer |

Run `${CLAUDE_PLUGIN_ROOT}/scripts/conformance-lint.mjs` on any forged skill you touched (a mapping skill
not under `<repo>/.claude/skills/` needs `--repo <repo>`; see
[`conformance-lint`](../../adapt/conformance-lint/SKILL.md)) — the structural gate must pass before the
skill ships.

### Step 3 — apply, then re-snapshot + re-checksum

Apply the approved diffs (surface them for the human approval gate). Then **re-snapshot the skill set
and re-checksum it** so it stays verifiable, and **record the checksum file** — the set's integrity is
now part of the audit trail, and the next run's leak-gate/decontamination works from a known-good
snapshot.

**Register every new/edited skill for decontamination — this is what keeps the retest honest.** A
skill you just wrote *from the findings* encodes the answer. Before any retest, for each new or edited
skill: (1) add it to `skills.derived_skills`, (2) author its method-only `SKILL.sanitized.md`, and (3)
append the retested units' distinctive answer symbols to `decontamination.answer_tokens`. The gate also
auto-derives tokens from each unit's human diff (language-aware) as a safety net, but do not rely on
the net alone — an unregistered skill that leaks the answer in prose is the harness's own most-repeated
failure re-entering through the improve→retest door.

## Phase 9 — retest the failed units (same units — not a held-out test)

A skill edit **fixes a miss only when the previously-missed case now passes in code** — re-implemented
blind and re-scored, not merely re-read. Because these are the units the edit came from, a pass shows
the edit fixes them, not that it generalises.

1. **Re-stage the FAILED units** through [`sandbox-isolation`](../sandbox-isolation/SKILL.md) with the
   **improved** skills.
2. **Decontaminate — mandatory here.** The improved skills were written *from the findings*, so they
   are the most likely artifacts to contain the units' answers. Sanitize the derived skills to
   method-only and run the leak-gate; the answer-token count **must be 0** or the retest is open-book
   and worthless.
3. **Re-implement blind** (fresh general-purpose subagent, never a fork) and **re-score** through
   [`adversarial-review-loop`](../adversarial-review-loop/SKILL.md). The fix holds only if the
   previously-`none`/`partial` criterion is now `full` **in the code result**.

## Self-improvement efficacy — the REQUIRED output

One flipped criterion is an anecdote; the claim **"the harness self-improves"** is a *measurement*, and
producing it is a **required output** of this loop. Compute the **efficacy delta**: re-score the
**previously-FAILED units** under **both** skill sets — *pre*-improvement (the snapshot from before
Step 3) and *post*-improvement — each decontaminated by the same leak-gate, and report the change:

    efficacy_delta = business_req_pct(post) − business_req_pct(pre)
                     over the previously-FAILED units only, decontaminated
                     (+ the count of criteria that flipped none/partial → full)

Rules that keep the claim honest:

- **Never claim "self-improves" from this delta.** It is measured on the units the edits came from, so
  it shows the edits fix those units, not that they generalise; that claim needs a KEEP on held-out
  (later-merged) units from `mahoraga loop run`, where a contained editor learns from earlier units
  and a sealed rule judges its edit on later ones (`${CLAUDE_PLUGIN_ROOT}/docs/LOOP.md`). That loop edits two always-on
  guidance files, not skills, so it does not replace this skill's EDIT/NEW flow (guidance written
  here as those two files can be measured with `mahoraga loop gate --candidate DIR`, never promoted). A skill that "reads
  better" but does not move the retest score is prose, not an improvement.
- **Same failed units, same decontamination, blind re-implement (fresh, never a fork) for both skill
  sets** — the only variable is the skill edit. This mirrors the harness-vs-baseline ablation in
  [`blind-eval`](../blind-eval/SKILL.md), but the two sides here are *pre-skill* vs *post-skill* on the
  failed subset.
- **A zero or negative delta is a real result — report it, do not bury it.** It means the edit missed
  (or the miss is a spec-gap, below); revert or re-plan the skill change rather than shipping a
  no-op edit that inflates the skill set.
- Under a thin spec (`attribution-ambiguous`) a flipped criterion is weaker evidence — say so instead
  of quoting the delta with false confidence.

## Classify each surviving miss — skill-gap vs spec-gap

Not every miss is a skill's fault. Before hardening a skill a third time, classify:

| | Skill-gap | Spec-gap |
|---|---|---|
| **What happened** | The agent had the information and chose wrong | The **spec sanctions the wrong choice** — e.g. it offers a non-functional option the agent dutifully picks |
| **Can a skill fix it?** | Yes — harden the skill and the retest passes | **No** — hardening makes the miss **visible**, but cannot override a spec that endorses it |
| **Route to** | More skill-hardening | A **spec-quality fix** — stop hardening the skill; fix the spec |

Endless skill-hardening against a spec-gap is wasted effort. Name the class in the findings so the
right team owns the fix. (When the spec was thin — a `attribution-ambiguous` run — the signal is
weaker; say so rather than assigning the miss confidently.)

## The write-it-down GATE hardening pattern

The most durable skill hardening turns an easy-to-skip check into a **forced, write-it-down gate**: the
skill must not let the agent *declare* something verified until it has written down the evidence. The
canonical shape for a producer→consumer contract:

> **grep the producer's write sites → state the exact value range it can emit (every clamp, default,
> decrement) → confirm the consumer's tested value is inside that range — before you may write
> "verified".**

Even when the underlying miss is a spec-gap the gate cannot force fixed, the gate still earns its
place: it **surfaces the miss** instead of letting it pass silently, so the choice becomes visible and
auditable rather than an invisible default. Transparency is a real improvement even when the fix isn't
forced.

## Related skills

- [`sandbox-isolation`](../sandbox-isolation/SKILL.md) — the sanitize + leak-gate the validation retest
  depends on to stay honest.
- [`adversarial-review-loop`](../adversarial-review-loop/SKILL.md) — re-scores the retested units; a
  fix is proven only when its criterion flips to `full` in code.
- [`blind-eval`](../blind-eval/SKILL.md) — the eval that produced the findings this loop consumes;
  append fixed units to `decontamination.exclusion`.
- [`skill-editor`](../../adapt/skill-editor/SKILL.md) — surgical, conformance-preserving edits to a
  forged mapping/spec skill.
