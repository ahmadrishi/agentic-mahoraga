<!-- Identity is defined once in branding.yaml; this file mirrors it. -->

# Forging (ADAPT) — how Mahoraga turns your code and specs into grounded skills

**ADAPT** is the per-project half of the wheel: it *forges* skills that teach an agent what a
project's systems are **really called** and how that team **writes specs** — grounded in the code and
the corpus, not guessed. The real path is the agentic [`/mahoraga-adapt`](../commands/mahoraga-adapt.md)
command; underneath it a **deterministic scan** grounds the names table so those facts are testable,
not model-authored. Everything the model adds on top (aliases, glossary, enum families, integrations,
the audit) is model-instructed and unchecked by code.

There are two forges. One is universal; the other is conditional.

| Forge | Output | Availability | `mahoraga.kind` / `grounding` |
|---|---|---|---|
| **Mapping forge** ([`codebase-mapping-forge`](../skills/adapt/codebase-mapping-forge/SKILL.md)) | `<project>-mapping` skill — the subsystem map, glossary, reality-ledger | **always** — it reads code, needs no docs; the default adapt output | `mapping` / `file-line` |
| **Spec forge** ([`spec-style-forge`](../skills/adapt/spec-style-forge/SKILL.md)) | `<project>-spec` skill — the team's spec-writing style, template, clarification playbook | **only where a spec corpus exists**; degrades or refuses otherwise | `spec` / `counted` |

The spec forge's Grounding phase **delegates to the mapping skill** — it inherits verified names
rather than re-deriving them, so the two compose: map first, spec on top.

---

## The one idea both forges are built around

> **Ground every claim, count don't estimate, then try to break your own work before shipping it.**

A skill that confidently asserts a wrong step name is **worse than no skill** — it launders a
hallucination into every downstream use. The dominant failure mode is not outright invention; it is
*confident restatement with the provenance, the denominator, or the exact bytes stripped out.* Every
discipline below puts one of those three back:

- **`file:line` grounding.** Every system noun a forged mapping skill teaches carries `path:line`
  evidence, or is explicitly marked `UNVERIFIED`. A summary is a receipt, not evidence — cite the line.
- **Count, don't estimate.** Before writing "all", "every", "8 of 11", or any percentage, **run the
  count yourself** with one line of `grep` over the actual tree/corpus. A number you did not run is a
  fabrication with a number on it. Every statistic names its **population and denominator**.
- **Audit discipline.** After a freeze, a **second agent — not the author** — audits every factual
  claim against the code/corpus and reports `CONFIRMED / OVERSTATED / FALSE / UNSUPPORTED`. The forge
  does not ship while any `FALSE` claim about a system name survives. Fix **per fact** (`grep -rF` the
  claim across all files, fix every instance), converge in **at most two rounds**, then ship with any
  open item named in `## Confidence and coverage`. An honest partial skill is usable; one polished in
  an unbounded loop is just expensive.

---

## The mapping forge — always available, code-grounded, cross-language

The mapping skill exists so an agent stops guessing your real names. Its grounding floor is a
**deterministic, no-LLM scan** — [`core/lib/mapping_scan.py`](../core/lib/mapping_scan.py):

```
python3 core/lib/mapping_scan.py <repo> --lang <lang> --format md > references/subsystem-map.md
```

The scan walks the repo (skipping build-artifact directories via
[`lang_profiles`](../core/lib/lang_profiles.py) — the single source of truth shared with the
decontamination gate) and emits **defined** names — functions, classes, methods, `UPPER_CASE`
constants, enums and their members, types — each with a real `file:line`, plus the `Regenerate:` line
that becomes the skill's `provenance`. It does not extract routes, annotations, schemas or config. It
is **deterministic** (no timestamps, no randomness; sorted walk, stable sort) so re-running it to
refresh the floor diffs cleanly.

**Cross-language — five languages, one per scan.** Per-language extractors live in
[`mapping_extractors`](../core/lib/mapping_extractors.py):

- **Python** via stdlib `ast` — the most complete.
- **TypeScript / JavaScript** by pattern — **exported** declarations and exported-enum members only
  (no class methods, no non-exported names).
- **Java** by pattern — `public`/`protected` types and methods plus enum constants (no fields or
  `static final` constants).
- **Go** by pattern — funcs, methods, types, exported `const`/`var`.
- **Anything else** makes the scan **exit 3 (UNSUPPORTED)** with the reason on stderr. A
  keyword-filtered generic grep runs only when you ask for it (`--lang <lang> --allow-generic`), over
  that language's own file extensions; it skips keywords and common type/modifier words (no `val`,
  `mut`, `int`, `class` or `com` as names) but is low precision — local variables and build-script
  constants appear — so every row needs an audit, and the map says so on its `Coverage:` line.

