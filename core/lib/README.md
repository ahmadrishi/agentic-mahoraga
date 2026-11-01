# `core/lib` — the module-agnostic engine

These scripts are the project-agnostic core that runs the adapt → prove → improve operation against
whatever project `$PROJECT_CONFIG` (a `PROJECT.yaml`, see `core/schema/PROJECT.schema.yaml`)
describes; they read every value through the config and never hard-code a vendor. The only non-stdlib
dependency is **PyYAML**. `cfgquery.py` is the single reader of the config shape (get / list / repos /
repofield / tokens / interp), and `lib.sh` sources it to expose shell helpers (`cfg_get`, `cfg_list`,
`repos_names`, `repo_field`, `repo_compiles`, `cfg_tokens`, `cfg_interp`) plus the exported
`PROJECT_ID` / `PROJECT_ROOT` / `SANDBOX_ROOT`. `prepare_task.sh` resolves each unit's fork-point and
writes the clean human reference diff (reviewer-only). `stage_sandbox.sh` builds an isolated,
git-history-free sandbox at that fork-point with the project's skills, strips Mahoraga's own
meta-skills using `core/schema/STRIP_SET.manifest` (fail-closed), calls `sanitize_skills.sh`
to swap each derived skill for its method-only `SKILL.sanitized.md` (fail-closed on a missing one),
copies the SPEC + business requirement, and then runs `leak_gate.sh`. `leak_gate.sh` is the
decontamination gate: it greps the sandbox skills for curated `decontamination.answer_tokens` plus
identifiers auto-derived from the human diff, and exits non-zero on any hit ("NOTHING CHECKED" is
reported distinctly from "clean"). `compile_gate.sh` builds or type-checks one sandbox repo from its
`repos[].verify.*` config, taking the verdict from grepping `success_marker` in the log (never the
wrapper exit code) and failing closed on an empty marker. `extract_ai_diff.sh` diffs the finished
sandbox against the pristine fork-point tree to capture the AI's change. `new_state.py` is a tiny,
lock-guarded, atomically-saved resumable run-state store. `aggregate_scores.py` rolls each unit's
`score.json` into `scores.json` with an aggregate block, and `build_report.py` renders the
theme-aware, self-contained HTML report (split human/AI diff, scoreboard, adversarial evidence) with
a credential redaction pass before write. The per-unit score contract lives in
`core/schema/SCORE.schema.json`.
