---
name: simplicity-first
description: Use during any implementation task to write the minimum code that solves the actual problem and nothing speculative — no features beyond the ask, no abstraction for single-use code, no configurability/flexibility that wasn't requested, no error handling for impossible states. If you wrote 200 lines where 50 would do, rewrite it. Do NOT use for limiting the size of an edit to existing code (that is small-diff-surgical-change) or for reusing an existing implementation instead of building one (that is reuse-before-create).
allowed-tools: Read, Grep, Glob
license: MIT
mahoraga:
  kind: guard
  grounding: none
---

# Simplicity First

Models default to over-engineering: a speculative interface for one implementation, config for one
caller, a "flexible" framework for a one-off, error handling for states that cannot occur. Every one
of those is a cost you pay forever — more to read, more to test, more to break. The rule: **write the
minimum code that solves the stated problem, and nothing speculative.**

## When it triggers

- Any implementation task.
- The moment you feel the pull to add an interface / factory / strategy / config flag / generic
  layer "in case we need it later."
- When you've written a lot of code for a small requirement — stop and re-read it.
- When a spec over-asks (requests flexibility the real use has no consumer for) — push back.

## The rule

1. **Minimum code that solves the problem.** Solve the case in front of you, not an imagined family
   of cases.
2. **No features beyond what was asked.** No "while we're at it."
3. **No abstraction for single-use code.** One caller → inline it. Add the interface when the *second*
   real caller arrives (YAGNI), not in anticipation of it.
4. **No configurability / flexibility that wasn't requested.** A config flag with one value is a
   liability, not an option.
5. **No error handling for impossible scenarios.** Handle the inputs that can actually occur; don't
   guard against states the type system or upstream already rule out.
6. **The rewrite test.** If you wrote 200 lines and it could be 50, rewrite it. Ask: *"Would a senior
   engineer call this overcomplicated?"* If yes, simplify before you ship.

## Key points — what this is NOT

- **Not minimal *diff*** (→ [`small-diff-surgical-change`](../small-diff-surgical-change/SKILL.md)):
  that governs how much *existing* code you touch. This governs how much *new* complexity you invent.
  You can add clean minimal code via a sprawling diff, or a small diff that introduces a needless
  abstraction — the two disciplines catch different failures.
- **Not reuse** (→ [`reuse-before-create`](../reuse-before-create/SKILL.md)): reusing what exists is
  *usually* the simplest design, so run that search first — but "simple" can also mean writing three
  obvious lines rather than wiring up a heavy existing framework you don't need.
- Simplicity is not terseness or cleverness. Clear, boring, obvious code is the goal; a dense
  one-liner that hides intent fails this skill too.

## Worked example

Task: *"Store a user's preferred language."*

- **Over-engineered.** A `PreferenceProvider` interface, a `PreferenceProviderFactory`, a
  `PreferenceStrategy` enum, a caching layer, and a config flag to switch storage backends — for a
  single string on a single entity. Hundreds of lines, and every future reader must understand the
  indirection to change one field.
- **Simple.** One column (or field) + its getter/setter, read where the UI needs it. A dozen lines.
  When a *second* kind of preference actually appears with a real second consumer, introduce the
  abstraction then — it will be better-informed by two real cases than by zero.

Second example: *"Parse this one fixed internal CSV."* Over-engineered: a pluggable
format-detecting parser registry with a plugin SPI. Simple: split on the delimiter with the known
columns; add a real parser library only if the input format is actually variable.

## Anti-patterns

- Adding an interface / factory / strategy for a single implementation.
- Config flags, hooks, or extension points no requirement asked for.
- Handling inputs that cannot occur (defensive code against impossible states).
- Building a generic "framework" for a one-off task.
- 200 lines where 50 would do.
- Premature performance optimization with no measured problem.
- A dense, clever one-liner that hides intent (simple ≠ terse).

## Related skills

- [`small-diff-surgical-change`](../small-diff-surgical-change/SKILL.md) — minimal *diff* to existing
  code; this is minimal *new complexity*.
- [`reuse-before-create`](../reuse-before-create/SKILL.md) — the simplest code is often code you don't
  write because it already exists; run that search first.
- [`surface-assumptions`](../surface-assumptions/SKILL.md) — when a simpler approach exists, say so
  and push back on an over-asking spec.
- [`karpathy-guidelines`](../karpathy-guidelines/SKILL.md) — bias 2 (simplicity first), in context.
