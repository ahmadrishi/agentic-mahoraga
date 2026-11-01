---
name: spec-style-forge
description: Reverse-engineer how a team writes specifications for a project and package it as a "<project>-spec" skill. Use when the user wants a speccing or spec-writing skill for a project or team; wants an agent to learn how their team writes design docs / spec pages; wants to capture a BA's, PM's or tech writer's style as a skill; or asks to generate a skill from shipped tasks and their spec docs — even if they never say the word "skill". It harvests a two-sided corpus through the spec + tracker adapters, derives the template by counting, analyses author style, mines the clarification playbook, writes the skill (its Grounding phase delegating to the mapping skill), then checks it with a held-out test and an adversarial audit. DEGRADES without a corpus — needs finished specs to learn from and refuses when there are none. Do NOT use to map code names (that is codebase-mapping-forge), edit an existing spec skill (that is skill-editor), or run the structural gate alone (that is conformance-lint).
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit, Task]
license: MIT
mahoraga:
  kind: meta
  grounding: none
---

# Spec style forge

You are building a **skill that writes specs for a project**, by learning from that project's own
finished specs. The output is a `<project>-spec` skill whose **Grounding phase delegates to the
project's `<project>-mapping` skill** (from
[`codebase-mapping-forge`](../codebase-mapping-forge/SKILL.md)) — so it inherits verified names instead
of guessing them.

**This is the conditional half of adapt.** Unlike the mapping forge, it needs a *corpus* — a handful of
finished specs to learn from. Where a doc corpus exists it forges the spec skill; where it does not, it
**degrades or refuses** (below). The value is not prose about style — it is that **every claim about
the team's conventions was counted rather than guessed, and every noun is grounded in the mapping
skill.** The failure mode is *confident restatement with the provenance, the denominator, or the exact
bytes stripped out* — so: **harvest verbatim, count don't estimate, then try to break your own work
before shipping it.**

## Inputs

Ask for anything missing before starting — without exemplar specs there is nothing to learn from.

| Input | Required | Notes |
|---|---|---|
| Project / area name | yes | Becomes the skill name (`<project>-spec`). |
| Tracker source | if there is one | Read through the `tracker` adapter (`PROJECT.yaml tracker.adapter`) — never a vendor by name. |
| **~8–15 finished exemplar tasks** | yes | The finished artefact, not a draft. Ask for a spread of sizes; a corpus of only big tasks teaches the wrong length. **8 is the threshold** below which frequency claims stop being defensible. Fewer → the thin-corpus degraded mode. |
| Spec source | yes | Read through the `spec` adapter (`spec.adapter`: markdown \| issue-body \| confluence \| notion \| gdocs). `confluence` / `notion` / `gdocs` ship **text-extract-only (degraded)**; visual specs (Figma/Balsamiq) are out of scope and must be pre-transcribed. |
| The project's mapping skill | recommended | The grounding companion; if absent, run [`codebase-mapping-forge`](../codebase-mapping-forge/SKILL.md) first. |

## What the spec skill contains

A `<project>-spec` skill whose natural contents are: `sources` (how to read each system),
`clarification-playbook` (questions to pre-empt + a "not ready to build" readiness test),
`spec-template` (the section skeleton + per-section frequencies), `house-style` (how to write the
body), `worked-examples` (real input→output pairs, delta-annotated), `definition-of-done` (the gate
checklist, hard blockers marked), and a `spec-page-skeleton` template. Its **Grounding step delegates
to the mapping skill** rather than restating names. It conforms to `${CLAUDE_PLUGIN_ROOT}/core/schema/SKILL.schema.md`
(`mahoraga: {kind: spec, grounding: counted}`). Keep **one fact, one home** and **one level deep**.
Not yet written: a *cross-org* generalized recipe for these (a portable frequency-table format, reusable
style micro-rules, a shared clarification taxonomy) is genuinely deferred; each run derives them by
counting over its own harvested corpus (Phase 2) and cites the source — see the **Calibration /
self-re-measurement** section below for why per-run counting, not a baked-in taxonomy.

