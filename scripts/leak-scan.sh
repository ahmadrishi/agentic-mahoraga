#!/usr/bin/env bash
# leak-scan.sh — company-data denylist gate. THIS GATES THE PUSH.
#
# Greps everything that would be published for the company-data denylist and exits non-zero on any
# hit. The repo is public; it MUST contain ZERO company data. Every finding is a real leak that must
# be removed (or the offending file dropped from the commit) before pushing.
#
# TWO LAYERS OF DENYLIST (why this published file names no organisation)
#   - Generic layer, below: credential and token shapes, personal home paths, vendor-neutral
#     private-host markers. It is the same for everyone.
#   - Private layer: patterns that name one organisation (its domains, product names, ticket
#     prefixes). They live outside the repo and its history, and are read from
#       $LEAK_SCAN_EXTRA        the list itself, one `NAME | SEV | CASE | ERE` per line (CI sets it
#                               from a secret), and/or
#       $LEAK_SCAN_EXTRA_FILE   a file holding the list (default:
#                               ${XDG_CONFIG_HOME:-~/.config}/mahoraga/leak-scan.extra).
#     Both are loaded if both exist. Blank lines and whole-line `#` comments are skipped. A malformed
#     line is exit 3, named by number and never echoed. With no private list the scan runs the
#     generic layer only and says so; LEAK_SCAN_REQUIRE_EXTRA=1
#     turns that into exit 3.
#
# WHAT IS SCANNED
#   - Inside a git work tree: exactly the tracked regular files (`git ls-files`) — i.e. what a push
#     carries. Contents are searched as text (binary files too) and file NAMES are matched as well.
#     Symlinks and other non-regular entries are skipped, and the count is printed.
#     This is authoritative: files that are not tracked never reach this gate.
#   - Outside git (a bare working copy): a filesystem walk that excludes VCS/build/vendor dirs.
#   - The scanner itself and its allow-file are always excluded (they hold the denylist literals).
#
# DENYLIST DESIGN NOTES (why the patterns are shaped the way they are)
#   - Ticket keys (a private-layer category) are matched only for the KNOWN project prefixes, not a
#     blanket [A-Z]+-[0-9]+, because doc cross-references (DOC-7, SEC-1) and tokens like
#     UTF-8 / SHA-256 are legitimate and must not trip the gate.
#   - Secrets are matched by VALUE-bearing shapes (an assignment to a quoted literal, a bearer/basic
#     header, a PEM header, an AWS/GitHub/Slack token), never the bare words "password"/"secret"/
#     "token", so SECURITY.md prose that discusses them stays clean.
#   - Credential files are matched as a real credential PATH/CONTENT (~/.m2/settings.xml, an inline
#     <password> element), never the bare filename "settings.xml" — that would flag .gitignore.
#
# In CI (GITHUB_ACTIONS set) or with LEAK_SCAN_REDACT=1 a finding prints only its location, never the
# matched text: the logs of a public repository are public. LEAK_SCAN_CHUNK=<n> sets the files per grep.
#
# Usage: scripts/leak-scan.sh [REPO_ROOT]   (default: the repo containing this script)
# Exit:  0 = clean · 2 = at least one hit · 3 = usage/environment error
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "leak-scan: cannot cd into '$ROOT'" >&2; exit 3; }

SELF="scripts/leak-scan.sh"
ALLOW="scripts/leak-scan.allow"   # optional: literal path prefixes to exclude, one per line, '#' comments

# ---- denylist: NAME | SEV(fail|warn) | CASE(ci|cs) | ERE -----------------------------------------
# One extended-regex per category (internal alternations are fine). Keep additions vendor-neutral:
# anything that names an organisation belongs in the private layer, never here.
# SEV=fail blocks the push; SEV=warn is surfaced but non-blocking — reserved for tokens the project
# legitimately uses as PORTABILITY ANTI-EXAMPLES (e.g. a comment "use $TMPDIR, NOT a macOS /private/tmp
# default"), which a contract file itself documents and which a regex cannot cleanly tell from real use.
CATEGORIES=(
  "atlassian-host     |fail|ci|atlassian\.net"
  "atlassian-cloud-id |fail|ci|cloud[_-]?id[\"'[:space:]:=]{0,6}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  "private-host       |fail|ci|artifactory|(^|[^a-z])jfrog([^a-z]|$)"
  "cred-file          |fail|ci|\.m2/settings\.xml"
  "cred-inline        |fail|ci|<password>[A-Za-z0-9][A-Za-z0-9!@#\$%^&*()_.+=/~-]{2,}</password>"
  "personal-path      |fail|cs|/Users/[A-Za-z0-9._-]+"
  "private-key        |fail|cs|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "aws-access-key     |fail|cs|AKIA[0-9A-Z]{16}"
  "gh-token           |fail|cs|(^|[^A-Za-z0-9])ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}"
  "slack-token        |fail|cs|xox[baprs]-[0-9A-Za-z-]{10,}"
  "auth-header        |fail|ci|authorization:[[:space:]]*(bearer|basic)[[:space:]]+[A-Za-z0-9._+/=~-]{12,}"
  "secret-assignment  |fail|ci|(password|passwd|api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token)[[:space:]]*[:=][[:space:]]*[\"'][^\"']{6,}[\"']"
  "macos-path         |warn|cs|/private/tmp|/Library/Java"
)

