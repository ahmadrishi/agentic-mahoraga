---
name: blind-eval
description: Master orchestrator for a blind, spec-vs-human evaluation of a project's agentic coding setup. Use when evaluating how well a project's skills+agents implement real work — on recently-shipped human-authored units, measuring where an agentic setup loses business context. Drives the whole operation from one PROJECT.yaml — select+vet units, disclose the sampling frame, stage sandboxes in TWO arms (full-skills harness vs a skills-stripped baseline) for an attribution ablation, implement blind from SPEC+BUSINESS_REQUIREMENT, verify, score adversarially, label each unit's pretraining-cutoff + decontam-confidence, and report the harness-vs-baseline delta — resumable, in low-concurrency waves. Triggers "eval this project", "run the agentic eval", "prove it on our merged work", "ablation baseline". Do NOT use for improving skills from the findings (that is skill-improvement-loop), staging one sandbox (that is sandbox-isolation), or scoring one implementation in isolation (that is adversarial-review-loop).
allowed-tools: [Read, Grep, Glob, Bash, Task]
license: MIT
mahoraga:
  kind: meta
  grounding: none
---

# Blind eval — prove the setup on your own merged work

This is the driver protocol for evaluating a project's agentic coding setup against the humans who
actually shipped the work. You take real, already-merged **units of work**, hide the human's answer,
re-implement each one blind from its spec and business requirement, and score the result
adversarially against the human diff as a **reference, never a match target**. Everything
project-specific comes from **`PROJECT.yaml`** (schema in `${CLAUDE_PLUGIN_ROOT}/core/schema/PROJECT.schema.yaml`); this
protocol and its `${CLAUDE_PLUGIN_ROOT}/core/lib/*` scripts are project-agnostic — read config and call the named
**adapters**, never hard-code a repo, host, key, path, or toolchain. Every vendor detail lives behind
a `tracker` / `spec` / `vcs` / `verify` adapter (see `${CLAUDE_PLUGIN_ROOT}/docs/ADAPTER-CONTRACT.md`).

## The core probe — why this eval is fair, and what it is designed to catch

Give the implementer **both** the SPEC (design doc, from the `spec` adapter) and the
BUSINESS_REQUIREMENT (the actual ask, from the `tracker` unit). Then any miss is unambiguously an
**agent weakness**, not a spec-completeness gap — the report scores against the real business ask, so
there is nowhere for a miss to hide. Empirically, with both provided, hallucination and
over-engineering are near-zero; the dominant failure is **lost business context on the largest / most
ambiguous units**: output that satisfies the spec's letter but lands where the intended consumer
never reads it, or a value the consumer keys off that the producer never emits. **Deliberately weight
selection toward storage/integration and coordinated producer↔consumer units that span repos** — that
is where lost-context surfaces (`selection.require_multi_repo`). If your batch is all small
single-repo units, you have not run the probe.

When the spec is thin (`spec.adapter: none` / `issue-body` with only a PR description), the run is
flagged **`attribution-ambiguous`**: the skill-gap-vs-spec-gap signal is weaker and spec-fidelity is
not scored as if an independent spec existed.

## The two arms — ablation makes the number attributable

Decontamination makes a score *blind*; the **ablation arm** makes it *attributable*. A high harness
score on its own is unfalsifiable — it could be the base model, not your skills. So **every unit is
evaluated in TWO arms** on the **same fork-point sandbox** and the **same SPEC+BR**:

- **harness** — sandbox staged with the project's **full skills** (mapping + spec + GUARD pack, per
  `skills.source_dir`). Score → `<RUN_DIR>/<UNIT>/score.json` (`arm: "harness"`).
- **baseline** — sandbox staged with **NO forged skills and NO GUARD pack** (the staged skills tree
  is stripped to empty). Score → `<RUN_DIR>/<UNIT>/score.baseline.json` (`arm: "baseline"`).

