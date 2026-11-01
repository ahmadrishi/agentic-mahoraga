#!/usr/bin/env bash
# verify/command.sh — the generic (and only shipped) verify adapter.
#
# Runs a repo's build / typecheck / test commands exactly as declared in
# PROJECT.yaml `repos[].verify` and emits the mandatory HONESTY VERDICT. There is
# NO single global build command: verification is per-repo (see ADAPTER-CONTRACT §4).
#
# Config read (from $PROJECT_YAML, matched by repo dir basename):
#   repos[].verify.build_cmd       non-interactive, test-skipping build (optional)
#   repos[].verify.typecheck_cmd   e.g. "npx tsc --noEmit -p tsconfig.json" (optional)
#   repos[].verify.test_cmd        OPTIONAL — its ABSENCE is why a pass is only BUILD-VERIFIED
#   repos[].verify.success_marker  log line proving build success, grepped from the log
#                                  (NOT the wrapper exit code). Optional: if omitted, the
#                                  build verdict falls back to the command's exit code.
#   repos[].verify.oracle_cmd      OPTIONAL — a command that runs a SINGLE mined behavioural
#                                  oracle (a cheaply-provisionable one), e.g.
#                                  "pytest -q tests/test_ledger.py::test_computes_prorated_refund".
#                                  When declared and the full test_cmd did not run, a green oracle
#                                  climbs the verdict to SMOKE-VERIFIED.
#   repos[].verify.oracle_marker   OPTIONAL — a log line proving the oracle passed, grepped
#                                  fail-closed (like success_marker); else the oracle's exit code is
#                                  the source of truth.
#
# Usage:  PROJECT_YAML=/path/PROJECT.yaml  command.sh <fn> <repo_dir> [abs_log]
#
#   build       <repo_dir> <abs_log>              -> BUILD_SUCCESS | BUILD_FAILURE | n/a
#   typecheck   <repo_dir> <abs_log>              -> pass | fail | n/a            (verdict = exit code)
#   test        <repo_dir> <abs_log>              -> pass | fail | n/a            (verdict = exit code)
#   run_oracle  <repo_dir> <oracle_spec> <abs_log> -> pass | fail | n/a           (verdict = exit/marker)
#   verdict     <repo_dir> [log_dir]             -> UNVERIFIED | BUILD-VERIFIED | SMOKE-VERIFIED | behavior-verified
#
# VERDICT LADDER (low -> high): UNVERIFIED < BUILD-VERIFIED < SMOKE-VERIFIED < behavior-verified.
# (Matches the GUARD honesty-vocabulary skill.) SMOKE-VERIFIED = a mined oracle ran and passed but
# the full test suite did not run/exist; behavior-verified = the full test_cmd ran and passed.
#
# HONESTY RULE (mandatory): never imply tests ran when they did not, and never fake a pass. A repo
# with no test_cmd is at most BUILD-VERIFIED unless a mined oracle actually ran+passed (then
# SMOKE-VERIFIED); an oracle that is not runnable NEVER lifts the verdict. Real full-suite execution
# in the history-free sandbox needs provisioning (deps/network/fixtures) and is a follow-on (see
# docs), not something this adapter fakes.
#
# R12: a build/typecheck cd's INTO the repo, so
# any <abs_log> MUST be an absolute path or the log write fails before the build runs.
set -u

: "${PROJECT_YAML:?set PROJECT_YAML to the PROJECT.yaml path (see core/schema/PROJECT.schema.yaml)}"
[ -f "$PROJECT_YAML" ] || { echo "command.sh: PROJECT_YAML not found: $PROJECT_YAML" >&2; exit 2; }

# --- tiny, self-contained config reader (python3 + PyYAML; no yq/jq) -----------------
# repofield <repo_name> <dotted.field> -> one scalar (nothing if absent / non-scalar)
_repofield() {
  python3 - "$PROJECT_YAML" "$1" "$2" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
name, field = sys.argv[2], sys.argv[3]
for r in (d.get("repos") or []):
    if r.get("name") == name:
        cur = r
        for k in field.split("."):
            if isinstance(cur, dict) and k in cur: cur = cur[k]
            else: cur = None; break
        if cur is not None and not isinstance(cur, (dict, list)):
            print("true" if cur is True else "false" if cur is False else cur)
        break
PY
}

