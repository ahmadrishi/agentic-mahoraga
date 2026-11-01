---
name: conformance-lint
description: Run the structural gate on a forged or edited skill before it ships. Use when a forged skill was just written or edited, or before it ships. For a mapping skill it checks the grounding key, the name | kind | evidence table (≥3 rows, each evidence a path:line or UNVERIFIED), a Regenerate line, and that every path:line resolves to a real line carrying the name; for a spec skill, the blueprint layout, description, references and cross-links. It runs scripts/conformance-lint.mjs (executed, not loaded) and reports PASS or the exact violations. It checks the CONTAINER and that cited evidence exists, never the truth of a claim — a wrong fact on a real line passes. Triggers "run conformance-lint", "does this skill pass the gate", "is this skill shippable". Do NOT use to forge a skill (that is codebase-mapping-forge / spec-style-forge), to edit one (that is skill-editor), or to verify a claim is factually correct (that is the forge's adversarial audit).
allowed-tools: [Read, Grep, Glob, Bash]
license: MIT
mahoraga:
  kind: meta
  grounding: none
---

# Conformance lint — the structural ship gate

Every skill Mahoraga forges or edits must pass this gate before it ships. It is a **structural** check
against `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md`: it verifies the *container*, and it says nothing about whether a
claim inside the skill is true — **a wrong fact passes the lint** (for a mapping skill it does check
that every cited `path:line` exists inside the repo and carries the row's name, so evidence pointing
at a missing file or line fails — it proves the name is on that line, not that it is defined there). Truth is the job of the forge's
adversarial audit; conformance is the job of this gate. A skill that fails conformance does not ship.

Run it as a script — **executed, never loaded** (its code never enters context, only its output does):

```
node ${CLAUDE_PLUGIN_ROOT}/scripts/conformance-lint.mjs <path-to-skill-dir> [--repo <repo-root>]...
```

Give it an absolute (or cwd-relative) path to the **target** skill directory. For a mapping skill,
`--repo` is the directory the evidence paths are relative to (where the scan ran) — repeat it once
per repo for a multi-repo map. Without it, the root is the directory holding the skill's `.claude/`
(right for a skill forged into `<repo>/.claude/skills/`, including a monorepo package), else the
nearest git root; with neither, the lint fails rather than skip the check. It exits 0 and prints a
PASS line only if every structural rule holds; otherwise it lists the violations and exits non-zero.

## When to run it

- **In the forges' shipping gate** — [`codebase-mapping-forge`](../codebase-mapping-forge/SKILL.md) and
  [`spec-style-forge`](../spec-style-forge/SKILL.md) run it in Phase-4/5 Verify, after the freeze, before
  ship.
- **In [`skill-editor`](../skill-editor/SKILL.md)'s Step 3** — after any edit, before hand-off.
- **In [`skill-improvement-loop`](../../prove/skill-improvement-loop/SKILL.md)** — on any forged skill a
  proposed edit touched.

## Two modes, selected by `mahoraga.kind`

The linter reads the SKILL.md frontmatter `mahoraga.kind` and runs **one** of two modes — never both:

| `mahoraga.kind` | Mode | What runs |
|---|---|---|
| `mapping` | **mapping-kind** | the grounded names-table checks below; the 8-file spec-blueprint manifest is **skipped** |
| anything else (`spec`, `meta`, `guard`, absent) | **spec-blueprint** | the full container check below — the fixed 8-file, split-by-read-trigger manifest |

Both modes are dependency-free Node stdlib: each exits 0 with a `CONFORMANCE PASS` line (the mapping
mode appends `(mapping)`) or lists violations and exits 1, and neither judges truth (see below). This
is what lets a mapping skill pass; without it, a mapping skill would be forced through the spec-blueprint path and fail.

## Spec-blueprint mode — the container check

The default mode (any non-`mapping` kind). Against `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md`:

- **Frontmatter validity** — `name` is lowercase-hyphen (`[a-z0-9-]`, ≤ 64 chars), **matches the folder
  name**, and does **not** contain the reserved words `anthropic` / `claude`; `description` is present,
  third person, and ≤ 1024 chars; `allowed-tools`, if present, parses; the YAML parses.
- **Size budget** — `SKILL.md` is **< 500 lines / < 5k tokens** (it is a router, not a manual); deep
  material belongs in `references/*`, determinism in `scripts/*`.
- **One H1 per file** (fence-aware) — a reference file must have exactly one H1 title; a template may
  have at most one. Zero and two both fail.
- **References one level deep** — every reference links directly from the `SKILL.md` router table; no
  reference is reachable *only* through another reference (nesting makes a reader preview with
  `head` and miss content).
- **Resolved cross-links** — every `references/…` / `templates/…` path (in `SKILL.md`, references, and
  templates) and every in-page `## Contents` anchor resolves to something that exists; no stale
  pre-rename filename survives anywhere.
- **Manifest hygiene** — the skill root holds only `SKILL.md` + `references/` + `templates/` (+ optional
  `scripts/`); a stray file beside `SKILL.md` fails.
- **TOC when long** — any reference file over ~100 lines opens with a `## Contents` list.

## Mapping-kind mode — the grounded names table

When `mahoraga.kind: mapping`, the linter runs these checks **instead of** the spec-blueprint manifest
(a mapping skill has no 8-file manifest, so the blueprint path would wrongly fail it). Per
`${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md` and the mapping format contract:

- **Frontmatter** carries `mahoraga.kind: mapping` **and** `mahoraga.grounding: file-line`.
- **A names table exists** — in `SKILL.md` or `references/subsystem-map.md` (both locations are
  checked) — whose header row is `name | kind | evidence`, in that order.
- **Every data row is grounded** — its `evidence` cell is a `path:line` (the path may contain spaces) **or** is
  exactly `UNVERIFIED`. Each offending row is reported by name; a blank or free-text evidence cell
  fails, because a confident wrong name is worse than no skill.
- **Every `path:line`, in every names table, resolves** under some root: the file is source inside
  the root (symlinks resolved; never the skill's own files or anything under `.claude/`), the line
  exists, and the row's name appears on that line as a whole identifier — the last identifier of the
  name cell's first word (`Ledger.post` → `post`; anything after the first word is annotation and
  never counts). Up to 10 offenders are reported by name. With no root, this is a violation — the
  lint never silently skips the check. A name that only appears in a comment or string on that line
  still passes: the check proves presence, not definition. Only markdown tables in `SKILL.md` and
  `references/subsystem-map.md` are read (near-miss headers such as `**evidence**` count; HTML tables
  and other reference files do not).
- **A regenerate command is present** — a `Regenerate:` line in the table file, or a `provenance` key
  in the frontmatter, so the map can be re-derived (typically `python3 ${CLAUDE_PLUGIN_ROOT}/core/lib/mapping_scan.py …`).
- **At least 3 data rows** — a real map, not a stub.

The **mapping** half has its own per-half lint (this mode); the **spec** half is still checked
by the unified spec-blueprint manifest above. Not yet built: a dedicated per-half spec-kind lint (splitting
the 8-file blueprint into a leaner spec-fragment check) is deferred — today a spec skill is validated
by the blueprint manifest it already conforms to.

## What it does NOT check

- **Truth.** A grounded-looking but wrong name passes — verify facts with the forge's adversarial audit.
- **One-fact-one-home.** Non-duplication across files is mandatory but not machine-checkable; a human
  enforces it during synthesis and review.

## Related skills

- [`codebase-mapping-forge`](../codebase-mapping-forge/SKILL.md) / [`spec-style-forge`](../spec-style-forge/SKILL.md)
  — forge the skills this gate checks.
- [`skill-editor`](../skill-editor/SKILL.md) — runs this gate after every edit.
