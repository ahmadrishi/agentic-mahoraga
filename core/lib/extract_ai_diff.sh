#!/usr/bin/env bash
# extract_ai_diff.sh <RUN_DIR> <UNIT_KEY> <SLUG> <VARIANT>
# Diff the sandbox's current state vs the pristine fork-point tree -> $RUN_DIR/<KEY>/<VARIANT>_<repo>.diff
# VARIANT is an AI-run label (e.g. "ai","blind","rt2") — always the AI's work; use an "ai"-prefixed
# variant for the scored run since build_report.py globs ai_*.diff.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
RUN_DIR="$1"; KEY="$2"; SLUG="$3"; VARIANT="$4"
TASKDIR="$RUN_DIR/$KEY"; SB="$SANDBOX_ROOT/$SLUG"
TMP=$(mktemp -d)
while IFS= read -r line; do
  repo=$(echo "$line" | cut -d'|' -f1)
  fork=$(echo "$line" | sed -n 's/.*|fork=\([0-9a-f]*\)|.*/\1/p')
  [ -z "$repo" ] && continue; [ -z "$fork" ] && continue
  mkdir -p "$TMP/$repo"
  git -C "$PROJECT_ROOT/$repo" archive "$fork" | tar -x -C "$TMP/$repo"
  # Per-repo build-artifact excludes come from lang_profiles.excludes(<repo language>) — the
  # single source of truth shared with the leak gate — so a non-JS/Java repo's generated dirs
  # (__pycache__/.venv for python, build/.gradle for gradle, bin/obj for dotnet, vendor/ for go, …)
  # don't pollute the AI-vs-fork diff. '.git' is always excluded regardless of language.
  lang=$(repo_field "$repo" language)
  EXARGS=( --exclude='.git' )
  while IFS= read -r _d; do
    [ -n "$_d" ] && EXARGS+=( "--exclude=$_d" )
  done < <(python3 "$HERE/lang_profiles.py" excludes "$lang")
  ( cd "$TMP" && diff -ruN "${EXARGS[@]}" "$repo" "$SB/$repo" ) > "$TASKDIR/${VARIANT}_${repo}.diff" 2>/dev/null
  files=$(grep -cE '^diff ' "$TASKDIR/${VARIANT}_${repo}.diff" 2>/dev/null || true); files=${files:-0}
  lines=$(grep -cE '^[+-]' "$TASKDIR/${VARIANT}_${repo}.diff" 2>/dev/null || true); lines=${lines:-0}
  echo "  ${VARIANT}_${repo}.diff: ~${files} files, ${lines} +/- lines"
done < "$TASKDIR/meta.lines"
rm -rf "$TMP"
