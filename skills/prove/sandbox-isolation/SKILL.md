---
name: sandbox-isolation
description: Stage an isolated, answer-free sandbox for a blind implementation and keep the run decontaminated. Use when setting up a blind eval unit, preventing answer leakage into a "blind" run, or decontaminating skills before a first run or a retest. Builds a history-free sandbox at the fork-point (no .git, no human ref, opaque slug) holding only the skills + SPEC + BUSINESS_REQUIREMENT, launches a FRESH general-purpose implementer (never a fork), and runs the leak-gate that aborts staging if any answer token survives in the sandbox skills. Triggers "stage the eval sandbox", "prevent answer leakage", "decontaminate the skills", "set up a blind run", "why is my eval contaminated", "prepare a retest sandbox". Do NOT use to score the result (that is adversarial-review-loop) or to drive the whole eval (that is blind-eval).
allowed-tools: [Read, Grep, Glob, Bash, Task]
license: MIT
mahoraga:
  kind: meta
  grounding: none
---

# Sandbox isolation — keep the blind run blind

Contamination is the single most-repeated failure class in this kind of eval: the "blind" run quietly
sees the answer, and the score becomes circular. The answer leaks through three doors — the
orchestrator's own context (which holds the human diffs), the git history/ref left in the sandbox, and
**skills that were tuned from earlier eval units and now literally name those units' answers**. This
skill shuts all three: a history-free fork-point sandbox, a **fresh** implementer that never inherits
your context, and a leak-gate that greps the sandbox skills for the unit's answer tokens and **aborts
staging unless the count is 0**.

Everything project-specific comes from **`PROJECT.yaml`** (`${CLAUDE_PLUGIN_ROOT}/core/schema/PROJECT.schema.yaml`); the
scripts are `${CLAUDE_PLUGIN_ROOT}/core/lib/*` and are project-agnostic.

## When to use

- Setting up any unit of work for a blind implementation in an eval.
- **Before any retest** of a previously-failed unit — the improved skills are the *most* likely to
  contain that unit's answer.
- Whenever you suspect a "blind" run wasn't blind, or a score looks suspiciously good.

## What goes in the sandbox — and what must not

| Include | Exclude (leaks the answer) |
|---|---|
| The **fork-point tree** of each touched repo (`repos[].name` from `PROJECT.yaml`) | `.git` / any history — strip it entirely |
| The project's **skills** (`skills.source_dir`), **sanitized** (below) | The **human ref / diff** — the reference lives with the scorer, never here |
| `SPEC.md` (the design doc, from the `spec` adapter) | Any `eval-run` / prior-run data, notes, or `score.json` |
| `BUSINESS_REQUIREMENT.md` (the real ask, from the `tracker` unit) | The unit id **anywhere in the path** — use an **opaque slug** |

The path must not reveal the unit. Stage under `output.sandbox_root` with a random/opaque slug so the
implementer cannot infer the unit (and cannot map the path back to a known answer).

**The engine skills never enter the sandbox.** This skill and its siblings (`blind-eval`,
`adversarial-review-loop`, `sandbox-isolation`, `skill-improvement-loop`, and the `adapt/*` forge
skills) describe the eval itself. If they were staged, the "blind" implementer would know it is being
tested and how. `${CLAUDE_PLUGIN_ROOT}/core/lib/stage_sandbox.sh` strips any skill whose directory basename appears in
**`${CLAUDE_PLUGIN_ROOT}/core/schema/STRIP_SET.manifest`** after copying `skills.source_dir` — a **manifest**, not a
hard-coded list, so a renamed or newly-added engine skill is not silently left behind (CI's
zero-residue sandbox test asserts none of them survive staging). This holds **even if an operator
installed the engine skills alongside the project's skills** under `.claude/skills/`.

## Stage it — `${CLAUDE_PLUGIN_ROOT}/core/lib/stage_sandbox.sh`

Reads the repos from config, checks out each touched repo at the unit's **fork-point** (via the `vcs`
adapter's `archive`), removes `.git`, copies the skills into the sandbox's `.claude/skills/` minus the
STRIP_SET entries and sanitizes them, copies `skills.index_file` (if set; it lives inside
`skills.source_dir`) to the sandbox **root** as well, and writes `SPEC.md` + `BUSINESS_REQUIREMENT.md`.
It **runs the leak-gate as its last step and aborts on a hit** — staging is not "done" until the gate
is green. The gate scans `.claude/skills`, so it checks the index file through its identical copy
there — unless the index sits inside a stripped or derived (sanitized) skill dir, whose copy is
removed; keep it at the top of `skills.source_dir`. A gate with nothing to check prints
`NOTHING CHECKED` and still exits 0, so staging goes ahead — read the gate's output, not the exit code.

