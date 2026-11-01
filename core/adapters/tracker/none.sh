#!/usr/bin/env bash
# tracker/none.sh — no tracker: operate directly on the last N merged units of base_branch.
#
# For teams with no queryable tracker (or when you just want to run against recent
# history). The unit of work is a commit on base_branch — a squashed PR (default) or a
# merge commit — and there is NO ticket metadata (no title beyond the commit subject,
# no labels). Because there is no independent spec source here, pair this with the
# `none` SPEC adapter, which flags every run `attribution-ambiguous`.
#
# Pure local git — NO hostnames, no `gh`, no network.
#
# Config read (from $PROJECT_YAML):
#   project.root                dir that contains the local checkout
#   tracker.config.n            how many recent units (default 20)
#   tracker.config.merge_strategy   squash | merge  (default squash)
#   tracker.config.repo         optional "owner/name" — basename locates the local dir
#   tracker.config.base_branch  (falls back to vcs.base_branch, then "main")
#   MAHORAGA_REPO_DIR (env)      overrides the local checkout dir
#
# Usage:  PROJECT_YAML=/path/PROJECT.yaml  none.sh <fn> [args]
#   list_units   [since] [n] [filters]  -> "<sha>\t<subject>\t<merged_at>\t" per line
#   fork_point   <unit>                 -> sha (per-commit: merge => merge-base of parents; else parent)
#   change_files <unit>                 -> changed path per line (fork..tip)
#   reference_diff <unit>               -> unified diff fork..tip (the human's shipped change)
#   metadata     <unit>                 -> "key=value" lines (id,title,merged_at,base,fork,tip)
set -u

: "${PROJECT_YAML:?set PROJECT_YAML to the PROJECT.yaml path (see core/schema/PROJECT.schema.yaml)}"
[ -f "$PROJECT_YAML" ] || { echo "none.sh: PROJECT_YAML not found: $PROJECT_YAML" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GIT="$HERE/../vcs/git.sh"

_cfg() {  # _cfg <op> [dotted] ; op = get|repos_first
  python3 - "$PROJECT_YAML" "$@" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
op = sys.argv[2]
def dig(dotted):
    cur = d
    for k in dotted.split("."):
        if isinstance(cur, dict) and k in cur: cur = cur[k]
        else: return None
    return cur
def sca(v): return "true" if v is True else "false" if v is False else str(v)
if op == "get":
    v = dig(sys.argv[3])
    if v is not None and not isinstance(v, (dict, list)): print(sca(v))
elif op == "repos_first":
    rs = d.get("repos") or []
    if rs: print(rs[0].get("name", ""))
PY
}

ROOT="$(_cfg get project.root)"
CFGREPO="$(_cfg get tracker.config.repo)"
BASE="$(_cfg get tracker.config.base_branch)"; [ -z "$BASE" ] && BASE="$(_cfg get vcs.base_branch)"; [ -z "$BASE" ] && BASE="main"
N="$(_cfg get tracker.config.n)"; [ -z "$N" ] && N=20
STRAT="$(_cfg get tracker.config.merge_strategy)"; [ -z "$STRAT" ] && STRAT="squash"

_repo_dir() {
  if [ -n "${MAHORAGA_REPO_DIR:-}" ]; then echo "$MAHORAGA_REPO_DIR"; return; fi
  local rn="${CFGREPO##*/}"
  if [ -n "$rn" ] && [ -d "$ROOT/$rn/.git" ]; then echo "$ROOT/$rn"; return; fi
  echo "$ROOT/$(_cfg repos_first)"
}
REPO_DIR="$(_repo_dir)"

# _resolve <unit-sha> -> "fork<TAB>tip" ; fork/tip line up with the fork-point tree the
# sandbox is staged at. Merge vs squash is detected per-commit by parent count.
_resolve() {
  local sha nparents fork tip
  sha="$("$GIT" rev-parse "$REPO_DIR" "$1" 2>/dev/null)" || { echo "none.sh: cannot resolve '$1'" >&2; return 3; }
  nparents=$(( $(git -C "$REPO_DIR" rev-list --parents -n1 "$sha" | wc -w) - 1 ))
  if [ "$nparents" -ge 2 ]; then
    tip="$(git -C "$REPO_DIR" rev-parse "${sha}^2")"
    fork="$("$GIT" merge-base "$REPO_DIR" "${sha}^1" "$tip")"
  else
    tip="$sha"
    fork="$(git -C "$REPO_DIR" rev-parse "${sha}^" 2>/dev/null)"
  fi
  [ -n "$fork" ] && [ -n "$tip" ] || { echo "none.sh: could not derive fork/tip for '$1'" >&2; return 3; }
  printf '%s\t%s\n' "$fork" "$tip"
}

fn="${1:-}"; shift 2>/dev/null || true
case "$fn" in
  list_units)
    n="${2:-$N}"; since="${1:-}"; sinceopt=""; [ -n "$since" ] && sinceopt="--since=$since"
    if [ "$STRAT" = "merge" ]; then
      git -C "$REPO_DIR" log --merges --first-parent $sinceopt --format='%H%x09%s%x09%cI%x09' -n "$n" "$BASE"
    else
      git -C "$REPO_DIR" log --no-merges --first-parent $sinceopt --format='%H%x09%s%x09%cI%x09' -n "$n" "$BASE"
    fi
    ;;
  fork_point)     r="$(_resolve "${1:?unit}")" || exit 3; printf '%s' "$r" | cut -f1;;
  change_files)   r="$(_resolve "${1:?unit}")" || exit 3; "$GIT" name-only "$REPO_DIR" "$(printf '%s' "$r" | cut -f1)" "$(printf '%s' "$r" | cut -f2)";;
  reference_diff) r="$(_resolve "${1:?unit}")" || exit 3; "$GIT" diff "$REPO_DIR" "$(printf '%s' "$r" | cut -f1)" "$(printf '%s' "$r" | cut -f2)";;
  metadata)
    r="$(_resolve "${1:?unit}")" || exit 3
    sha="$("$GIT" rev-parse "$REPO_DIR" "$1")"
    printf 'id=%s\n' "$sha"
    printf 'title=%s\n' "$(git -C "$REPO_DIR" log -1 --format='%s' "$sha")"
    printf 'merged_at=%s\n' "$(git -C "$REPO_DIR" log -1 --format='%cI' "$sha")"
    printf 'base=%s\n' "$BASE"
    printf 'fork=%s\n' "$(printf '%s' "$r" | cut -f1)"
    printf 'tip=%s\n' "$(printf '%s' "$r" | cut -f2)"
    ;;
  ""|-h|--help) sed -n '2,30p' "$0";;
  *) echo "none.sh: unknown fn '$fn' (list_units|fork_point|change_files|reference_diff|metadata)" >&2; exit 2;;
esac