## Pipeline

```
Phase 0  Recon      — ONE task end to end, by hand. Fix both sides of the pair.  ⛔ GATE
         ══ BARRIER: the corpus scope is fixed here. No later claim about anything outside it.
Phase 1  Harvest    — corpus to disk, VERBATIM, in parallel (spec + tracker adapters)
         ══ BARRIER: nothing downstream may quote a source that is not on disk.
Phase 2  Analyse    — template survey (by counting) · style analysis · clarification mining
Phase 3  Converge   — resolve contradictions; count things yourself
Phase 4  Synthesise — write the spec skill; Grounding delegates to the mapping skill
         ══ FREEZE #1: snapshot + hashes. Verification reads the snapshot, not the live tree.
Phase 5  Verify     — held-out generation test + adversarial audit; conformance-lint  ⛔ GATE
Phase 5b Fix        — apply findings per FACT; re-snapshot (FREEZE #2)
Phase 5c Re-audit   — against snapshot #2, at most TWO rounds, then ship with open items named
Phase 6  Ship       — report + record what is known-unverified
```

Work in your **scratchpad**. Expected subagent count: **2–4 harvesters** (one per 3–4 tasks) + **~3
analysts** (template surveyor, style analyst, clarification miner). Recon and Converge are **yours** —
adjudicating between agents cannot be delegated. Put the recursion guard in **every** brief: *"You are
performing one bounded task for a larger pipeline. Do not invoke a forge skill and do not spawn
subagents of your own."*

## Phase 0 — Recon (do this yourself) ⛔ GATE

A wrong assumption here poisons every downstream agent. Take one exemplar task and walk it end to end.
Establish **the two sides of the pair**: the **input** (what the business handed over) and the
**output** (what the speccer produced) — the skill teaches the *transformation between them*. If you
cannot identify both sides, stop (degraded mode below). Two things the adapters must do that a naive
read misses:

- **Follow links, not just the description text.** A spec is sometimes attached to a unit with no
  mention in the body — the `tracker` adapter must resolve linked/remote artefacts, not only the
  description. Per-vendor link/short-link resolution lives in the adapter, not this skill.
- **Probe the tracker's own vocabulary before filtering.** Work-item types and workflow states vary;
  a wrong filter returns a **silent zero**. Derive the archive/superseded convention from the corpus;
  don't assume one.

**Gate.** Before fanning out, state in one paragraph: where inputs live, where outputs live, the
output's section skeleton, who writes them (and whether there is a dominant author), how you read each
system, and roughly how many finished specs exist **for this project** (counted from the tracker, which
is the only thing that scopes the corpus). Every blank must be answered — but "no dominant author",
"no single template", and "no local checkout" *are* answers that route you to a degraded mode.

## Phase 1 — Harvest the corpus (verbatim, to disk)

Fan out, one agent per 3–4 tasks. Non-negotiables — they are why the phase works:

- **Verbatim to disk.** Agents write files (`corpus/specs/<id>.md`, `corpus/inputs/<id>.md`,
  `corpus/tickets/<id>.md`); their prose reply is a receipt, not a deliverable. Summarising destroys
  the evidence the whole pipeline rests on. Read the **source**, not the rendering — rendered text
  normalises exactly the oddities (odd headings, template debris) you are here to capture.
- **Both sides of every pair, plus the discussion channel** — unit comments / review threads, wherever
  clarification happens. Every question a developer asked is a hole the spec should have closed.
- **Write incrementally** (save after each item), one browser tab per agent if a browser is needed.

## Phase 2 — Analyse (parallel)

1. **Template survey — by counting.** Derive the section skeleton across the corpus; report
   **frequencies, not impressions**, and **separate document genres** (a spec, a release note and an
   API reference must not be averaged together).
