#!/usr/bin/env bash
# stage_sandbox.sh <RUN_DIR> <UNIT_KEY> <SLUG>
# Stage an ISOLATED, history-free sandbox: each touched repo at its fork-point (NO .git) + the
# project's skills (derived ones sanitized) + SPEC.md + BUSINESS_REQUIREMENT.md.
# Opaque slug => no unit id in the path. Then run the leak-gate; ABORT if it fails.
set -eu
set -o pipefail   # so a failed `git archive` in `archive | tar` can't yield a silent partial sandbox
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
RUN_DIR="$1"; KEY="$2"; SLUG="$3"
TASKDIR="$RUN_DIR/$KEY"
[ -f "$TASKDIR/meta.lines" ] || { echo "stage_sandbox: no meta.lines — run prepare_task.sh first" >&2; exit 4; }
# the slug must be opaque — it must not reveal the unit key to the implementer
case "$SLUG" in *"$KEY"*) echo "stage_sandbox: SLUG must be opaque and must NOT contain the unit key '$KEY'" >&2; exit 6;; esac
# the orchestrator must have written SPEC.md + BUSINESS_REQUIREMENT.md into the task dir (no script writes these)
for req in SPEC.md BUSINESS_REQUIREMENT.md; do
  [ -f "$TASKDIR/$req" ] || { echo "stage_sandbox: missing $TASKDIR/$req — gather the SPEC + business requirement into the task dir BEFORE staging (fetch from the spec source + tracker)." >&2; exit 4; }
done
SB="$SANDBOX_ROOT/$SLUG"
rm -rf "$SB"; mkdir -p "$SB"

# 1. each touched repo at its fork-point, history-free
while IFS= read -r line; do
  repo=$(echo "$line" | cut -d'|' -f1)
  fork=$(echo "$line" | sed -n 's/.*|fork=\([0-9a-f]*\)|.*/\1/p')
  [ -z "$repo" ] && continue; [ -z "$fork" ] && continue
  mkdir -p "$SB/$repo"
  git -C "$PROJECT_ROOT/$repo" archive "$fork" | tar -x -C "$SB/$repo"
  echo "  staged $repo @ ${fork:0:9}"
done < "$TASKDIR/meta.lines"

# 2. skills (project's live set), then sanitize the derived ones — FAIL CLOSED
mkdir -p "$SB/.claude"
cp -R "$(cfg_get skills.source_dir)" "$SB/.claude/skills"
# NEVER stage Mahoraga's OWN meta-skills into the blind sandbox: they describe the eval itself
# (staging/scoring/decontamination) and would tell the implementer it is being tested, or hand it the
# methodology as an answer key. The set is READ FROM core/schema/STRIP_SET.manifest (NOT hard-coded):
# a list hard-coded here would silently leave a renamed or newly added meta-skill in the sandbox — a
# decontamination TELL. Reading the manifest keeps this correct as skills evolve;
# CI's zero-residue test asserts none survive staging. Basename match ANYWHERE under the staged tree.
STRIP_MANIFEST="$HERE/../schema/STRIP_SET.manifest"
# FAIL CLOSED: a missing manifest means we cannot know what to strip -> staging the meta-skills would
# leak the methodology, so abort rather than proceed under-protected.
[ -f "$STRIP_MANIFEST" ] || { echo "stage_sandbox: STRIP_SET.manifest not found at $STRIP_MANIFEST — cannot strip meta-skills" >&2; rm -rf "$SB"; exit 5; }
while IFS= read -r sname || [ -n "$sname" ]; do
  sname="${sname%%#*}"                             # drop inline / whole-line comments
  sname="$(echo "$sname" | tr -d '[:space:]')"     # trim all surrounding whitespace
  [ -z "$sname" ] && continue
  # collect matches first, THEN remove, so pruning a parent can't disturb an in-flight find traversal
  matches="$(find "$SB/.claude/skills" -type d -name "$sname" -prune 2>/dev/null || true)"
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    rm -rf "$d"
    echo "  excluded meta-skill from sandbox: ${d#"$SB/.claude/skills/"}"
  done <<< "$matches"
done < "$STRIP_MANIFEST"
if ! bash "$HERE/sanitize_skills.sh" "$SB/.claude/skills"; then
  echo "SANITIZE FAILED — staging aborted, removing $SB (a derived skill lacks its SKILL.sanitized.md)" >&2
  rm -rf "$SB"; exit 2
fi
IDX="$(cfg_get skills.index_file)"
if [ -n "$IDX" ] && [ -f "$(cfg_get skills.source_dir)/$IDX" ]; then
  cp "$(cfg_get skills.source_dir)/$IDX" "$SB/$IDX"
fi

# 3. the two inputs the implementer gets — and NOTHING else (no human diff, no eval data, no .git)
cp "$TASKDIR/SPEC.md" "$SB/SPEC.md"
cp "$TASKDIR/BUSINESS_REQUIREMENT.md" "$SB/BUSINESS_REQUIREMENT.md"
# keep the sandbox blind — strip the unit key from the copied SPEC/BR so the id can't be inferred.
# (Python, not perl: OS-portable and the one allowed non-stdlib dep stays PyYAML — this uses stdlib.)
for f in "$SB/SPEC.md" "$SB/BUSINESS_REQUIREMENT.md"; do
  MAHORAGA_STRIP_KEY="$KEY" MAHORAGA_STRIP_FILE="$f" python3 - <<'PY' 2>/dev/null || true
import os
k = os.environ.get("MAHORAGA_STRIP_KEY", "")
f = os.environ.get("MAHORAGA_STRIP_FILE", "")
if k and f:
    try:
        s = open(f, encoding="utf-8", errors="replace").read()
        open(f, "w", encoding="utf-8").write(s.replace(k, ""))
    except OSError:
        pass
PY
done

# 4. LEAK-GATE — must pass or the sandbox is destroyed. RUN_DIR lets it auto-derive tokens from the human diff.
if ! bash "$HERE/leak_gate.sh" "$SLUG" "$KEY" "$RUN_DIR"; then
  echo "LEAK-GATE FAILED — staging aborted, removing $SB" >&2
  rm -rf "$SB"
  exit 2
fi

repos_csv=$(ls -d "$SB"/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | grep -v '^.claude$' | tr '\n' ',')
echo "STAGED $SLUG ($KEY): $repos_csv"
