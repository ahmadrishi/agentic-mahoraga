#!/usr/bin/env bash
# tracker/github_pr.sh — the unit of work is a MERGED PULL REQUEST.
#
# Implements the tracker contract (docs/ADAPTER-CONTRACT.md §1) over local git +
# (optionally) GitHub PR metadata. The fork-point is a real git merge-base, so this
# is exact for the squash/PR teams that are the first target. If the `gh` CLI is
# present it is used for PR listing + labels; otherwise a PURE-GIT fallback is used
# (documented below) so the adapter works with git alone.
#
# There are NO literal hostnames here — the repo slug ("owner/name") and the base
# branch come from PROJECT.yaml.
#
# Config read (from $PROJECT_YAML):
#   project.root                       dir that contains the local checkouts
#   tracker.config.repo                "owner/name" — used by `gh` and to locate the local dir
#   tracker.config.base_branch         e.g. "main"  (falls back to vcs.base_branch, then "main")
#   tracker.config.labels_exclude      list of PR labels that disqualify a unit as a baseline
#   tracker.config.merge_strategy      squash | merge  — only affects which commits list_units
#                                       returns on the pure-git fallback (default: squash).
#   MAHORAGA_REPO_DIR (env, optional)  overrides the local checkout dir directly.
#   MAHORAGA_NO_GH    (env, optional)  when set (non-empty), FORCE the pure-git fallback even if the
#                                      `gh` CLI is installed — so a pure-git fixture (or an offline
#                                      run) is not derailed by a `gh` that happens to be on PATH but
#                                      cannot see this repo. Default (unset): use `gh` when present.
#
# Usage:  PROJECT_YAML=/path/PROJECT.yaml  github_pr.sh <fn> [args]
#
#   list_units   [since] [n] [exclude_csv]   -> "<id>\t<title>\t<merged_at>\t<labels>" per line
#   fork_point   <unit>                      -> sha  (merge-base of base_branch and the unit)
#   change_files <unit>                      -> changed path per line
#   reference_diff <unit>                    -> unified diff (the human's shipped change; a REFERENCE)
#   metadata     <unit>                      -> "key=value" lines (id,title,labels,merged_at,base,tip,fork)
#
# UNIT ID: a PR number when `gh` drives the listing; a git commit sha on the pure-git
# fallback. fork_point/change_files/reference_diff/metadata accept either — a raw sha
# is resolved by parent count (>=2 parents => merge commit; else a squash/plain commit).
set -u

: "${PROJECT_YAML:?set PROJECT_YAML to the PROJECT.yaml path (see core/schema/PROJECT.schema.yaml)}"
[ -f "$PROJECT_YAML" ] || { echo "github_pr.sh: PROJECT_YAML not found: $PROJECT_YAML" >&2; exit 2; }
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
CFGREPO="$(_cfg get tracker.config.repo)"          # owner/name
BASE="$(_cfg get tracker.config.base_branch)"; [ -z "$BASE" ] && BASE="$(_cfg get vcs.base_branch)"; [ -z "$BASE" ] && BASE="main"

_repo_dir() {
  if [ -n "${MAHORAGA_REPO_DIR:-}" ]; then echo "$MAHORAGA_REPO_DIR"; return; fi
  local rn="${CFGREPO##*/}"
  if [ -n "$rn" ] && [ -d "$ROOT/$rn/.git" ]; then echo "$ROOT/$rn"; return; fi
  local first; first="$(_cfg repos_first)"
  echo "$ROOT/$first"
}
REPO_DIR="$(_repo_dir)"
# `gh` drives PR listing/labels only when it is installed AND a repo slug is configured AND the
# operator has not forced pure-git via MAHORAGA_NO_GH. Otherwise the documented pure-git fallback runs.
_have_gh() { [ -z "${MAHORAGA_NO_GH:-}" ] && command -v gh >/dev/null 2>&1 && [ -n "$CFGREPO" ]; }

