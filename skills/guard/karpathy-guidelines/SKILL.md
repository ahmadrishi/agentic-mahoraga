---
name: karpathy-guidelines
description: Umbrella behavioral discipline for the most common LLM coding mistakes — overcomplication, sprawling diffs, hidden assumptions, and calling work "done" without proof. Use at the START of any non-trivial coding task to run the four pre-flight biases (think-before-coding, simplicity, surgical change, goal-driven verification) and route to the dedicated skill for each. Do NOT use for the deep drill on one discipline — go straight to that sibling — simplicity-first, small-diff-surgical-change, surface-assumptions, or verification-before-advance.
allowed-tools: Read, Grep, Glob
license: MIT
mahoraga:
  kind: guard
  grounding: none
---

# Karpathy Guidelines

Behavioral guidelines to reduce the common coding mistakes an LLM makes regardless of stack,
derived from Andrej Karpathy's public observations on where LLM coding goes wrong. This is the
**front door** of the GUARD pack: it names the four failure modes and hands you to the dedicated
skill for each. Read it first on any task that is more than a trivial edit.

**Tradeoff:** these guidelines bias toward caution over speed. For a truly trivial change, use
judgment — but "trivial" is a claim you should be able to defend, not a default.

## When to use

- At the start of any non-trivial implementation, refactor, or bug-fix.
- When you feel the pull to write a lot of code fast — that is exactly when the four biases pay off.
- As a checklist before you claim a task is finished.

## The four biases (and where each lives)

1. **Think before coding — surface assumptions.** Don't assume, don't hide confusion, present
   tradeoffs, and never take the spec's framing about the codebase's current state on faith.
   → [`surface-assumptions`](../surface-assumptions/SKILL.md)
2. **Simplicity first.** The minimum code that solves the actual problem; nothing speculative.
   → [`simplicity-first`](../simplicity-first/SKILL.md)
3. **Surgical changes.** Touch only what the request requires; every changed line traces to the ask.
   → [`small-diff-surgical-change`](../small-diff-surgical-change/SKILL.md)
4. **Goal-driven execution — verify before you advance.** Turn the task into a verifiable goal, loop
   until it is proven, and close with a word your evidence supports.
   → [`verification-before-advance`](../verification-before-advance/SKILL.md) +
   [`honesty-vocabulary`](../honesty-vocabulary/SKILL.md)

## Steps — the pre-flight

Before writing code, run this in order:

```
1. Restate the goal + assumptions → verify current state (grep), name open interpretations.
2. Pick the SIMPLEST approach that meets the goal; push back if the spec over-asks.
3. Define success criteria: "goal → verify: <concrete check>".
4. Implement the narrowest diff that satisfies (3).
5. Climb the verification ladder; close with BUILD-/SMOKE-/UNVERIFIED — never "tested" unless tests ran.
```

For a multi-step task, write the plan as a list of `step → verify: check` lines so you can loop
independently. Strong criteria let you proceed without asking; weak criteria ("make it work") force
constant clarification and hide failures.

## Key points

- The four biases compound: a simple design (2) produces a small diff (3), which is easy to verify
  (4), and rests on assumptions you already surfaced (1). Skipping one usually costs you in another.
- Each dedicated skill is self-contained and goes far deeper (real search drills, worked misses,
  anti-patterns). This umbrella exists to make sure you *reach for* all four, not to replace them.
- Two more pack skills sit alongside these four: [`reuse-before-create`](../reuse-before-create/SKILL.md)
  (don't reinvent what exists) and [`trace-to-consumer`](../trace-to-consumer/SKILL.md) (prove your
  output reaches its reader). Both are part of "think before coding."

## Worked example

Task: *"Add retry to the payment webhook handler."*

- **Think first (1):** grep the handler — does a retry helper already exist? What does "retry" mean
  here — transport retries, or replaying a failed business action? Two readings; name them or ask.
- **Reuse (side-check):** the `billing` module already has a `RetryPolicy` used by three callers —
  reuse it rather than writing a new loop ([`reuse-before-create`](../reuse-before-create/SKILL.md)).
- **Simple (2):** wrap the existing call in the existing policy. No new `RetryStrategy` interface,
  no config for backoff curves nobody asked for.
- **Surgical (3):** the diff is the wrapping call plus one import — not a reformat of the handler.
- **Verify (4):** typecheck ✓, build ✓, drive one failing-then-succeeding call ✓ →
  **SMOKE-VERIFIED**, not "tested."

The overeager version invents a `RetryStrategyFactory`, reformats the file, and reports "done and
tested" after only a compile. Each bias catches one of those.

## Anti-patterns

- Diving into code before restating the goal and checking the codebase's current state.
- Adding abstraction, config, or error paths nobody asked for.
- A large, multi-concern diff for a small requirement.
- Closing with "done" / "tested" on the strength of a compile.
- Treating this umbrella as the whole discipline — the depth is in the four dedicated skills.

## Related skills

- [`surface-assumptions`](../surface-assumptions/SKILL.md) — bias 1, in depth.
- [`simplicity-first`](../simplicity-first/SKILL.md) — bias 2, in depth.
- [`small-diff-surgical-change`](../small-diff-surgical-change/SKILL.md) — bias 3, in depth.
- [`verification-before-advance`](../verification-before-advance/SKILL.md) — bias 4, in depth.
- [`honesty-vocabulary`](../honesty-vocabulary/SKILL.md) — the words you are allowed to close with.
- [`reuse-before-create`](../reuse-before-create/SKILL.md) / [`trace-to-consumer`](../trace-to-consumer/SKILL.md) — the two search disciplines that pair with "think before coding."
