<!-- Identity is defined once in branding.yaml; this file mirrors it. -->

# Emitted-SKILL.md schema (v0.1.0) — the contract, versioned

Every skill Agentic Mahoraga **ships** (the GUARD pack, the adapt/prove engine skills) or **forges**
(a `<project>-mapping` or `<project>-spec` skill) is a Markdown file with YAML frontmatter that
conforms to a single, versioned contract. This document is the **human-readable account** of that
contract and its versioning policy.

- **Normative source:** [`core/schema/SKILL.schema.md`](../core/schema/SKILL.schema.md). Where this
  doc and that file disagree, the schema file wins — this is the explanation, not the law.
- **The machine gate:** [`scripts/skill-schema-lint.py`](../scripts/skill-schema-lint.py) lints every
  `skills/**/SKILL.md` against the hard rules below and is wired into CI
  ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)). Exit 0 = all pass; exit 1 = any hard
  violation, with per-file verdicts printed. It runs over Mahoraga's own `skills/`; a forged skill
  in your repo is linted only if you run it there. The **container** gate for forged skills —
  [`scripts/conformance-lint.mjs`](../scripts/conformance-lint.mjs) — checks different things by kind:
  for a `spec` skill the blueprint (reference manifest, required sections, one-level references,
  resolved cross-links); for a `mapping` skill only the grounded names table's shape, evidence format
  and `Regenerate:` line, plus that every `path:line` resolves to a real line carrying the name — not
  that a claim is true. See the
  [`conformance-lint`](../skills/adapt/conformance-lint/SKILL.md) skill.

> **Current version: `0.1.0`.** The single source of truth is
> [`branding.yaml`](../branding.yaml) → `skill_schema_version`. Nothing hard-codes the number; code
> and docs mirror it from there.

The format is a **strict superset of Anthropic's Agent Skills format** — a Mahoraga skill is a valid
Claude Code skill unchanged. The extra fields all live under one optional `mahoraga:` block that a
plain Claude Code consumer ignores.

---

## 1. Frontmatter contract

```yaml
---
name: <lowercase-hyphen>          # REQUIRED
description: <one line>           # REQUIRED
allowed-tools: [Read, Grep, ...]  # RECOMMENDED (Mahoraga surfaces least-privilege explicitly)
license: MIT                      # optional
mahoraga:                         # optional — the Mahoraga extension block
  kind: guard | mapping | spec | meta
  grounding: file-line | counted | none
  provenance: <regenerate command>
---
```

### `name` — REQUIRED

| Rule | Why |
|---|---|
| Present. | It is the skill's identity. |
| ≤ 64 characters. | Anthropic format limit. |
| Matches `^[a-z0-9-]+$` (lowercase letters, digits, hyphens). | Portable, filesystem-safe, no surprises. |
| **Matches its folder name.** | The directory `skills/guard/reuse-before-create/` must hold `name: reuse-before-create`; a mismatch is how a rename silently orphans a skill. |
| Must **not** contain `anthropic` or `claude`. | Reserved. A forged skill named after the vendor misrepresents provenance. |

### `description` — REQUIRED

| Rule | Why |
|---|---|
| Present. | This is the **retrieval key** — Claude Code selects a model-invoked skill by matching the task to this line. |
| ≤ 1024 characters. | Anthropic format limit; a description longer than this is doing the body's job. |
| Third person, states **what** it does **and when** to use it. | "Run the structural gate that checks a forged skill…" not "This skill lints skills." |
| End with a `Do NOT use for … (that is <sibling-skill>)` router when a sibling exists. | Prevents the wrong skill firing when two are adjacent (e.g. mapping-forge vs spec-forge). |

### `allowed-tools` — RECOMMENDED (least privilege)

Optional in Anthropic's format; Mahoraga **recommends** it as the security posture
([`SECURITY.md`](../SECURITY.md) §2): a skill gets `Read`, `Grep`, `Glob` unless its job genuinely
needs more, and every broader capability (a `Bash` build step, a `Write`) is a **visible, reviewable
line**, not an implicit power. This is a convention, not an enforced default: `mahoraga init` writes
`security.default_allowed_tools: [Read, Grep, Glob]` into `PROJECT.yaml`, but no code applies it, and
no code applies it: the deterministic scan emits no frontmatter, and only `/mahoraga-adapt`'s instructions
ask the model to add a least-privilege `allowed-tools` — review it in the diff. The lint
**WARNs (does not fail)** if a `kind: guard` skill omits `allowed-tools`, because a behavioral gate
that can touch the tree without declaring it is a posture smell worth a human's eyes.

