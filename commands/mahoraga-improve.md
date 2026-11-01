---
description: Turn a prove run's findings into skill edits / new skills — cluster findings, fan out planners, adversarially review for best practice, surface diffs for approval, register for decontamination.
argument-hint: "[project-id] [run-dir]"
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit, Task, Skill]
---

> **Unmeasured.** Edits made here are a *session candidate*: this session can read the repo's whole
> history, including the answers to any ticket you might later test them on. Use **`/mahoraga-loop`**
> for an edit that is written by a contained proposer and kept only if a sealed held-out gate says so.
> A candidate from this command can still be measured (`mahoraga loop gate --candidate DIR`), but it
> is never promotable.

Improve **$ARGUMENTS**'s skills from its latest prove findings (default: the project in
`./PROJECT.yaml`, its newest run dir).

Invoke the **`skill-improvement-loop`** skill (`${CLAUDE_PLUGIN_ROOT}/skills/prove/skill-improvement-loop/SKILL.md`), the
findings→edits phase. In short:

1. Read the run's findings + aggregated scores (weakness flags: lost-context, hallucination,
   over-engineering, spec-fidelity). Cluster them.
2. **Fan out one planner per cluster** to propose **EDIT-an-existing-skill** (preferred — reuse before
   creating) or **NEW-skill** (only if nothing owns the concern; its `description` IS its trigger).
   **Deconflict** overlapping proposals — cross-reference, never duplicate.
3. **Adversarially review every proposed skill** for best practice: a triggering description, the
   right altitude, no bloat, valid frontmatter (per `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md`), resolved
   cross-links, and **examples grep-verified against the LIVE repo** — a grep-teaching skill must not
   contain a grep-disprovable example.
4. **Surface the skill diffs for human approval** (the approval gate). On approval, apply them, then
   re-snapshot + re-checksum the skill set. **Register every new/edited skill for decontamination** —
   add it to `PROJECT.yaml` `skills.derived_skills` and author its method-only `SKILL.sanitized.md` —
   so `/mahoraga-retest` cannot read back the answer you just wrote into the skills.

Do **not** validate here — that is `/mahoraga-retest`, which re-runs the failed units decontaminated.
A skill edit is not proven until the retest passes in code. Apply the **skill-gap vs spec-gap**
classifier: when the spec itself sanctions the wrong choice, hardening a skill only makes the miss
*visible*, not fixed — name it a spec-gap and route it to a spec fix rather than endless
skill-hardening, so the loop terminates honestly.
