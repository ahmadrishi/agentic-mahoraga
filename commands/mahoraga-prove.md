---
description: Run the blind eval (identifier-level leak gate) on a project — select+vet shipped units, implement each blind, verify, score adversarially against an ablation baseline, report.
argument-hint: "[project-id] [--n 10]"
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit, Task, Skill]
---

Run the blind eval on **$ARGUMENTS** (default: the project described by `./PROJECT.yaml`).

Invoke the **`blind-eval`** skill (`${CLAUDE_PLUGIN_ROOT}/skills/prove/blind-eval/SKILL.md`) and follow its protocol end to
end, delegating isolation to **`sandbox-isolation`** and scoring to **`adversarial-review-loop`**. In
short:

1. Load `PROJECT.yaml`. Honor `--n` if given, else `selection.n`.
2. **Select + vet** `n` shipped, human-authored units (merged PRs / ticket-with-branch / tagged
   commits) of mixed complexity spanning the repos, via the project's `tracker` adapter. Skip
   automated/agentic-labelled units, untranscribable-spec units, under-specified units, and
   over-captured diffs. Never re-select anything in `decontamination.exclusion`. Weight selection
   toward cross-repo, coordinated producer↔consumer tasks — that is where lost business context
   surfaces. **Surface a one-line vetting summary per unit** for a possible human veto, then proceed.
3. For each unit: write its `SPEC.md` + `BUSINESS_REQUIREMENT.md` (fetched via the `spec` and
   `tracker` adapters — the core touches no vendor API; adapters write files to disk), resolve the
   **fork-point** (merge-base for a PR), and stage an **isolated, history-free, leak-gated sandbox**
   via `sandbox-isolation`. **Decontaminate, fail closed:** the sandbox holds only the fork-point
   tree (no `.git`), the sanitized skills, and the two docs, under an opaque slug; the leak gate
   aborts unless the answer-token count is **0** (curated tokens + symbols auto-derived from the human
   diff). Strip Mahoraga's own meta-skills per `${CLAUDE_PLUGIN_ROOT}/core/schema/STRIP_SET.manifest`.
4. **Implement blind** with a FRESH `general-purpose` subagent (never a fork — a fork inherits the
   answer), neutral prompt, no git history / no network. Then **verify** per-repo (`build_cmd` /
   `typecheck_cmd` / `test_cmd`) — grep the `success_marker`, never the wrapper exit code — and emit
   the honesty verdict (BUILD-VERIFIED vs behavior-verified; never imply tests ran when they did not).
5. **Score** each unit through `adversarial-review-loop` (reviewer → red-team → reconciling verifier,
   `file:line`-grounded). The human diff is a **REFERENCE, never a match target**: grade
   business-requirement-achieved against the real ask, grade code quality better/equal/worse; never
   emit a "human-match %".
6. **Ablation arm (required):** run the same units with a bare agent — **no forged skills, no GUARD
   pack** — and report harness-vs-baseline deltas, per-metric distributions (not just means).
7. Aggregate → a self-contained, theme-aware HTML report. **Scan for credential leaks before
   sharing.** Append every evaluated unit to `decontamination.exclusion`.

Cutoff honesty: a HEADLINE number must come from private / post-cutoff units
(`decontamination.cutoff_policy`); a public repo yields a "cutoff-unverified" label. Respect the
runtime rules (low-concurrency waves, stall-watch → re-stage → cap at `max_restages` → `infra-stalled`,
resumable state file). Never terminate peer or teammate sessions.

Offer to publish the HTML report as an artifact so it can be viewed on another device.
