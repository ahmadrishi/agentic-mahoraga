---
description: Legacy, in-sample, not evidence — re-run the FAILED units with the improved skills, on the same units the edits came from. For a held-out test use /mahoraga-loop.
argument-hint: "[project-id] [unit-id...]"
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit, Task, Skill]
---

Validate that **$ARGUMENTS**'s improved skills actually fix the units that failed (default: the
project in `./PROJECT.yaml`; all previously-failed units if none named).

Invoke the **`skill-improvement-loop`** skill (`${CLAUDE_PLUGIN_ROOT}/skills/prove/skill-improvement-loop/SKILL.md`), the
retest phase, reusing `sandbox-isolation` and `adversarial-review-loop`. For each named failed unit:

1. **Re-stage the unit** through `sandbox-isolation` with the **improved** skills, at the **same
   fork-point** as the original prove run.
2. **Decontaminate — mandatory, fail closed.** The improved skills were written from the findings, so
   they are the most likely to contain this unit's answer. Sanitize the derived skills (swap in each
   `SKILL.sanitized.md`) and run the leak gate; the answer-token count **MUST be 0** — checking both
   the curated tokens and the symbols auto-derived from the human diff — or the retest is open-book:
   abort and fix the sanitization first. Strip Mahoraga's own meta-skills per
   `${CLAUDE_PLUGIN_ROOT}/core/schema/STRIP_SET.manifest`.
3. **Re-implement blind** (a FRESH `general-purpose` subagent, never a fork; a neutral prompt matching
   the original), verify per-repo, and **re-score** through `adversarial-review-loop`.
4. Report **before → after** per unit: the fix holds only if the previously-`none`/`partial`
   criterion is now **`full` in the code result** — not merely that the skill reads better.

For any miss that reproduces, apply the **skill-gap vs spec-gap** classifier: if the spec itself
sanctions the wrong choice, hardening the skill only makes the miss *visible*, not fixed — name it a
spec-gap and route it to a spec fix. Use the write-it-down GATE pattern (grep the producer → state the
emit range → confirm the consumer's value falls inside it) before declaring a unit verified.

Record each retest outcome (fixed / reproduced / spec-gap / infra-stalled), and append any
newly-cleared unit's answer tokens to `PROJECT.yaml` `decontamination.answer_tokens`.
