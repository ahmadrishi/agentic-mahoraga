#!/usr/bin/env bash
# tests/fail_loud_test.sh — the forge's grounding floor fails LOUD instead of silently mapping junk.
#
# Asserts, on hermetic temp repos:
#   1. mapping_scan + oracle_scan auto-detect on a Kotlin repo that also ships two .mjs tools exit 3
#      (UNSUPPORTED, naming kotlin) — they no longer map the minority JavaScript, or report 0/0/0.
#   2. --lang kotlin exits 3 and points at --allow-generic; with it, the keyword-filtered grep finds the
#      real definitions and never emits a keyword (com / val / class / package) as a name.
#   3. --lang java on a repo with no .java files exits 3 (an init mislabel cannot yield an empty map).
#   4. A python-dominant repo with Kotlin beside it scans python (exit 0) and records the unscanned
#      Kotlin on a "Coverage:" line + a stderr NOTE; a docs-only repo exits 3.
#   5. conformance-lint (mapping) resolves every path:line against --repo: the real scan PASSES (a
#      multi-line unpacking cites each name's own line); an invented file, a line past EOF, and a name
#      not on its line each FAIL; no root and no --repo FAILS.
#   6. Regressions found by adversarial review: generated dirs (coverage/) cannot flip the language; a
#      Python syntax error is skipped + reported, never mapped by the generic grep; --allow-generic
#      still needs files of that language and reads only them; an explicit --lang under 10% of the
#      source exits 3 (PARTIAL) unless --allow-partial; the lint checks EVERY names table, takes one --repo per repo
#      of a multi-repo map, rejects a symlink out of the repo, and defaults to the .claude/ parent;
#      a bare-CR file gets editor line numbers from every extractor; a row may not cite the skill's own
#      files; UTF-8-BOM Python is mapped; a TS-dominant repo is labelled typescript.
#
# Hermetic: own temp dir, cleaned up on exit. Needs bash + python3 + node + git. Run from the repo root:
#     bash tests/fail_loud_test.sh          # exit 0 = pass, non-zero = failure
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/core/lib/mapping_scan.py"
ORACLE="$ROOT/core/lib/oracle_scan.py"
LINT="$ROOT/scripts/conformance-lint.mjs"
PY="${PYTHON:-python3}"
NODE="${NODE:-node}"

