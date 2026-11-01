#!/usr/bin/env bash
# sanitize_skills.sh <SANDBOX_SKILLS_DIR>
# Skills DERIVED from eval units leak those units' answers. For each config skills.derived_skills
# entry, overwrite the sandbox copy with the curated method-only `<name>/SKILL.sanitized.md`. This
# script does NOT auto-strip prose — a derived skill with no sanitized copy is a decontamination hole
# (the token leak-gate won't catch an un-tokenised worked example), so this FAILS CLOSED: any missing
# sanitized copy => non-zero exit, and the caller (stage_sandbox.sh) aborts staging. Author one
# SKILL.sanitized.md per derived skill.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
SBSK="$1"
[ -d "$SBSK" ] || { echo "sanitize_skills: no dir $SBSK" >&2; exit 3; }
SRC="$(cfg_get skills.source_dir)"
missing=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  san="$SRC/$name/SKILL.sanitized.md"
  dst="$SBSK/$name/SKILL.md"
  if [ -f "$san" ]; then
    cp "$san" "$dst"
    rm -f "$SBSK/$name/SKILL.sanitized.md"   # drop the redundant sibling from the sandbox
    echo "SANITIZED $name -> method-only copy"
    # whole-dir sanitize: the rest of a derived skill's tree (references/, examples/, extra .md) is
    # the answer-bearing grounded material — a worked example there can name the fix in prose that no
    # token matches, the exact hole the token gate can miss. So after swapping in the method-only
    # SKILL.md, REMOVE every other file under the sandbox skill dir and prune the emptied dirs;
    # nothing but SKILL.md survives by default.
    removed=$(find "$SBSK/$name" -type f ! -name 'SKILL.md' 2>/dev/null | tr '\n' ' ')
    find "$SBSK/$name" -type f ! -name 'SKILL.md' -delete 2>/dev/null
    find "$SBSK/$name" -mindepth 1 -type d -empty -delete 2>/dev/null
    # EXCEPTION: if a curated, method-only references.sanitized/ ships next to the SOURCE skill, swap
    # it in as references/ (grounded material the author vetted). Copied AFTER the delete so it takes
    # the place of the removed originals.
    refsan="$SRC/$name/references.sanitized"
    if [ -d "$refsan" ]; then
      mkdir -p "$SBSK/$name/references"
      cp -R "$refsan/." "$SBSK/$name/references/" 2>/dev/null
      echo "SANITIZE-NOTE $name: removed all non-SKILL.md files (${removed:-none}); references/ replaced with curated references.sanitized/" >&2
    else
      [ -n "$removed" ] && echo "SANITIZE-NOTE $name: removed all non-SKILL.md files (grounded material that could leak un-tokenised answers): ${removed}" >&2
    fi
  else
    echo "SANITIZE-FAIL $name: no $san — derived skill would leak answers. Author a method-only SKILL.sanitized.md next to the skill." >&2
    missing=$((missing+1))
  fi
done < <(cfg_list skills.derived_skills)
if [ "$missing" -gt 0 ]; then
  echo "sanitize_skills: FAILED CLOSED — $missing derived skill(s) without a SKILL.sanitized.md" >&2
  exit 2
fi
