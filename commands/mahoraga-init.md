---
description: Discover a project's repos/tracker/build/spec sources and draft its PROJECT.yaml for confirmation (the one setup gate).
argument-hint: "[path-to-repo-or-project-root]"
allowed-tools: [Read, Grep, Glob, Bash, Write]
---

You are onboarding a new project to Agentic Mahoraga. The target: **$ARGUMENTS** (default: the
current directory).

Goal: produce a `PROJECT.yaml` (conforming to `${CLAUDE_PLUGIN_ROOT}/core/schema/PROJECT.schema.yaml`) that fully
describes this project so the module-agnostic core can run `adapt → prove → improve → retest` on it,
then present it for the human to confirm. **This confirmation is the one setup gate — do not forge,
prove, or improve anything yet.**

Read `${CLAUDE_PLUGIN_ROOT}/core/schema/PROJECT.schema.yaml` (the contract — every field's type and meaning) and
`${CLAUDE_PLUGIN_ROOT}/docs/ADAPTER-CONTRACT.md` (how each tracker / spec / vcs / verify adapter is configured) first. The
`mahoraga init` CLI writes a shallow single-repo draft; your job is to verify and deepen it.

Discover, by inspecting the project (never by guessing):

1. **Repos** — every repo the project spans (git repos under the project root). For each: its
   `language` (java, typescript, python, go, …; this selects the decontamination token heuristic and
   the diff-exclude set), and its per-repo `verify` block — a non-interactive, test-skipping
   `build_cmd` and/or `typecheck_cmd` (verdict = exit code), an optional `test_cmd` (its absence means
   the repo is BUILD-VERIFIED, not behavior-verified — say so honestly), and a `success_marker` log
   line when the build produces no reliable exit code.
2. **Tracker** (the unit of work — a merged PR, a ticket-with-branch, or a tagged commit): pick the
   `adapter` (`github-pr` | `jira` | `linear` | `gitea` | `file` | `none`) and fill its `config` from
   `${CLAUDE_PLUGIN_ROOT}/docs/ADAPTER-CONTRACT.md`. Take every hostname / project id / base branch from the repo — never
   hard-code a vendor.
3. **Spec source** — where design/requirement docs live: `markdown` (a repo glob), `issue-body`, or a
   degraded connector (`confluence` / `notion` / `gdocs`, text-extract-only), else `none`. Record any
   `untranscribable` formats (e.g. figma, whiteboard-image) that force task exclusion.
4. **vcs** — `git`, with the `base_branch` used for merge-base fork-point resolution.
5. **Skills** — the project's live `.claude/skills` dir (`skills.source_dir`); leave `derived_skills`
   empty on a first onboard (nothing has been tuned from a prove task yet).

Then:

- Write `PROJECT.yaml` with everything discovered. Leave `decontamination.exclusion: []` and
  `decontamination.answer_tokens: {}` (both fill in as units get evaluated). Keep the schema defaults
  for `selection`, `runtime`, `output`, and `security` unless the project needs otherwise.
- **Verify it parses and resolves:** load it and echo `project.id`, the repo names, and each repo's
  verify verdict path, and confirm no literal vendor hostname leaked into anything but the adapter
  `config` blocks.
- Present a concise summary of every discovered value and **ask the human to confirm or correct**
  before first use. Do not proceed to `/mahoraga-adapt` in the same step.

Never print any adapter credential or token (registry settings, API keys, credential-file paths). The
forge is read-only on the team's repos, tracker, and docs by default.