2. **Style analysis** — the input→output delta per pair, the micro-style rules (unit, naming, delta
   framing, tone, banned words, measured length ranges), and the author's typos with an explicit *do
   not reproduce* note.
3. **Clarification mining** — the catalogue of questions developers and QA asked, each with the real
   verbatim quote, grouped by kind; end with the "not ready to build" signature.

## Phase 3 — Converge

The analyses will disagree. **You** resolve it.

- **Count the things you assert.** If you will write "always"/"usually"/"8 of 11", run the count
  yourself over `corpus/specs/`. One line of `grep` beats a subagent's recollection.
- **Scope every statistic to its population.** "The template is used 50% of the time" (broad, mixed
  genres) and "used 11 of 11" (task specs only) can both be true — say which population each number
  describes.
- **Identify the target author before you count.** If several people write specs their conventions
  differ; averaging them manufactures a house style nobody writes. Decide whose style is the target,
  count within that population, and note the weaker variant as something to recognise, not imitate.
- **Names come from the mapping skill, not from prose.** A name in a shipped spec is not evidence the
  thing still exists — defer to [`codebase-mapping-forge`](../codebase-mapping-forge/SKILL.md)'s
  verified index.

## Phase 4 — Synthesise → FREEZE #1

Write the spec skill; its **Grounding phase delegates to the mapping skill**. **One fact, one home**;
**one level deep**; cite everything (source id, quote, or the mapping skill's `file:line`); **label
prescription vs description** where the skill prescribes what the corpus does < ~80% of the time. Leave
the worked-examples **calibration** section (how far the skill over-shoots the real author) as a
placeholder — it can only be filled from the held-out test. Then **freeze**: snapshot + hashes.

## Phase 5 — Verify ⛔ GATE

1. **Held-out generation test.** Pick a corpus task **not quoted anywhere in the skill** (grep to
   confirm). Give a fresh agent only the skill + that task's *inputs*, forbid reading its finished
   spec, and have it produce one. Diff against the real artefact yourself. This tests whether the skill
   *works* — do **not** patch the skill to fit one example; if the output is unrecognisable, diagnose
   which phase was wrong (usually the template survey or the author choice) and redo it.
2. **Adversarial claim audit.** A second agent (**not** the author) checks every factual claim against
   the corpus, the mapping skill, and the source systems, reporting `CONFIRMED / OVERSTATED / FALSE /
   UNSUPPORTED`. Expect defects in the tens — that is the healthy outcome.
3. **Conformance-lint.** Run `${CLAUDE_PLUGIN_ROOT}/scripts/conformance-lint.mjs` (see
   [`conformance-lint`](../conformance-lint/SKILL.md)); it must pass — a spec skill is validated by the spec-blueprint manifest (a dedicated per-half spec-kind lint is not built yet; see conformance-lint).

**Fix per fact** (`grep -rF` every corrected string across all files). **Gate:** do not ship while any
`FALSE` claim about a system name survives. Convergence: round 1 apply everything; round 2 only `FALSE`
name/number/citation findings on the files you touched; then **stop** and name anything still open in
`## Confidence and coverage`.

## Degraded modes and when to refuse

A smaller, honest skill beats a complete-looking, invented one. Each mode below is a *named* fallback
the skill must declare in `## Confidence and coverage`, not a silent quality drop.

- **Thin corpus (n < 8 finished specs).** Below eight, frequency claims stop being defensible, so
  **drop the frequency tables entirely** — no "50%", no "8 of 11". Do the style analysis anyway (the
  input→output delta is visible in even three pairs) and report shape as presence, not proportion
  ("observed in 3 of 4"); lean harder on the mapping skill for names. Say in the skill that the
  template is *observed, not measured*.
- **Attribution-ambiguous (thin corpus, or no dominant author).** With a thin corpus — or several
  authors and no clear majority — you **cannot separate one author's voice from a single spec's
  idiosyncrasy**. Flag every style rule as attribution-ambiguous rather than asserting a "house style":
  present it as *"a pattern in the specs seen"*, name whose specs it came from, and do not promote a
  lone author's habit into a team convention. This is the honest counterpart to Phase 3's "identify the
  target author before you count" when the population is too small to actually do so.
- **The ticket *is* the spec** (no separate spec artefact). The deliverable becomes a proposed
  description / final-state written *into the ticket*; the template survey collapses to the ticket's
  own fields; and the clarification playbook gets *more* valuable — it is now most of the value. Say
  plainly the skill teaches how to turn a ticket into a buildable spec, not how to match an exemplar.
- **No single template** — report it plainly, extract the small shared spine, and **propose** the rest,
  labelled as a proposal, never presented as an observed convention.
- **One doc space serving every project (contamination)** — **fence the corpus at the tracker**: the
  project's specs are exactly those linked from its units; a page not on that list may be quoted as
  context but never counted as this project's convention. Every statistic names its population.

⛔ **Refuse — no-corpus** (and say why) when there are **no finished specs and no author to learn
from**, or when the user wants it built from tickets alone with no code and no docs — the result would
be a formatting guide with invented nouns, the exact failure this pipeline exists to prevent. Do not
degrade past this line into invention. Name the smallest addition that would make it viable (usually
three finished specs + read access to one repo). Always write a `## Confidence and coverage` section
naming every degraded mode that applied. Not yet defined: the composition order when several of these modes
apply at once (which substitute wins, how the flags stack) is genuinely deferred; each mode here is
honest on its own.

## Calibration / self-re-measurement

The numeric constants in this skill are **single-corpus descriptive defaults, not universal laws** —
the `n < 8` frequency-table cutoff, the "~8–15 exemplar tasks", "one harvester per 3–4 tasks", the
"< ~80%" prescription-vs-description line. Treat them in two distinct ways:

- **Descriptive percentages — re-count every run.** Any figure the *forged* skill states about the
  team ("used 11 of 11", "80% open with a problem statement") must be counted afresh over *this*
  project's `corpus/specs/`, never copied from a prior run or from these defaults, and must name its
  population and denominator. A percentage inherited rather than recounted is a fabrication with a
  number on it.
- **Tuned decision thresholds — calibrate, don't recount.** The cutoffs that decide *behaviour* — n=8
  for dropping frequency tables, ~80% for the prescription/description label — are judgement calls
  fitted to one corpus. Re-counting this project's data does **not** validate them; only measuring
  outcomes across several orgs would. So carry them as flagged defaults: if one clearly misfits (say
  frequency claims still feel unsafe at n=10), record the misfit with evidence rather than silently
  moving the line. Cross-org calibration is out of scope here — name the misfit; do not invent a new
  threshold from a single corpus.

## Phase 6 — Ship

Report: where the skill is + its inventory; the held-out test result (what matched, where it diverged
in each direction); audit numbers; and **what remains unverified**, plainly. Offer the next step: run
the new skill on a live task.

## Guardrails

- **Read-only** on the team's code, tracker, and doc system (`security.forge_read_only`) unless the
  user explicitly asked for a publishing skill — the default is **hand off**.
- **Never let a summary become evidence**, **never assert a count you did not run**, **never invent a
  name** (defer to the mapping skill; mark gaps "verify before use").
- **Do not ship without the audit and the held-out test** — the generation test alone will not catch
  false claims (it produces plausible output *because* the skill is plausible), and the audit alone
  cannot tell you the procedure doesn't work.

## Related skills

- [`codebase-mapping-forge`](../codebase-mapping-forge/SKILL.md) — the always-available grounding
  companion this skill's Grounding phase delegates to.
- [`skill-editor`](../skill-editor/SKILL.md) — surgically edit the spec skill after it ships.
- [`conformance-lint`](../conformance-lint/SKILL.md) — the structural + spec-kind gate this forge runs
  before shipping.