### `mahoraga:` block — optional

Ignored by plain Claude Code; read by Mahoraga's forges, lint, and staging. When the block is present:

- **`kind`** ∈ `{guard, mapping, spec, meta}` — a value outside that set is a hard violation.

  | `kind` | Meaning | Lifecycle |
  |---|---|---|
  | `guard` | A stack-agnostic behavioral discipline/gate. | Shipped; loads as a plugin skill, and `mahoraga install` copies it **unchanged** into other agents; never stripped from sandboxes. |
  | `mapping` | A forged `<project>-mapping` skill — the code-grounded vocabulary. | Forged per project; MUST be `grounding: file-line`. |
  | `spec` | A forged `<project>-spec` skill — the team's spec-writing style. | Forged where a doc corpus exists; MUST be `grounding: counted`. |
  | `meta` | An engine skill that describes the eval itself (adapt/prove machinery). | **Stripped from blind sandboxes** via [`core/schema/STRIP_SET.manifest`](../core/schema/STRIP_SET.manifest) — a meta-skill in a sandbox is a decontamination tell. |

- **`grounding`** ∈ `{file-line, counted, none}` — how the skill's factual claims are backed.
  A forged `mapping` skill is `file-line` (every system noun carries `path:line` evidence or is
  marked `UNVERIFIED`); a forged `spec` skill is `counted` (every frequency claim was counted over a
  named corpus, never estimated); engine and behavioral skills that assert no project facts are
  `none`. **Grounding is the point** — a confident wrong name is worse than no skill.

- **`provenance`** — the command that rebuilds this skill's facts (typically
  `python3 core/lib/mapping_scan.py <repo> --lang <lang>`), so the map can be regenerated and diffed.

---

## 2. Body — three-tier progressive disclosure

`SKILL.md` is a **router, not a manual**. The body is organized so a reader (human or model) pulls in
only the depth a task needs:

| Tier | Lives in | Entered how | Budget |
|---|---|---|---|
| **1 — the router** | `SKILL.md` | Always loaded when the skill fires. | **< 500 lines / < 5k tokens** (hard). |
| **2 — deep material** | `references/*.md` | Loaded **only when read** — linked from the router table. | One level deep (see below). |
| **3 — determinism** | `scripts/*` | **Run via bash — the code never enters context, only its output does.** | — |

**One level deep.** Every `references/*` file links directly from the `SKILL.md` router; a reference
reachable only through another reference is invisible to a reader who previews with `head`. **One
fact, one home:** each fact lives in exactly one file and others cross-link to it — never restate.

**House shape** (matches the studied skill library): thesis → when/rule → numbered steps → *Key types
& classes* → worked examples → anti-patterns → related skills. A reference file over ~100 lines opens
with a `## Contents` TOC.

**Grounding & honesty in the prose:**

- Every system noun a **forged** skill teaches carries `file:line` evidence or is explicitly marked
  `UNVERIFIED`.
- **Prescription vs description.** When a skill prescribes something the corpus does only some of the
  time, say "improves on observed practice" — never present a prescription as an observed convention.

---

## 3. The hard lint rules (what CI actually enforces)

[`scripts/skill-schema-lint.py`](../scripts/skill-schema-lint.py) walks `skills/**/SKILL.md` (CI runs it
on this repo's `skills/`; point it at a forged skill's parent directory to lint that), parses
frontmatter, and applies exactly these. A **hard violation** fails the build (exit 1); a **WARN** is
printed but passes.

| Check | Level |
|---|---|
| `name` present, ≤ 64 chars, `^[a-z0-9-]+$` | hard |
| `name` matches its folder | hard |
| `name` does not contain `anthropic` / `claude` | hard |
| `description` present, ≤ 1024 chars | hard |
| `mahoraga.kind` ∈ `{guard, mapping, spec, meta}` **when a `mahoraga` block exists** | hard |
| Body ≤ 500 lines | hard |
| `allowed-tools` present on a `kind: guard` skill | **WARN** |