fail() { printf 'FAIL-LOUD-TEST FAIL: %b\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
command -v "$NODE" >/dev/null 2>&1 || fail "node not found (required to run conformance-lint.mjs)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# expect <want-rc> <label> <cmd...> — run, keep stdout/stderr in $TMP/out|err, assert the exit code
expect() {
  local want="$1" label="$2"; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local rc=$?
  [ "$rc" -eq "$want" ] || { sed 's/^/  stderr: /' "$TMP/err" >&2; fail "$label: exit $rc, expected $want"; }
  echo "  ok: $label (exit $rc)"
}

# ---- fixtures ------------------------------------------------------------------------------------
KT="$TMP/fleet"; mkdir -p "$KT/src/main/kotlin/fleet" "$KT/src/test/kotlin/fleet" "$KT/tools"
cat > "$KT/src/main/kotlin/fleet/Maintenance.kt" <<'KT'
package com.example.fleet

const val MAX_DAILY_KM = 500

enum class Status { ACTIVE, RETIRED }

fun isDue(km: Int): Boolean = km > MAX_DAILY_KM
KT
cat > "$KT/src/test/kotlin/fleet/MaintenanceTest.kt" <<'KT'
package com.example.fleet

class MaintenanceTest {
    fun dueAfterLimit() { check(isDue(501)) }
}
KT
printf 'package com.example.fleet\n\ndata class Vehicle(val id: String, val km: Int)\n' \
  > "$KT/src/main/kotlin/fleet/Vehicle.kt"
printf 'export function bumpVersion(v) { return v + 1; }\n' > "$KT/tools/bump.mjs"
printf 'export function lintAll() { return 0; }\n' > "$KT/tools/lint.mjs"

PYK="$TMP/billing"; mkdir -p "$PYK/src" "$PYK/android"
for n in a b c; do printf 'def settle_%s(x):\n    return x\n' "$n" > "$PYK/src/settle_$n.py"; done
printf '(\n    RATE_FLOOR,\n    RATE_CEILING,\n) = 1, 9\n' > "$PYK/src/rates.py"   # multi-line unpacking
printf 'fun syncNow() = Unit\n' > "$PYK/android/Sync.kt"

DOCS="$TMP/handbook"; mkdir -p "$DOCS"; printf '# Handbook\n\nOnboarding notes.\n' > "$DOCS/README.md"

# ---- 1. unscannable dominant language -> exit 3 --------------------------------------------------
step "1. Kotlin + two .mjs tools: auto-detect fails loud (no minority-language map, no 0/0/0)"
expect 3 "mapping_scan auto on Kotlin" "$PY" "$SCAN" "$KT"
grep -q 'UNSUPPORTED.*kotlin' "$TMP/err" || fail "mapping_scan did not name kotlin as unsupported"
expect 3 "oracle_scan auto on Kotlin" "$PY" "$ORACLE" "$KT"
grep -q 'UNSUPPORTED.*kotlin' "$TMP/err" || fail "oracle_scan did not name kotlin as unsupported"

# ---- 2. explicit unscannable language: opt-in generic grep, no keyword names ---------------------
step "2. --lang kotlin needs --allow-generic; the generic grep emits names, never keywords"
expect 3 "mapping_scan --lang kotlin (no flag)" "$PY" "$SCAN" "$KT" --lang kotlin
grep -q -- '--allow-generic' "$TMP/err" || fail "the error does not point at --allow-generic"
expect 0 "mapping_scan --lang kotlin --allow-generic" "$PY" "$SCAN" "$KT" --lang kotlin --allow-generic
for want in MAX_DAILY_KM Status isDue; do
  grep -Eq "^\| $want \|" "$TMP/out" || fail "generic grep missed the real definition '$want'"
done
for kw in com val class package; do
  grep -Eq "^\| $kw \|" "$TMP/out" && fail "generic grep emitted the keyword '$kw' as a name"
done
grep -q '^Coverage: generic keyword grep' "$TMP/out" || fail "generic run does not label itself low precision"

# ---- 3. requested language with no files ---------------------------------------------------------
step "3. --lang java on a repo with no .java files fails loud"
expect 3 "mapping_scan --lang java (0 files)" "$PY" "$SCAN" "$KT" --lang java
grep -q 'no java source files' "$TMP/err" || fail "the error does not say there are no java files"

# ---- 4. scannable dominant: scan it, record what was left out; docs-only -> exit 3 ---------------
step "4. python-dominant repo with Kotlin beside it: scanned, and the gap is recorded"
expect 0 "mapping_scan auto on python + kotlin" "$PY" "$SCAN" "$PYK"
grep -q '^Coverage: Not scanned in this run.*kotlin 1' "$TMP/out" || fail "no Coverage line naming the unscanned kotlin"
grep -q 'NOTE.*kotlin 1' "$TMP/err" || fail "no stderr NOTE naming the unscanned kotlin"
expect 3 "mapping_scan auto on a docs-only repo" "$PY" "$SCAN" "$DOCS"

# ---- 5. conformance-lint resolves evidence -------------------------------------------------------
step "5. conformance-lint checks every path:line against the repo"
mkskill() {  # mkskill <dir> <subsystem-map.md source>
  mkdir -p "$1/references"; cp "$2" "$1/references/subsystem-map.md"
  printf -- '---\nname: %s\ndescription: Test mapping skill.\nmahoraga:\n  kind: mapping\n  grounding: file-line\n---\n# t\n' \
    "$(basename "$1")" > "$1/SKILL.md"
}
"$PY" "$SCAN" "$PYK" --lang python > "$TMP/map.md" 2>/dev/null || fail "scan of the python fixture failed"
grep -q '^| RATE_CEILING | constant | src/rates.py:3 |' "$TMP/map.md" \
  || fail "multi-line unpacking: RATE_CEILING must cite its own line (src/rates.py:3), not the '(' line"
mkskill "$TMP/good" "$TMP/map.md"
expect 0 "lint: real scan evidence" "$NODE" "$LINT" "$TMP/good" --repo "$PYK"
doctor() {  # doctor <skill> <sed expr> — a copy of the good skill with one evidence row changed
  rm -rf "$1"; cp -r "$TMP/good" "$1"; sed -i "$2" "$1/references/subsystem-map.md"
}
doctor "$TMP/invented" 's#| settle_a | function | src/settle_a.py:1 |#| settle_a | function | does/not/exist.go:9999 |#'
expect 1 "lint: invented file" "$NODE" "$LINT" "$TMP/invented" --repo "$PYK"
grep -q 'no such file' "$TMP/err" || fail "invented file not reported as missing"
doctor "$TMP/eof" 's#src/settle_a.py:1 |#src/settle_a.py:99 |#'
expect 1 "lint: line past EOF" "$NODE" "$LINT" "$TMP/eof" --repo "$PYK"
doctor "$TMP/ghost" 's#| settle_a | function |#| settle_ghost | function |#'
expect 1 "lint: name not on its line" "$NODE" "$LINT" "$TMP/ghost" --repo "$PYK"
grep -q 'not on that line' "$TMP/err" || fail "name mismatch not reported"
expect 1 "lint: no git root and no --repo" "$NODE" "$LINT" "$TMP/good"
if git -C "$TMP" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "  note: TMPDIR is inside a git work tree, so the lint used that root (rows fail as unresolved)"
else
  grep -q 'evidence not checked' "$TMP/err" || fail "missing root not reported"
fi

# ---- 6. regressions from adversarial review ------------------------------------------------------
step "6a. generated output (coverage/) cannot flip the dominant language"
NX="$TMP/nx"; mkdir -p "$NX/app" "$NX/coverage/lcov-report"
for n in a b; do printf 'def run_%s():\n    return 1\n' "$n" > "$NX/app/$n.py"; done
for n in 1 2 3 4 5; do printf 'function cov%s() {}\n' "$n" > "$NX/coverage/lcov-report/p$n.js"; done
expect 0 "mapping_scan auto with a coverage/ report" "$PY" "$SCAN" "$NX"
grep -q -- '--lang python' "$TMP/out" || fail "coverage/ JS flipped the language away from python"
grep -q 'coverage/' "$TMP/out" && fail "generated coverage/ files were mapped"

step "6b. a Python syntax error is skipped and reported, never mapped by a fallback"
printf 'def broken(:\n    # of the old API\n' > "$PYK/src/bad.py"
expect 0 "mapping_scan with one unparseable file" "$PY" "$SCAN" "$PYK"
grep -q '^Coverage:.*unparseable, skipped: 1 file(s) (src/bad.py)' "$TMP/out" || fail "unparseable file not reported on Coverage"
grep -q 'src/bad.py:' "$TMP/out" && fail "the unparseable file was mapped"
rm -f "$PYK/src/bad.py"

printf '\xef\xbb\xbfdef with_bom():\n    return 1\n' > "$PYK/src/bom.py"   # UTF-8 BOM is valid Python
expect 0 "mapping_scan with a UTF-8-BOM file" "$PY" "$SCAN" "$PYK"
grep -q '^| with_bom | function | src/bom.py:1 |' "$TMP/out" || fail "UTF-8-BOM python file was not mapped"
rm -f "$PYK/src/bom.py"
TSL="$TMP/tslabel"; mkdir -p "$TSL/src"
for n in 1 2 3; do printf 'export function f%s(): number { return 1; }\n' "$n" > "$TSL/src/m$n.ts"; done
printf 'export function cfg() { return 1; }\n' > "$TSL/vite.config.js"
expect 0 "TS-dominant repo" "$PY" "$SCAN" "$TSL"
grep -q -- '--lang typescript`' "$TMP/out" || fail "a TS-dominant repo was labelled javascript"

step "6c. --allow-generic still needs that language's files, and reads only them"
expect 3 "--lang rust --allow-generic on a repo with no .rs" "$PY" "$SCAN" "$PYK" --lang rust --allow-generic
expect 0 "--lang kotlin --allow-generic" "$PY" "$SCAN" "$KT" --lang kotlin --allow-generic
grep -q 'bumpVersion' "$TMP/out" && fail "the generic kotlin grep read the .mjs tools"

step "6d. a small-minority --lang (under 10% of the source) is PARTIAL unless --allow-partial"
AND="$TMP/android"; mkdir -p "$AND/app/src/main/kotlin" "$AND/app/src/main/java"
for n in $(seq 1 12); do printf 'class Screen%s\n' "$n" > "$AND/app/src/main/kotlin/Screen$n.kt"; done
printf 'public class LegacyUtil {\n  public static int one() { return 1; }\n}\n' > "$AND/app/src/main/java/LegacyUtil.java"
expect 3 "--lang java on a Kotlin app with one Java file" "$PY" "$SCAN" "$AND" --lang java
grep -q 'PARTIAL' "$TMP/err" || fail "small-minority --lang not reported as PARTIAL"
expect 0 "--lang java --allow-partial" "$PY" "$SCAN" "$AND" --lang java --allow-partial
grep -q '^Coverage: Not scanned in this run.*kotlin 12' "$TMP/out" || fail "partial scan does not record the unscanned kotlin"
grep -q -- '--allow-partial`' "$TMP/out" || fail "the Regenerate line drops --allow-partial"
expect 0 "--lang javascript on the Kotlin repo (2 of 5 files: not a small minority)" "$PY" "$SCAN" "$KT" --lang javascript

step "6e. the lint checks every names table, every repo root, and the real path"
cp -r "$TMP/good" "$TMP/twotables"
printf '\n| name | kind | evidence |\n|---|---|---|\n| RefundEngine | class | does/not/exist.go:9999 |\n' >> "$TMP/twotables/SKILL.md"
expect 1 "lint: invented row in a second table" "$NODE" "$LINT" "$TMP/twotables" --repo "$PYK"
grep -q 'RefundEngine' "$TMP/err" || fail "the second table's invented row was not reported"
API="$TMP/multi/api"; WEB="$TMP/multi/web"; mkdir -p "$API" "$WEB"
printf 'def charge(x):\n    return x\n\ndef refund(x):\n    return x\n' > "$API/pay.py"
printf 'def render(x):\n    return x\n' > "$WEB/view.py"
"$PY" "$SCAN" "$API" --lang python > "$TMP/api.md" 2>/dev/null; "$PY" "$SCAN" "$WEB" --lang python > "$TMP/web.md" 2>/dev/null
mkskill "$TMP/multi-skill" "$TMP/api.md"; tail -n +6 "$TMP/web.md" >> "$TMP/multi-skill/SKILL.md"
expect 0 "lint: multi-repo map, one --repo per repo" "$NODE" "$LINT" "$TMP/multi-skill" --repo "$API" --repo "$WEB"
expect 1 "lint: multi-repo map, one root only" "$NODE" "$LINT" "$TMP/multi-skill" --repo "$API"
mkdir -p "$TMP/outside"; printf 'def secret_fn():\n    return 1\n' > "$TMP/outside/s.py"; ln -s "$TMP/outside" "$PYK/link"
doctor "$TMP/escape" 's#| settle_a | function | src/settle_a.py:1 |#| secret_fn | function | link/s.py:1 |#'
expect 1 "lint: evidence through a symlink out of the repo" "$NODE" "$LINT" "$TMP/escape" --repo "$PYK"
rm -f "$PYK/link"
CR="$TMP/cr"; mkdir -p "$CR/src"   # bare-CR line endings: every extractor must count \r as a break
printf '// header\r// note\rexport function chargeCard() {}\rexport const MAX_RETRY_COUNT = 3\rexport class Ledger {}\r' > "$CR/src/pay.ts"
"$PY" "$SCAN" "$CR" --lang typescript > "$TMP/cr.md" 2>/dev/null || fail "scan of the bare-CR fixture failed"
grep -q '^| chargeCard | function | src/pay.ts:3 |' "$TMP/cr.md" || fail "bare-CR file: chargeCard must cite line 3"
mkskill "$TMP/cr-skill" "$TMP/cr.md"
expect 0 "lint: bare-CR TS file" "$NODE" "$LINT" "$TMP/cr-skill" --repo "$CR"
mkskill "$PYK/.claude/skills/billing-mapping" "$TMP/map.md"
SELF="$PYK/.claude/skills/billing-mapping/references/subsystem-map.md"
printf '| GhostRefundEngine | class | .claude/skills/billing-mapping/references/subsystem-map.md:%s |\n' \
  "$(( $(wc -l < "$SELF") + 1 ))" >> "$SELF"
expect 1 "lint: a row citing its own skill file" "$NODE" "$LINT" "$PYK/.claude/skills/billing-mapping"
grep -q 'cites the skill' "$TMP/err" || fail "self-citation not reported"
mkskill "$PYK/.claude/skills/billing-mapping" "$TMP/map.md"
expect 0 "lint: default root is the skill's .claude/ parent" "$NODE" "$LINT" "$PYK/.claude/skills/billing-mapping"

echo
echo "FAIL-LOUD-TEST PASS"
