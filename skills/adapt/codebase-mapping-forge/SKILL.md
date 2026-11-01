---
name: codebase-mapping-forge
description: Forge a grounded "<project>-mapping" skill from a codebase — the subsystem map, glossary and reality-ledger that say what things are really called in the running system, every name carrying file:line evidence or marked UNVERIFIED. Use when the user wants a mapping/vocabulary skill for a project, wants an agent to learn a codebase's real step names and statuses (routes and integrations are model-curated, not scanned), or to ground business terms before speccing. Always available — it reads code and needs no doc corpus, so it is the default adapt output and the grounding companion the spec skill uses. It fans out one mapper per repo, counts against the code, and audits its own claims before shipping. Triggers "map this codebase", "what is X really called", "build the mapping skill", "ground the names in code". Do NOT use to learn a team's spec-writing style (that is spec-style-forge), edit an existing mapping skill (that is skill-editor), or run the structural gate alone (that is conformance-lint).
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit, Task]
license: MIT
mahoraga:
  kind: meta
  grounding: none
---

# Codebase mapping forge

You are building a **skill that says what a project's systems are really called** — a
`<project>-mapping` skill — by reading the code, not by guessing. It is the **always-available** half
of adapt: it needs only a checkout, so it runs for every project, and its output is the grounding
companion that [`spec-style-forge`](../spec-style-forge/SKILL.md) delegates to.

**The thing that makes a mapping skill worth having is that every noun it teaches is a real, verified
name in the running system.** A skill that confidently asserts a wrong step name is worse than no
skill: it launders a hallucination into every downstream use of it. So this pipeline is built around
one idea: **ground every name in `file:line`, count don't estimate, then try to break your own work
before shipping it.** The dominant failure mode is not outright invention — it is *confident
restatement with the provenance, the denominator, or the exact bytes stripped out.* Nearly every rule
below puts one of those three back.

The forged skill conforms to `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md` (house shape, progressive disclosure, the
`mahoraga: {kind: mapping, grounding: file-line}` block, a `provenance:` regenerate command).

## What the mapping skill contains

A self-contained skill directory the team uses in any future conversation. Its natural contents:

| File | What it holds |
|---|---|
| `references/subsystem-map.md` | The vocabulary index — **scaffolded by `${CLAUDE_PLUGIN_ROOT}/core/lib/mapping_scan.py`** then curated: the canonical `name \| kind \| evidence` table (every row a `file:line` or `UNVERIFIED`) covering repo inventory · screens/routes · steps/states · **status enums (verbatim, complete)** · parameters · jobs · integrations, plus a ⚠️ **aliases & traps** section (display name vs identifier, near-duplicate names — the most expensive defect class) |
| `references/oracle-library.md` | The **behavioural-oracle floor** — **scaffolded by `${CLAUDE_PLUGIN_ROOT}/core/lib/oracle_scan.py`**: the `oracle \| expected \| tier \| evidence` table of real assertions mined from the repo's own tests, each WITNESSED at a `test-file:line`, stubs classified out, headed by the counted **Behavioural grounding:** denominator (real / total / files). A *different* table from `subsystem-map.md` (one fact, one home) — see [the behavioural-oracle floor](#the-behavioural-oracle-floor) below |
| `references/glossary.md` | Domain terms defined **operationally** (how the system computes the thing, not a dictionary gloss), each with evidence; where a term has a business meaning and a code meaning, give both |
| `templates/reality-ledger.md` | The grounding worksheet: business term → real name → kind → exists? → `file:line` evidence |
| `scripts/` (optional) | A thin wrapper so the map rebuilds in one command; the **canonical** regenerate command is `python3 ${CLAUDE_PLUGIN_ROOT}/core/lib/mapping_scan.py <repo> --lang <lang>`, which becomes the skill's frontmatter `provenance` |

