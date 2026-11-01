#!/usr/bin/env bash
# compile_gate.sh <SANDBOX_REPO_DIR> <ABS_LOG>
# Build / type-check a sandbox repo using that repo's repos[].verify.* config.
# The script cd's INTO the repo, so <ABS_LOG> MUST be an ABSOLUTE path or the log write fails before
# the build runs. For a repo with a build_cmd the verdict = grep of verify.success_marker in the log
# (NOT the wrapper exit code). For a repo with only a typecheck_cmd the verdict IS the exit code (a
# type-checker has no marker line). Build logs may contain credentials, so callers redact before
# publishing (see build_report.py); this script never echoes the build command's output to stdout.
#
# NOTE: verify.test_cmd is intentionally NOT run here. Real test execution in a history-free sandbox
# needs provisioning (deps / network / fixtures / DB) and is a follow-on, not a build-gate
# concern — absent a test run, a repo is BUILD-VERIFIED, not behavior-verified (see ADAPTER-CONTRACT.md).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
REPO="$1"; LOG="$2"
case "$LOG" in /*) : ;; *) echo "compile_gate: LOG must be ABSOLUTE (got '$LOG')" >&2; exit 5;; esac
[ -d "$REPO" ] || { echo "NO_REPO"; exit 3; }
NAME="$(basename "$REPO")"

# --- no build_cmd: type-check path (verdict = exit code) ---
if [ "$(repo_compiles "$NAME")" != "true" ]; then
  TC="$(repo_field "$NAME" verify.typecheck_cmd)"
  if [ -z "$TC" ]; then echo "n/a (no build_cmd, no typecheck_cmd)"; exit 3; fi
  cd "$REPO"
  bash -lc "$TC" > "$LOG" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then echo "BUILD_SUCCESS (typecheck)"; exit 0; else echo "BUILD_FAILURE (typecheck) rc=$rc"; exit 1; fi
fi

# --- build_cmd present: build + grep the success marker ---
CMD="$(cfg_interp "$(repo_field "$NAME" verify.build_cmd)")"
[ -n "$CMD" ] || { echo "NO_BUILD_CMD"; exit 3; }
MARKER="$(repo_field "$NAME" verify.success_marker)"
# FAIL CLOSED: an empty marker makes `grep -qF ""` match any non-empty log => every build "passes".
[ -n "$MARKER" ] || { echo "compile_gate: empty verify.success_marker for repo '$NAME' (would fail open)" >&2; exit 5; }
cd "$REPO"
bash -lc "$CMD" > "$LOG" 2>&1
rc=$?
if grep -qF "$MARKER" "$LOG"; then echo "BUILD_SUCCESS"; exit 0; else echo "BUILD_FAILURE rc=$rc"; exit 1; fi
