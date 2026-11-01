#!/usr/bin/env bash
# tests/leak_scan_test.sh — the leak scan's two denylist layers and what it scans (scripts/leak-scan.sh).
#
#   * generic layer (in the script): a token shape is caught with no private list at all
#   * private layer: loaded from $LEAK_SCAN_EXTRA, from $LEAK_SCAN_EXTRA_FILE and from the default
#     ~/.config/mahoraga/leak-scan.extra (XDG_CONFIG_HOME respected); both sources together are a union
#   * the list's syntax: comments, blank lines, CRLF, spaced columns and a missing final newline are fine;
#     ci/cs and fail/warn are honoured; a pattern starting with '-' works
#   * a bad list fails closed with exit 3, naming its line and never echoing it: wrong severity or case flag,
#     empty pattern, quoted pattern, an invalid regex, a regex grep only WARNS about (\d), a pattern that
#     matches the empty string (it could never report a hit), an unreadable file, a missing explicit file;
#     LEAK_SCAN_REQUIRE_EXTRA=1 with no list (or only comments) is exit 3
#   * what is scanned: binary files as text, file NAMES, every slice of a large tree (LEAK_SCAN_CHUNK), a
#     grep error is fatal, symlinks are skipped and counted
#   * CI redaction: a finding prints its location, never the matched text; a clean run never prints a pattern
#   * the real repo passes with the generic layer alone (what a fork's CI runs)
# Every case runs in a clean environment (`env -i`) so a maintainer's real private list can never leak into
# the result. All names here are synthetic.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'LEAK-SCAN-TEST FAIL: %b\n' "$*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
H="$TMP/home"; mkdir -p "$H"
N=0; R=""
newrepo() { N=$((N+1)); R="$TMP/r$N"; mkdir -p "$R/scripts"; cp "$ROOT/scripts/leak-scan.sh" "$R/scripts/"; git -C "$R" init -q; plant README.md "nothing to see here"; }
plant() { printf '%s\n' "$2" > "$R/$1"; git -C "$R" add -A; }
scan() { env -i PATH="$PATH" HOME="$H" "$@" bash "$R/scripts/leak-scan.sh" "$R" 2>&1; }   # VAR=val ... as args
rc() { scan "$@" >/dev/null; echo $?; }
TOK="ghp_$(printf 'a%.0s' $(seq 1 36))"   # built at run time: this file is itself scanned
BS='\'
AS_ROOT=0; [ "$(id -u)" -eq 0 ] && AS_ROOT=1

echo "== generic layer =="
newrepo
out="$(scan)"; [ $? -eq 0 ] && grep -q "no private denylist loaded" <<<"$out" || fail "clean tree: $out"
ok "a clean tree passes and says that only the generic patterns ran"
plant leak.md "a token $TOK in prose"
out="$(scan)"; [ $? -eq 2 ] && grep -q 'LEAK\[gh-token\]' <<<"$out" || fail "token shape not caught: $out"
ok "a token shape fails with no private list"

