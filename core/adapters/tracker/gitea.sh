#!/usr/bin/env bash
# tracker/gitea.sh — the unit of work is a MERGED PULL REQUEST on a Gitea host.
#
# Gitea is another HOST OF GIT, so the fork-point, changed files and reference diff
# all come from LOCAL GIT exactly as they do for github_pr.sh's pure-git path — this
# adapter is a WORKING pure-git tracker over the git-host model. Every git touch goes
# through core/adapters/vcs/git.sh, and all config (incl. any hostname) is read from
# PROJECT.yaml — there are NO literal hostnames here.
#
# The Gitea-REST layer (resolve a PR number -> head sha, PR listing, labels via the
# instance `base_url` + a token) needs a live Gitea instance and is OUT OF CI SCOPE:
#   Not yet implemented: add a `tea`/REST metadata layer (mirrors github_pr.sh's `gh` path) so a
#   unit id can be a PR number and `labels_exclude` can filter baselines by PR label.
# Until then the unit id is a git commit sha (as in github_pr.sh's pure-git fallback)
# and `labels_exclude` is a documented no-op — labels are a host concept.
#
# Config read (from $PROJECT_YAML; NO literal hostnames):
#   project.root                       dir that contains the local checkouts
#   tracker.config.base_url            Gitea instance url — reserved for the REST layer
#   tracker.config.repo                "owner/name" — used to locate the local checkout dir
#   tracker.config.base_branch         e.g. "main"  (falls back to vcs.base_branch, then "main")
#   tracker.config.labels_exclude      PR labels that disqualify a unit (REST layer; no-op in pure-git)
#   tracker.config.merge_strategy      squash | merge — which commits list_units returns (default squash)
#   MAHORAGA_REPO_DIR (env, optional)  overrides the local checkout dir directly.
#
# Usage:  PROJECT_YAML=/path/PROJECT.yaml  gitea.sh <fn> [args]
#
#   list_units   [since] [n] [exclude_csv]   -> "<id>\t<title>\t<merged_at>\t<labels>" per line
#   fork_point   <unit>                      -> sha  (merge-base of base_branch and the unit)
#   change_files <unit>                      -> changed path per line
#   reference_diff <unit>                    -> unified diff (the human's shipped change; a REFERENCE)
#   metadata     <unit>                      -> "key=value" lines (id,title,labels,merged_at,base,tip,fork)
#
# UNIT ID: a git commit sha (pure-git). fork_point/change_files/reference_diff/metadata
# resolve it by parent count (>=2 parents => merge commit; else a squash/plain commit) —
# identical to github_pr.sh's pure-git fallback, so a Gitea checkout behaves the same.
set -u

