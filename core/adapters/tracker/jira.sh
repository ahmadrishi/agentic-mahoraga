#!/usr/bin/env bash
# tracker/jira.sh — the unit of work is a Jira TICKET, shipped on a branch-per-ticket workflow.
#
# Implements the tracker contract (docs/ADAPTER-CONTRACT.md §1) over LOCAL GIT. Fork-point, changed
# files and the reference diff all come from git — the Jira REST API is only needed to filter by
# DONE status / labels at selection time, which is optional (TODO(jira-rest)): the ticket BRANCHES
# are themselves the shipped units. This mirrors github_pr.sh's pure-git path; no literal hostnames.
#
# Config read (from $PROJECT_YAML tracker.config):
#   project_key     e.g. "REC" — the branch/commit key prefix
#   branch_is_key   true => branch name == the ticket key (fork discovery relies on it)
#   branch_glob     pattern with {{key}} when branch_is_key=false
#   commit_grep     regex marking a ticket's own commits (e.g. "{{key}}([^0-9]|$)")
#   labels_exclude  labels marking non-human/agentic work (needs the REST API; advisory here)
#   cloud_id/base_url  for the REST metadata layer (TODO)
#   project.root    dir containing the repo checkouts; MAHORAGA_REPO_DIR overrides the repo dir.
#
# A ticket may span several repos (branch ABC-123 in both backend and frontend). fork_point/
# change_files/reference_diff resolve within ONE repo: MAHORAGA_REPO_DIR if set, else the first repo
# under project.root whose branch matches. The engine (prepare_task.sh) loops repos for multi-repo units.
#
# Usage:  PROJECT_YAML=/path/PROJECT.yaml  jira.sh <fn> [args]
#   list_units   [since] [n] [exclude_csv] -> "<key>\t<title>\t<merged_at>\t" per line (newest first)
#   fork_point   <unit> [repo]             -> sha (parent of the oldest ticket commit)
#   change_files <unit> [repo]             -> changed path per line
#   reference_diff <unit> [repo]           -> unified diff fork..endpoint (the human's shipped change)
#   metadata     <unit> [repo]             -> key=value lines (id,title,merged_at,repo,fork,tip)
set -u
: "${PROJECT_YAML:?set PROJECT_YAML to the PROJECT.yaml path (see core/schema/PROJECT.schema.yaml)}"
[ -f "$PROJECT_YAML" ] || { echo "jira.sh: PROJECT_YAML not found: $PROJECT_YAML" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GIT="$HERE/../vcs/git.sh"

_cfg() {  # _cfg <op> [dotted] ; op = get|list|repos
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
elif op == "repos":
    for r in (d.get("repos") or []):
        if isinstance(r, dict) and r.get("name"): print(r["name"])
PY
}

ROOT="$(_cfg get project.root)"
KEYPREFIX="$(_cfg get tracker.config.project_key)"
BRANCH_IS_KEY="$(_cfg get tracker.config.branch_is_key)"
COMMIT_GREP_RAW="$(_cfg get tracker.config.commit_grep)"

_interp() { printf '%s' "${1//\{\{key\}\}/$2}"; }   # {{key}} -> the unit key

_resolve_branch() {  # <repo_dir> <key> -> a rev-parseable ref, or empty
  local R="$1" key="$2" cand glob
  if [ "$BRANCH_IS_KEY" = "true" ]; then
    for cand in "origin/$key" "$key"; do
      git -C "$R" rev-parse "$cand" >/dev/null 2>&1 && { echo "$cand"; return; }
    done
  else
    glob="$(_interp "$(_cfg get tracker.config.branch_glob)" "$key")"
    [ -z "$glob" ] && { echo "jira.sh: branch_glob empty but branch_is_key=false ($key)" >&2; return; }
    cand="$(git -C "$R" for-each-ref --format='%(refname:short)' "refs/remotes/origin/$glob" "refs/heads/$glob" 2>/dev/null | head -1)"
    [ -n "$cand" ] && echo "$cand"
  fi
}

_pick_repo() {  # <key> -> absolute repo dir whose branch matches the key (MAHORAGA_REPO_DIR wins)
  local key="$1" name R
  if [ -n "${MAHORAGA_REPO_DIR:-}" ]; then echo "$MAHORAGA_REPO_DIR"; return; fi
  for name in $(_cfg repos); do
    R="$ROOT/$name"
    [ -d "$R/.git" ] || continue
    [ -n "$(_resolve_branch "$R" "$key")" ] && { echo "$R"; return; }
  done
}

# _resolve <unit> [repo] -> "fork<TAB>endpoint<TAB>title<TAB>merged_at<TAB>repo"
_resolve() {
  local key="$1" R="${2:-}" grep_re B TC NEW OLD FORK TIP
  [ -n "$R" ] || R="$(_pick_repo "$key")"
  [ -n "$R" ] && [ -d "$R/.git" ] || { echo "jira.sh: no repo with a branch for '$key' under $ROOT" >&2; return 3; }
  grep_re="$(_interp "$COMMIT_GREP_RAW" "$key")"
  B="$(_resolve_branch "$R" "$key")"
  [ -n "$B" ] || { echo "jira.sh: no branch for '$key' in $R" >&2; return 3; }
  TC=$(git -C "$R" log --no-merges --format='%H %s' "$B" | grep -iE "$grep_re" | awk '{print $1}')
  [ -n "$TC" ] || { echo "jira.sh: branch '$B' has no '$key' commits (commit_grep)" >&2; return 3; }
  NEW=$(echo "$TC" | head -1); OLD=$(echo "$TC" | tail -1)
  FORK=$(git -C "$R" rev-parse "${OLD}^" 2>/dev/null)
  # method-A (fork..newest unit commit); fall back to branch tip if the restricted diff is empty
  if [ -z "$(git -C "$R" diff --name-only "$FORK" "$NEW" 2>/dev/null)" ]; then
    NEW=$(git -C "$R" rev-parse "$B")
  fi
  local title mat
  title="$(git -C "$R" log -1 --format='%s' "$NEW" 2>/dev/null)"
  mat="$(git -C "$R" log -1 --format='%cI' "$NEW" 2>/dev/null)"
  [ -n "$FORK" ] && [ -n "$NEW" ] || { echo "jira.sh: could not derive fork/endpoint for '$key'" >&2; return 3; }
  printf '%s\t%s\t%s\t%s\t%s\n' "$FORK" "$NEW" "$title" "$mat" "$R"
}

# the ticket's OWN changed files (union over its commits), restricting the reference diff to them
_unit_files() {  # <repo> <key>
  local R="$1" key="$2" grep_re B
  grep_re="$(_interp "$COMMIT_GREP_RAW" "$key")"
  B="$(_resolve_branch "$R" "$key")"
  for c in $(git -C "$R" log --no-merges --format='%H %s' "$B" | grep -iE "$grep_re" | awk '{print $1}'); do
    git -C "$R" show --no-merges --name-only --format='' "$c"
  done | sort -u | grep -v '^$'
}

_list_units() {  # [since] [n] [exclude_csv]
  local since="${1:-}" n="${2:-20}" xcsv=",${3:-}," name R key seen=""
  local excl; excl=",$(_cfg list decontamination.exclusion 2>/dev/null | tr '\n' ',')${xcsv}"
  local sinceopt=""; [ -n "$since" ] && sinceopt="--since=$since"
  # enumerate ticket branches across repos, newest commit first, de-duped, minus exclusions.
  for name in $(_cfg repos); do
    R="$ROOT/$name"; [ -d "$R/.git" ] || continue
    git -C "$R" for-each-ref --sort=-committerdate --format='%(refname:short)|%(committerdate:iso-strict)|%(subject)' \
        refs/remotes/origin refs/heads 2>/dev/null \
      | grep -oiE "(^|/)${KEYPREFIX}-[0-9]+\|[^|]*\|.*" \
      | sed -E 's#^/##'
  done | awk -F'|' '{k=$1; sub(/^.*\//,"",k); print k"\t"$3"\t"$2}' \
       | awk -F'\t' '!seen[$1]++' \
       | while IFS=$'\t' read -r key title mat; do
           case "$excl" in *",$key,"*) continue;; esac
           printf '%s\t%s\t%s\t\n' "$key" "$title" "$mat"
         done | head -n "$n"
}