echo "== private layer: sources =="
newrepo
plant notes.md "the Acme Corp rollout, ticket ACME-1234, then acme-5678 lowercase"
[ "$(rc)" -eq 0 ] || fail "synthetic names must not be in the generic layer"
LIST=$'acme-name |fail|ci|acme[- ]corp\nacme-key  |fail|cs|(^|[^A-Za-z])ACME-[0-9]+'
out="$(scan LEAK_SCAN_EXTRA="$LIST")"; rc1=$?
[ $rc1 -eq 2 ] && grep -q 'LEAK\[acme-name\]' <<<"$out" && grep -q 'LEAK\[acme-key\]' <<<"$out" && grep -q "private denylist: 2 categories" <<<"$out" || fail "env list: rc $rc1 $out"
grep -q 'acme-5678' <<<"$out" && fail "a case-sensitive category matched lowercase"
ok "the list in \$LEAK_SCAN_EXTRA is applied; ci matches any case, cs only the written case"
printf '# private list\n\n%s\r\n%s\r\n' "acme-name |fail|ci|acme[- ]corp" "acme-key  |fail|cs|(^|[^A-Za-z])ACME-[0-9]+" > "$TMP/extra"
out="$(scan LEAK_SCAN_EXTRA_FILE="$TMP/extra")"; [ $? -eq 2 ] && grep -q "2 categories" <<<"$out" || fail "file list: $out"
ok "\$LEAK_SCAN_EXTRA_FILE works; comments, blank lines and CRLF are skipped"
printf '%s' "acme-name |fail|ci|acme[- ]corp" > "$TMP/nonl"
out="$(scan LEAK_SCAN_EXTRA_FILE="$TMP/nonl")"; [ $? -eq 2 ] && grep -q "1 category" <<<"$out" || fail "no trailing newline: $out"
ok "a last line without a newline is still loaded"
out="$(scan LEAK_SCAN_EXTRA=$'nm | fail | ci | acme[- ]corp  \t')"; [ $? -eq 2 ] && grep -q 'LEAK\[nm\]' <<<"$out" || fail "spaced columns / trailing blanks: $out"
ok "the documented 'NAME | SEV | CASE | ERE' layout works: the pattern is trimmed"
plant dash.md "see -acme-dash here"
out="$(scan LEAK_SCAN_EXTRA="esc |fail|cs|sentinelzq${BS}${BS}d")"; [ $? -eq 0 ] || fail "an escaped backslash followed by d is legal: $out"
out="$(scan LEAK_SCAN_EXTRA="esc |fail|cs|a${BS}sb${BS}.c")"; [ $? -eq 0 ] || fail "real escapes (\\s, \\.) must be accepted: $out"
out="$(scan LEAK_SCAN_EXTRA='dash |fail|ci|-acme-dash')"; grep -q 'LEAK\[dash\] dash.md:1' <<<"$out" || fail "a pattern starting with '-': $out"
ok "a pattern that starts with '-' is a pattern, not an option"
mkdir -p "$H/.config/mahoraga" "$TMP/xdg/mahoraga"
cp "$TMP/extra" "$H/.config/mahoraga/leak-scan.extra"
[ "$(rc)" -eq 2 ] || fail "the default ~/.config location was not read"
[ "$(rc XDG_CONFIG_HOME="$TMP/xdg")" -eq 0 ] || fail "XDG_CONFIG_HOME did not take precedence over ~/.config"
ok "the default list is ~/.config/mahoraga/leak-scan.extra, and XDG_CONFIG_HOME moves it"
rm "$H/.config/mahoraga/leak-scan.extra"
out="$(scan LEAK_SCAN_EXTRA="beta-name |fail|ci|beta" LEAK_SCAN_EXTRA_FILE="$TMP/extra")"; grep -q "3 categories" <<<"$out" || fail "union: $out"
ok "the env list and the file list are both loaded"
out="$(scan LEAK_SCAN_EXTRA="warn-name |warn|ci|acme[- ]corp")"; [ $? -eq 0 ] && grep -q 'WARN\[warn-name\]' <<<"$out" || fail "warn severity: $out"
ok "a warn category is reported but does not block"
newrepo
out="$(scan LEAK_SCAN_EXTRA='sent |fail|cs|zzqq-sentinel-[0-9]+')"; [ $? -eq 0 ] || fail "clean run with a list: $out"
grep -q 'zzqq-sentinel' <<<"$out" && fail "a clean run printed a pattern: $out"
ok "a clean run prints a count, never a pattern"

echo "== private layer: a bad list fails closed =="
newrepo
for case in "bad-sev |block|ci|sentinelzq:severity is not fail|warn" "bad-flag |fail|xx|sentinelzq:case flag is not ci|cs" \
            "no-pat |fail|ci|:empty pattern" "bad-re |fail|ci|(sentinelzq:invalid regular expression" \
            "stray |fail|cs|sentinelzq-${BS}d+:uses an escape" "stray2 |fail|cs|sentinelzq${BS}t:uses an escape" "empty-m |fail|ci|^:pattern matches the empty string" \
            "empty-m2 |fail|ci|(sentinelzq)?:pattern matches the empty string" 'quoted |fail|ci|"sentinelzq":pattern is wrapped in quotes' \
            "two|fields:fewer than four fields" " |fail|ci|sentinelzq:empty name"; do
  line="${case%:*}"; why="${case##*:}"
  out="$(scan LEAK_SCAN_EXTRA=$'# one\n'"$line")"; r=$?
  [ $r -eq 3 ] && grep -qF "line 2 is malformed: $why" <<<"$out" || fail "'$why': rc $r, $out"
  grep -q sentinelzq <<<"$out" && fail "the malformed line was echoed: $out"
done
ok "eleven malformations: exit 3, 'line 2 is malformed: <why>', the pattern never echoed"
[ "$(rc LEAK_SCAN_EXTRA_FILE="$TMP/none")" -eq 3 ] || fail "an explicit file that does not exist must be exit 3"
ok "an explicit LEAK_SCAN_EXTRA_FILE that is missing is exit 3"
if [ "$AS_ROOT" -eq 0 ]; then
  cp "$TMP/extra" "$TMP/locked"; chmod 000 "$TMP/locked"
  out="$(scan LEAK_SCAN_EXTRA_FILE="$TMP/locked")"; r=$?; chmod 600 "$TMP/locked"
  [ $r -eq 3 ] && grep -q "not readable" <<<"$out" || fail "an unreadable list must be exit 3, not a quiet pass (rc $r): $out"
  ok "a list file that cannot be read is exit 3, not a quiet pass"
