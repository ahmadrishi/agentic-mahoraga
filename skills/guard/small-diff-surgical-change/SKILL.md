---
name: small-diff-surgical-change
description: Use when editing existing code — make the smallest diff that satisfies the request and touch nothing else. Every changed line must trace to the request; no reformatting, import reordering, taste-renaming, or "while I'm here" refactors; clean up only the orphans your own change created; and check the blast radius before editing a shared symbol. Do NOT use for whether the code you add is minimal/over-engineered (that is simplicity-first), for reusing an existing implementation (that is reuse-before-create), or for proving the change works (that is verification-before-advance).
allowed-tools: Read, Grep, Glob, Bash
license: MIT
mahoraga:
  kind: guard
  grounding: none
---

# Small Diff, Surgical Change

A change that does the task but *also* reformats the file, reorders imports, renames a variable for
taste, and refactors an adjacent function is a bad change even when the feature works. It inflates
the diff, buries the real edit from reviewers, and introduces regression risk in code nobody asked
you to touch. The discipline: **touch only what you must, and clean up only your own mess.** The
test that governs everything below — *every changed line traces directly to the request.*

## When it triggers

- Any edit to existing code (as opposed to a greenfield file).
- Large or unfamiliar files, where the temptation to "tidy while I'm here" is strongest.
- Any edit to a **shared** symbol (a util, a base class, a shared DTO/format function) — its callers
  are your blast radius.
- Whenever you notice adjacent code you'd write differently. Noticing is fine; rewriting it is not.

## The rule

1. **Touch only what the request requires.** If a line's change does not trace to the ask, revert it.
2. **Match existing style**, even if you'd do it differently. No reformatting, no import reordering,
   no brace-style or quote-style "fixes," no renaming for taste.
3. **Don't refactor what isn't broken.** If you spot unrelated dead code or a real bug, *mention it*
   in your notes — don't fix it silently in this diff.
4. **Clean up only YOUR orphans.** Remove imports / variables / functions that *your* change made
   unused. Leave pre-existing dead code unless the task is to remove it.
5. **Prefer the narrowest edit.** Editing a shared symbol changes *every* caller. Before you do,
   sweep the callers (`grep` the symbol) and confirm they all still behave — or make a narrower local
   change (branch at your call site, add an overload) instead of widening the shared one.
6. **Keep the diff reviewable:** small, single-purpose, one concern per commit. If two unrelated
   things must change, make two commits.

## Key points — honest about what the hook can enforce

This is the one GUARD row backed by a **hard block**. The pack ships
[`hooks/small-diff-gate.sh`](../../../hooks/small-diff-gate.sh) (auto-discovered via
[`hooks/hooks.json`](../../../hooks/hooks.json)) as a **PreToolUse** hook on `Write|Edit`. It
counts the *lines* a single tool call changes — for an `Edit`, the line count of `new_string` (the
text being added); for a `Write` that **overwrites an existing file**, the content's line count; a
`Write` that **creates a new file is always allowed** (a fresh file is not drive-by sprawl into
existing code). It compares that against `MAHORAGA_MAX_EDIT_LINES` (default 300). Behavior is set by
`MAHORAGA_SMALL_DIFF_MODE`:

- **`warn`** (the default): over the cap → exit 0 with a note on stderr. Advisory; the edit proceeds.
- **`block`**: over the cap → **exit 2, which unconditionally BLOCKS the tool call** (PreToolUse
  honors exit 2). This is a genuine hard gate — the only one in GUARD.

On malformed stdin the hook **fails open** (exit 0) — a guard must never wedge the session.

Even the hard block is only a **size proxy**. It cannot verify *semantic* traceability (that each
line maps to the request), cannot tell a legitimate large change from sprawl, and cannot see the
blast radius across callers. So treat a green gate as "this edit is under the line cap," nothing more.
The real mechanism is a **pre-commit diff review**: read your own diff line by line and delete
anything that does not trace to the ask, *before* you claim done.

Minimal *diff* is not the same as minimal *code* (→ [`simplicity-first`](../simplicity-first/SKILL.md)):
you can add a clean, minimal 5-line feature (good code) via a sprawling 200-line diff that also
reformats the file (bad diff). This skill governs the diff; that one governs the code.

## Worked example

Task: *"Add a null check to `chargeCard()` so it rejects a missing token."*

- **Bad diff (sprawl).** Add the guard, but also: reorder the imports "alphabetically," reformat the
  whole file to a different brace style, rename `amt` → `amount` throughout, and extract an unrelated
  helper. The reviewer now cannot tell the 3 load-bearing lines from the 180 cosmetic ones, and the
  rename touched a sibling method.
- **Good diff (surgical).** Add the 3-line guard and its one import. Diff is 4 lines. Every line
  traces to "reject a missing token." If `amt` genuinely bothers you, note it — don't rename it here.

Blast-radius example: your task needs new behavior for *one* caller of a shared `formatAmount()`.
Editing `formatAmount()` changes every screen that calls it. Instead, `grep` the callers, and either
branch at your call site or add `formatAmount(value, opts)` with a default that leaves existing
callers unchanged.

## Anti-patterns

- Reformatting / reordering imports in a file you only touched for one line.
- "While I was here" refactors bundled into a feature diff.
- Renaming symbols for taste.
- Deleting pre-existing dead code you didn't create (mention it instead).
- Editing a shared function for one case, silently changing all its callers.
- A 400-line diff for a 10-line requirement.
- Treating a green per-edit size hook as proof the diff is traceable — it only bounds size.

## Related skills

- [`simplicity-first`](../simplicity-first/SKILL.md) — minimal *code*; this is minimal *diff*.
- [`reuse-before-create`](../reuse-before-create/SKILL.md) — the blast-radius of widening a shared
  symbol is a shared concern; that skill covers "verify what you reuse."
- [`trace-to-consumer`](../trace-to-consumer/SKILL.md) — editing a shared display/format method for
  one case silently changes every consumer of it.
- [`verification-before-advance`](../verification-before-advance/SKILL.md) — prove the surgical change
  compiles and runs before you close.
- [`karpathy-guidelines`](../karpathy-guidelines/SKILL.md) — bias 3 (surgical changes), in context.
