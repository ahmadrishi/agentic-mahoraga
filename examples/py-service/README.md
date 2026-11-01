# Example reference repo — `py-service` (Python)

A **real, runnable** minimal Python project (a fictional payments/billing service) used as an Agentic
Mahoraga fixture — the Python counterpart to `examples/ts-app`. The mechanical loop runs on it end to
end with **no** deps, no network, and no `gh`. Point Mahoraga at your own repo for a real prove run;
use this to see the shape and to smoke-test the pipeline on Linux.

A sibling `fixture/` directory is kept separate and unchanged — it backs the snake_case leak-gate
test (`tests/leak_gate_snake_test.sh`); see the last section.

## What is here

```
py-service/
├─ src/
│  ├─ __init__.py          # package surface: re-exports the money model + ledger
│  ├─ ledger.py            # Money (integer cents), to_cents, make_money, format_money, Ledger
│  └─ (refund.py)          # NOT committed here — added by setup-fixture.sh as the unit commit
├─ SPEC.md                 # the design note for the unit (fetched by the `markdown` spec adapter)
├─ BUSINESS_REQUIREMENT.md # the PR-body-sized business ask for the unit
├─ setup-fixture.sh        # builds a throwaway git repo: base commit + ONE feature commit (the unit)
├─ .claude/skills/         # the harness arm's one project skill (no answer symbols; see the note below)
├─ PROJECT.yaml            # the one file that describes the project to the module-agnostic core
└─ fixture/                # SEPARATE — the leak-gate test's inputs (see below); do not confuse
```

The committed `src/` compiles on its own (`python3 -m py_compile src/*.py` — stdlib only, no install).
The **feature** — a `compute_prorated_refund` function — is NOT committed here; `setup-fixture.sh`
adds it as the single feature commit so it becomes the unit of work discovered by the tracker.

## The fixture: `setup-fixture.sh`

```
bash examples/py-service/setup-fixture.sh [PARENT_DIR]
```

It git-inits `PARENT_DIR/py-service` (a fresh `mktemp` dir when `PARENT_DIR` is omitted), commits the
base tree on `main`, then makes one feature commit adding `src/refund.py`. It needs **git only** — no
`gh`, no `pip`, no network — and prints machine-readable lines to stdout:

```
root=/tmp/py-service-fixture.XXXXXX          # use as PROJECT.yaml project.root
repo=/tmp/py-service-fixture.XXXXXX/py-service
skills=/tmp/py-service-fixture.XXXXXX/.claude/skills
unit=<feature commit sha>                    # the unit of work
fork=<parent sha>                            # the fork-point the sandbox is staged at
base_branch=main
```

The `github-pr` tracker adapter's **pure-git fallback** then discovers the unit as the last non-merge
commit, with `fork_point` = its parent. Set `project.root` to the `root=` value (or point
`MAHORAGA_REPO_DIR` at `repo=`), and `skills.source_dir` at `skills=`.

## How the two-arm loop runs on it (mechanical, CI-friendly)

1. `setup-fixture.sh` → a git repo whose tip is the unit.
2. `tracker_fn list_units` / `fork_point` (github-pr, pure-git) → discover the unit + its fork-point.
3. `prepare_task.sh` → the fork-point and the clean `human_py-service.diff` (a **reference**, not a target).
4. `stage_sandbox.sh` → a history-free sandbox at the fork-point + `SPEC.md` / `BUSINESS_REQUIREMENT.md`,
   then the **leak gate**. The eval stages **two arms** on the same fork-point + SPEC + BR:
   - **harness** — staged with the full `.claude/skills/` (the `money-cents-guard` project skill). It
     names only pre-existing helpers, so the identifier leak gate passes.
   - **baseline** — staged with skills stripped to EMPTY. With real model scores, the delta between the
     two arms would attribute the result to the harness vs the base model; this fixture uses stub
     scores (harness 95, baseline 60).
5. a stub implementer applies a change per arm; `extract_ai_diff.sh` isolates it; scores land in
   `<UNIT>/score.json` (arm `harness`) and `<UNIT>/score.baseline.json` (arm `baseline`).
6. `verify` via the `command` adapter → `python3 -m py_compile src/*.py` (the honesty verdict is
   **BUILD-VERIFIED**: no `test_cmd`).
7. `aggregate_scores.py` + `build_report.py` → a `report.html` with the ablation panel, distributions,
   the sampling frame, and per-unit cutoff + decontamination-confidence labels.

## Decontamination + cutoff label

`PROJECT.yaml` sets `decontamination.cutoff_policy.repo_visibility: private` with an illustrative
`model_cutoff`. Because a private code base is not in public pretraining, the labeler
(`core/lib/cutoff_label.py`) labels this project's units **cutoff-clean** — the deliberate counterpart
to `ts-app`, which is `public` and so labels **cutoff-unverified**. Together the two fixtures exercise
both outcomes. The labeler trusts the declared visibility: this fixture ships with Mahoraga itself (an open-source demo fixture), so
its label exercises the code path, not a real guarantee.

The feature symbol `compute_prorated_refund` is a distinctive snake_case identifier that the
language-aware gate auto-derives from `human_py-service.diff` (absent at the fork-point, so it
survives fork-subtraction). The staged `money-cents-guard` skill names only pre-existing helpers
(`Money`, `to_cents`, `make_money`, `format_money`, `Ledger`), so the identifier gate passes — but its
worked example and anti-patterns paraphrase the unit's algorithm, a leak that no token match can see.
The demo's harness arm is therefore partly open-book; this is the identifier gate's known blind spot.

## The `fixture/` directory (leak-gate test — unchanged)

`fixture/` is a **separate**, self-contained input set for `tests/leak_gate_snake_test.sh`: a human diff
(`fixture/human_svc.diff`) that introduces the snake_case answer symbol `compute_prorated_refund` on a
repo named `svc`, plus a deliberately CONTAMINATED `fixture/leaky-skill/SKILL.md` that names that symbol
in prose. The test builds its own hermetic config and points the gate at that sandbox, proving the gate
CATCHES the leak when the symbol is absent at the fork-point and does NOT flag it when it is pre-existing.
This directory is intentionally left untouched by the runnable repo above.

> See `core/schema/PROJECT.schema.yaml` for every field, `docs/ADAPTER-CONTRACT.md` for the adapters,
> and `docs/DECONTAMINATION.md` for the leak gate + cutoff-label rationale.
