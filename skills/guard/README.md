<!-- Identity is defined once in /branding.yaml; this pack is copied unchanged by `mahoraga install`. -->

# GUARD — the stack-agnostic behavioral pack

GUARD is the one Agentic Mahoraga deliverable that is **truly stack-agnostic**: a small set of
behavioral skills aimed at the mistakes models make *regardless of language, framework, or vendor*.
Unlike the forged `<project>-mapping` / `<project>-spec` skills (which read your code) and the
prove/improve engine skills (which describe the eval), GUARD needs no per-project step:
the same pack applies to any project, day one.

Every skill here conforms to [`core/schema/SKILL.schema.md`](../../core/schema/SKILL.schema.md):
third-person `description` stating *what + when* with a `Do NOT use for … (that is <sibling>)` router,
least-privilege `allowed-tools`, `mahoraga.kind: guard`, and the house shape (thesis → when → steps →
key points → worked example → anti-patterns → related). These skills are **not** on the
[`STRIP_SET.manifest`](../../core/schema/STRIP_SET.manifest) — they are disciplines the implementer is
meant to have, not descriptions of the eval, so they stay in every blind sandbox.

## The pack

| Skill | One line |
|---|---|
| [`karpathy-guidelines`](karpathy-guidelines/SKILL.md) | Umbrella front door — the four pre-flight biases; routes to the dedicated skills. |
| [`surface-assumptions`](surface-assumptions/SKILL.md) | State assumptions, present interpretations, don't trust the spec's framing of current state. |
| [`simplicity-first`](simplicity-first/SKILL.md) | Minimum code that solves the actual problem; nothing speculative. |
| [`small-diff-surgical-change`](small-diff-surgical-change/SKILL.md) | Smallest diff; touch only what the request requires; clean up only your own orphans. |
| [`reuse-before-create`](reuse-before-create/SKILL.md) | Search the whole codebase for an existing equivalent before writing a new symbol. |
| [`trace-to-consumer`](trace-to-consumer/SKILL.md) | Prove your output reaches the consumer the business outcome depends on. |
| [`verification-before-advance`](verification-before-advance/SKILL.md) | Turn the task into a goal, climb the highest verification rung, report UNVERIFIED honestly. |
| [`honesty-vocabulary`](honesty-vocabulary/SKILL.md) | Close with BUILD-/SMOKE-/UNVERIFIED; never "tested" unless tests ran. |

## Hard block vs surfacing vs advice (honest accounting)

GUARD is not "gates, not advice": only ONE row is a true hard block. This pack labels each row
honestly. The pack ships exactly two Claude Code hooks, auto-discovered
from [`hooks/hooks.json`](../../hooks/hooks.json) at the plugin root and wired to `Write|Edit`.

| Skill | Mechanism | Hard block? |
|---|---|---|
| `small-diff-surgical-change` | **PreToolUse** hook [`hooks/small-diff-gate.sh`](../../hooks/small-diff-gate.sh) — counts the lines a single edit changes vs `MAHORAGA_MAX_EDIT_LINES` (default 300). | **YES in `block` mode** (exit 2 refuses the tool call); **default `warn`** (exit 0 + note). New-file writes always allowed. |
| `verification-before-advance` | **PostToolUse** hook [`hooks/verify-after-edit.sh`](../../hooks/verify-after-edit.sh) — a fast per-file syntax check (`py_compile` / `bash -n` / `json.load` / `node --check`) that **surfaces** its verdict on stderr. | **NO.** A PostToolUse hook cannot block — Claude Code ignores its exit code, so it always exits 0. Surfacing only. |
| `karpathy-guidelines` | Model-invoked prose (fires by `description` triggers). | no — advice |
| `surface-assumptions` | Model-invoked prose. | no — advice |
| `simplicity-first` | Model-invoked prose. | no — advice |
| `reuse-before-create` | Model-invoked prose. | no — advice |
| `trace-to-consumer` | Model-invoked prose (design-time contract check). | no — advice |
| `honesty-vocabulary` | Model-invoked prose. Its verdict *source* is the engine's verify adapter (a code gate, not a Claude Code hook — see below); the word in the close stays discipline. | no — advice |

Both hooks **fail open** on malformed stdin (exit 0) — a guard must never wedge the session. They
parse stdin with `python3` (stdlib `json`), never `jq`.

**Not a Claude Code hook, but still a code gate:** decontamination is enforced by the engine's
`leak_gate.sh` and the verify adapter emits a machine build-verdict that feeds `honesty-vocabulary` —
both run in the engine regardless of agent, and are *separate* from the two GUARD hooks above.

**Three consequences, stated plainly:** (1) exactly one GUARD row is a hard block, and only when
`MAHORAGA_SMALL_DIFF_MODE=block` — the default is `warn`; (2) the verify hook **surfaces, it does not
gate** — PostToolUse cannot block, and this pack does not pretend otherwise; (3) hooks are a Claude
Code primitive — on other agents they don't port and every row degrades to discipline-only prose. The
IMPROVE loop hardens findings into `SKILL.md` edits (advice), not new hooks, so the ratio won't shift
on its own.

## How they fit together

- **Before coding:** `karpathy-guidelines` (front door) → `surface-assumptions`, `simplicity-first`,
  `reuse-before-create`, `trace-to-consumer`.
- **While coding:** `small-diff-surgical-change`, `simplicity-first`.
- **Before claiming done:** `verification-before-advance` → `honesty-vocabulary`.

The `Do NOT use for …` router in each `description` keeps the boundaries sharp so the right skill fires
for the task at hand.

## Conformance

Guard skills follow [`core/schema/SKILL.schema.md`](../../core/schema/SKILL.schema.md): valid
frontmatter (`mahoraga.kind: guard`), the < 500-line / < 5k-token budget, references one level deep,
and resolved cross-links. `scripts/conformance-lint.mjs` currently gates the forged `spec` and
`mapping` skills; a `guard`-kind lint branch is not built yet, so guard skills are schema-checked by review.