: "${PROJECT_YAML:?set PROJECT_YAML to the PROJECT.yaml path (see core/schema/PROJECT.schema.yaml)}"
[ -f "$PROJECT_YAML" ] || { echo "gitea.sh: PROJECT_YAML not found: $PROJECT_YAML" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GIT="$HERE/../vcs/git.sh"   # all git touches go through the vcs adapter

# --- config reader (python3 + PyYAML; no yq/jq) --------------------------------------
_cfg() {  # _cfg <op> [dotted] ; op = get|list|repos_first
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
elif op == "list":
    v = dig(sys.argv[3]) or []
    if isinstance(v, list):
        for it in v:
            if not isinstance(it, (dict, list)): print(sca(it))
elif op == "repos_first":
    rs = d.get("repos") or []
    if rs: print(rs[0].get("name", ""))
PY
}

ROOT="$(_cfg get project.root)"
BASEURL="$(_cfg get tracker.config.base_url)"      # reserved for the REST layer
CFGREPO="$(_cfg get tracker.config.repo)"          # owner/name — locates the local checkout
BASE="$(_cfg get tracker.config.base_branch)"; [ -z "$BASE" ] && BASE="$(_cfg get vcs.base_branch)"; [ -z "$BASE" ] && BASE="main"
: "${BASEURL:=}"   # read-and-reserved: the pure-git path needs no network; the REST layer will.

_repo_dir() {
  if [ -n "${MAHORAGA_REPO_DIR:-}" ]; then echo "$MAHORAGA_REPO_DIR"; return; fi
  local rn="${CFGREPO##*/}"
  if [ -n "$rn" ] && [ -d "$ROOT/$rn/.git" ]; then echo "$ROOT/$rn"; return; fi
  local first; first="$(_cfg repos_first)"
  echo "$ROOT/$first"
}
REPO_DIR="$(_repo_dir)"

# --- _resolve <unit> -> "fork<TAB>tip<TAB>title<TAB>merged_at<TAB>labels" -------------
# fork = the point the work forked off base; tip = the human endpoint. reference_diff
# and change_files are both fork..tip, so they line up with the fork-point tree the
# sandbox is staged at (git archive <fork>) — same method-A isolation as github_pr.sh.
_resolve() {
  local unit="$1" fork tip title mat labels sha nparents
  sha="$("$GIT" rev-parse "$REPO_DIR" "$unit" 2>/dev/null)" || { echo "gitea.sh: cannot resolve unit '$unit'" >&2; return 3; }
  nparents=$(( $(git -C "$REPO_DIR" rev-list --parents -n1 "$sha" | wc -w) - 1 ))
  if [ "$nparents" -ge 2 ]; then
    # true merge commit: tip = feature side (2nd parent); fork = merge-base(base_parent, feature)
    tip="$(git -C "$REPO_DIR" rev-parse "${sha}^2")"
    fork="$("$GIT" merge-base "$REPO_DIR" "${sha}^1" "$tip")"
  else
    # squash / plain commit on base: tip = the commit; fork = its parent
    tip="$sha"
    fork="$(git -C "$REPO_DIR" rev-parse "${sha}^" 2>/dev/null)"
  fi
  title="$(git -C "$REPO_DIR" log -1 --format='%s' "$sha")"
  mat="$(git -C "$REPO_DIR" log -1 --format='%cI' "$sha")"
  labels=""   # labels are a Gitea-host concept; unavailable until the REST layer
  [ -n "$fork" ] && [ -n "$tip" ] || { echo "gitea.sh: could not derive fork/tip for '$unit' (is the PR head in local history? see vcs contract)" >&2; return 3; }
  printf '%s\t%s\t%s\t%s\n' "$fork" "$tip" "$title" "${mat}	${labels}"
}

# --- list_units ----------------------------------------------------------------------
# PURE-GIT: the last N units on base_branch. Labels are unavailable (so labels_exclude,
# read below to honour the config contract, is a documented no-op here — it filters in
# the REST layer, not yet implemented). merge_strategy picks the shape:
#   squash (default): last N non-merge first-parent commits (one squashed PR each)
#   merge           : last N merge commits (one merged PR each)
_list_units() {  # [since] [n] [exclude_csv]
  local since="${1:-}" n="${2:-20}" xcsv="${3:-}"
  # merge configured excludes with any passed on the CLI (reserved for the REST layer)
  local excl; excl="$(_cfg list tracker.config.labels_exclude | tr '\n' ',')${xcsv}"
  : "${excl:=}"   # no-op in pure-git; keeps the labels_exclude config key wired for later
  local strat; strat="$(_cfg get tracker.config.merge_strategy)"; [ -z "$strat" ] && strat="squash"
  local sinceopt=""; [ -n "$since" ] && sinceopt="--since=$since"
  if [ "$strat" = "merge" ]; then
    git -C "$REPO_DIR" log --merges --first-parent $sinceopt --format='%H%x09%s%x09%cI%x09' -n "$n" "$BASE"
  else
    git -C "$REPO_DIR" log --no-merges --first-parent $sinceopt --format='%H%x09%s%x09%cI%x09' -n "$n" "$BASE"
  fi
}

fn="${1:-}"; shift 2>/dev/null || true
case "$fn" in
  list_units)     _list_units "${1:-}" "${2:-}" "${3:-}";;
  fork_point)     r="$(_resolve "${1:?unit}")" || exit 3; printf '%s\n' "$r" | cut -f1;;
  change_files)   r="$(_resolve "${1:?unit}")" || exit 3; f="$(printf '%s' "$r" | cut -f1)"; t="$(printf '%s' "$r" | cut -f2)"; "$GIT" name-only "$REPO_DIR" "$f" "$t";;
  reference_diff) r="$(_resolve "${1:?unit}")" || exit 3; f="$(printf '%s' "$r" | cut -f1)"; t="$(printf '%s' "$r" | cut -f2)"; "$GIT" diff "$REPO_DIR" "$f" "$t";;
  metadata)
    r="$(_resolve "${1:?unit}")" || exit 3
    printf 'id=%s\n' "${1}"
    printf 'title=%s\n' "$(printf '%s' "$r" | cut -f3)"
    printf 'merged_at=%s\n' "$(printf '%s' "$r" | cut -f4)"
    printf 'labels=%s\n' "$(printf '%s' "$r" | cut -f5)"
    printf 'base=%s\n' "$BASE"
    printf 'fork=%s\n' "$(printf '%s' "$r" | cut -f1)"
    printf 'tip=%s\n' "$(printf '%s' "$r" | cut -f2)"
    ;;
  ""|-h|--help) sed -n '2,40p' "$0";;
  *) echo "gitea.sh: unknown fn '$fn' (list_units|fork_point|change_files|reference_diff|metadata)" >&2; exit 2;;
esac