Both arms get a **fresh** `general-purpose` implementer (never a fork) and pass the **same** leak-gate
on the **same** two inputs — the comparison is apples-to-apples, decontaminated identically. The
report's headline is the **harness − baseline delta**, not an absolute percentage:
`${CLAUDE_PLUGIN_ROOT}/core/lib/aggregate_scores.py` reads both files (glob `<UNIT>/score*.json`), groups by the `arm`
field, and emits `arms` + `ablation_delta` (positive `business_req_avg` = the harness beat the base
model; positive `lost_context`/`hallucinations`/`overeng` = the harness had **fewer** defects). A
single-arm (harness-only) run still reports cleanly — there is just no delta. The full rationale and
rubric live in `${CLAUDE_PLUGIN_ROOT}/docs/EVAL-RUBRIC.md`.

## Before the first unit

1. **Load config** — source `${CLAUDE_PLUGIN_ROOT}/core/lib/lib.sh` to read `PROJECT.yaml` (repos+languages, tracker, spec
   source, per-repo verify, skills, selection, decontamination, runtime knobs). Every value below
   comes from it.
2. **Fresh run, resumable** — create a new output dir + JSON state file with `${CLAUDE_PLUGIN_ROOT}/core/lib/new_state.py`
   (`output.run_dir` / `output.state_file`). The state file tracks each unit's phase
   (`prepared → staged → implemented → verified → reviewed → scored`), its opaque slug, and its
   fork-point. **Update it after every step** so any run resumes cleanly; if the runtime dies mid-run,
   checkpoint at a wave boundary and finish in a fresh session.
3. **Honor the exclusion list** — never re-select a unit in `decontamination.exclusion`. Its answer is
   already baked into the tuned skills and project memory, so scoring it is circular. **Append every
   unit to `exclusion` the moment it is evaluated.**

## The phases at a glance

| # | Phase | Do | Script / adapter | Delegate to | Guardrail |
|---|---|---|---|---|---|
| 1 | Select + vet | Pick N shipped, human-authored units of mixed complexity spanning the repos; vet each for fairness; **record the sampling frame to `selection.json`** | `tracker.list_units` | — | Fairness table below + no fabricated frame |
| 2 | Gather dual input | Write `SPEC.md` (spec adapter) + `BUSINESS_REQUIREMENT.md` (tracker metadata) into the unit dir; produce the cleaned human reference diff | `spec.fetch_spec` (call it via `${CLAUDE_PLUGIN_ROOT}/core/lib/adapters.sh` — no script calls it) + `tracker.reference_diff` via `${CLAUDE_PLUGIN_ROOT}/core/lib/prepare_task.sh` | — | Clean the diff range (below) |
| 3 | Stage (×2 arms) | History-free sandbox at the fork-point + SPEC + BR, opaque slug, leak-gate must pass — **once with full skills (harness), once with skills stripped to empty (baseline)** | `${CLAUDE_PLUGIN_ROOT}/core/lib/stage_sandbox.sh`, `${CLAUDE_PLUGIN_ROOT}/core/lib/leak_gate.sh` | [`sandbox-isolation`](../sandbox-isolation/SKILL.md) | Leak count MUST be 0 or staging aborts — **each arm** |
| 4 | Implement blind (×2 arms) | A **fresh general-purpose** subagent implements from SPEC+BR (+skills in the harness arm; none in baseline) | — | [`sandbox-isolation`](../sandbox-isolation/SKILL.md) | FRESH, never `fork` |
| 5 | Verify (×2 arms) | Build / typecheck each arm's AI result per repo; extract each AI diff | `verify` adapter via `${CLAUDE_PLUGIN_ROOT}/core/lib/compile_gate.sh`, `${CLAUDE_PLUGIN_ROOT}/core/lib/extract_ai_diff.sh` | — | Absolute log path + grep the verdict |
| 6 | Score (×2 arms, blinded) | `score_hygiene.py blind` → reviewer → red-team → reconciling verifier on opaque labels, every finding file:line-grounded → `score_hygiene.py unblind` (**harness → `score.json`, baseline → `score.baseline.json`**), each tagged `arm` + `cutoff_label` + `decontam_confidence` + scorer/implementer model + family | `${CLAUDE_PLUGIN_ROOT}/core/lib/score_hygiene.py` | [`adversarial-review-loop`](../adversarial-review-loop/SKILL.md) | Human diff is a REFERENCE, not a match target |
| 7 | Aggregate + report | Roll up BOTH arms; emit HTML split-diff + scoreboard + **ablation panel + distributions + sampling frame + per-unit cutoff/decontam chips** | `${CLAUDE_PLUGIN_ROOT}/core/lib/aggregate_scores.py`, `${CLAUDE_PLUGIN_ROOT}/core/lib/build_report.py` | — | Scan for credential leaks before sharing |

