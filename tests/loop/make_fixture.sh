#!/usr/bin/env bash
# tests/loop/make_fixture.sh <dir> <n_units> [late] — env FRAG=planted|random:<seed> (default none)
# The loop's test fixture: <dir>/proj/app, a Java repo whose main branch has <n_units> merged units,
# each adding one public class with a distinctive method (computeAlphaTotal, ...; at most 26 units). Commit dates run BACKWARDS (unit 1 is "newest") so any code that
# orders units by date instead of first-parent topology gets the split wrong. With `late`, one more
# unit is forked from before the 6th merge and merged right after the 8th (its fork lacks merges 6-8).
# With FRAG, every merge also adds a release-notes fragment: planted = always under changes/, random =
# under changes-a/, changes-b/ or changes-c/ drawn per unit (a convention no history can teach).
# Prints one line per unit, oldest first: "<sha> <name> <fragment dir or ->"; then "side <sha>" (a
# commit on an unmerged side branch) and, with `late`, "late <sha>".
set -eu
D="$1"; N="$2"; LATE="${3:-}"
R="$D/proj/app"; mkdir -p "$R/src"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
date_of() { printf '2026-01-%02dT12:00:00Z' $((28 - $1 % 28)); }   # later units get EARLIER dates
git -C "$R" init -q -b main
printf 'public class App {\n    public void runApplication() {}\n}\n' > "$R/src/App.java"
git -C "$R" add -A; GIT_COMMITTER_DATE="$(date_of 0)" GIT_AUTHOR_DATE="$(date_of 0)" git -C "$R" commit -qm init
WORDS=(Alpha Bravo Charlie Delta Echo Foxtrot Golf Hotel India Juliet Kilo Lima Mike November Oscar Papa Quebec Romeo Sierra Tango Uniform Victor Whiskey Xray Yankee Zulu)
for i in $(seq 1 "$N"); do
  name="${WORDS[$((i - 1))]}"   # words, not Unit7: the leak gate needs camel humps to call an identifier distinctive
  [ -n "$LATE" ] && [ "$i" -eq 6 ] && git -C "$R" branch late-base
  git -C "$R" checkout -qb "f$i"
  printf 'public class %s {\n    public int compute%sTotal() { return %d; }\n}\n' "$name" "$name" "$i" > "$R/src/$name.java"
  frag=-
  case "${FRAG:-}" in
    planted) frag=changes ;;
    random:*) frag="changes-$(printf '%s' "${FRAG#random:}$i" | cksum | awk '{print substr("abc", $1 % 3 + 1, 1)}')" ;;
  esac
  if [ "$frag" != - ]; then mkdir -p "$R/$frag"; printf -- '- Added the %s total.\n' "$name" > "$R/$frag/$(echo "$name" | tr 'A-Z' 'a-z').md"; fi
  git -C "$R" add -A; GIT_COMMITTER_DATE="$(date_of "$i")" GIT_AUTHOR_DATE="$(date_of "$i")" git -C "$R" commit -qm "$name"
  git -C "$R" checkout -q main
  GIT_COMMITTER_DATE="$(date_of "$i")" git -C "$R" merge -q --no-ff "f$i" -m "Merge $name"
  echo "$(git -C "$R" rev-parse HEAD) $name $frag"
  if [ -n "$LATE" ] && [ "$i" -eq 8 ]; then   # forked before merge 6, merged after merge 8: inside the val range
    git -C "$R" checkout -qb late late-base
    printf 'public class Late {\n    public int computeLateTotal() { return 0; }\n}\n' > "$R/src/Late.java"
    git -C "$R" add -A; git -C "$R" commit -qm late; git -C "$R" checkout -q main
    git -C "$R" merge -q --no-ff late -m "Merge late"; echo "late $(git -C "$R" rev-parse HEAD)"
  fi
done
git -C "$R" checkout -qb side; echo "side" > "$R/src/side.txt"; git -C "$R" add -A; git -C "$R" commit -qm side
echo "side $(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q main
