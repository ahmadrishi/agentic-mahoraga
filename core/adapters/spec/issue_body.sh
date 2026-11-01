#!/usr/bin/env bash
# spec/issue_body.sh — the spec is the tracker unit's own body (PR description / ticket body).
#
# When there is no separate design doc, the unit's own prose is the best available spec.
# This adapter writes that body to SPEC.md and, when the body is THIN, sets the
# `attribution-ambiguous` flag: with only a PR description the dual-input probe's
# skill-gap-vs-spec-gap signal is weak, so spec-fidelity must NOT be scored as if an
# independent spec existed (docs/ADAPTER-CONTRACT.md §2).
#
# It reads the body from the SAME source the tracker uses:
#   tracker.adapter=github-pr + `gh` present + numeric unit  -> the PR description
#   otherwise                                                -> the unit commit's full message
#
# Config read (from $PROJECT_YAML): project.root, tracker.adapter, tracker.config.repo,
#   spec.untranscribable. NO literal hostnames.
#
# Usage:  PROJECT_YAML=/path/PROJECT.yaml  issue_body.sh <fn> [args]
#   fetch_spec      <unit> <out_dir>   writes <out_dir>/SPEC.md; on a thin body also writes
#                                      <out_dir>/.attribution-ambiguous and prints "SPEC: THIN ..."
#   is_transcribable <fmt>             exit 0 (true) / 1 (false, when fmt is untranscribable)
set -u

: "${PROJECT_YAML:?set PROJECT_YAML to the PROJECT.yaml path (see core/schema/PROJECT.schema.yaml)}"
[ -f "$PROJECT_YAML" ] || { echo "issue_body.sh: PROJECT_YAML not found: $PROJECT_YAML" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GIT="$HERE/../vcs/git.sh"

# THIN when fewer than this many words survive (a one-line "fix bug" body carries no spec).
THIN_WORDS="${MAHORAGA_SPEC_THIN_WORDS:-40}"

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
CFGREPO="$(_cfg get tracker.config.repo)"
ADAPTER="$(_cfg get tracker.adapter)"

_repo_dir() {
  if [ -n "${MAHORAGA_REPO_DIR:-}" ]; then echo "$MAHORAGA_REPO_DIR"; return; fi
  local rn="${CFGREPO##*/}"
  if [ -n "$rn" ] && [ -d "$ROOT/$rn/.git" ]; then echo "$ROOT/$rn"; return; fi
  echo "$ROOT/$(_cfg repos_first)"
}

_is_transcribable() {  # <fmt>
  local fmt="$1" bad
  while IFS= read -r bad; do
    [ -z "$bad" ] && continue
    [ "$(printf '%s' "$fmt" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$bad" | tr '[:upper:]' '[:lower:]')" ] && return 1
  done < <(_cfg list spec.untranscribable)
  return 0
}

# _body <unit> -> the unit's descriptive text on stdout
_body() {
  local unit="$1"
  if [ "$ADAPTER" = "github-pr" ] && command -v gh >/dev/null 2>&1 && [ -n "$CFGREPO" ] && printf '%s' "$unit" | grep -qE '^[0-9]+$'; then
    gh pr view "$unit" --repo "$CFGREPO" --json body -q .body 2>/dev/null
  else
    git -C "$(_repo_dir)" log -1 --format='%B' "$unit" 2>/dev/null
  fi
}

_fetch_spec() {  # <unit> <out_dir>
  local unit="$1" out="${2:?issue_body.sh: fetch_spec needs <out_dir>}"
  mkdir -p "$out"
  local body words
  body="$(_body "$unit")"
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    echo "SPEC: THIN (empty body for unit '$unit')"
    return 3
  fi
  printf '%s\n' "$body" > "$out/SPEC.md"
  words="$(printf '%s' "$body" | wc -w | tr -d ' ')"
  if [ "${words:-0}" -lt "$THIN_WORDS" ]; then
    echo "spec source: tracker unit body ($ADAPTER); $words words — below thin threshold ($THIN_WORDS)" > "$out/.attribution-ambiguous"
    echo "SPEC: THIN (attribution-ambiguous; $words words)"
  else
    echo "SPEC: OK ($words words)"
  fi
}

fn="${1:-}"; shift 2>/dev/null || true
case "$fn" in
  fetch_spec)       _fetch_spec "${1:?unit}" "${2:-}"; exit $?;;
  is_transcribable) if _is_transcribable "${1:?fmt}"; then echo true; exit 0; else echo false; exit 1; fi;;
  ""|-h|--help) sed -n '2,24p' "$0";;
  *) echo "issue_body.sh: unknown fn '$fn' (fetch_spec|is_transcribable)" >&2; exit 2;;
esac
