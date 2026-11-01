---
name: honesty-vocabulary
description: Use whenever reporting status, closing a task, or writing a PR/commit summary — pick the word that matches the evidence you actually have. Close with BUILD-VERIFIED (it compiles), SMOKE-VERIFIED (you ran the path and it produced the expected result), or UNVERIFIED (you could not reach a verifying rung — say why); never write "tested" / "the tests pass" unless a real test suite actually executed and passed. Do NOT use for HOW to verify or which rung to climb (that is verification-before-advance) or for confirming the output reaches its reader (that is trace-to-consumer).
allowed-tools: Read, Grep, Glob, Bash
license: MIT
mahoraga:
  kind: guard
  grounding: none
---

# Honesty Vocabulary

The word you use to describe your confidence is itself a claim. Using a stronger word than your
evidence supports is the most damaging thing you can do in a harness whose entire value rests on
*trustworthy measurement* — a false "tested" poisons every downstream decision. The rule: **pick the
word that matches the evidence, and never "tested" unless tests ran.**

## When it triggers

- Any status report, task close, PR description, or commit summary.
- Any moment you are about to write "tested," "verified," "works," or "done."
- When a verifying rung was unreachable and you must state a result honestly.

## The vocabulary

Use exactly these close-verdicts; each names what you *actually* did:

- **BUILD-VERIFIED** — it compiles / typechecks / builds. Says **nothing** about behavior. Name the
  rung ("BUILD-VERIFIED, rung 2, build config X").
- **SMOKE-VERIFIED** — you ran it and drove the specific path; it produced the expected result for
  the case(s) you tried. **Not exhaustive** — say which case.
- **UNVERIFIED** — you could not reach a verifying rung (no deps / network / fixtures / harness).
  **Say why.** This is a legitimate, honest verdict, not a failure to hide behind vague confidence.
- **CONTRACT-CHECKED** *(supplementary, not a standalone close)* — for a coordinated
  producer→consumer change, you grepped the producer and confirmed it emits a value the consumer's
  condition can match (→ [`trace-to-consumer`](../trace-to-consumer/SKILL.md)). Add it *alongside* a
  build/smoke/unverified verdict; it does not replace one.

## Forbidden unless literally true

- **"tested" / "the tests pass" / "test coverage"** — ONLY when a real test suite actually executed
  and passed. A stub that asserts something trivial (e.g. "the object was created") is **not** a test.
  Do not add a hollow test to license the word.
- **bare "verified"** — always qualify with the rung (BUILD-/SMOKE-).
- **"works" / "done" / "fully working"** — replace with the rung word; they overclaim by default.

## Key points — the one GUARD row with a code backing

Honesty-about-limits is the GUARD row that is genuinely **hard-gate-backed**: the verify adapter
emits a **machine verdict** (build success / not-applicable) from a grepped success marker — not from
a wrapper exit code it could misread — and the adapter contract makes the honesty verdict
**mandatory** (never imply tests ran when they did not). So the *verdict source* is a code gate; the
*word you type in prose* is still your discipline. **Never let the prose outrun the adapter's
verdict** — if the adapter says build-only, your close is BUILD-VERIFIED at most.

Note the boundaries: real test execution in a history-free / sandboxed environment needs provisioning
(deps, network, fixtures, a database) and is often absent — which is exactly why UNVERIFIED is a
first-class, respectable verdict here rather than an admission of failure.

## Worked example

- **Build passed, you didn't run it:** *"BUILD-VERIFIED (rung 2). Behavior UNVERIFIED — I did not run
  the path; no test added."* — not *"Tested and working."*
- **Registry / deps unreachable:** *"UNVERIFIED — could not install dependencies (private registry
  unreachable), so no verification rung was climbable. The change is a 3-line guard; please build
  once deps resolve."* — the correct honest close, **not** a reason to guess a green.
- **Ran the happy path only:** *"SMOKE-VERIFIED — the valid case renders and submits; error and empty
  cases UNVERIFIED."* — scope the claim to what you exercised.

## Anti-patterns

- Writing "tested" when only the build ran.
- "Fully working" / "done" with no rung named.
- Hiding an UNVERIFIED behind vague confidence ("should be fine").
- Adding a do-nothing test purely to justify the word "tested."
- Calling a passing typecheck "verified" (it's BUILD-VERIFIED at most, and only for types).
- Letting a PR summary claim more than the verify adapter's machine verdict supports.

## Related skills

- [`verification-before-advance`](../verification-before-advance/SKILL.md) — HOW to earn each word:
  the ladder of rungs and when a rung is unreachable.
- [`trace-to-consumer`](../trace-to-consumer/SKILL.md) — the source of the CONTRACT-CHECKED note.
- [`karpathy-guidelines`](../karpathy-guidelines/SKILL.md) — bias 4 closes with a verdict you can defend.