_abslog() {  # <log> — enforce R12
  case "$1" in /*) : ;; *) echo "command.sh: log must be ABSOLUTE (got '$1') — R12" >&2; exit 5;; esac
}

# --- build: grep success_marker if declared, else use the exit code -------------------
_build() {  # <repo_dir> <abs_log> ; echoes verdict, returns 0=success 1=failure 3=n/a
  local repo="$1" log="$2" name cmd marker rc
  [ -d "$repo" ] || { echo "n/a (no repo dir)"; return 3; }
  _abslog "$log"
  name="$(basename "$repo")"
  cmd="$(_repofield "$name" verify.build_cmd)"
  [ -n "$cmd" ] || { echo "n/a (no build_cmd)"; return 3; }
  marker="$(_repofield "$name" verify.success_marker)"
  ( cd "$repo" && bash -lc "$cmd" ) > "$log" 2>&1; rc=$?
  if [ -n "$marker" ]; then
    # FAIL CLOSED on the marker: an explicitly-empty marker is handled above (treated as unset).
    if grep -qF "$marker" "$log"; then echo "BUILD_SUCCESS"; return 0
    else echo "BUILD_FAILURE (marker absent, rc=$rc)"; return 1; fi
  else
    # no marker declared -> the command's exit code is the source of truth
    if [ "$rc" -eq 0 ]; then echo "BUILD_SUCCESS"; return 0
    else echo "BUILD_FAILURE (rc=$rc)"; return 1; fi
  fi
}

# --- typecheck / test: verdict IS the exit code --------------------------------------
_exitcmd() {  # <field> <repo_dir> <abs_log> ; echoes pass|fail|n/a, returns 0|1|3
  local field="$1" repo="$2" log="$3" name cmd rc
  [ -d "$repo" ] || { echo "n/a (no repo dir)"; return 3; }
  _abslog "$log"
  name="$(basename "$repo")"
  cmd="$(_repofield "$name" "verify.${field}_cmd")"   # config keys are typecheck_cmd / test_cmd
  [ -n "$cmd" ] || { echo "n/a (no ${field}_cmd)"; return 3; }
  ( cd "$repo" && bash -lc "$cmd" ) > "$log" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then echo "pass"; return 0; else echo "fail (rc=$rc)"; return 1; fi
}

# --- run_oracle: run ONE mined behavioural oracle -------------------------------
# echoes pass|fail|n/a, returns 0=pass 1=fail 3=n/a. NEVER fakes a pass: an oracle with no spec, no
# repo, or an unprovisionable runner (rc 127) is n/a (not runnable) — only a real exit-0 (or a matched
# marker) is a pass. <marker> is optional and grepped fail-closed like the build success_marker.
_run_oracle() {  # <repo_dir> <oracle_spec> <abs_log> [marker]
  local repo="$1" spec="$2" log="$3" marker="${4:-}" rc
  [ -d "$repo" ] || { echo "n/a (no repo dir)"; return 3; }
  [ -n "$spec" ] || { echo "n/a (no oracle_spec)"; return 3; }
  _abslog "$log"
  ( cd "$repo" && bash -lc "$spec" ) > "$log" 2>&1; rc=$?
  [ "$rc" -eq 127 ] && { echo "n/a (oracle runner not found, rc=127)"; return 3; }
  if [ -n "$marker" ]; then
    if grep -qF "$marker" "$log"; then echo "pass"; return 0
    else echo "fail (marker absent, rc=$rc)"; return 1; fi
  else
    if [ "$rc" -eq 0 ]; then echo "pass"; return 0
    else echo "fail (rc=$rc)"; return 1; fi
  fi
}

# --- verdict: compose the honesty verdict --------------------------------------------
_verdict() {  # <repo_dir> [log_dir]
  local repo="$1" logdir="${2:-}" name gate_ran=0 gate_ok=0 test_ran=0 test_ok=0 v
  local ocmd omark orc_ran=0 orc_ok=0
  [ -d "$repo" ] || { echo "UNVERIFIED"; echo "  reason: no repo dir at $repo" >&2; return 0; }
  name="$(basename "$repo")"
  if [ -z "$logdir" ]; then logdir="$(mktemp -d)"; fi
  mkdir -p "$logdir"; case "$logdir" in /*) : ;; *) logdir="$(cd "$logdir" && pwd)";; esac

  # compile gate: prefer build_cmd, else typecheck_cmd
  if [ -n "$(_repofield "$name" verify.build_cmd)" ]; then
    v="$(_build "$repo" "$logdir/build.log")"; [ "${v#BUILD_SUCCESS}" != "$v" ] && gate_ok=1; gate_ran=1
    echo "  build: $v" >&2
  elif [ -n "$(_repofield "$name" verify.typecheck_cmd)" ]; then
    v="$(_exitcmd typecheck "$repo" "$logdir/typecheck.log")"; [ "$v" = "pass" ] && gate_ok=1; gate_ran=1
    echo "  typecheck: $v" >&2
  fi

  # tests (optional)
  if [ -n "$(_repofield "$name" verify.test_cmd)" ]; then
    v="$(_exitcmd test "$repo" "$logdir/test.log")"; [ "$v" = "pass" ] && test_ok=1; test_ran=1
    echo "  test: $v" >&2
  fi

  # mined behavioural oracle (optional) — only meaningful when the full test suite did NOT run.
  ocmd="$(_repofield "$name" verify.oracle_cmd)"
  if [ "$test_ran" -eq 0 ] && [ -n "$ocmd" ]; then
    omark="$(_repofield "$name" verify.oracle_marker)"
    v="$(_run_oracle "$repo" "$ocmd" "$logdir/oracle.log" "$omark")"
    case "$v" in pass) orc_ran=1; orc_ok=1;; fail*) orc_ran=1;; esac   # n/a => not runnable, did not run
    echo "  oracle: $v" >&2
  fi

  # honesty composition — never imply tests ran when they did not; never fake a pass.
  if [ "$gate_ran" -eq 1 ] && [ "$gate_ok" -eq 0 ]; then
    echo "UNVERIFIED"; echo "  reason: build/typecheck failed" >&2
  elif [ "$test_ran" -eq 1 ] && [ "$test_ok" -eq 1 ]; then
    echo "behavior-verified"
  elif [ "$test_ran" -eq 1 ] && [ "$test_ok" -eq 0 ]; then
    echo "UNVERIFIED"; echo "  reason: tests ran and failed" >&2
  elif [ "$orc_ran" -eq 1 ] && [ "$orc_ok" -eq 1 ]; then
    echo "SMOKE-VERIFIED"; echo "  reason: a mined oracle ran and passed; full test_cmd did not run/exist" >&2
  elif [ "$orc_ran" -eq 1 ] && [ "$orc_ok" -eq 0 ]; then
    echo "UNVERIFIED"; echo "  reason: a mined oracle ran and failed" >&2
  elif [ "$gate_ran" -eq 1 ] && [ "$test_ran" -eq 0 ]; then
    echo "BUILD-VERIFIED"; echo "  reason: build/typecheck passed; no test_cmd (nor a runnable oracle) — not behavior-verified" >&2
  else
    echo "UNVERIFIED"; echo "  reason: nothing to verify (no build/typecheck/test/oracle cmd ran for '$name')" >&2
  fi
}

fn="${1:-}"; shift 2>/dev/null || true
case "$fn" in
  build)     _build "${1:-}" "${2:-}";     exit $?;;
  typecheck) _exitcmd typecheck "${1:-}" "${2:-}"; exit $?;;
  test)      _exitcmd test "${1:-}" "${2:-}";      exit $?;;
  run_oracle)
    _ro_repo="${1:-}"; _ro_marker=""
    [ -d "$_ro_repo" ] && _ro_marker="$(_repofield "$(basename "$_ro_repo")" verify.oracle_marker)"
    _run_oracle "$_ro_repo" "${2:-}" "${3:-}" "$_ro_marker"; exit $?;;
  verdict)   _verdict "${1:-}" "${2:-}";   exit 0;;
  ""|-h|--help) sed -n '2,43p' "$0";;
  *) echo "command.sh: unknown fn '$fn' (build|typecheck|test|run_oracle|verdict)" >&2; exit 2;;
esac
