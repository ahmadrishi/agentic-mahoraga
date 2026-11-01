#!/usr/bin/env bash
# tracker/file.sh — the unit of work comes from a hand-maintained CSV.
#
# The escape hatch for any workflow the built-in trackers miss: you list the units
# yourself as rows of  unit_id,fork_point,ref  and this adapter turns each row into
# the tracker contract (docs/ADAPTER-CONTRACT.md §1) using local git for the diffs.
#   unit_id    an id you choose (names the task dir)
#   fork_point a git rev the sandbox is staged at (history-free tree)
#   ref        a git rev = the human endpoint; reference_diff is fork_point..ref
#
# There are NO hostnames here. The CSV path and the repo live in PROJECT.yaml.
#
# Config read (from $PROJECT_YAML):
#   project.root                   dir that contains the local checkout
#   tracker.config.path            CSV path (absolute, or relative to CWD then project.root)
#   tracker.config.repo            optional "owner/name" — its basename locates the local dir
#   MAHORAGA_REPO_DIR (env)         overrides the local checkout dir
#
# Usage:  PROJECT_YAML=/path/PROJECT.yaml  file.sh <fn> [args]
#   list_units   [since] [n] [filters]  -> "<unit_id>\t<ref>\t\t" per line (n limits; since/filters ignored)
#   fork_point   <unit>                 -> the row's fork_point
#   change_files <unit>                 -> changed path per line (fork_point..ref)
#   reference_diff <unit>               -> unified diff fork_point..ref
#   metadata     <unit>                 -> "key=value" lines (id,fork,tip)
set -u

: "${PROJECT_YAML:?set PROJECT_YAML to the PROJECT.yaml path (see core/schema/PROJECT.schema.yaml)}"
[ -f "$PROJECT_YAML" ] || { echo "file.sh: PROJECT_YAML not found: $PROJECT_YAML" >&2; exit 2; }
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

_repo_dir() {
  if [ -n "${MAHORAGA_REPO_DIR:-}" ]; then echo "$MAHORAGA_REPO_DIR"; return; fi
  local rn="${CFGREPO##*/}"
  if [ -n "$rn" ] && [ -d "$ROOT/$rn/.git" ]; then echo "$ROOT/$rn"; return; fi
  echo "$ROOT/$(_cfg repos_first)"
}
REPO_DIR="$(_repo_dir)"

_csv() {  # resolve the CSV path
  local p; p="$(_cfg get tracker.config.path)"
  [ -n "$p" ] || { echo "file.sh: tracker.config.path is required (the CSV of unit_id,fork_point,ref)" >&2; exit 2; }
  case "$p" in
    /*) echo "$p";;
    *)  if [ -f "$p" ]; then echo "$p"; elif [ -f "$ROOT/$p" ]; then echo "$ROOT/$p"; else echo "$p"; fi;;
  esac
}

# _row <unit> -> "fork_point<TAB>ref"  (first matching data row; skips header/blank/#)
_row() {
  local unit="$1" csv; csv="$(_csv)"
  [ -f "$csv" ] || { echo "file.sh: CSV not found: $csv" >&2; return 3; }
  awk -F',' -v u="$unit" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NR==1 && $1=="unit_id" { next }        # skip a header row if present
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1) }
    $1==u { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3);
            printf "%s\t%s\n", $2, $3; exit }
  ' "$csv"
}

fn="${1:-}"; shift 2>/dev/null || true
case "$fn" in
  list_units)
    n="${2:-0}"; csv="$(_csv)"
    [ -f "$csv" ] || { echo "file.sh: CSV not found: $csv" >&2; exit 3; }
    awk -F',' '
      /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next }
      NR==1 && $1=="unit_id" { next }
      { for(i=1;i<=3;i++) gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i);
        printf "%s\t%s\t\t\n", $1, $3 }
    ' "$csv" | { if [ "${n:-0}" -gt 0 ] 2>/dev/null; then head -n "$n"; else cat; fi; }
    ;;
  fork_point)
    r="$(_row "${1:?unit}")" || exit 3; [ -n "$r" ] || { echo "file.sh: no row for '$1'" >&2; exit 3; }
    printf '%s' "$r" | cut -f1
    ;;
  change_files)
    r="$(_row "${1:?unit}")" || exit 3; [ -n "$r" ] || { echo "file.sh: no row for '$1'" >&2; exit 3; }
    "$GIT" name-only "$REPO_DIR" "$(printf '%s' "$r" | cut -f1)" "$(printf '%s' "$r" | cut -f2)"
    ;;
  reference_diff)
    r="$(_row "${1:?unit}")" || exit 3; [ -n "$r" ] || { echo "file.sh: no row for '$1'" >&2; exit 3; }
    "$GIT" diff "$REPO_DIR" "$(printf '%s' "$r" | cut -f1)" "$(printf '%s' "$r" | cut -f2)"
    ;;
  metadata)
    r="$(_row "${1:?unit}")" || exit 3; [ -n "$r" ] || { echo "file.sh: no row for '$1'" >&2; exit 3; }
    printf 'id=%s\n' "$1"
    printf 'fork=%s\n' "$(printf '%s' "$r" | cut -f1)"
    printf 'tip=%s\n' "$(printf '%s' "$r" | cut -f2)"
    ;;
  ""|-h|--help) sed -n '2,30p' "$0";;
  *) echo "file.sh: unknown fn '$fn' (list_units|fork_point|change_files|reference_diff|metadata)" >&2; exit 2;;
esac
