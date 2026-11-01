---
name: surface-assumptions
description: Use before implementing anything ambiguous — state the assumptions you are about to bet on, present competing interpretations instead of silently picking one, flag a simpler approach when you see it, and never take the spec's framing about the codebase's current state on faith (grep to confirm before acting). Distinguish assumptions you verified on disk from ones you are carrying forward unverified. Do NOT use for the full verify-current-state drill on a restore/re-add task (that is reuse-before-create) or for proving your change works after you build it (that is verification-before-advance).
allowed-tools: Read, Grep, Glob
license: MIT
mahoraga:
  kind: guard
  grounding: none
---

# Surface Assumptions

The cheapest defect to prevent is the one you catch *before* writing code, by naming the assumption
you are about to bet on. Models fail here by hiding confusion, silently choosing one of several
readings, and taking the spec's framing on faith. The rule: **state assumptions, present
interpretations, verify the codebase's actual state — don't guess quietly.**

## When it triggers

- Before implementing anything ambiguous or under-specified.
- When a spec has more than one plausible reading.
- When you spot a simpler approach than the one implied.
- When the spec says **restore / revert / re-add / add X** — verify X isn't already there.
- Whenever something is genuinely unclear and the answer changes the outcome.

## The rule

1. **State assumptions explicitly.** Write down what you're taking for granted. If uncertain and it
   changes the outcome, ask rather than pick silently.
2. **Present competing interpretations.** If the spec reads two ways, name both and say which you'll
   act on and why — don't choose one in silence and hope.
3. **Flag a simpler approach.** If one exists, say so and push back when warranted
   (→ [`simplicity-first`](../simplicity-first/SKILL.md)).
4. **When something is unclear, stop, name what's confusing, and ask.** A precise question is cheaper
   than a wrong implementation.
5. **Don't trust the spec's framing about current state.** "Restore / revert / re-add / add X"
   describes an intended *end-state*, not proof X is missing. **Grep for X first.** If it's already
   present and wired, don't re-add it (you'll duplicate it and may break the build) — verify it works
   and report the mismatch. (The full drill is in
   [`reuse-before-create`](../reuse-before-create/SKILL.md).)
6. **Label verified vs unverified assumptions.** Separate "I grepped and confirmed X on disk" from
   "I'm assuming X" — the reader must know which claims you checked.

## Key points

- **Surfacing ≠ asking.** Writing an assumption into your notes is good, but when the assumption is
  *load-bearing and unverified*, do both: verify what you can (grep), and ask about what you can't.
- **The autonomy slider.** Strong, verifiable success criteria let you proceed without asking; genuine
  ambiguity that changes the deliverable warrants a question. Calibrate: don't ask about trivia you
  can resolve by reading the code, and don't silently guess on a fork in the requirement.
- A caught spec-vs-reality contradiction is a **valid, high-quality result** — often a no-op plus a
  report — not a failure to produce a diff.

## Worked example

Spec: *"Re-add the export button that was removed last sprint."*

- **Assumption to check:** was it actually removed? **Grep** the button / its handler / its
  registration → it's still declared and wired at the fork-point.
- **Correct move:** report *"Export button already present and wired at the fork-point — verified it
  renders and fires; re-added nothing"* — a valid no-op — rather than adding a duplicate that breaks
  the build. Silently "re-adding" it on faith would have shipped the bug.

Second example — competing interpretations. Spec: *"Add caching to the report endpoint."* Readings:
(a) an HTTP response cache with a TTL; (b) an in-memory memoization of the expensive query;
(c) a per-user cache. They differ in correctness and invalidation. **Correct move:** name the three,
state which you'll do and why (or ask), instead of silently picking one and discovering later it
served stale per-user data.

## Anti-patterns

- Silently picking one interpretation of an ambiguous spec and hoping it's the intended one.
- Taking "restore / re-add X" on faith without grepping the current state first.
- Hiding confusion and guessing rather than naming what's unclear.
- Not flagging a simpler approach you noticed because "the spec said to do it this way."
- Presenting an unverified assumption as a confirmed fact.
- Asking about trivia you could have resolved by reading the code (over-asking is its own failure).

## Related skills

- [`reuse-before-create`](../reuse-before-create/SKILL.md) — the full verify-current-state-first drill
  for restore/revert/re-add tasks.
- [`simplicity-first`](../simplicity-first/SKILL.md) — the simpler approach you should surface and
  push for.
- [`verification-before-advance`](../verification-before-advance/SKILL.md) — turn a resolved
  assumption into a concrete success criterion, then prove it.
- [`karpathy-guidelines`](../karpathy-guidelines/SKILL.md) — bias 1 (think before coding), in context.
