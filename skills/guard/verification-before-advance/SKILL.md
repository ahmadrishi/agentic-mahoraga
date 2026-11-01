---
name: verification-before-advance
description: Use before claiming a task done or moving to the next step of a multi-step plan — turn the task into a verifiable goal, climb the highest verification rung you can actually reach (deps → typecheck → build → run → tests), and report UNVERIFIED with a reason when a rung is unreachable rather than guessing. Honest about hooks — the shipped PostToolUse check (hooks/verify-after-edit.sh) runs a fast per-file syntax check and SURFACES the result, but a PostToolUse hook CANNOT block (Claude Code ignores its exit code) and cannot certify that the behavior is correct, that the right check ran, or that tests really executed. Do NOT use for the exact words you close with once verified (that is honesty-vocabulary) or for whether the output reaches its reader (that is trace-to-consumer).
allowed-tools: Read, Grep, Glob, Bash
license: MIT
mahoraga:
  kind: guard
  grounding: none
---

# Verification Before Advance

"It should work" is not "it works." The failure this prevents is advancing — closing a task, or
moving to the next step — on the strength of a mental model instead of an executed check. The rule:
**before you claim done or advance, run the highest verification you can actually reach, and name
exactly what it proved.** And be honest that a hook can nudge this but cannot certify it.

## When it triggers

- After any source change, before you claim it works.
- Before closing a task, or advancing to the next step of a multi-step plan.
- When asked "did this work?" / "verify my change."
- When you are tempted to write "done," "tested," or "verified."

## The rule — turn the task into a goal, then climb the ladder

1. **State a verifiable goal up front.** "Add validation" → "write a check for invalid input, then
   make it pass." "Fix the bug" → "write a check that reproduces it, then make it pass." Weak criteria
   ("make it work") cannot be looped on and hide failure.
2. **Climb the verification ladder** and stop at the highest rung you can actually reach; then *name
   that rung* in your close:

   | Rung | Check | What it proves | What it does NOT prove |
   |---|---|---|---|
   | 0 | dependencies resolve / install | you can build at all | nothing about your change |
   | 1 | typecheck / static analysis (`tsc --noEmit`, `mypy`, compiler) | types line up | templates, wiring, behavior |
   | 2 | **build** (where one exists) | it compiles + links; the minimum bar | it does the right thing |
   | 3 | **run it / drive the path** | behavior for the case(s) you tried | untried cases; other stacks |
   | 4 | **automated tests execute and pass** | the asserted cases hold | only what the tests assert |

3. **If a rung is unreachable** (no network, no fixtures, no test harness, private registry), that is
   a **legitimate UNVERIFIED** — say so with the reason. Do **not** guess a green or fabricate a result.
4. **Close with the honesty vocabulary** (→ [`honesty-vocabulary`](../honesty-vocabulary/SKILL.md)):
   name the rung you reached; never write "tested" unless real tests actually ran.

## Producer↔consumer contract — the rung the build cannot climb

A build proves each side compiles in isolation; it can **never** prove that a downstream reader
consumes the value an upstream writer emits, because there is often no compile-time link across the
boundary. On any change spanning two sides of a contract (a shared attribute key, a value's
units/semantics, a detection condition), run the design-time contract check in
[`trace-to-consumer`](../trace-to-consumer/SKILL.md) **before** you close — two green builds do not
prove the two sides agree.

## Key points — honest about what the hook can and cannot do

This is the theme that keeps GUARD honest, so state it exactly. The pack ships
[`hooks/verify-after-edit.sh`](../../../hooks/verify-after-edit.sh) (auto-discovered via
[`hooks/hooks.json`](../../../hooks/hooks.json)) as a **PostToolUse** hook on `Write|Edit`.
It runs a *fast per-file syntax check* keyed on the file's extension — `.py` → `python3 -m
py_compile`, `.sh` → `bash -n`, `.json` → `json.load`, `.js`/`.mjs` → `node --check` (only when node
is present), anything else → prints `UNVERIFIED (no fast offline check for <ext>)` — and **surfaces**
that verdict on stderr. Then it **always exits 0**.

Why exit 0 always: **a PostToolUse hook CANNOT block.** Claude Code runs it *after* the tool has
already applied the edit and ignores its exit code (exit 2 is not honored, unlike PreToolUse). So this
hook is a **surfacing / reminder** mechanism, not a gate — it cannot stop you advancing, and it does
not run a full build. Even setting that aside, a syntax check **cannot**:

- verify you chose the *right* check for the change (a clean parse says nothing about behavior);
- verify the code is *correct*, only that this one file parses;
- verify that tests *actually executed* versus were stubbed or skipped;
- verify a cross-service / producer→consumer contract.

Those are model-judgment rungs. So verification-before-advance is **skill-prose plus a PostToolUse
surfacing check** — the discipline does the gating, the hook only reminds. Never treat a green hook as
proof the behavior is right; treat it as "this file parses," and climb the ladder above yourself.
(The one row of GUARD that IS a hard block lives elsewhere — see
[`small-diff-surgical-change`](../small-diff-surgical-change/SKILL.md)'s PreToolUse gate.)

## Worked example

Task: *"Fix the bug where a zero-amount charge is accepted."*

1. **Goal:** "reproduce a zero-amount charge being accepted, apply the fix, confirm it is now
   rejected." (verifiable, loopable)
2. **Climb:** typecheck ✓ (rung 1) → build ✓ (rung 2) → run the repro: a zero-amount charge now
   returns a validation error, a positive charge still succeeds ✓ (rung 3).
3. **Close:** *"SMOKE-VERIFIED — reproduced the zero-amount input, applied the guard, the path now
   rejects it and a valid charge still succeeds. Not exhaustively tested; no automated test added."*

Counter-example (overclaim): applying the guard, seeing the build pass, and closing *"done, the
validation works and is tested"* — no run, no test. The honest close is **BUILD-VERIFIED**, behavior
UNVERIFIED.

## Anti-patterns

- "It should work" / "this looks correct" as a close.
- Writing "tested" when no test ran, or adding a do-nothing stub and calling it verification.
- Skipping the build because "it's a one-line change."
- Treating a green PostToolUse hook (the file parsed) as proof the behavior is right — worse, treating
  it as a gate at all; it surfaces after the edit and cannot block.
- Guessing a result when a rung is unreachable instead of reporting UNVERIFIED with the reason.
- Advancing to step N+1 of a plan without checking step N met its criterion.

## Related skills

- [`honesty-vocabulary`](../honesty-vocabulary/SKILL.md) — the exact words you may close with once
  you know which rung you reached.
- [`trace-to-consumer`](../trace-to-consumer/SKILL.md) — the contract rung a build cannot climb.
- [`small-diff-surgical-change`](../small-diff-surgical-change/SKILL.md) — a small diff is faster and
  safer to verify.
- [`karpathy-guidelines`](../karpathy-guidelines/SKILL.md) — bias 4 (goal-driven execution), in context.