# --- _resolve <unit> -> "fork<TAB>tip<TAB>title<TAB>merged_at<TAB>labels" -------------
# fork = the point the work forked off base; tip = the human endpoint. reference_diff
# and change_files are both fork..tip, so they line up with the fork-point tree the
# sandbox is staged at (git archive <fork>). This isolates the human's own change (fork..human-endpoint).
_resolve() {
  local unit="$1" fork tip title mat labels sha nparents
  if _have_gh && printf '%s' "$unit" | grep -qE '^[0-9]+$'; then
    local head
    head="$(gh pr view "$unit" --repo "$CFGREPO" --json headRefOid -q .headRefOid 2>/dev/null)"
    title="$(gh pr view "$unit" --repo "$CFGREPO" --json title -q .title 2>/dev/null)"
    mat="$(gh pr view "$unit" --repo "$CFGREPO" --json mergedAt -q .mergedAt 2>/dev/null)"
    labels="$(gh pr view "$unit" --repo "$CFGREPO" --json labels -q '[.labels[].name]|join(",")' 2>/dev/null)"
    tip="$head"
    fork="$("$GIT" merge-base "$REPO_DIR" "$BASE" "$head" 2>/dev/null)"
  else
    sha="$("$GIT" rev-parse "$REPO_DIR" "$unit" 2>/dev/null)" || { echo "github_pr.sh: cannot resolve unit '$unit'" >&2; return 3; }
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
    labels=""   # labels are a host concept; unavailable on the pure-git fallback
  fi
  [ -n "$fork" ] && [ -n "$tip" ] || { echo "github_pr.sh: could not derive fork/tip for '$unit' (is the PR head in local history? see vcs contract)" >&2; return 3; }
  printf '%s\t%s\t%s\t%s\n' "$fork" "$tip" "$title" "${mat}	${labels}"
}

# --- list_units ----------------------------------------------------------------------
_list_units() {  # [since] [n] [exclude_csv]
  local since="${1:-}" n="${2:-20}" xcsv="${3:-}"
  # merge configured excludes with any passed on the CLI
  local excl; excl="$(_cfg list tracker.config.labels_exclude | tr '\n' ',')${xcsv}"
  if _have_gh; then
    local search=""; [ -n "$since" ] && search="merged:>=$since"
    gh pr list --repo "$CFGREPO" --state merged --base "$BASE" --limit "$n" \
        ${search:+--search "$search"} \
        --json number,title,mergedAt,labels 2>/dev/null | python3 - "$excl" <<'PY'
import sys, json
excl = [x.strip().lower() for x in sys.argv[1].split(",") if x.strip()]
for pr in json.load(sys.stdin):
    labs = [l["name"] for l in (pr.get("labels") or [])]
    if any(l.lower() in excl for l in labs):   # a disqualifying label -> not a baseline
        continue
    print("%s\t%s\t%s\t%s" % (pr["number"], pr.get("title","").replace("\t"," "),
                              pr.get("mergedAt",""), ",".join(labs)))
PY
  else
    # PURE-GIT FALLBACK: the last N units on base_branch. Labels are unavailable (so the
    # label-exclude filter is a documented no-op here). merge_strategy picks the shape:
    #   squash (default): last N non-merge first-parent commits (one squashed PR each)
    #   merge           : last N merge commits (one merged PR each)
    local strat; strat="$(_cfg get tracker.config.merge_strategy)"; [ -z "$strat" ] && strat="squash"
    local sinceopt=""; [ -n "$since" ] && sinceopt="--since=$since"
    if [ "$strat" = "merge" ]; then
      git -C "$REPO_DIR" log --merges --first-parent $sinceopt --format='%H%x09%s%x09%cI%x09' -n "$n" "$BASE"
    else
      git -C "$REPO_DIR" log --no-merges --first-parent $sinceopt --format='%H%x09%s%x09%cI%x09' -n "$n" "$BASE"
    fi
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
  *) echo "github_pr.sh: unknown fn '$fn' (list_units|fork_point|change_files|reference_diff|metadata)" >&2; exit 2;;
esac