**Phases 3–6 run once per arm** (harness, then baseline) on the same fork-point tree + same SPEC+BR;
Phase 7 reads both. After Phase 7, improving the skills from the findings is a **separate protocol** —
[`skill-improvement-loop`](../skill-improvement-loop/SKILL.md) (its own approval gate).

## Phase 1–2 — select and vet (fairness is the whole game)

Draw candidates from the `tracker` adapter (`tracker.list_units(since, n, filters)`, within
`selection.lookback_days`). The unit of work is a **merged PR, a ticket-with-branch, or a tagged
commit** — never hard-coded to a branch; the adapter resolves each unit's `fork_point` (merge-base of
`vcs.base_branch` and the unit for a PR; parent-of-oldest-commit for a branch). Aim for `selection.n`,
mixed complexity (`selection.complexity_spread`), and some multi-repo units
(`selection.require_multi_repo`). Then **vet every candidate** and drop any that fails — a bad unit
poisons the score:

| Reject / flag when | Why it is unfair | How to check |
|---|---|---|
| Unit carries an agentic-system label | Not a human baseline | the adapter's `labels_exclude` |
| Spec is diagram/whiteboard-only | You cannot fairly give an agent a spec you cannot write down | `spec.untranscribable` / `spec.is_transcribable(fmt)` |
| Under-specified investigation unit | No derivable spec or answer to score against | no design doc + no acceptance in the unit metadata |
| **Restore/revert** unit whose human diff has **0 new-file markers** | The feature was already present at the fork-point → the "restore" is a no-op at fork; scoring it as a build is a trap | grep the human diff for `^new file` markers |
| Human diff doesn't mention the unit's own subject terms | The fork..ref range **over-captured** unrelated commits, inflating the human stat | grep the diff for the unit's subject words; if absent, regenerate from the unit's genuine commits only |

Surface a **one-line vetting summary per unit** for a fast human veto, then proceed. For each
surviving unit: **you write `$UNITDIR/SPEC.md`** (from the `spec` adapter — it writes `SPEC.md` to the
unit dir on disk, or reports "thin") **and `$UNITDIR/BUSINESS_REQUIREMENT.md`** (the real ask, from
the `tracker` unit metadata) — `${CLAUDE_PLUGIN_ROOT}/core/lib/stage_sandbox.sh` errors if they are absent.
`${CLAUDE_PLUGIN_ROOT}/core/lib/prepare_task.sh` writes the **cleaned** human reference diff (`tracker.reference_diff`):
`fork-point → ref, restricted to the unit's own commits`, not the whole branch range. Treat an
inflated human line-count as a measurement artifact, not a real signal.

**Record the sampling frame — never fabricate one.** Selection is a claim about representativeness, so
disclose it. Write `<RUN_DIR>/selection.json`:
`{"candidates": <int considered from the tracker>, "selected": <int evaluated>, "excluded":
[{"unit": "<slug>", "reason": "<vetting-table reason, e.g. restore-noop | over-captured-range |
untranscribable-spec | agentic-label>"}, …]}`. The report renders it as a **sampling-frame** line;
if the file is absent the report says **"sampling frame not recorded"** rather than inventing one. A
number without a frame is a number you cannot defend.

