---
name: trace-to-consumer
description: Use BEFORE choosing where to store/emit a value, or before any coordinated producer→consumer change (a DB column/field/table to hold output, a backend attribute the frontend reads, one service's output another service reads, a value a pipeline/report/UI keys off). First identify who CONSUMES the output the business outcome depends on, grep the consumer's actual read path, confirm your write lands on that path, and confirm the value's semantics/units/sentinel/range match what the consumer expects. Prevents output that satisfies the spec's letter but lands where the intended reader never looks, or a value the consumer keys off but the producer never emits. Do NOT use for finding an existing producer to reuse (that is reuse-before-create) or for proving a change compiles and runs (that is verification-before-advance).
allowed-tools: Read, Grep, Glob, Bash
license: MIT
mahoraga:
  kind: guard
  grounding: none
---

# Trace To Consumer

The most expensive avoidable defect on large or ambiguous tickets is not reinventing a producer
(that is [`reuse-before-create`](../reuse-before-create/SKILL.md)) or a broken build (that is
[`verification-before-advance`](../verification-before-advance/SKILL.md)) — it is writing output that
is *locally correct* but that the intended **consumer never reads**, or emitting a **value the
consumer's condition can never match**. A change can satisfy every line of the spec, compile cleanly,
and still leave the business outcome unmet because nothing downstream sees it. This skill makes
"prove the output reaches its consumer" a required step.

## When it triggers

- Any open **"where do I store this?"** decision — a column / field / table / relation for new output.
- Any **coordinated producer→consumer** change: backend emits → frontend reads; one service writes →
  another reads; a job populates → a pipeline / rating / analysis / report consumes.
- Any ticket whose value is an **analytics / detection / alerting / "what the next stage sees"**
  outcome — the whole point is that *something downstream reads it*.
- Whenever the spec **leaves storage or a detection mechanism as an open decision** — pair the
  pick-and-note with this validation.

## The rule

Before you choose where to WRITE output or how a consumer READS a value:

1. **Name** the consumer the business outcome depends on.
2. **Grep** its actual read path (never from memory).
3. **Confirm** your write lands on that path.
4. **Confirm** the value's semantics / units / sentinel / range satisfy the consumer's condition.

If any link is missing, the requirement is **not met** — even if the spec's letter is.

## Step 1 — Name the outcome and its consumer (one sentence)

From the **business requirement**, not just the spec, write: *"This output exists so that ⟨CONSUMER⟩
can ⟨do the business thing⟩."* Make the consumer concrete code, not a concept — name the actual
service / pipeline / component / report that has to read your output for the outcome to happen. If
you cannot name the consumer, you cannot finish the ticket — go find it (Step 2).

## Step 2 — Find the consumer's read path by grep (never from memory)

Grep for who **reads** the store/signal the outcome depends on *before* you choose where to write.
Locate the exact `file:line` that reads it. A **spec-named table/field is not proof it is on the read
path** — verify which field the consumer actually reads. Generic patterns (substitute your symbols):

- **A stored field/relation → who reads it:**
  `grep -rniE "get<Field>\(|\.<field>\b|<relation>\.getContent" <src> --include="*.<ext>"`
- **A pipeline / report / rating / analysis consumer:** grep its entry points for the field it pulls:
  `grep -rniE "<consumerClass>|<getterTheConsumerCalls>|analysis|rating|report" <src>`
- **Producer→UI attribute (the round-trip key):** find the producer's write of a key and the
  consumer's read of the **same** key:
  producer `grep -rniE "<KEY>|attributes.put|emit\(" <backend-src>` ;
  consumer `grep -rniE "attributes\??\.<key>|<stateFieldTheUIreads>" <frontend-src>`
- **service→service:** grep the writer (`new X(`, `setX(`, `save`) and every reader (`getX(`), and
  confirm they share the same row/instance.

## Step 3 — Confirm your write lands on the consumer's read path

The field/column/signal you write MUST be the one the consumer reads. If the consumer reads relation
A and you write field B, the output does not reach it — even if B is the "natural" system-of-record.
Two legitimate fixes: **(a)** write to the consumer's field/relation directly, or **(b)** trigger the
existing pipeline that populates it. A "system of record" column and "the field the downstream
analysis reads" are often *different* fields fed by *different* writers — grep to find which writer
feeds the consumer, and reach that one. "Locally correct but off the read path" is the #1 miss shape —
reject it.

## Step 4 — Confirm value semantics / units / sentinel / range match

Even on the **same** key, verify the producer's actual output can satisfy the consumer's condition:

- **Type & unit** — minutes vs milliseconds, string vs int, ISO vs epoch.
- **Sentinel & range (MANDATORY — the check most often skipped; matching the key is NOT enough).**
  Whenever the consumer branches on a specific value (`<= 0`, `== null`, `=== 'X'`, `> N`, an empty
  string, a specific enum), do this **in order and WRITE IT DOWN**, not just assert "the key matches":
    1. Grep the producer's write/set site(s) for that value.
    2. State the **exact set or range of values the producer can actually emit** — account for every
       clamp, default, fallback, and whether anything decrements/mutates it *after* it is set.
       (Example shape: "the producer computes `x`, but on the `x <= 0` edge it clamps back to the full
       positive value, and nothing decrements it afterward → it emits only positive values.")
    3. Confirm the consumer's tested value is **inside** that set.
  If not, the consumer's branch is **dead code** — fix it by keying off a value the producer actually
  emits. A value can share the key/type/units and still be one the producer never produces. **You have
  not completed the contract check until step 2 is written out** — and you may not call it verified
  before then.
- **Prefer an existing populated signal** over a sentinel you assume: if the codebase already sets a
  state/flag field that means what you want to detect, grep for it and key off that rather than
  inventing a numeric threshold.

## Step 5 — For coordinated producer/consumer changes, pin the contract and change both ends together

Write the contract explicitly before coding: **key · type · unit · sentinel meaning · who writes ·
who reads**. Change the consumer to key off a signal the producer actually emits. Note release
coordination (feature flag / same release) so a half-shipped contract doesn't double-count or go dead.
This is the design-time semantic sibling of the build proof and the producer↔consumer contract drill
in [`verification-before-advance`](../verification-before-advance/SKILL.md) — do this first, then let
that prove it compiles/runs and that no other caller broke.

## Step 6 — Verify the loop end-to-end and record the trace

Write the chain into your notes / PR:
`outcome → consumer (file:line) → read path → your write (file:line) → value/sentinel match ✓`
If any arrow is broken, the ticket is not done. If the spec's suggested storage/detection **can't
reach the consumer**, flag it (a valid caught-spec-error) — and carry that observation *through* to
the read path, don't stop at the column choice.

## Build the consumer map for this ticket

Do not assume the read path from the field name. For each output your ticket produces, grep the
codebase to establish, on disk:
- the **field/relation/attribute the intended consumer actually reads** (getter + call sites), and
- the **writer that feeds that consumer** (which may not be the obvious system-of-record column), and
- the **value range/sentinel** that writer can emit.
Record those `file:line`s. That short map — for *your* ticket's consumers — is the deliverable of
this step.

## Worked examples

- **Off the read path (a miss).** An implementer wrote a derived value (a transcription) to the
  technically-correct system-of-record column — but the downstream analysis pipeline reads a
  *different* relation, so the value never reached the reader and the detection blind spot stayed
  open. **Fix:** write to (or trigger the pipeline that populates) the field the analysis actually
  reads, not the "natural" column.
- **Dead sentinel (a miss).** The UI keyed an overdue/idle detection on `remainingTimer <= 0` — a
  value the backend clamps away and never emits (on the `<= 0` edge it resets to the full positive
  timer, and nothing decrements it). Detection was frozen for every record. **Fix:** key off an
  existing state flag the backend actually sets (e.g. `state === 'inactive'`), a signal the producer
  really emits.

## Anti-patterns

- Choosing the "natural" system-of-record column without grepping who reads it for *this* outcome.
- Following the spec's named table/field/sentinel without confirming it is on the consumer's read
  path (spec text can be imprecise).
- Keying a consumer off a sentinel (`<=0`, `==null`) without proving the producer emits it.
- Treating "the value is stored / the number is correct / it compiles" as done, when nothing
  downstream reads it.
- Editing a **shared** display/format method for one case and silently changing every other consumer
  of it.

## Related skills

- [`reuse-before-create`](../reuse-before-create/SKILL.md) — finds an existing *producer* to reuse
  (backward search); this finds the *consumer* your output must reach (forward search). Run both.
- [`verification-before-advance`](../verification-before-advance/SKILL.md) — the build proof and the
  producer↔consumer contract drill; this owns the design-time principle, that proves it at runtime.
- [`honesty-vocabulary`](../honesty-vocabulary/SKILL.md) — when the contract is only design-checked,
  say **CONTRACT-CHECKED**, not "verified."
- [`karpathy-guidelines`](../karpathy-guidelines/SKILL.md) — the generic "define success criteria";
  this makes the criterion concrete: *the consumer reads it*.
