#!/usr/bin/env bash
# adapters.sh — the adapter DISPATCH SHIM. `source` me (after PROJECT_CONFIG is set), or run me as a
# CLI: `adapters.sh <family> <fn> [args...]`.
#
# The core never branches on a vendor: it calls the adapter named in PROJECT.yaml. This shim resolves
# that name to core/adapters/<family>/<adapter>.sh and runs it, bridging the engine's PROJECT_CONFIG
# env var to the PROJECT_YAML the adapters read for themselves. See docs/ADAPTER-CONTRACT.md.
#
# Four dispatchers — each runs  <family>/<adapter>.sh <fn> [args...]  with PROJECT_YAML exported:
#   tracker_fn <fn> [args...]    adapter = tracker.adapter   (github-pr|jira|linear|gitea|file|none)
#   spec_fn    <fn> [args...]    adapter = spec.adapter      (markdown|issue-body|confluence|notion|gdocs|none)
#   verify_fn  <fn> [args...]    adapter = verify.adapter    (default "command" — the only shipped one)
#   vcs_fn     <verb> [args...]  adapter = git               (vcs is ALWAYS git — no config branch)
#
# NAME -> FILE: a tracker/spec adapter name maps to a filename by turning '-' into '_'
# (github-pr -> github_pr.sh, issue-body -> issue_body.sh). If only a "<name>.stub.sh" exists the
# adapter is DECLARED-BUT-UNIMPLEMENTED and the dispatcher errors clearly (exit 64); a genuinely
# missing adapter errors too (exit 2). Both are fail-closed — the caller never silently proceeds.
set -u

_ADAPTERS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Self-contained: source the config loader if the caller has not already. lib.sh requires
# PROJECT_CONFIG and fails closed (return/exit non-zero) if it is unset — that check propagates here.
if ! declare -F cfg_get >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_ADAPTERS_SH_DIR/lib.sh"
fi

ADAPTERS_ROOT="$_ADAPTERS_SH_DIR/../adapters"   # resolved from the shim's own location, CWD-independent

# _resolve_adapter <family> <name> -> prints the adapter script path on stdout.
# Distinguishes an UNIMPLEMENTED stub (exit 64) from a genuinely-missing adapter (exit 2).
_resolve_adapter() {
  local family="$1" name="$2" base file stub
  [ -n "$name" ] || {
    echo "adapters.sh: no adapter configured for '$family' — set '${family}.adapter' in PROJECT.yaml" >&2
    return 2
  }
  base="$(printf '%s' "$name" | tr '-' '_')"          # github-pr -> github_pr ; issue-body -> issue_body
  file="$ADAPTERS_ROOT/$family/$base.sh"
  stub="$ADAPTERS_ROOT/$family/$base.stub.sh"
  if [ -f "$file" ]; then
    printf '%s\n' "$file"
    return 0
  elif [ -f "$stub" ]; then
    echo "adapters.sh: $family adapter '$name' is a STUB (not implemented) — $stub" >&2
    echo "adapters.sh: use an implemented $family adapter for now (see docs/ADAPTER-CONTRACT.md and core/adapters/$family/)" >&2
    return 64
  else
    echo "adapters.sh: $family adapter '$name' not found — expected $file (see core/adapters/$family/)" >&2
    return 2
  fi
}

# _dispatch <family> <config-key> <default-adapter> <fn> [args...]
_dispatch() {
  local family="$1" cfgkey="$2" default="$3"; shift 3
  local name path rc
  name="$(cfg_get "$cfgkey")"; [ -n "$name" ] || name="$default"
  path="$(_resolve_adapter "$family" "$name")"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # Bridge PROJECT_CONFIG (engine env var) -> PROJECT_YAML (what the adapters read). Prefix-assigned
  # so it is exported to the adapter's environment only, without polluting the caller's shell.
  PROJECT_YAML="$PROJECT_CONFIG" bash "$path" "$@"
}

tracker_fn() { _dispatch tracker "tracker.adapter" ""        "$@"; }
spec_fn()    { _dispatch spec    "spec.adapter"    ""        "$@"; }
verify_fn()  { _dispatch verify  "verify.adapter"  "command" "$@"; }   # no verify.adapter key => "command"

# vcs is ALWAYS git — there is no vcs adapter to resolve. git.sh reads no config; PROJECT_YAML is
# exported for uniformity with the other dispatchers (harmless for git.sh).
vcs_fn() {
  local git_sh="$ADAPTERS_ROOT/vcs/git.sh"
  [ -f "$git_sh" ] || { echo "adapters.sh: vcs adapter (git) missing — expected $git_sh" >&2; return 2; }
  PROJECT_YAML="$PROJECT_CONFIG" bash "$git_sh" "$@"
}

# CLI form (handy for tests / manual runs). Sourced use defines the *_fn functions instead.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  fam="${1:-}"; shift 2>/dev/null || true
  case "$fam" in
    tracker) tracker_fn "$@";;
    spec)    spec_fn "$@";;
    verify)  verify_fn "$@";;
    vcs)     vcs_fn "$@";;
    ""|-h|--help) sed -n '2,20p' "$0";;
    *) echo "adapters.sh: unknown family '$fam' (tracker|spec|verify|vcs)" >&2; exit 2;;
  esac
fi