else ok "(skipped: running as root, mode 000 is readable)"; fi
[ "$(rc LEAK_SCAN_REQUIRE_EXTRA=1)" -eq 3 ] || fail "REQUIRE with no list must be exit 3"
printf '# only a comment\n\n' > "$TMP/empty"
[ "$(rc LEAK_SCAN_REQUIRE_EXTRA=1 LEAK_SCAN_EXTRA_FILE="$TMP/empty")" -eq 3 ] || fail "an all-comment list counts as no list"
[ "$(rc LEAK_SCAN_REQUIRE_EXTRA=1 LEAK_SCAN_EXTRA="gamma |fail|ci|gamma")" -eq 0 ] || fail "REQUIRE with a list must run"
ok "LEAK_SCAN_REQUIRE_EXTRA=1: no list (or only comments) is exit 3; with a list it runs"

echo "== what is scanned =="
newrepo
printf 'Acme Corp\n\000more' > "$R/blob.dat"; git -C "$R" add -A
out="$(scan LEAK_SCAN_EXTRA='acme-name |fail|ci|acme[- ]corp')"; [ $? -eq 2 ] && grep -q 'LEAK\[acme-name\] blob.dat:1' <<<"$out" || fail "a name inside a file with a NUL byte: $out"
ok "a binary file is searched as text"
newrepo
plant acme-corp-notes.md "nothing inside"; mkdir -p "$R/dir"; plant "dir/Acme Corp plan.md" "nothing inside"
out="$(scan LEAK_SCAN_EXTRA='acme-name |fail|ci|acme[- ]corp')"; r=$?
[ $r -eq 2 ] && grep -q 'LEAK\[acme-name\] (file name) acme-corp-notes.md' <<<"$out" && grep -q '(file name) dir/Acme Corp plan.md' <<<"$out" || fail "file names: rc $r $out"
ok "file names are matched, a name with spaces included"
newrepo
for i in 1 2 3 4 5 6 7; do plant "f$i.md" "clean $i"; done; plant f1.md "the Acme Corp"; plant f7.md "the Acme Corp"
out="$(scan LEAK_SCAN_CHUNK=2 LEAK_SCAN_EXTRA='acme-name |fail|ci|acme[- ]corp')"
[ "$(grep -c 'LEAK\[acme-name\] f' <<<"$out")" -eq 2 ] && grep -q 'f1.md:1' <<<"$out" && grep -q 'f7.md:1' <<<"$out" || fail "slices: $out"
ok "a large tree is scanned in slices and every slice is covered (the first and last file both hit)"
if [ "$AS_ROOT" -eq 0 ]; then
  newrepo; plant a.md "clean"; plant b.md "clean"; chmod 000 "$R/b.md"
  out="$(scan LEAK_SCAN_CHUNK=1)"; r=$?; chmod 600 "$R/b.md"
  [ $r -eq 3 ] && grep -q "grep failed" <<<"$out" || fail "an unreadable tracked file must be exit 3 (rc $r): $out"
  ok "a grep error (an unreadable tracked file) is exit 3, not a pass"
else ok "(skipped: running as root)"; fi
newrepo
ln -s nowhere-at-all "$R/dangling.md"; git -C "$R" add -A
out="$(scan)"; r=$?; [ $r -eq 0 ] && grep -q "skipped 1 symlink" <<<"$out" || fail "a dangling symlink: rc $r $out"
ok "a symlink is skipped and counted, not scanned and not a crash"

echo "== CI redaction =="
newrepo
plant notes.md "the Acme Corp rollout"
out="$(scan LEAK_SCAN_EXTRA='acme-name |fail|ci|acme[- ]corp')"; grep -q 'notes.md:1:Acme Corp' <<<"$out" || fail "the local report must show the match: $out"
out="$(scan GITHUB_ACTIONS=true LEAK_SCAN_EXTRA='acme-name |fail|ci|acme[- ]corp')"; r=$?
[ $r -eq 2 ] && grep -q 'LEAK\[acme-name\] notes.md:1$' <<<"$out" || fail "redacted report: rc $r $out"
grep -qi 'acme corp' <<<"$out" && fail "CI output printed the matched text: $out"
out="$(scan LEAK_SCAN_REDACT=1 LEAK_SCAN_EXTRA='acme-name |fail|ci|acme[- ]corp')"; grep -qi 'acme corp' <<<"$out" && fail "LEAK_SCAN_REDACT=1 printed the matched text"
plant acme-corp-file.md "x"
out="$(scan GITHUB_ACTIONS=true LEAK_SCAN_EXTRA='acme-name |fail|ci|acme[- ]corp')"; grep -qi 'acme-corp-file' <<<"$out" && fail "redacted output printed a matching file name: $out"
ok "in CI (or LEAK_SCAN_REDACT=1) a finding is its location only: no matched text, no matching file name"

echo "== the repo itself =="
out="$(env -i PATH="$PATH" HOME="$H" bash "$ROOT/scripts/leak-scan.sh" "$ROOT" 2>&1)"; r=$?
[ $r -eq 0 ] && grep -q "LEAK-SCAN PASS" <<<"$out" || fail "the repo fails its own generic layer (rc $r): $(grep -m3 'LEAK\[' <<<"$out")"
ok "this repo passes the generic layer alone — what a fork's CI runs"
echo
echo "LEAK-SCAN-TEST PASS"