`SKILL.md` is a short router (< 500 lines) whose Grounding step is the point of the whole skill. Keep
**one fact, one home** (every fact in exactly one file; others cross-link, never restate) and **one
level deep** (every reference links directly from the router).

### The deterministic grounding scan (do this first)

Before any curation, scaffold the names table with the stdlib scan `${CLAUDE_PLUGIN_ROOT}/core/lib/mapping_scan.py` — the
testable, no-LLM floor the whole skill stands on:

```
python3 ${CLAUDE_PLUGIN_ROOT}/core/lib/mapping_scan.py <repo> --lang <lang> --format md > references/subsystem-map.md
```

It walks the repo (git-tracked + unignored files in a work tree, minus build-artifact dirs; Python via stdlib
`ast`, TS/JS/Java/Go by pattern) and emits every **defined** name — functions, classes, methods,
`UPPER_CASE` constants, enums and their members, types — each with a real `file:line`, plus the
`Regenerate:` line that becomes the skill's `provenance` and a `Coverage:` line naming any recognised
language — or unparseable file — this run did not scan. That output is exactly the
`name | kind | evidence` table the mapping-kind lint validates, so the map is grounded *by
construction*: the scan cannot emit a name it did not read.

**If it exits 3** — the dominant or requested language has no extractor (UNSUPPORTED), the requested
one has no files, or the requested one is under 10% of the repo's source (PARTIAL) — do not
hand-write a table to fill the gap. Either scan the part it can read (`--lang <scannable language>
--allow-partial`, as the error suggests) and record the rest as unscanned in
`## Confidence and coverage`, or rerun with `--lang <lang> --allow-generic` and **audit every row**:
that grep skips keywords and common type/modifier words but is low precision (local variables and
build-script constants appear).

**Curate on top of the scan, never under it.** The scan gives verified defined names; you add what a
pure scan cannot — the ⚠️ aliases & traps, the operational glossary, the enum-completeness audit, and
the referenced-but-undefined integrations (marked `UNVERIFIED`). Curation may reorder, group and
annotate rows, but must never weaken an evidence cell: a row the scan grounded stays grounded. The
scan is deterministic (no timestamps/random), so re-running it to refresh the floor diffs cleanly.

### The behavioural-oracle floor

Names are not the only thing an agent guesses; it also guesses **what the code is supposed to do** —
and "there are tests" is not the same as knowing what they pin down. So scaffold a *second* grounded
table beside the names table — the behavioural-oracle library — from the repo's own tests with the
stdlib scan `${CLAUDE_PLUGIN_ROOT}/core/lib/oracle_scan.py`:

```
python3 ${CLAUDE_PLUGIN_ROOT}/core/lib/oracle_scan.py <repo> --lang <lang> --format md > references/oracle-library.md
```

It walks the repo's **test** files and emits, per test, one `oracle | expected | tier | evidence`
row: a real assertion becomes a **WITNESSED** oracle carrying the asserted literal in `expected` and
the `test-file:line` it was read at; a test with no concrete assertion (empty, `pass`, `assert True`,
existence-only matchers) is classified **STUB** and does not count. The table is headed by the
**Behavioural grounding:** line — `<real> real / <total> tests / <files> files (stubs: <stub>)`.

**That counted denominator is the honest measure of behavioural grounding — read it, don't skip it.**
A repo can be thick with test files and still ground very little real behaviour; the denominator is
what stops "there are tests" from being mistaken for "the behaviour is pinned down." Report it the
way you report the names count: with its population and denominator, never an estimate.

Keep it a **FLOOR**, exactly like the names scan:

- **Witnessed literals + `file:line` only.** A WITNESSED row is a literal the scan actually read in
  an assertion at a line it can point at — nothing inferred.
- **STUB is a counted absence, not a verdict.** It records "no real assertion found", not a judgement
  about test quality.
- **The interpretation stays agent-time.** The scan never writes what a test *proves*; that inference
  is authored by the agent at ticket time, against this floor, never baked into the skill.