## Phase 3–4 — stage and implement blind, in two arms (delegate)

Hand each vetted unit to [`sandbox-isolation`](../sandbox-isolation/SKILL.md) **twice** — the two arms
above. The arms are **identical** in everything (fork-point tree, `SPEC.md`, `BUSINESS_REQUIREMENT.md`,
opaque-slug scheme, leak-gate, fresh-not-fork rule, verify) **except** the staged skills tree: full
skills for harness (`skills.source_dir`, minus the stripped meta-skills per
`${CLAUDE_PLUGIN_ROOT}/core/schema/STRIP_SET.manifest`) vs stripped-to-empty for baseline. Nothing else differs, so the delta
attributes cleanly to the harness.

Non-negotiables `sandbox-isolation` enforces in **both** arms, which you must not shortcut:

- The sandbox contains **only** the fork-point tree (no `.git`, no history, no human ref), the
  project's skills, `SPEC.md`, `BUSINESS_REQUIREMENT.md` — under an **opaque slug** (no unit id in the
  path).
- The implementer is a **FRESH `general-purpose` subagent, NEVER a `fork`** — a fork inherits your
  context, which holds the human diffs and the answers. It makes **no `Skill` tool calls**: plugin
  and live-repo skills are loaded session-wide, so the sandbox's skill files are the arm's only skills.
  (Code-launched arms under `mahoraga loop` are separate containers with a fresh config; there the
  rule does not apply, and staged content is delivered always-on.)
- The **leak-gate must pass before implementing** (and always before a retest): skills derived from
  prior eval units leak those units' answers, so `${CLAUDE_PLUGIN_ROOT}/core/lib/sanitize_skills.sh` swaps each derived skill
  for its curated method-only `SKILL.sanitized.md` (failing closed if one is missing) and
  `${CLAUDE_PLUGIN_ROOT}/core/lib/leak_gate.sh` greps each sandbox for that unit's answer tokens — the curated
  `decontamination.answer_tokens` **plus** distinctive symbols auto-derived from the human diff using
  the repo's language-aware heuristic (`repos[].language`) — count **must be 0** or staging aborts.
- The **engine skills never enter the sandbox.** `${CLAUDE_PLUGIN_ROOT}/core/lib/stage_sandbox.sh` strips any skill whose
  directory basename is listed in `${CLAUDE_PLUGIN_ROOT}/core/schema/STRIP_SET.manifest` (this skill and its siblings) so a
  blind implementer cannot read the methodology as an answer key.
- The implementer prompt is **neutral** (no leading question that hands the answer) and bounded: no
  git, no network, no external/MCP tools, stay in the sandbox, read and follow any skill whose
  description matches the unit.

Run implementers in **waves of `runtime.implementer_wave`** (default 3). Record the slug and phase in
the state file as each completes.

## Phase 5 — verify (the concrete hallucinated-symbol detector)

Verification is **per-repo** (`repos[].verify`), via the `verify` adapter, not one global command. For
each repo with a `verify.build_cmd`, run `${CLAUDE_PLUGIN_ROOT}/core/lib/compile_gate.sh`. Two hard rules the script's callers get
wrong:

- **Pass an ABSOLUTE log path.** The script `cd`s into the repo internally; a relative log path
  silently breaks before the build even runs.
- **Never trust the wrapper's exit code — grep the log for the real verdict** (`verify.success_marker`,
  e.g. the `BUILD SUCCESS` / `BUILD FAILURE` line).

For a repo with only a `typecheck_cmd`, the verdict is the exit code. For a repo with neither, mark the
result **`n/a` and state explicitly that the code is not verified**. **The honesty verdict is
mandatory** (`${CLAUDE_PLUGIN_ROOT}/docs/ADAPTER-CONTRACT.md`): a repo with no `test_cmd` is **BUILD-VERIFIED, not
behavior-verified** — never imply tests ran when they did not (real test execution in the history-free
sandbox needs provisioning and is a follow-on). Then extract the AI diff with
`${CLAUDE_PLUGIN_ROOT}/core/lib/extract_ai_diff.sh` for the reviewers. **Never echo any build/registry credential or
settings file** (guard this again at report time).

