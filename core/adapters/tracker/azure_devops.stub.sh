#!/usr/bin/env bash
# tracker/azure_devops.stub.sh — HONEST STUB. Unit of work = a completed Azure DevOps
# pull request (Azure Repos), optionally tied to a Boards work item.
#
# Configured as `tracker.adapter: azure-devops` in PROJECT.yaml — the dispatch shim
# (core/lib/adapters.sh) maps a hyphenated adapter name to an underscored filename
# (`azure-devops` -> `azure_devops.stub.sh`, exactly as `github-pr` -> `github_pr.sh`),
# so this stub is reachable and reported as declared-but-unimplemented (exit 64).
#
# NOT YET IMPLEMENTED. Every contract fn below exits non-zero with a clear
# message; the shim already treats a `.stub.sh` as unimplemented and fails closed, so
# no run silently proceeds on Azure DevOps.
#
# WHY IT NEEDS THE AZURE DEVOPS API (unlike gitea.sh, which is pure git):
#   Azure Repos is git-hosted, so once a PR's completion commit / source ref is known the
#   fork-point and diffs come from local git exactly as in gitea.sh/github_pr.sh. What
#   local git CANNOT give is the PR LISTING and its metadata — completed PRs for a repo,
#   their labels/tags, completion time, and the source-branch head — which live behind the
#   Azure DevOps REST API (or the `az repos pr` CLI) under an organization + project, with
#   a PAT from config. So this adapter is a THIN metadata layer in front of the shared
#   pure-git logic — EITHER a REST client OR an orchestrator MCP fetch-step. The core still
#   consumes files/refs on disk and calls no vendor API itself (docs/ADAPTER-CONTRACT.md §1).
#
# Config it will read (from $PROJECT_YAML tracker.config; NO literal hostnames):
#   base_url        Azure DevOps org url (from config, never hard-coded)
#   project         Azure DevOps project name
#   repo            repository name (locates the local checkout dir)
#   base_branch     e.g. "main" (falls back to vcs.base_branch)
#   labels_exclude  PR labels/tags that disqualify a unit as a baseline
#
# Contract fns to implement (see gitea.sh / github_pr.sh for the working shape):
#   list_units   [since] [n] [filters]  -> "<pr#>\t<title>\t<completed_at>\t<labels>" per line
#                  (Azure query: completed PRs targeting <base_branch>, closedDate >= since)
#   fork_point   <unit>   -> sha. Resolve the PR's source head, then
#                            merge-base(base_branch, head) — a real git merge-base.
#   change_files <unit>   -> changed paths (fork..head, via ../vcs/git.sh name-only)
#   reference_diff <unit> -> unified diff fork..head (the human's shipped change; a REFERENCE)
#   metadata     <unit>   -> id,title,labels,completed_at,base,fork,tip
set -u
fn="${1:-}"
case "$fn" in
  list_units|fork_point|change_files|reference_diff|metadata)
    echo "azure_devops.stub.sh: '$fn' not implemented — needs the Azure DevOps REST API (or 'az repos pr') to list completed PRs + metadata (PAT from tracker.config; NO literal hostnames). Use tracker.adapter=github-pr|gitea|file|none for now." >&2
    exit 64 ;;   # EX_USAGE-ish: a declared-but-unimplemented contract function
  ""|-h|--help) sed -n '2,40p' "$0" ;;
  *) echo "azure_devops.stub.sh: unknown fn '$fn' (list_units|fork_point|change_files|reference_diff|metadata)" >&2; exit 2 ;;
esac
