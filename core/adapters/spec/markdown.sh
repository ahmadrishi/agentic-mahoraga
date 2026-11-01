#!/usr/bin/env bash
# spec/markdown.sh — the spec is a Markdown file already in the repo.
#
# The trivial, high-fidelity spec source: point a glob at the design/requirement doc
# the team wrote (e.g. "docs/specs/{{unit}}.md" or "docs/design/*.md") and this adapter
# copies it verbatim to SPEC.md. Implements the spec contract (docs/ADAPTER-CONTRACT.md §2).
#
# Config read (from $PROJECT_YAML):
#   project.root         dir that contains the repos
#   spec.config.glob     shell glob for the spec file; {{unit}} is interpolated
#   spec.untranscribable list of formats that force task exclusion (is_transcribable)
#
# Usage:  PROJECT_YAML=/path/PROJECT.yaml  markdown.sh <fn> [args]
#   fetch_spec      <unit> <out_dir>   writes <out_dir>/SPEC.md; prints "SPEC: OK" or
#                                      "SPEC: THIN (...)" (exit 3, nothing written, if no match)
#   is_transcribable <fmt>             exit 0 (true) / 1 (false, when fmt is untranscribable)
set -u

: "${PROJECT_YAML:?set PROJECT_YAML to the PROJECT.yaml path (see core/schema/PROJECT.schema.yaml)}"
[ -f "$PROJECT_YAML" ] || { echo "markdown.sh: PROJECT_YAML not found: $PROJECT_YAML" >&2; exit 2; }

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

_is_transcribable() {  # <fmt>
  local fmt="$1" bad
  # a Markdown/text spec is transcribable unless the operator listed the format as excluded
  while IFS= read -r bad; do
    [ -z "$bad" ] && continue
    [ "$(printf '%s' "$fmt" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$bad" | tr '[:upper:]' '[:lower:]')" ] && return 1
  done < <(_cfg list spec.untranscribable)
  return 0
}

_fetch_spec() {  # <unit> <out_dir>
  local unit="$1" out="${2:?markdown.sh: fetch_spec needs <out_dir>}"
  mkdir -p "$out"
  local root glob first found=""
  root="$(_cfg get project.root)"
  glob="$(_cfg get spec.config.glob)"
  [ -n "$glob" ] || { echo "markdown.sh: spec.config.glob is required" >&2; exit 2; }
  glob="${glob//\{\{unit\}\}/$unit}"
  first="$(_cfg repos_first)"
  # search relative to project.root, then to the first repo dir
  local base f
  for base in "$root" "$root/$first"; do
    [ -d "$base" ] || continue
    # shellcheck disable=SC2086  # intentional glob expansion of $glob
    for f in $(cd "$base" 2>/dev/null && ls -1d $glob 2>/dev/null); do
      if [ -f "$base/$f" ]; then found="$base/$f"; break 2; fi
    done
  done
  if [ -z "$found" ]; then
    echo "SPEC: THIN (no file matched glob '$glob' under $root)"
    return 3
  fi
  cp "$found" "$out/SPEC.md"
  echo "SPEC: OK (from $found)"
}

fn="${1:-}"; shift 2>/dev/null || true
case "$fn" in
  fetch_spec)      _fetch_spec "${1:?unit}" "${2:-}"; exit $?;;
  is_transcribable) if _is_transcribable "${1:?fmt}"; then echo true; exit 0; else echo false; exit 1; fi;;
  ""|-h|--help) sed -n '2,20p' "$0";;
  *) echo "markdown.sh: unknown fn '$fn' (fetch_spec|is_transcribable)" >&2; exit 2;;
esac