# ---- the private layer (see the header) ----------------------------------------------------------
trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
EXTRA_N=0
plain_escapes() {  # <pattern> — fails if it holds a backslash-letter that GNU grep reads as the plain letter
  local p="$1" i=0 c n="${#1}"   # (\d, \t, \n ... are PCRE/C escapes: in ERE they match "d", "t", "n"; only \w \W \s \S \b \B are real)
  while [ "$i" -lt "$n" ]; do
    c="${p:i:1}"
    if [ "$c" = '\' ]; then
      c="${p:i+1:1}"
      if [[ "$c" =~ ^[A-Za-z]$ ]] && [[ "$c" != [wWsSbB] ]]; then return 1; fi
      i=$((i+2)); continue
    fi
    i=$((i+1))
  done
}
add_extra() {  # <label> — reads a list on stdin into CATEGORIES; any malformed line is exit 3
  local label="$1" n=0 line name rest sev flag pat bars why w g
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    bars="${line//[^|]/}"; why=""
    name="$(trim "${line%%|*}")"; rest="${line#*|}"; sev="$(trim "${rest%%|*}")"; rest="${rest#*|}"
    flag="$(trim "${rest%%|*}")"; pat="$(trim "${rest#*|}")"
    if   [ "${#bars}" -lt 3 ]; then why="fewer than four fields"
    elif [ -z "$name" ]; then why="empty name"
    elif [ "$sev" != fail ] && [ "$sev" != warn ]; then why="severity is not fail|warn"
    elif [ "$flag" != ci ] && [ "$flag" != cs ]; then why="case flag is not ci|cs"
    elif [ -z "$pat" ]; then why="empty pattern"
    elif [[ "$pat" == \"*\" || "$pat" == \'*\' ]]; then why="pattern is wrapped in quotes (give the bare expression)"
    elif ! plain_escapes "$pat"; then why="uses an escape such as \\d or \\t that grep reads as a plain letter (write [0-9], [[:space:]])"
    else
      w="$(printf '\n' | grep -E -e "$pat" 2>&1 >/dev/null)"; g=$?
      if   [ "$g" -eq 0 ]; then why="pattern matches the empty string, so it could never report a hit"
      elif [ "$g" -ge 2 ] || [ -n "$w" ]; then why="invalid regular expression"
      fi
    fi
    if [ -n "$why" ]; then
      echo "leak-scan: private denylist ($label) line $n is malformed: $why (expected 'NAME | fail|warn | ci|cs | ERE')" >&2
      exit 3
    fi
    CATEGORIES+=("$name |$sev|$flag|$pat"); EXTRA_N=$((EXTRA_N+1))
  done
}
if [ -n "${LEAK_SCAN_EXTRA:-}" ]; then add_extra 'LEAK_SCAN_EXTRA' <<< "$LEAK_SCAN_EXTRA"; fi
EXTRA_FILE="${LEAK_SCAN_EXTRA_FILE:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/mahoraga/leak-scan.extra}"
if [ -f "$EXTRA_FILE" ]; then
  [ -r "$EXTRA_FILE" ] || { echo "leak-scan: the private denylist file is not readable: $EXTRA_FILE" >&2; exit 3; }
  add_extra "$EXTRA_FILE" < "$EXTRA_FILE"
elif [ -n "${LEAK_SCAN_EXTRA_FILE:-}" ]; then echo "leak-scan: LEAK_SCAN_EXTRA_FILE does not exist: $EXTRA_FILE" >&2; exit 3; fi
if [ "$EXTRA_N" -gt 0 ]; then echo "leak-scan: private denylist: $EXTRA_N categor$([ "$EXTRA_N" -eq 1 ] && echo y || echo ies) loaded"
elif [ "${LEAK_SCAN_REQUIRE_EXTRA:-}" = 1 ]; then echo "leak-scan: LEAK_SCAN_REQUIRE_EXTRA=1 but no private denylist is loaded (LEAK_SCAN_EXTRA / LEAK_SCAN_EXTRA_FILE)" >&2; exit 3
else echo "leak-scan: NOTICE: no private denylist loaded — only the generic patterns ran (see the header)"; fi

# ---- collect the file list ----------------------------------------------------------------------
declare -a FILES=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MODE="git (tracked files)"
  mapfile -d '' -t FILES < <(git ls-files -z)
else
  MODE="filesystem (VCS and build directories excluded)"
  mapfile -d '' -t FILES < <(find . -type f \
    -not -path './.git/*' \
    -not -path '*/node_modules/*' -not -path '*/__pycache__/*' \
    -not -path '*/.venv/*' -not -path '*/venv/*' \
    -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/.egg-info/*' \
    -print0)
fi

# ---- filter out the scanner, its allow-file, and any allow-listed paths --------------------------
declare -a ALLOW_PREFIXES=()
if [ -f "$ALLOW" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] && ALLOW_PREFIXES+=("$line")
  done < "$ALLOW"
fi
is_allowed() {
  local f="${1#./}" p
  [ "$f" = "$SELF" ] && return 0
  [ "$f" = "$ALLOW" ] && return 0
  for p in "${ALLOW_PREFIXES[@]:-}"; do [ -n "$p" ] && [[ "$f" == $p* ]] && return 0; done
  return 1
}
declare -a SCAN=(); SKIPPED=0
for f in "${FILES[@]}"; do
  is_allowed "$f" && continue
  if [ -f "$f" ] && [ ! -L "$f" ]; then SCAN+=("$f"); else SKIPPED=$((SKIPPED+1)); fi
done

echo "leak-scan: mode=$MODE ; scanning ${#SCAN[@]} file(s) under $ROOT"
[ "$SKIPPED" -gt 0 ] && echo "leak-scan: skipped $SKIPPED symlink(s) / non-regular entr$([ "$SKIPPED" -eq 1 ] && echo y || echo ies)"
if [ "${#SCAN[@]}" -eq 0 ]; then echo "leak-scan: nothing to scan — PASS (nothing checked)"; exit 0; fi

# ---- scan: per category, the contents (binary files too, as text), then the file names ------------
CHUNK="${LEAK_SCAN_CHUNK:-400}"   # files per grep, so a large tree cannot overflow the argument list
[[ "$CHUNK" =~ ^[1-9][0-9]*$ ]] || { echo "leak-scan: LEAK_SCAN_CHUNK must be a positive integer" >&2; exit 3; }
REDACT=0; if [ -n "${GITHUB_ACTIONS:-}" ] || [ "${LEAK_SCAN_REDACT:-}" = 1 ]; then REDACT=1; fi
ERRF="$(mktemp)"; NAMES="$(mktemp)"; trap 'rm -f "$ERRF" "$NAMES"' EXIT
printf '%s\0' "${SCAN[@]}" > "$NAMES"
hits=0; warns=0
say() {  # <sev> <name> <where> <text> — one finding; redacted, the matched text is never printed
  local tag=LEAK; [ "$1" = warn ] && tag=WARN
  if [ "$REDACT" -eq 1 ]; then printf '%s[%s] %s\n' "$tag" "$2" "$3"; else printf '%s[%s] %s%s\n' "$tag" "$2" "$3" "$4"; fi
  if [ "$1" = warn ]; then warns=$((warns+1)); else hits=$((hits+1)); fi
}
grep_failed() {  # <rc> <category> — a grep that errors means the scan cannot vouch for the tree
  echo "leak-scan: grep failed (exit $1) while scanning category '$2'; the scan cannot vouch for the tree" >&2
  [ "$REDACT" -eq 1 ] || head -c 300 "$ERRF" >&2
  exit 3
}
loc_re='^([^:]+:[0-9]+):(.*)$'
for spec in "${CATEGORIES[@]}"; do
  name="${spec%%|*}"; rest="${spec#*|}"
  sev="${rest%%|*}"; rest="${rest#*|}"
  flag="${rest%%|*}"; pat="${rest#*|}"
  name="${name%"${name##*[![:space:]]}"}"   # rstrip label
  ci=""; [ "$flag" = "ci" ] && ci="-i"
  i=0
  while [ "$i" -lt "${#SCAN[@]}" ]; do
    out="$(grep -HnoEa $ci -e "$pat" -- "${SCAN[@]:i:CHUNK}" 2>"$ERRF")"; rc=$?
    [ "$rc" -ge 2 ] && grep_failed "$rc" "$name"
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      if [[ "$m" =~ $loc_re ]]; then say "$sev" "$name" "${BASH_REMATCH[1]}" ":${BASH_REMATCH[2]}"
      else say "$sev" "$name" "(location unavailable)" ""; fi
    done <<< "$out"
    i=$((i+CHUNK))
  done
  nrc=0; nmatch="$(grep -zEac $ci -e "$pat" "$NAMES" 2>"$ERRF")" || nrc=$?
  [ "$nrc" -ge 2 ] && grep_failed "$nrc" "$name"
  if [ "${nmatch:-0}" -gt 0 ]; then
    if [ "$REDACT" -eq 1 ]; then say "$sev" "$name" "(file names) $nmatch name(s) match" ""
    else while IFS= read -r -d '' pth; do say "$sev" "$name" "(file name) $pth" ""; done < <(grep -zEa $ci -e "$pat" "$NAMES"); fi
  fi
done

echo "----------------------------------------------------------------------"
[ "$warns" -gt 0 ] && echo "leak-scan: $warns advisory WARN(s) — macOS-path anti-example mentions, review but non-blocking."
if [ "$hits" -eq 0 ]; then
  echo "LEAK-SCAN PASS: 0 blocking company-data hits across ${#SCAN[@]} file(s)."
  exit 0
else
  echo "LEAK-SCAN FAIL: $hits company-data hit(s). Remove the data or drop the file from the commit." >&2
  echo "This gate blocks the push. The repo MUST contain zero company data." >&2
  exit 2
fi
