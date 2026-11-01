---
description: Forge the grounded per-project skills — a <project>-mapping skill (always) and, where a spec corpus exists, a <project>-spec skill — plus a CLAUDE.md.
argument-hint: "[project-id] [--only mapping|spec]"
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit, Task, Skill]
---

Forge the per-project skills for **$ARGUMENTS** (default: the project described by `./PROJECT.yaml`).

Load `PROJECT.yaml` first, then invoke the adapt engine skills and follow their protocol end to end:

- **`codebase-mapping-forge`** (`${CLAUDE_PLUGIN_ROOT}/skills/adapt/codebase-mapping-forge/SKILL.md`) — **always.** It reads
  the project's code and forges a `<project>-mapping` skill: the system nouns (entities, services,
  endpoints, key types) each carried with **`file:line` evidence** or explicitly marked `UNVERIFIED`.
  A confident wrong name is worse than no skill.
- **`spec-style-forge`** (`${CLAUDE_PLUGIN_ROOT}/skills/adapt/spec-style-forge/SKILL.md`) — **only where a spec/doc corpus
  exists** (per `PROJECT.yaml` `spec.adapter`). It forges a `<project>-spec` skill capturing the
  team's spec-to-code conventions. If the corpus is thin, say so and skip it rather than inventing one.

Then:

1. Every forged skill must conform to `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md`: valid frontmatter, a triggering
   third-person `description`, least-privilege `allowed-tools`, the `mahoraga.grounding` field set to
   `file-line` or `counted`, and a `provenance` regenerate command. Keep `SKILL.md` under
   ~500 lines / 5k tokens; push deep material into `references/*` (one level deep) and determinism
   into `scripts/*`.
2. Run **`conformance-lint`** (`${CLAUDE_PLUGIN_ROOT}/skills/adapt/conformance-lint/SKILL.md`) on every forged skill — a
   skill that fails conformance does not ship. Mapping/spec skills additionally get the kind-specific
   lint (a names table with a mandatory evidence column + a regenerate command).
3. Generate a `CLAUDE.md` for the project that points at the forged skills and the GUARD pack.
4. **Surface every forged/edited file as a human-approved diff** — this is the approval gate. The
   forge is read-only on the team's repos; nothing lands without approval.

Prescription vs description: when a skill prescribes something the corpus only does half the time, say
so ("improves on observed practice") — never present a prescription as an observed convention.

Do not run the eval here — that is `/mahoraga-prove`.