## Phase 6 — score both arms (delegate)

**Blind the arms first** — the scorer must not know which arm it is scoring:

```
python3 ${CLAUDE_PLUGIN_ROOT}/core/lib/score_hygiene.py blind <RUN_DIR> <UNIT> --seed <run seed> \
  --arm harness=<harness diff variant> --arm baseline=<baseline diff variant>
```

It copies each arm's `<variant>_<repo>.diff` to `<UNIT>/blind/<A|B|…>/candidate_<repo>.diff` under a
seeded shuffle and keeps the label→arm key in `<UNIT>/.blind-key.json`, outside `blind/`. Give the
scorers **only** `blind/<label>/` plus the human reference diff, SPEC+BR and verify verdict — never the
key, the arm names, or the other arm's verdicts — and have them write `blind/<label>/score.json`.
Then `score_hygiene.py unblind <RUN_DIR> <UNIT>` maps each back to `score.json` / `score.baseline.json`
with `arm` and `blind_label` stamped. Record `scorer_model` + `scorer_family` and `implementer_model` +
`implementer_family` on every score: the report flags SAME-FAMILY SCORING (self-preference risk).

Hand each blinded candidate, the human reference diff, the SPEC+BR, and the verify verdict to
[`adversarial-review-loop`](../adversarial-review-loop/SKILL.md). It runs **reviewer → red-team →
reconciling verifier**, discards any claim not grounded in a confirmable `file:line`, and emits one
score file per blinded candidate in the shape of `${CLAUDE_PLUGIN_ROOT}/core/schema/SCORE.schema.json`, which `unblind`
turns into the **harness** arm's `<UNIT>/score.json` (`arm:"harness"`) and the **baseline** arm's
`<UNIT>/score.baseline.json` (`arm:"baseline"`). It scores **business-requirement-achieved %** (the
weighted `business_criteria` roll-up — the construct rubric in `${CLAUDE_PLUGIN_ROOT}/docs/EVAL-RUBRIC.md`;
`aggregate_scores.py` recomputes the % from the criteria and overrides a grader value that disagrees), **code quality vs the human reference**
(better/equal/worse — the human diff is a comparison baseline, **never** a match target; do not score
"human-match %"), **net-new reachable security threat vs the human diff baseline**, and the **weakness
flags** (hallucination / over-engineering / lost-context) + spec-fidelity. Run reviewers read-only in
**waves of `runtime.reviewer_wave`** (default 6). Save every reviewer/red-team/verifier transcript.

### Stamp each score file's per-unit labels

Before the score file is final, stamp the two decontamination labels onto it (both arms of a unit
carry the **same** labels — they describe the unit, not the arm):

- **`cutoff_label` + `cutoff_reason`** — compute with `${CLAUDE_PLUGIN_ROOT}/core/lib/cutoff_label.py` from the unit's
  `merged_at` (tracker `metadata`), `decontamination.cutoff_policy.repo_visibility`, and
  `decontamination.cutoff_policy.model_cutoff`:
  `python3 ${CLAUDE_PLUGIN_ROOT}/core/lib/cutoff_label.py "<merged_at>" "<repo_visibility>" "<model_cutoff>"` →
  `cutoff-clean` (private repo, or merged strictly after the model cutoff) or `cutoff-unverified`
  (public repo / no `model_cutoff` / merged ≤ cutoff / unknown `merged_at`), plus the reason string.
  Never hand-label — the script is the single source of truth so the rule is deterministic and
  testable.
- **`decontam_confidence`** — derive from the leak-gate result for this unit (§4 of
  `${CLAUDE_PLUGIN_ROOT}/docs/DECONTAMINATION.md`): `auto+curated` (language heuristic **and** curated tokens both ran, 0
  hits), `auto-only`, `curated-only`, `hand-mitigated` (a hit was found and removed before the blind
  run — disclose it), or `nothing-checked` (nothing derivable and none curated → the score is
  **unverified for contamination**).

