#!/usr/bin/env bash
# lib.sh — config loader for the Agentic Mahoraga core engine. `source` me.
# Requires: PROJECT_CONFIG = absolute path to a PROJECT.yaml (see core/schema/PROJECT.schema.yaml).
# Provides: cfg_get / cfg_list / repos_names / repo_field / repo_compiles / cfg_tokens / cfg_interp
#           and exported PROJECT_ID, PROJECT_ROOT, SANDBOX_ROOT.
# Dependency-light: python3 + PyYAML (via cfgquery.py) + coreutils. No yq/jq. OS-portable.

: "${PROJECT_CONFIG:?set PROJECT_CONFIG to the project yaml path (see core/schema/PROJECT.schema.yaml)}"
if [ ! -f "$PROJECT_CONFIG" ]; then
  echo "lib.sh: PROJECT_CONFIG not found: $PROJECT_CONFIG" >&2
  return 1 2>/dev/null || exit 1
fi

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"   # ${..:-$0} so `source lib.sh` works under zsh too
_CFGQ="$_LIB_DIR/cfgquery.py"

cfg_get()    { python3 "$_CFGQ" get "$1"; }
cfg_list()   { python3 "$_CFGQ" list "$1"; }
repos_names(){ python3 "$_CFGQ" repos; }
repo_field() { python3 "$_CFGQ" repofield "$1" "$2"; }   # <name> <field> (field may be dotted, e.g. verify.build_cmd)
cfg_tokens() { python3 "$_CFGQ" tokens "$1"; }           # <unit-id>
# cfg_interp <string> [unit-key] — expands {{project.id}} {{run_id}} {{key}} and ${TMPDIR:-/tmp}
cfg_interp() { KEY="${2:-${KEY:-}}" RUN_ID="${RUN_ID:-}" python3 "$_CFGQ" interp "$1"; }

# repo_compiles <name> -> "true"/"false".
# A repo "compiles" iff it declares repos[].verify.build_cmd (the new schema INFERS this from the
# presence of a build command; it replaces the old explicit repos[].compiles bool).
repo_compiles() { [ -n "$(repo_field "$1" verify.build_cmd)" ] && echo "true" || echo "false"; }

export PROJECT_ID="$(cfg_get project.id)"
export PROJECT_ROOT="$(cfg_get project.root)"

# SANDBOX_ROOT: fall back to the documented schema default when output.sandbox_root is unset, then
# interpolate {{project.id}}/{{run_id}} and the shell-style ${TMPDIR:-/tmp} (resolved in cfgquery.py,
# so it is portable — no macOS-specific /private/tmp). A leading ~ is expanded here.
_RAW_SBR="$(cfg_get output.sandbox_root)"
[ -n "$_RAW_SBR" ] || _RAW_SBR='${TMPDIR:-/tmp}/{{project.id}}-mahoraga-sandboxes'
SANDBOX_ROOT="$(cfg_interp "$_RAW_SBR")"
case "$SANDBOX_ROOT" in "~"*) SANDBOX_ROOT="${HOME}${SANDBOX_ROOT#\~}";; esac
export SANDBOX_ROOT