`--lang` auto-detect counts every recognised source extension (Kotlin, Rust, C#, Ruby, PHP … as well
as the five; TS and JS as one family; generated dirs such as `node_modules`, `coverage`, `.next`,
`build` pruned) and takes the most frequent, a tie going to the language it cannot read. Support
languages — shell, SQL, Terraform — are listed but never decide what a repo is. So a Kotlin repo with
a few `.py` or `.mjs` helpers fails loud instead of being mapped as Python or JavaScript, and the
error suggests the `--lang` (and `--allow-partial`, when needed) for the part it can read. An explicit
`--lang` under 10% of the repo's application source exits 3 (PARTIAL) unless `--allow-partial` is
passed — so a Java backend in a Java + Angular repo scans directly, but the one `.java` file in a
Kotlin app does not; a `--lang` with no source files exits 3. In a git work tree the scanners read only
tracked and untracked-but-not-ignored files, so gitignored build output neither counts nor gets
mapped; outside git they prune never-source dirs by name (`node_modules`, `coverage`, `.venv` …). One language per scan: the other recognised languages, and any
file that failed to parse (skipped, never mapped by a fallback), are listed on the map's `Coverage:`
line and in a stderr NOTE.

For the five supported languages the scan cannot emit a name it did not read, so **that table is
grounded by construction**. The agentic layer then **curates on top, never under**: it adds the
aliases & traps, the operational glossary, complete enum families, and the referenced-but-undefined
integrations (marked `UNVERIFIED`). Curation may reorder and annotate rows but must never weaken an
evidence cell — a rule the model follows; the lint re-checks only that each cited line exists and
carries the row's name.

Then: freeze → adversarial claim audit (model-instructed) →
[`conformance-lint`](../skills/adapt/conformance-lint/SKILL.md) in **mapping-kind mode** (a names table
with a mandatory evidence column, every row `path:line` or `UNVERIFIED`, a regenerate command, ≥ 3
rows, and every `path:line` resolving to a real line that carries the row's name) → ship.

> **Portability status.** The deterministic scan produces a
> lint-passing, `file:line`-grounded names table on a **Python repo it has never seen**
> (`tests/mapping_forge_python_test.sh`, which scaffolds a throwaway Python repo).
> The full agentic forge (`/mahoraga-adapt`) has no committed run. **No local checkout** for a repo is
> meant to be a *named degraded mode* (built from documentation, marked `UNVERIFIED` throughout) — it
> is not built in the forge skill.

### The behavioural-oracle floor

Grounded names stop an agent guessing what things are *called*; they do not stop it guessing what the
code is supposed to *do*. So the mapping forge scaffolds a second grounded table beside the names
table — the **behavioural-oracle library** — from the repo's own tests, with the stdlib scan
[`core/lib/oracle_scan.py`](../core/lib/oracle_scan.py):

```
python3 core/lib/oracle_scan.py <repo> --lang <lang> --format md > references/oracle-library.md
```

Per test it emits one `oracle | expected | tier | evidence` row: a real assertion becomes a
**WITNESSED** oracle carrying the asserted literal and the `test-file:line` it was read at; a
non-trivial assertion with no extractable literal is also counted WITNESSED, with `<computed>` in place
of the literal. A test with no concrete assertion (empty, `pass`, `assert True`, existence-only
matchers) is classified **STUB** and is not counted. The table is headed by the counted **Behavioural
grounding:** denominator — `<real> real / <total> tests / <files> files (stubs: <stub>)`. Test
extraction covers the same five languages as the names scan; on any other dominant language it
exits 3 (UNSUPPORTED) instead of reporting `0 real / 0 tests / 0 files`. A zero still means only "no
tests found in the scanned language": tests written in a different, unscanned language (Kotlin tests
for Java code) are not counted, and the `Coverage:` line names that language.

**That denominator is the honest measure of behavioural grounding.** "There are tests" is not the same
as knowing what they pin down — a repo can be thick with test files and still ground very little real
behaviour. Like every other statistic the forge states, it names its **population and denominator**
rather than estimating.

It is a **FLOOR**, exactly like the names scan: witnessed literals + `file:line` only, STUB as a
*counted absence*, and **no inference about what a test proves** — that interpretation stays with the
agent at ticket time, never baked into the skill. `oracle-library.md` sits *alongside*
`subsystem-map.md` (one fact, one home) and leaves the mapping-kind conformance lint unchanged (it
still checks the names table, and nothing checks the oracle rows). Downstream, `verify/command.sh`
has a `run_oracle` verb with a **SMOKE-VERIFIED** rung (a mined oracle runs and passes), and the
aggregator supports a third `mapping+oracle` ablation arm. Neither is on PROVE's path yet: PROVE
verifies with `compile_gate.sh` (build only), and the third arm has only been exercised with stub
scores.

## The spec forge — doc-corpus, and its degraded modes

The spec forge learns *how a team writes specs* from that team's own finished specs. It is the
**conditional** half — the value is not prose about style but that **every convention was counted, not
guessed, and every noun is grounded in the mapping skill.** It harvests a two-sided corpus (the
business **input** and the shipped **spec output**, plus the discussion channel) **verbatim to disk**
through the `spec` and `tracker` [adapters](ADAPTER-CONTRACT.md) (model-driven: no pipeline script calls
the spec adapter — the model invokes it through `adapters.sh` — and the tracker contract has no
ticket-body verb), derives the template by counting,
analyses author style, mines the clarification playbook, then checks the skill (model-run) with a **held-out
generation test** and an adversarial audit before shipping.

