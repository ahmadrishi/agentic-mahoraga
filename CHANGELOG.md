<!-- Identity is defined once in branding.yaml; this file mirrors it. -->

# Changelog

All notable changes to Agentic Mahoraga are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Executable-surface policy (SECURITY.md §4):** any change to **hooks or core** — code that runs
> with no per-invocation approval — gets an entry here. A version bump must never silently push new
> executable hooks into installed repos.

## [Unreleased]

## [0.1.0] — 2026-11-01

The first public release.

### What is in it

- **GUARD** — a small, stack-agnostic behavioral pack: 8 prose skills (`honesty-vocabulary`,
  `karpathy-guidelines`, `reuse-before-create`, `simplicity-first`, `small-diff-surgical-change`,
  `surface-assumptions`, `trace-to-consumer`, `verification-before-advance`) and 2 Claude Code hooks:
  a small-diff size gate (warns by default; `MAHORAGA_SMALL_DIFF_MODE=block` makes it a hard gate) and a
  post-edit verification check that reports but cannot block.
- **ADAPT** — `/mahoraga-adapt` forges a grounded `<project>-mapping` skill (and a `<project>-spec` skill
  where a doc corpus exists) plus a `CLAUDE.md`. `core/lib/mapping_scan.py` names code with `file:line`
  evidence for Python, TS/JS, Java and Go; `scripts/conformance-lint.mjs` checks every `path:line` resolves.
- **PROVE** — `/mahoraga-prove` and `mahoraga loop prove` blind-reimplement your shipped tickets in
  history-free sandboxes and score them against the human diff (as a reference) and a bare-model
  baseline, with an identifier-level leak gate and cutoff labels.
- **IMPROVE** — `mahoraga loop` (Linux + Docker): `preflight`, `prove`, `insample`, `gate`, `run` and
  `promote` (the held-out gate refuses the `jira` and `file` trackers). One contained edit to the always-on guidance is judged on later, held-out tickets by a sealed
  keep/revert rule ([`docs/LOOP.md`](docs/LOOP.md)); only a KEEP can be promoted, after a typed
  confirmation. `/mahoraga-improve` and `/mahoraga-retest` are the model-instructed, in-session path.
- **Adapters** — tracker (`github-pr`, `gitea`, `jira`, `file`, `none`), spec (`issue-body`, `markdown`,
  `none`), vcs (`git`) and verify (`command`), behind a documented contract
  ([`docs/ADAPTER-CONTRACT.md`](docs/ADAPTER-CONTRACT.md)). Stubs exist for Azure DevOps, Linear,
  Confluence, Google Docs and Notion.
- **Install** — as a Claude Code plugin (`/plugin install mahoraga --marketplace
  ahmadrishi/agentic-mahoraga`, tested with Claude Code 2.1.290), or `bash cli/mahoraga install --target <dir>`
  to copy the GUARD skills to another agent. The npm package is not published yet.
- **Safety gates** — [`SECURITY.md`](SECURITY.md); `scripts/leak-scan.sh` (credential, private-data and
  personal-path scan); `scripts/adapter-security-check.sh`; a committed dependency allowlist; and a
  legibility budget on the core.

### Limits

See [Limits in the README](README.md#limits).
