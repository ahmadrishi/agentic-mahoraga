# Example reference repo — `ts-app` (TypeScript)

A **real, runnable** minimal TypeScript project used as an Agentic Mahoraga fixture. Unlike a bare
skeleton, the mechanical loop actually runs on it end to end, with a stub implementer and no model
(this is what `tests/e2e_ts_app_test.sh` exercises). Point Mahoraga at your own repo for a real prove run; use this to see the shape and to
smoke-test the pipeline on Linux with **no** macOS / Jira / Maven assumptions.

## What is here

```
ts-app/
├─ package.json           # a "typecheck" script: tsc --noEmit -p tsconfig.json
├─ tsconfig.json          # strict; CommonJS module so extensionless imports resolve, no @types needed
├─ src/
│  ├─ money.ts            # Money (integer cents) + toCents
│  ├─ format.ts           # formatMoney
│  └─ index.ts            # makeMoney, describe
├─ SPEC.md                # the design note for the unit (fetched by the `markdown` spec adapter)
├─ BUSINESS_REQUIREMENT.md# the PR-body-sized business ask for the unit
├─ setup-fixture.sh       # builds a throwaway git repo: base commit + ONE feature commit (the unit)
├─ .claude/skills/        # a benign skill library staged into the sandbox (no answer symbols)
└─ PROJECT.yaml           # the one file that describes the project to the module-agnostic core
```

The committed `src/` typechecks on its own (`npm run typecheck` after `npm install`, or
`npx --yes --package=typescript tsc --noEmit -p tsconfig.json` with no install — plain `npx tsc`
runs a decoy package, so the package must be named). The **feature** — a `computeProratedRefund` function — is
NOT committed here; `setup-fixture.sh` adds it as the single feature commit so it becomes the unit of
work discovered by the tracker.

## The fixture: `setup-fixture.sh`

```
bash examples/ts-app/setup-fixture.sh [PARENT_DIR]
```

It git-inits `PARENT_DIR/ts-app` (a fresh `mktemp` dir when `PARENT_DIR` is omitted), commits the base
tree on `main`, then makes one feature commit adding `src/refund.ts`. It needs **git only** — no `gh`,
no `npm`, no network — and prints machine-readable lines to stdout:

```
root=/tmp/ts-app-fixture.XXXXXX      # use as PROJECT.yaml project.root
repo=/tmp/ts-app-fixture.XXXXXX/ts-app
skills=/tmp/ts-app-fixture.XXXXXX/.claude/skills
unit=<feature commit sha>            # the unit of work
fork=<parent sha>                    # the fork-point the sandbox is staged at
base_branch=main
```

The `github-pr` tracker adapter's **pure-git fallback** then discovers the unit as the last non-merge
commit, with `fork_point` = its parent. Set `project.root` to the `root=` value (or point
`MAHORAGA_REPO_DIR` at `repo=`), and `skills.source_dir` at `skills=`.

## How the loop runs on it (mechanical, CI-friendly)

1. `setup-fixture.sh` → a git repo whose tip is the unit.
2. `tracker_fn list_units` / `fork_point` (github-pr, pure-git) → discover the unit + its fork-point.
3. `prepare_task.sh` → the fork-point and the clean `human_ts-app.diff` (a **reference**, not a target).
4. `stage_sandbox.sh` → a history-free sandbox at the fork-point + skills + `SPEC.md` /
   `BUSINESS_REQUIREMENT.md`, then the **leak gate** (a clean pass — the staged skill names none of
   the unit's answer symbols).
5. a stub implementer applies a change, then `extract_ai_diff.sh` isolates it.
6. `verify` via the `command` adapter → `npx --yes --package=typescript tsc --noEmit` (the honesty verdict is
   **BUILD-VERIFIED**: no `test_cmd`). If `npx`/`tsc` is unavailable the runner documents a skip.
7. `aggregate_scores.py` + `build_report.py` → a `report.html`.

## Decontamination note

The feature symbol `computeProratedRefund` is a distinctive lowerCamelCase identifier that the
language-aware gate auto-derives from `human_ts-app.diff` (it is absent at the fork-point, so it
survives fork-subtraction). The staged `money-formatting` skill deliberately names only pre-existing
helpers, so the leak gate passes cleanly — demonstrating a true-negative on a real diff.

> See `core/schema/PROJECT.schema.yaml` for every field and `docs/ADAPTER-CONTRACT.md` for the
> `github-pr`, `markdown`, `git`, and `command` (verify) adapters.