- **A different table, its own home.** `oracle-library.md` sits *alongside* `subsystem-map.md`, does
  not replace it, and leaves the mapping-kind conformance lint unchanged — that lint still validates
  the names table, not this one (one fact, one home).

## Pipeline

```
Phase 0  Recon      — ONE repo tour by hand. Fix the territory before any fan-out.  ⛔ GATE
Phase 1  Map        — one mapper subagent per repo; deliverable is VOCABULARY with file:line
Phase 2  Converge   — resolve contradictions; count things yourself   ⛔ code beats analysis
Phase 3  Synthesise — write the mapping skill from verified content
         ══ FREEZE #1: snapshot + hashes. The audit reads the snapshot, not the live tree.
Phase 4  Verify     — adversarial claim audit against the snapshot; conformance-lint  ⛔ GATE
Phase 4b Fix        — apply findings per FACT, in one pass; re-snapshot (FREEZE #2)
Phase 4c Re-audit   — against snapshot #2, at most TWO rounds, then ship with open items named
Phase 5  Ship       — report + record what is known-unverified
```

Work in your **scratchpad**, not the team's repo. Expected subagent count for a normal run:
**1 mapper per repo, capped at ~3** — map the repos the project actually spans; do not fan out further.
Put this line in **every** brief: *"You are performing one bounded task for a larger pipeline. Do not
invoke a forge skill and do not spawn subagents of your own."* (this skill's own description is pushy
and self-triggering — the recursion guard matters).

## Phase 0 — Recon (do this yourself) ⛔ GATE

A wrong assumption here poisons every downstream mapper. For each repo the project spans (from
`PROJECT.yaml repos[]`): identify its territory — by package/route/table-name prefix or directory —
and confirm it is **checked out locally**. A slice of a monolith is common: scope every grep to the
slice and say so. Note the default branch and how current the checkout is. **Do not fan out** until you
can state, in one paragraph, which repos are in scope and how you will scope each one.

## Phase 1 — Map (one mapper per repo)

Fan out, one agent per repo. The deliverable is **vocabulary**: the real step names, statuses,
parameters, screens, tables, jobs, document types, enum values — **each with a `file:line`**. Rules
that make it trustworthy:

