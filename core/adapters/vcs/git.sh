#!/usr/bin/env sh
# vcs/git.sh — the only vcs adapter: host-agnostic local git.
#
# GitHub / GitLab / Gitea are *hosts of git*; they are handled by the tracker
# adapter. This layer knows nothing about any host — it operates on a full local
# checkout and exposes exactly the git verbs the engine (and the tracker/spec
# adapters) call. See docs/ADAPTER-CONTRACT.md §3.
#
# Requires: a local checkout whose history reaches each fork-point. There is no
# shallow-clone path yet (roadmap). No config is read here — every verb takes an
# explicit repo directory, so this file has no vendor coupling and no hostnames.
#
# Usage:  git.sh <verb> <repo_dir> [args...]
#
#   archive       <repo> <ref> <dest_dir>      export the tree at <ref> into
#                                              <dest_dir>, history-free (no .git)
#   log           <repo> <ref> [grep_ere]      "<sha> <subject>" per line, newest
#                                              first, non-merge; optional -E filter
#   rev-parse     <repo> <rev>                 resolve <rev> to a full 40-char sha
#   diff          <repo> <from> <to> [-- p...] unified diff <from>..<to>, optional paths
#   name-only     <repo> <from> <to> [-- p...] changed paths only, one per line
#   merge-base    <repo> <a> <b>               best common ancestor of <a> and <b>
#   for-each-ref  <repo> <pattern...>          short refnames matching pattern(s)
#   root                                       print this adapter's family name ("git")
#
# Exit: non-zero on a git error or bad usage. stdout carries only the requested data.
set -u

_die() { echo "git.sh: $*" >&2; exit 2; }

_need_repo() {  # <repo_dir>
  [ -n "${1:-}" ] || _die "missing <repo_dir>"
  [ -d "$1/.git" ] || git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || _die "not a git repo: $1"
}

verb="${1:-}"; shift 2>/dev/null || true

case "$verb" in
  archive)
    REPO="${1:-}"; REF="${2:-}"; DEST="${3:-}"
    _need_repo "$REPO"; [ -n "$REF" ] || _die "archive: need <ref>"; [ -n "$DEST" ] || _die "archive: need <dest_dir>"
    mkdir -p "$DEST" || _die "archive: cannot create $DEST"
    # archive|tar is the history-free export the sandbox stager relies on. Fail the
    # whole pipe (not a silent partial tree) if the archive step errors.
    git -C "$REPO" archive "$REF" | ( cd "$DEST" && tar -x ) || _die "archive failed for $REF"
    ;;
  log)
    REPO="${1:-}"; REF="${2:-}"; GRE="${3:-}"
    _need_repo "$REPO"; [ -n "$REF" ] || _die "log: need <ref>"
    if [ -n "$GRE" ]; then
      git -C "$REPO" log --no-merges --format='%H %s' "$REF" | grep -iE "$GRE" || true
    else
      git -C "$REPO" log --no-merges --format='%H %s' "$REF"
    fi
    ;;
  rev-parse)
    REPO="${1:-}"; REV="${2:-}"
    _need_repo "$REPO"; [ -n "$REV" ] || _die "rev-parse: need <rev>"
    git -C "$REPO" rev-parse "$REV"
    ;;
  merge-base)
    REPO="${1:-}"; A="${2:-}"; B="${3:-}"
    _need_repo "$REPO"; [ -n "$A" ] && [ -n "$B" ] || _die "merge-base: need <a> <b>"
    git -C "$REPO" merge-base "$A" "$B"
    ;;
  diff)
    REPO="${1:-}"; FROM="${2:-}"; TO="${3:-}"; shift 3 2>/dev/null || _die "diff: need <from> <to>"
    _need_repo "$REPO"
    # remaining args (if any) are the `-- path...` limiter the caller passes verbatim
    git -C "$REPO" diff "$FROM" "$TO" "$@"
    ;;
  name-only)
    REPO="${1:-}"; FROM="${2:-}"; TO="${3:-}"; shift 3 2>/dev/null || _die "name-only: need <from> <to>"
    _need_repo "$REPO"
    git -C "$REPO" diff --name-only "$FROM" "$TO" "$@"
    ;;
  for-each-ref)
    REPO="${1:-}"; shift 2>/dev/null || _die "for-each-ref: need <pattern...>"
    _need_repo "$REPO"; [ "$#" -gt 0 ] || _die "for-each-ref: need <pattern...>"
    git -C "$REPO" for-each-ref --format='%(refname:short)' "$@"
    ;;
  root)
    echo "git"
    ;;
  ""|-h|--help)
    sed -n '2,30p' "$0"
    ;;
  *)
    _die "unknown verb '$verb' (archive|log|rev-parse|diff|name-only|merge-base|for-each-ref|root)"
    ;;
esac