The lint checks the **schema** (including the body-size budget), not the truth of a claim or the full
container. A grounded-looking but wrong name passes the lint (the forge's adversarial audit is what
catches that), and one-level/cross-link checks belong to `conformance-lint.mjs`'s spec mode. The forge
skills instruct the model not to ship a skill that fails **either** gate; nothing in code blocks the
write.

---

## 4. Versioning — semver on the contract

The schema is versioned with [Semantic Versioning](https://semver.org/); the current version is
`skill_schema_version: 0.1.0` in [`branding.yaml`](../branding.yaml). The version describes the
**contract**, not any single skill.

| Change to the contract | Bump |
|---|---|
| A rule removed, tightened so an existing valid skill becomes invalid, or a field's meaning changed | **major** |
| A new optional field, a new `kind`/`grounding` value, a WARN added, a rule relaxed | **minor** |
| Wording/clarification with no behavioral change to the lint | **patch** |

While the project is pre-1.0 (`0.x`), the minor slot carries breaking changes per semver's `0.x`
convention — but even pre-1.0 we **announce** a breaking schema change (below) rather than letting it
land silently, because forged skills live in users' repos.

### Forward-compatibility rule (extra fields are ignorable)

**A consumer that meets a field it does not know MUST ignore it, never error.** This is what lets the
schema grow without breaking old tooling:

- Plain Claude Code already ignores the whole `mahoraga:` block — that is the mechanism, applied
  recursively. A newer Mahoraga may add `mahoraga.confidence` or a new frontmatter key; an older lint
  passes the skill through untouched rather than rejecting it.
- Therefore **the lint only rejects a value it *does* understand and finds invalid** (a bad `kind`, a
  too-long `name`) — never the mere *presence* of an unrecognized key. A skill authored against a
  later minor version stays valid under an earlier lint of the same major.

This is why unknown-field tolerance is a **rule**, not a nicety: it is the contract that makes minor
bumps non-breaking.

---

## 5. Migration policy — moving between versions

When the schema bumps, forged skills already living in users' repos must not silently rot. The policy:

1. **A `major` bump ships a migration note** in [`CHANGELOG.md`](../CHANGELOG.md) under the release,
   stating exactly which rule changed and what an author must do (rename a field, add a required key).
   It also updates [`core/schema/SKILL.schema.md`](../core/schema/SKILL.schema.md) (the law) and this
   doc (the explanation) **in the same change** — the executable-surface discipline from
   [`SECURITY.md`](../SECURITY.md) §4 applies to the contract too.
2. **The lint stays honest about which version it enforces.** A skill written for a newer major is not
   silently "passed" by an older lint that cannot check the new rule — it is flagged for a lint
   upgrade. Forward-compatibility (§4) covers *added* fields, not *changed* rules.
3. **Re-forge over hand-migrate for grounded skills.** A forged `mapping`/`spec` skill's facts have a
   `provenance` command; the cheapest correct migration to a new schema is usually to **re-run the
   forge** (which emits the new shape and re-grounds every name against current code) rather than
   hand-edit the old file and risk a stale `file:line`. Hand-migration is for shipped GUARD/engine
   skills, which have no per-project facts.
4. **No auto-rewrite of a user's skills.** Mahoraga never rewrites a skill in a user's repo without a
   human-approved diff (SECURITY.md §3) — a schema migration is proposed as a diff like any other edit.

---

## 6. Related

- [`core/schema/SKILL.schema.md`](../core/schema/SKILL.schema.md) — the normative schema.
- [`scripts/skill-schema-lint.py`](../scripts/skill-schema-lint.py) — the CI gate for these rules.
- [`conformance-lint`](../skills/adapt/conformance-lint/SKILL.md) — the container gate for forged skills.
- [`docs/FORGING.md`](FORGING.md) — how a conforming `mapping`/`spec` skill is forged.
- [`branding.yaml`](../branding.yaml) — the one place `skill_schema_version` lives.
