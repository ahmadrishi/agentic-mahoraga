#!/usr/bin/env bash
# zero-residue-sandbox-test.sh — the decontamination acceptance test for the strip-set.
#
# BACKGROUND. Mahoraga's OWN "meta" skills describe the eval itself (how the sandbox is staged, how
# scoring works, how decontamination works). If any of them survives into a blind sandbox, the
# implementer can tell it is being tested and can read the methodology as an answer key — a
# decontamination TELL. A list of skills to strip hard-coded in the
# staging script would silently leave a renamed or newly added meta-skill in the sandbox, so
# the staging code reads core/schema/STRIP_SET.manifest, and THIS test asserts the manifest and the
# staging code stay in agreement.
#
# WHAT THIS TEST VERIFIES (statically — no live sandbox is built here):
#   A. Every skill directory named in the manifest actually exists under skills/ (so the strip-set
#      cannot name a skill that has been renamed away — that would make it a silent no-op).
#   B. The staging code reads the manifest (it must NOT re-introduce a hard-coded list).
#
# Each check is PASS / FAIL / SKIP. A SKIP happens only when the subtree it inspects is absent
# (skills not populated, or the core staging lib missing); it prints a clear
# warning and does not fail the build, so this gate is safe to run on a partial checkout
# while still being a real gate once the repo is whole.
#
# Usage: scripts/zero-residue-sandbox-test.sh [REPO_ROOT]
# Exit:  0 = all checks PASS or SKIP · 2 = at least one FAIL · 3 = environment error
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "zero-residue: cannot cd into '$ROOT'" >&2; exit 3; }

MANIFEST="core/schema/STRIP_SET.manifest"
SKILLS_DIR="skills"
fail=0

[ -f "$MANIFEST" ] || { echo "zero-residue: manifest not found at $MANIFEST" >&2; exit 3; }

# --- parse manifest: skill dir names, one per line, '#' comments and blanks stripped --------------
declare -a NAMES=()
while IFS= read -r line; do
  line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] && NAMES+=("$line")
done < "$MANIFEST"
echo "zero-residue: strip-set names in manifest: ${#NAMES[@]}"
[ "${#NAMES[@]}" -gt 0 ] || { echo "zero-residue: manifest lists no skill names" >&2; exit 3; }

# ================= Check A — every manifest name exists as a skill dir under skills/ ===============
populated=0
if [ -d "$SKILLS_DIR" ]; then
  populated="$(find "$SKILLS_DIR" -type f -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
fi
if [ "$populated" -eq 0 ]; then
  echo "CHECK A: SKIP — skills/ is not populated yet (0 SKILL.md files); the adapt/prove workstreams"
  echo "         build these. Existence of manifest skills will be enforced once skills/ is built."
else
  missing=0
  for name in "${NAMES[@]}"; do
    if [ -z "$(find "$SKILLS_DIR" -type d -name "$name" -print -quit 2>/dev/null)" ]; then
      echo "  MISSING: strip-set skill '$name' has no directory under $SKILLS_DIR/" >&2
      missing=$((missing+1))
    fi
  done
  if [ "$missing" -eq 0 ]; then
    echo "CHECK A: PASS — all ${#NAMES[@]} strip-set skills exist under $SKILLS_DIR/."
  else
    echo "CHECK A: FAIL — $missing strip-set skill(s) named in the manifest do not exist under $SKILLS_DIR/." >&2
    echo "         A strip-set entry with no matching skill dir is a silent no-op (rename drift)." >&2
    fail=1
  fi
fi

# ================= Check B — the staging code reads the manifest (not a hard-coded list) ==========
# Candidate staging scripts (any language) in the core lib.
mapfile -t CANDIDATES < <(find core -type f \( -iname '*stage*sandbox*' -o -iname 'stage_sandbox*' \) 2>/dev/null)
# Anything under core/ that references the manifest by name is evidence the strip-set is data-driven.
mapfile -t READERS < <(grep -rlF "STRIP_SET.manifest" core 2>/dev/null)

if [ "${#CANDIDATES[@]}" -gt 0 ]; then
  ref=0
  for c in "${CANDIDATES[@]}"; do
    if grep -qF "STRIP_SET.manifest" "$c" 2>/dev/null; then
      echo "  staging script reads the manifest: $c"
      ref=$((ref+1))
    fi
  done
  if [ "$ref" -gt 0 ]; then
    echo "CHECK B: PASS — a staging script reads $MANIFEST (strip-set is manifest-driven, not hard-coded)."
  else
    echo "CHECK B: FAIL — found staging script(s) but NONE reference $MANIFEST:" >&2
    printf '           %s\n' "${CANDIDATES[@]}" >&2
    echo "         This is the regression the manifest prevents: a hard-coded strip-set goes stale under a rename." >&2
    fail=1
  fi
elif [ "${#READERS[@]}" -gt 0 ]; then
  echo "CHECK B: PASS — core reads $MANIFEST:"
  printf '           %s\n' "${READERS[@]}"
else
  echo "CHECK B: SKIP — no core staging code found yet (core/lib is built by another workstream)."
  echo "         Once it lands, it MUST read $MANIFEST rather than hard-code the strip-set."
fi

echo "----------------------------------------------------------------------"
if [ "$fail" -eq 0 ]; then
  echo "ZERO-RESIDUE TEST PASS (checks passed or were skipped pending their workstream)."
  exit 0
else
  echo "ZERO-RESIDUE TEST FAIL." >&2
  exit 2
fi
