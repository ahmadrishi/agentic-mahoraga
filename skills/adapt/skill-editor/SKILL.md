---
name: skill-editor
description: Surgically modify a forged mapping or spec skill (a "<project>-mapping", a "<project>-spec", or a split mapping+spec pair from the adapt forges) to satisfy one change request — add / edit / remove / rename a system name, alias or trap, glossary term, template section, house-style rule, guardrail, or the skill's own description / trigger. Use when the user says "modify / edit / fix the <X> skill", "add a trap to the mapping skill", "update the house style", "rename status <X>". It makes a minimal diff, preserves everything else byte-for-byte, keeps the skill conformant, grep-verifies any new name against the repo (EXISTING / NEW / UNVERIFIED), re-runs the conformance gate, and reports the diff. HAND-OFF — it edits files locally, never publishes to a doc system or tracker, and never edits the project's repos. Do NOT use to forge a new mapping skill (that is codebase-mapping-forge) or spec skill (that is spec-style-forge), or to run the gate alone (that is conformance-lint).
allowed-tools: [Read, Grep, Glob, Bash, Edit, Write]
license: MIT
mahoraga:
  kind: meta
  grounding: none
---

# Skill editor — surgical edits to a forged skill

You surgically modify an existing forged skill on request. A good edit is a **minimal diff**: the one
thing asked for changes, **everything else is preserved byte-for-byte**, the skill stays **conformant**
(per `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md`), and the **conformance gate is green** before you report. You are a
maintenance tool for skills that [`codebase-mapping-forge`](../codebase-mapping-forge/SKILL.md) and
[`spec-style-forge`](../spec-style-forge/SKILL.md) created — you never forge a new skill, run a
`*-spec` / `*-mapping` skill, or touch the project's own code.

## Workflow

### Step 0 — Understand the request

Pin down three things before touching anything: **what** is changing (which concept — a name, an
alias/trap, a glossary term, a clarification question, a template section, a house-style rule, a worked
example, a DoD item, a phase, a guardrail, the description/trigger), **which project/module**, and the
**operation** (add / edit / remove / rename). If any of the three is ambiguous, ask before editing.

Then **locate the target skill directory(ies)** under the project's `.claude/skills/` (and the user's
global skills dir), and **detect the model from what exists on disk**:

- **A single `<project>-spec` holding all the speccing references** (no `<project>-mapping` sibling) —
  a **UNIFIED** skill. The full conformance-lint applies to it.
- **Both `<project>-mapping` and `<project>-spec` exist** — a **SPLIT** pair. Route the edit to the
  half that owns the concept: the **mapping half** owns the subsystem-map + glossary + reality-ledger
  (system names, statuses, routes, aliases/traps, glossary terms); the **spec half** owns everything
  else (sources, clarification-playbook, spec-template, house-style, worked-examples,
  definition-of-done). Each half carries only a partial manifest, so run the **kind-specific** lint on
  each half — never the unified lint (it false-fails on either half), and **never satisfy a lint
  complaint by adding the "missing" files to a half** (that duplicates facts and corrupts the split).

> Detect the model by the **directory pair**, not the local file set: a split *mapping half* looks like
> a unified skill with several files deleted. The give-away is the sibling `<project>-mapping` +
> `<project>-spec` pair on disk — check for it before you decide.

### Step 1 — Locate the file(s)

Find which file owns the thing to change (and, for a SPLIT pair, which half). **Before any rename, or
any removal of a name, grep the WHOLE skill first** — all of `references/`, `templates/`, and `SKILL.md`
— for every occurrence. A system name, a status, or a trap usually appears in several files (the map,
the glossary, a worked example, a guardrail, the template); missing one leaves the skill inconsistent.
Not yet written: the full concept→file change-map and per-operation editing recipes; for now grep and
reason.

### Step 2 — Edit surgically

Apply the change, preserving all surrounding content.

- **If the request contradicts grounded content, stop.** When Step 1's grep shows the requested change
  conflicts with what the skill already establishes (e.g. a "these two differ" trap for two tokens that
  are actually the same screen — a display label and its own route), do **not** ship it and do **not**
  silently substitute your own corrected version. Report the evidence (`file:line`), propose the
  correct edit, and ask before editing. **The lint checks structure, never truth — a wrong fact passes
  it.**
- **Propagate a rename to every occurrence** found in Step 1, including inside `templates/`.
- For a **system name being added**, grep the project repo to confirm it is real and mark it
  **EXISTING** (`file:line`) / **NEW** (proposed, does not exist yet) / **UNVERIFIED** (believed to
  exist, not found) — never invent one.
- Keep **exactly one H1** per file; keep the skill within `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md` budgets
  (SKILL.md < 500 lines / < 5k tokens; references one level deep). If you change sections in a long
  file, update its `## Contents` TOC.

### Step 3 — Verify

- **UNIFIED skill:** run `${CLAUDE_PLUGIN_ROOT}/scripts/conformance-lint.mjs` against the target skill dir (plus
  `--repo <repo>` for a mapping skill outside `<repo>/.claude/skills/`) — it must pass. Fix
  each violation **in place** and re-run until green — but never satisfy it by adding, removing, or
  renaming a manifest file.
- **SPLIT pair:** run the **kind-specific** lint on each half; do not run the unified lint on a half.
- In both cases, **grep for dangling cross-references** (`references/…` / `templates/…` paths that no
  longer resolve). If a name changed, **re-grep the project repo** to confirm its status.

### Step 4 — Hand off

Report the **diff** of exactly what changed, the **gate result**, and anything the user must confirm (a
name marked NEW/UNVERIFIED, an ambiguity you resolved, a rename that touched more files than expected).
**Never publish.**

## Guardrails

- **Minimal diff.** Preserve everything not asked to change — do not reformat, re-order, or "improve"
  untouched content.
- **Never invent a system name.** Grep the repo; mark it EXISTING / NEW / UNVERIFIED.
- **Never ship an edit that contradicts grounding.** If repo or in-skill evidence refutes the request,
  stop and confirm with the user — don't apply a wrong fact, and don't silently swap in a different
  one. The gate checks structure, not truth.
- **Never leave a dangling cross-reference** anywhere in the skill.
- **Always re-run the gate before reporting done** — the unified lint for a UNIFIED skill, the
  kind-specific lint per half for a SPLIT pair.
- **Hand-off only.** Edit the skill's files locally; never write to a doc system or tracker, and never
  edit the project repositories (`security.forge_read_only`).

## Related skills

- [`codebase-mapping-forge`](../codebase-mapping-forge/SKILL.md) / [`spec-style-forge`](../spec-style-forge/SKILL.md)
  — forge the skills this editor maintains.
- [`conformance-lint`](../conformance-lint/SKILL.md) — the structural gate Step 3 runs.
- [`skill-improvement-loop`](../../prove/skill-improvement-loop/SKILL.md) — routes eval-driven skill
  edits through this editor.
