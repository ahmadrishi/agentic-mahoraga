<!-- Identity is defined once in branding.yaml; this file mirrors it. -->

# Agentic Mahoraga — documentation

The reference docs behind the harness. Start with the [top-level README](../README.md) for what the
project is and what it does today; these documents are the **contracts and methodology** the
code implements. Each doc is explicit about what is **enforced in code** and what is
**process or discipline**.

Four verbs, one wheel:

- **ADAPT** forges grounded skills from your code (and specs) → [`FORGING.md`](FORGING.md)
- **GUARD** is the stack-agnostic behavioral pack ([`../skills/guard/`](../skills/guard/))
- **PROVE** blind-reimplements your shipped work and scores it against a bare-model baseline →
  [`EVAL-RUBRIC.md`](EVAL-RUBRIC.md) + [`DECONTAMINATION.md`](DECONTAMINATION.md)
- **IMPROVE** is code in `mahoraga loop run`: a contained editor learns from earlier tickets and a
  sealed rule keeps its edit only if it helps on later, held-out ones → [`LOOP.md`](LOOP.md) +
  [`../core/loop/README.md`](../core/loop/README.md). The
  in-session path, `/mahoraga-improve` + `/mahoraga-retest` (the
  [`skill-improvement-loop`](../skills/prove/skill-improvement-loop/SKILL.md) skill), is still
  model-instructed and re-tests the same units, so it measures nothing held out.

---

## The documents

| Doc | What it covers | Read it when |
|---|---|---|
| [`ADAPTER-CONTRACT.md`](ADAPTER-CONTRACT.md) | The four adapter families (`tracker` · `spec` · `vcs` · `verify`) — the only vendor-specific surface. Where the units and specs come from; how a vendor-coupled fetch works without a vendor hostname in core. | Adding a tracker/spec adapter, or asking what your list endpoint returns. |
| [`FORGING.md`](FORGING.md) | The **ADAPT** forge: the always-available mapping forge (code-grounded, cross-language via `mapping_scan.py`) + the conditional spec forge (doc-corpus, degraded modes), and the count-don't-estimate / `file:line` / audit discipline. | Understanding what `/mahoraga-adapt` produces and why every name is grounded. |
| [`DECONTAMINATION.md`](DECONTAMINATION.md) | How the eval is kept **blind**: fresh-not-fork implementers, the history-free opaque sandbox, the fork-point-subtracting leak-gate, fail-closed derived-skill sanitize, the manifest strip-set, and the pretraining-cutoff holdout. | Trusting (or attacking) a Prove number's blindness. |
| [`EVAL-RUBRIC.md`](EVAL-RUBRIC.md) | How a **PROVE** number is constructed and defended: the weighted atomic-criteria `business_req_pct`, distributions (read the min), the **ablation delta** (harness − baseline), sampling-frame disclosure, cutoff labels, per-unit decontam confidence, and the human inter-rater plan. | Reading a report, or auditing whether the headline measures the real ask. |
| [`LOOP.md`](LOOP.md) | The loop's **sealed keep/revert rule** (v2 current, v1 on record): every threshold, its sha256, and why v2 replaced v1. | Reading a `decision.json`, or before proposing a rule change. |
| [`SKILL-SCHEMA.md`](SKILL-SCHEMA.md) | The **semver'd emitted-SKILL.md contract** (v0.1.0): the frontmatter rules, three-tier progressive disclosure, forward-compatibility, and the migration policy. Normative source: [`../core/schema/SKILL.schema.md`](../core/schema/SKILL.schema.md). | Authoring a skill, or understanding what the forge emits and the lint enforces. |
| [`../SECURITY.md`](../SECURITY.md) | The threat model and controls for a tool that auto-edits code-executing skills and sends private work to a model API: least-privilege skills, human-diff approval, the planned SHA-pinned marketplace + signed releases, community-adapter review, data governance + cold-start, and how to report a vulnerability. | Before pointing Mahoraga at proprietary code, or contributing an adapter. |

## How they fit together

```
PROJECT.yaml ──▶ ADAPTER-CONTRACT ──▶ units + specs
                        │
                        ▼
                    FORGING (ADAPT) ──▶ <project>-mapping / <project>-spec skills
                        │                     (conform to SKILL-SCHEMA)
                        ▼
   DECONTAMINATION ──▶ PROVE ──▶ EVAL-RUBRIC ──▶ an ablated, cutoff-labelled report
      (keeps it blind)              (defines the number)
                        │
                        ▼
                    SECURITY governs every step (read-only forge, human-diff gate,
                    what leaves the machine)
```

- **[`SKILL-SCHEMA.md`](SKILL-SCHEMA.md)** is the contract everything ADAPT emits conforms to; its
  machine gates are [`../scripts/skill-schema-lint.py`](../scripts/skill-schema-lint.py) (schema) and
  [`../scripts/conformance-lint.mjs`](../scripts/conformance-lint.mjs) (container).
- **[`EVAL-RUBRIC.md`](EVAL-RUBRIC.md)** and **[`DECONTAMINATION.md`](DECONTAMINATION.md)** are two
  halves of one claim: the rubric makes a number *mean something*; decontamination makes it *blind*.
  Neither is sufficient alone.
- **[`SECURITY.md`](../SECURITY.md)** and **[`ADAPTER-CONTRACT.md`](ADAPTER-CONTRACT.md)** meet at the
  contribution security review — adapters are executable code that runs in every user's repo.

## Machine-readable schemas

The prose docs above point at the machine-readable schemas in [`../core/schema/`](../core/schema/)
(`SCORE.schema.json` documents the score shape; nothing validates against it yet):
[`PROJECT.schema.yaml`](../core/schema/PROJECT.schema.yaml) (project config),
[`SKILL.schema.md`](../core/schema/SKILL.schema.md) (the normative skill contract),
[`SCORE.schema.json`](../core/schema/SCORE.schema.json) (the per-unit score shape), and
[`STRIP_SET.manifest`](../core/schema/STRIP_SET.manifest) (the meta-skills stripped from sandboxes).

## For contributors

- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — the add-an-adapter flow, the local gate suite, and the
  two hard bars (zero company data, the legibility budget).
- [`../CHANGELOG.md`](../CHANGELOG.md) — what shipped, in Keep-a-Changelog style.