## Phase 7 — aggregate + report

`${CLAUDE_PLUGIN_ROOT}/core/lib/aggregate_scores.py` globs **both** arms' files per unit (`<UNIT>/score*.json`), groups by
`arm`, and rolls them up: the per-arm summaries (`arms.harness` / `arms.baseline`), the
**`ablation_delta`** (business-req harness−baseline; defect counts baseline−harness so positive =
harness has fewer), the **`distributions`** (min/median/max, not just the mean, for the harness arm),
and the **`sampling_frame`** (the `selection.json` content, or `null`). It also surfaces each unit's
`cutoff_label` + `decontam_confidence` in `tasks`. `${CLAUDE_PLUGIN_ROOT}/core/lib/build_report.py` emits a
**self-contained, theme-aware, responsive HTML report**: split-diff (human left, AI right),
scoreboard, an **ablation panel** (harness vs baseline per metric + the delta), a **distributions**
row, a **sampling-frame** line, per-unit adversarial evidence + weakness blocks, and per-unit
**cutoff/decontam chips**.

**The honesty rule — the headline comes only from cutoff-clean units.** When
`cutoff_policy.require_post_cutoff_for_headline` is true (the default), a **headline** number must be
computed over units labelled `cutoff-clean` — private repos, or work merged strictly after the model
cutoff. Public-repo demos are labelled `cutoff-unverified` and their numbers are shown but **never
quoted as the headline** (the model may have memorized the merged change at pretraining, so the
"blind" result would be recall, not reasoning). A single-arm (harness-only) run still renders cleanly
— every ablation-dependent section guards on both arms being present. **Keep every per-unit artifact**
(spec, BR, human/AI diffs, review transcripts, verify logs, `score.json` + `score.baseline.json`,
`selection.json`). **Scan the report and diffs for credential leaks before sharing anything.** Then
append every evaluated unit to `decontamination.exclusion`.

## Runtime resilience & minimum supervision

Subagents may run as pane teammates that **stall under load**, and the runtime degrades cumulatively —
so keep concurrency low and watch for stalls:

- **Waves:** `runtime.implementer_wave` fresh implementers (~3–4) and `runtime.reviewer_wave` read-only
  reviewers (~6–8) at a time — no more.
- **Stall watch:** watch each sandbox for **file-write activity**; if nothing is written for
  `runtime.stall_watch_secs`, suspect a stall. Nudge once; if still dead, stop + **re-stage on a fresh
  slug** + relaunch. Cap at `runtime.max_restages` (default 4); after the cap, mark it **`infra-stalled`
  (NOT an agent-quality result)**.
- **Resumable:** fresh output dir per run; state file updated after every step; a killed run resumes
  from the last recorded phase.
- **Script hygiene:** absolute paths everywhere; **quote `grep --include` globs** (`--include="*.ts"`,
  not bare — some shells expand it); never trust a wrapper exit code, read the real verdict line.

## The three human gates (everything else is automatic)

1. **Onboard once** — a confirmed `PROJECT.yaml` (`mahoraga init` drafts it by discovery).
2. **Kick off** — you select+vet (one-line summary for a possible veto), then run
   implement→verify→score in waves to a report, unattended.
3. **Approve improvements** — hand off to [`skill-improvement-loop`](../skill-improvement-loop/SKILL.md).

## Related skills

- [`sandbox-isolation`](../sandbox-isolation/SKILL.md) — staging, fresh-not-fork implementers,
  decontamination + the leak-gate (Phases 3–4).
- [`adversarial-review-loop`](../adversarial-review-loop/SKILL.md) — the reviewer→red-team→verifier
  scoring protocol + `score.json` shape (Phase 6).
- [`skill-improvement-loop`](../skill-improvement-loop/SKILL.md) — turn the findings into skill
  edits/new skills and validate them by decontaminated retest.