- **Start from the scan, enrich by hand.** Run `${CLAUDE_PLUGIN_ROOT}/core/lib/mapping_scan.py` on the repo first to
  scaffold the grounded `name | kind | evidence` table, and `${CLAUDE_PLUGIN_ROOT}/core/lib/oracle_scan.py` to scaffold the
  [behavioural-oracle floor](#the-behavioural-oracle-floor) (`references/oracle-library.md`);
  hand-grounding then begins where the scans stop (aliases, complete enum families, integrations),
  never by re-deriving what they already grounded, and never by inferring what a test proves.
- **Cite, don't summarize.** If it is going in the skill, it came from the code and you can point at
  the line. A summary is a receipt, not evidence.
- **Complete the enumerable families.** Status enums, step/state inventories and parameters go in
  **verbatim and complete**, with the shell command that regenerates them (verify the glob covers the
  whole tree; quote `--include` globs).
- **Flag aliases and traps hard.** Display name vs identifier, near-duplicate names, delegating
  aliases — the most expensive defect class.
- **Vocabulary shared with the platform layer** (forms, grids, workflow primitives) belongs in the map
  too, marked platform-wide.

## Phase 2 — Converge ⛔ code beats analysis

The mappers will disagree with each other and with your notes. **You** resolve it, and the code wins.

- **Code beats analysis.** A subagent's map is secondary evidence — if it asserts a route the router
  contradicts, the router is right. Verify any claim before you put it in the skill.
- **Count the things you assert.** If you are about to write "all", "every", or "8 of 11", run the
  count yourself with one line of `grep`. Never assert a count you did not run.
- **Never invent a name.** If you cannot find it, the skill says **"not found in code — verify before
  use"**. An honest gap beats a confident fabrication. Mark each name EXISTING (`file:line`) / NEW /
  **UNVERIFIED**.
- **No local checkout for a repo?** Its slice of the map is built from documentation and marked
  `UNVERIFIED` throughout, and the skill's grounding step becomes "verify against the running system or
  ask". Say plainly this is a materially weaker skill. The documentation-only degraded mode
  is not generalized yet.

## Phase 3 — Synthesise → FREEZE #1

Write the mapping skill's files from the verified content. **One fact, one home**; **one level deep**;
a `## Contents` TOC on any reference over ~100 lines; cite `file:line` on everything; mark the
unverified. **Prescription vs description:** where the skill instructs something the code does only
some of the time, label it *"improves on observed practice"* — never present a prescription as an
observed convention. Then **freeze**: snapshot the skill + record hashes; the audit reads the snapshot
so nothing moves under it.

## Phase 4 — Verify ⛔ GATE

1. **Adversarial claim audit.** A second agent (**not** the author) checks every factual claim against
   the code and reports `CONFIRMED / OVERSTATED / FALSE / UNSUPPORTED` with evidence. Brief it to be
   hostile; expect it to find defects — that is the healthy outcome, not a sign something broke.
2. **Conformance-lint (mapping-kind mode).** Run `node ${CLAUDE_PLUGIN_ROOT}/scripts/conformance-lint.mjs <skill-dir> --repo <repo>` — one `--repo` per repo for a multi-repo map (see
   [`conformance-lint`](../conformance-lint/SKILL.md)). Because the forged skill's frontmatter is
   `mahoraga: {kind: mapping, grounding: file-line}`, the linter selects its **mapping-kind mode**
   (real, not aspirational — it skips the spec-blueprint manifest and instead checks: the
   `name | kind | evidence` table exists in `SKILL.md` or `references/subsystem-map.md`; every data
   row's evidence matches `path:line` or is exactly `UNVERIFIED`; every `path:line` resolves under
   `--repo` to a real line carrying the row's name; a `Regenerate:`/`provenance` command is present;
   ≥3 data rows). It must pass before ship — a curated row whose evidence drifted fails here.

**Fix per fact, not per file.** For each finding, `grep -rF` the whole skill for the claim and fix
every instance — that one discipline prevents most second-round defects. **Gate:** do not ship while
any `FALSE` claim about a system name survives — those are the ones that turn into wrong code.
Convergence: apply everything (round 1), then only `FALSE` name/number/citation findings (round 2),
then **stop** — anything still open goes into the skill's `## Confidence and coverage` section as a
named, unresolved item. An honest partial skill is usable; one polished in an unbounded loop is just
expensive.

## Phase 5 — Ship

Report: where the skill is and its file inventory; audit numbers (claims checked, defects found,
defects fixed); and **what remains unverified**, plainly. Place the skill where the work happens — if
the project spans several repos, in their common parent so it is reachable from any of them; a skill in
the wrong directory is invisible. Offer the obvious next step: forge the spec skill on top of it with
[`spec-style-forge`](../spec-style-forge/SKILL.md), or run the mapping skill on a live lookup.

## Guardrails

- **Read-only on the team's code** (`security.forge_read_only`) — this pipeline never writes to the
  project's repos, tracker, or docs.
- **Never let a summary become evidence**, **never assert a count you did not run**, **never invent a
  name** — mark it EXISTING / NEW / UNVERIFIED.
- **Do not ship without the audit** and a green conformance-lint.

## Related skills

- [`spec-style-forge`](../spec-style-forge/SKILL.md) — the doc-corpus half; its Grounding phase
  delegates to the mapping skill this forge produces.
- [`skill-editor`](../skill-editor/SKILL.md) — surgically edit a mapping skill after it ships.
- [`conformance-lint`](../conformance-lint/SKILL.md) — the structural + mapping-kind gate this forge
  runs before shipping.