fn="${1:-}"; shift 2>/dev/null || true
case "$fn" in
  list_units)     _list_units "${1:-}" "${2:-}" "${3:-}";;
  fork_point)     r="$(_resolve "${1:?unit}" "${2:-}")" || exit 3; printf '%s\n' "$r" | cut -f1;;
  change_files)   r="$(_resolve "${1:?unit}" "${2:-}")" || exit 3; _unit_files "$(printf '%s' "$r" | cut -f5)" "$1";;
  reference_diff) r="$(_resolve "${1:?unit}" "${2:-}")" || exit 3
                  R="$(printf '%s' "$r" | cut -f5)"; f="$(printf '%s' "$r" | cut -f1)"; t="$(printf '%s' "$r" | cut -f2)"
                  # restrict to the ticket's own files so merged-in mainline noise is excluded
                  FILES="$(_unit_files "$R" "$1")"; ARR=()
                  while IFS= read -r _f; do [ -n "$_f" ] && ARR+=("$_f"); done <<< "$FILES"
                  git -C "$R" diff "$f" "$t" -- "${ARR[@]}" ;;
  metadata)
    r="$(_resolve "${1:?unit}" "${2:-}")" || exit 3
    printf 'id=%s\n' "$1"
    printf 'title=%s\n' "$(printf '%s' "$r" | cut -f3)"
    printf 'merged_at=%s\n' "$(printf '%s' "$r" | cut -f4)"
    printf 'repo=%s\n' "$(printf '%s' "$r" | cut -f5)"
    printf 'fork=%s\n' "$(printf '%s' "$r" | cut -f1)"
    printf 'tip=%s\n' "$(printf '%s' "$r" | cut -f2)"
    printf 'labels=\n'   # TODO(jira-rest): populate from the Jira REST API (labels_exclude filtering)
    ;;
  ""|-h|--help) sed -n '2,30p' "$0";;
  *) echo "jira.sh: unknown fn '$fn' (list_units|fork_point|change_files|reference_diff|metadata)" >&2; exit 2;;
esac