Because a real corpus is often thin or messy, the forge has **named, declared degraded modes** — each
written into the skill's `## Confidence and coverage`, never a silent quality drop:

| Situation | Degraded mode |
|---|---|
| **< 8 finished specs** | Drop the frequency tables entirely (below 8, "50%"/"8 of 11" stop being defensible); report shape as *presence*, and say the template is **observed, not measured**. |
| **No dominant author / thin corpus** | *Attribution-ambiguous* — present each rule as "a pattern in the specs seen", name whose specs, and never promote a lone habit into a "house style". |
| **The ticket *is* the spec** (no separate artefact) | Teach turning a ticket into a buildable spec; the clarification playbook becomes most of the value. |
| **No single template** | Extract the shared spine; **propose** the rest, labelled a proposal. |
| **One doc space serving many projects** | *Fence the corpus at the tracker* — the project's specs are exactly those linked from its units; others are context, never counted. |

⛔ **It refuses** (`no-corpus`) when there are no finished specs and no author to learn from, or when
asked to build from tickets alone with no code and no docs — the result would be a formatting guide
with invented nouns, the exact failure the pipeline exists to prevent. A smaller, honest skill beats a
complete-looking, invented one.

**Descriptive vs tuned constants.** Any percentage the *forged* skill states about the team is
**re-counted every run** over that project's corpus (a percentage inherited rather than recounted is a
fabrication). The *decision thresholds* (n=8, the ~80% prescription/description line) are
single-corpus defaults carried as **flagged judgement calls** — if one misfits, record the misfit
with evidence rather than silently moving the line; cross-org calibration is out of scope for one run.

---

## Shipping gate — conformance before it lands

The forge skills instruct the model not to ship a forged skill until it passes
[`conformance-lint`](../skills/adapt/conformance-lint/SKILL.md)
([`scripts/conformance-lint.mjs`](../scripts/conformance-lint.mjs)) — a **structural** gate. Nothing in
code blocks the write; the gate is the instruction plus your review of the diff. What it checks depends
on `mahoraga.kind`:

- **`mapping`** — `grounding: file-line`, a `name | kind | evidence` table with ≥ 3 rows, each
  evidence cell matching `path:line` or exactly `UNVERIFIED`, a `Regenerate:` / `provenance` command,
  and **every `path:line` in every names table resolving** (`--repo <dir>` per repo, default the dir holding the skill's `.claude/`, else the nearest git root): the file is source inside the
  repo — symlinks resolved, never the skill's own files or anything under `.claude/` — the line
  exists, and the row's name (the last identifier of its first word; any annotation after it is
  ignored) is on that line — a table citing `does/not/exist.go:9999` fails. With no root the lint
  fails rather than skip the check. It proves the name is on the line, not that it is defined there,
  and it reads markdown tables in `SKILL.md` and `references/subsystem-map.md` only (not HTML tables or
  other reference files). It does not check frontmatter, size or links.
- **`spec`** (and other kinds) — the blueprint container: the reference-file manifest, required
  sections and phase headings, the description, resolved cross-links and anchors.

It says **nothing about whether a claim is true** — a wrong fact passes the lint; truth is the audit's
job. The schema lint, [`scripts/skill-schema-lint.py`](../scripts/skill-schema-lint.py) (frontmatter,
name, description, ≤ 500-line body), runs in CI over Mahoraga's own `skills/` only; run it by hand on a
forged skill's parent directory.

## Guardrails (both forges)

- **Read-only on the team's systems** by instruction (`PROJECT.yaml → security.forge_read_only`,
  which no code reads) — the forge skills tell the model to observe, not mutate your repos, tracker, or
  docs. Your Claude Code permission prompts are the actual enforcement.
- **Never let a summary become evidence; never assert a count you did not run; never invent a name** —
  mark it EXISTING (`file:line`) / NEW / `UNVERIFIED`.
- **Do not ship without the audit** (and, for the spec forge, the held-out test) **and a green
  conformance-lint.**

## Related

- [`codebase-mapping-forge`](../skills/adapt/codebase-mapping-forge/SKILL.md) ·
  [`spec-style-forge`](../skills/adapt/spec-style-forge/SKILL.md) ·
  [`skill-editor`](../skills/adapt/skill-editor/SKILL.md) ·
  [`conformance-lint`](../skills/adapt/conformance-lint/SKILL.md)
- [`docs/SKILL-SCHEMA.md`](SKILL-SCHEMA.md) — the contract a forged skill conforms to.
- [`docs/ADAPTER-CONTRACT.md`](ADAPTER-CONTRACT.md) — where the corpus (units + specs) comes from.
- [`docs/EVAL-RUBRIC.md`](EVAL-RUBRIC.md) — how the forged skills are then measured (PROVE).
