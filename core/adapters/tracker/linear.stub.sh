#!/usr/bin/env bash
# tracker/linear.stub.sh — HONEST STUB. Unit of work = a Linear issue with a linked branch/PR.
#
# NOT YET IMPLEMENTED. Every contract fn below exits non-zero with a clear
# message; the dispatch shim (core/lib/adapters.sh) already treats a `.stub.sh` as
# declared-but-unimplemented and fails closed, so no run silently proceeds on Linear.
#
# WHY IT NEEDS THE LINEAR API (unlike gitea.sh, which is pure git):
#   Linear's unit is an ISSUE (e.g. "BILL-142"), not a git object. Git alone cannot map
#   an issue id to code — you need the Linear GraphQL API to (a) list issues in a done
#   state, (b) read each issue's auto-created branch name / attached PR, and (c) read
#   labels for the baseline filter. Only AFTER that mapping does the work become git:
#   the fork-point and diffs then come from local git exactly as in gitea.sh/github_pr.sh.
#   So this adapter is a THIN metadata layer (Linear GraphQL, token from config) in front
#   of the shared pure-git logic — EITHER a REST client OR an orchestrator MCP fetch-step.
#   The core still consumes files/refs on disk and calls no vendor API itself
#   (docs/ADAPTER-CONTRACT.md §1).
#
# Config it will read (from $PROJECT_YAML tracker.config; NO literal hostnames):
#   api_url         Linear GraphQL API url (from config, never hard-coded)
#   team_key        e.g. "BILL"
#   done_state      workflow state counted as shipped, e.g. "Done" / "Merged"
#   branch_glob     Linear auto-branch pattern (e.g. "{{unit}}-*") to find the branch
#   labels_exclude  issues with these labels are not baselines
#
# Contract fns to implement (see gitea.sh / github_pr.sh for the working shape):
#   list_units   [since] [n] [filters]  -> "<id>\t<title>\t<completed_at>\t<labels>" per line
#                  (Linear query: issues in <team_key> at <done_state>, completedAt >= since)
#   fork_point   <unit>   -> sha. Resolve the issue's linked branch/PR head, then
#                            merge-base(base_branch, head) — a real git merge-base.
#   change_files <unit>   -> changed paths (fork..head, via ../vcs/git.sh name-only)
#   reference_diff <unit> -> unified diff fork..head (the human's shipped change; a REFERENCE)
#   metadata     <unit>   -> id,title,labels,completed_at,base,fork,tip
set -u
fn="${1:-}"
case "$fn" in
  list_units|fork_point|change_files|reference_diff|metadata)
    echo "linear.stub.sh: '$fn' not implemented — needs the Linear GraphQL API to map an issue id to its branch/PR (token from tracker.config; NO literal hostnames). Use tracker.adapter=github-pr|gitea|file|none for now." >&2
    exit 64 ;;   # EX_USAGE-ish: a declared-but-unimplemented contract function
  ""|-h|--help) sed -n '2,38p' "$0" ;;
  *) echo "linear.stub.sh: unknown fn '$fn' (list_units|fork_point|change_files|reference_diff|metadata)" >&2; exit 2 ;;
esac