## The leak-gate MUST pass — `${CLAUDE_PLUGIN_ROOT}/core/lib/sanitize_skills.sh` + `${CLAUDE_PLUGIN_ROOT}/core/lib/leak_gate.sh`

Skills derived from earlier eval units encode those units' answers: a "trace to the consumer" skill
built from a unit will name that unit's consumer field; a worked example will name the exact symbol.
Handing that to the "blind" implementer is handing it the answer.

1. **Sanitize the derived skills** — for each `skills.derived_skills` entry, `${CLAUDE_PLUGIN_ROOT}/core/lib/sanitize_skills.sh`
   **swaps the sandbox copy for a curated method-only `<name>/SKILL.sanitized.md` that you author once
   per derived skill** (a version with the consumer maps, worked examples, and named symbols removed but
   the technique kept). It does **not** auto-strip prose — so if a derived skill has no
   `SKILL.sanitized.md`, the script **fails closed** (non-zero exit) and staging aborts rather than
   shipping the answer-bearing skill. (Reviewers may keep the full skills; the *sandbox* copy must be
   the sanitized one.) **Authoring one `SKILL.sanitized.md` per derived skill is a required onboarding
   step.**
2. **Gate it** — `${CLAUDE_PLUGIN_ROOT}/core/lib/leak_gate.sh` greps the sandbox skills for the unit's **answer tokens** —
   both the curated `decontamination.answer_tokens[<unit_id>]` (fields/symbols/consumers the skill must
   not hand over) **and distinctive identifiers auto-derived from the unit's human diff using the repo's
   language-aware heuristic** (`repos[].language`), so a skill that leaks the answer in prose using a
   symbol nobody tokenised is still caught. **The count MUST be 0** or staging aborts. Quote your
   `grep --include` globs (`--include="*.md"`), and read the real count, not a wrapper exit code.

This runs **before every blind run and ALWAYS before a retest**. A retest re-runs failed units with
the *improved* skills, which were written from the findings and therefore carry the answers — the gate
is what makes a retest a fair test rather than an open-book one. (Retest flow:
[`skill-improvement-loop`](../skill-improvement-loop/SKILL.md).)

## The implementer — FRESH, never a fork

- **Launch a FRESH `general-purpose` subagent. NEVER a `fork`.** A fork inherits the orchestrator's
  context, which contains the human diffs and the answers — an instant, invisible leak.
  (`general-purpose`, not a fork, is the whole point.)
- The prompt is **neutral and bounded**. It must:
  - Implement the unit from **`SPEC.md` + `BUSINESS_REQUIREMENT.md` + the sandbox skills only**.
  - **Read and follow any skill whose `description` matches the unit** — the skills are under eval; the
    implementer must actually use them.
  - **No git, no network, no external/MCP tools; stay inside the sandbox.**
  - **No `Skill` tool calls.** The sandbox's `.claude/skills` files are the only skills the arm has —
    read them as files. Session-loaded skills (the `mahoraga:*` plugin pack, the live repo's
    `.claude/skills`) sit outside the arm; invoking one puts GUARD into the baseline arm and voids
    the ablation. (This rule is for subagent implementers inside a session. Under `mahoraga loop`
    each arm is its own container with a fresh config, its staged content is delivered always-on,
    and the `Skill` tool can reach nothing but what was staged.)
  - Carry **no leading question** that hands over the answer — judge the agent by its code, not by a
    hint. If a prompt leaks the answer, the run is void: re-stage on a fresh slug and relaunch.

## Reviewers may see the human ref; implementers may not

The asymmetry is deliberate. The **scorer needs the human diff as its comparison baseline**, so keep
it available to the review step — but **never inside the sandbox**, where the implementer would see
it. Blind for the implementer; sighted for the reviewer.

## After implementing — extract exactly what changed

Run `${CLAUDE_PLUGIN_ROOT}/core/lib/extract_ai_diff.sh` to diff the sandbox tree against its fork-point baseline: that is
precisely what the agent changed, and it is what the verify step and
[`adversarial-review-loop`](../adversarial-review-loop/SKILL.md) consume. Record the slug and phase in
the run state file so the unit resumes cleanly.

## Related skills

- [`blind-eval`](../blind-eval/SKILL.md) — the orchestrator that calls this per unit and runs
  implementers in low-concurrency waves.
- [`adversarial-review-loop`](../adversarial-review-loop/SKILL.md) — scores the extracted AI diff
  against the human reference; re-stage here if it finds a leaked prompt.
- [`skill-improvement-loop`](../skill-improvement-loop/SKILL.md) — its validation retest depends on
  this skill's sanitize + leak-gate to stay honest.
