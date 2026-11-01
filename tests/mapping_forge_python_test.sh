#!/usr/bin/env bash
# tests/mapping_forge_python_test.sh — cross-language mapping-forge held-out test.
#
# Proves (cross-language grounded mapping scan) + (mapping-kind conformance lint) end to end,
# on a FRESH repo the forge has never seen:
#
#   1. Scaffold a throwaway Python repo in a temp dir defining NEW distinctive names
#      (function settle_open_invoice, constant MAX_SETTLEMENT_BATCH, Enum SettlementState + members).
#   2. Run  core/lib/mapping_scan.py <repo> --lang python --format md  -> the subsystem-map.md table.
#   3. Assemble a minimal kind:mapping skill dir (SKILL.md + references/subsystem-map.md).
#   4. POSITIVE: node scripts/conformance-lint.mjs <skill> => CONFORMANCE PASS, and each of the three
#      new symbols appears in the table with a REAL file:line (never UNVERIFIED).
#   5. NEGATIVE: doctor one data row's evidence to a non-`path:line` value => the lint FAILS (exit 1).
#   6. Cross-language bonus (guarded): a fresh .ts file's `export function` is found with file:line too.
#
# A minimal kind:mapping skill legitimately has NO 8-file spec manifest, so a CONFORMANCE PASS here is
# only reachable via the mapping-kind branch of the lint — the positive assertion doubles as proof that
# branch fired (a spec-path evaluation of this dir would fail on the missing manifest).
#
# Depends on:
#   * core/lib/mapping_scan.py — deterministic cross-language grounding scan
#   * scripts/conformance-lint.mjs — mapping-kind branch
#
# Hermetic: own temp dirs only, cleaned up on exit; touches no repo files. Needs python3 + node.
# Run from the repo root:   bash tests/mapping_forge_python_test.sh    # exit 0 = pass, non-zero = fail
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/core/lib/mapping_scan.py"
LINT="$ROOT/scripts/conformance-lint.mjs"
PY="${PYTHON:-python3}"
NODE="${NODE:-node}"
# TS cross-language check: assert (default) | skip. Guarded so the mandated Python proof never hinges
# on the optional TS variant.
TS_MODE="${MAPPING_TEST_TS:-skip}"

fail() { printf 'MAPPING-TEST FAIL: %b\n' "$*" >&2; exit 1; }

# ---- required upstream artifacts + toolchain ----------------------------------------------------
[ -f "$SCAN" ] || fail "missing $SCAN"
[ -f "$LINT" ] || fail "missing $LINT"
command -v "$PY"   >/dev/null 2>&1 || fail "python3 not found (required to run mapping_scan.py)"
command -v "$NODE" >/dev/null 2>&1 || fail "node not found (required to run conformance-lint.mjs)"

# ---- table helpers (parse the fixed subsystem-map.md names table) -------------------------------
# The evidence column is always the 3rd content cell = awk field 4 (field 1 is the empty cell before
# the leading '|'), whether or not the row carries a trailing '|'. Separator rows (only |,-,:,space)
# and the header row (name == "name") are skipped.

# assert_grounded <symbol> <map-file>: the symbol is a data row whose evidence is a real path:line.
assert_grounded() {
  local sym="$1" mapf="$2" ev
  ev="$(awk -F'|' -v s="$sym" '
    function trim(x){ sub(/^[ \t]+/,"",x); sub(/[ \t]+$/,"",x); return x }
    NF>=4 && $0 ~ /^[ \t]*\|/ && $0 !~ /^[ \t]*\|[ \t:|-]*$/ {
      if (trim($2)==s) { print trim($4); exit }
    }' "$mapf")"
  [ -n "$ev" ] || fail "symbol '$sym' is not present as a data row in $mapf"
  [ "$ev" = "UNVERIFIED" ] && fail "symbol '$sym' evidence is UNVERIFIED in $mapf; expected a real file:line"
  printf '%s' "$ev" | grep -Eq '^[^[:space:]]+:[0-9]+$' \
    || fail "symbol '$sym' evidence '$ev' is not a path:line in $mapf"
  echo "  grounded: $sym -> $ev"
}

# count_data_rows <map-file>: number of table data rows (excludes header + separator).
count_data_rows() {
  awk -F'|' '
    function trim(x){ sub(/^[ \t]+/,"",x); sub(/[ \t]+$/,"",x); return x }
    NF>=4 && $0 ~ /^[ \t]*\|/ && $0 !~ /^[ \t]*\|[ \t:|-]*$/ {
      n=trim($2); if (n!="name" && n!="") c++
    } END { print c+0 }' "$1"
}

# doctor_evidence <in-map> <out-map>: copy the map, rewriting the FIRST data row's evidence to a value
# that is neither a path:line nor UNVERIFIED — the exact defect the mapping-kind lint must reject.
doctor_evidence() {
  awk '
    function trim(x){ sub(/^[ \t]+/,"",x); sub(/[ \t]+$/,"",x); return x }
    {
      if (!done && $0 ~ /^[ \t]*\|/ && $0 !~ /^[ \t]*\|[ \t:|-]*$/) {
        split($0, c, "|"); name=trim(c[2]);
        if (name != "name" && name != "") {
          print "| " name " | " trim(c[3]) " | BOGUS_NOT_A_LOCATION |";
          done=1; next;
        }
      }
      print;
    }' "$1" > "$2"
}

# ---- hermetic scaffold --------------------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/settlement-svc"                     # fresh Python repo the forge has never seen
SKILL="$TMP/settlement-svc-mapping"           # the minimal kind:mapping skill we assemble
mkdir -p "$SRC/src" "$SKILL/references"

# a couple of .py files with NEW, distinctive names (all clean of any company vocabulary)
cat > "$SRC/src/ledger.py" <<'PY'
"""Settlement ledger — core write path."""
from enum import Enum

MAX_SETTLEMENT_BATCH = 500


class SettlementState(Enum):
    OPEN = "open"
    PARTIALLY_SETTLED = "partially_settled"
    CLOSED = "closed"


def settle_open_invoice(invoice_id, amount):
    """Settle a single open invoice, capped by the batch size."""
    return {"invoice": invoice_id, "amount": amount, "state": SettlementState.CLOSED}


def reconcile_settlement_batch(entries):
    """Reconcile a batch of settlement entries."""
    return sum(1 for _ in entries)
PY

cat > "$SRC/src/config.py" <<'PY'
"""Runtime configuration for the settlement service."""

SETTLEMENT_RETRY_LIMIT = 3
DEFAULT_LEDGER_CURRENCY = "AED"
PY

echo "fixture: fresh python repo at $SRC (title=$(basename "$SRC"))"

# ---- 1) run the deterministic grounding scan into the skill's references ------------------------
MAP="$SKILL/references/subsystem-map.md"
"$PY" "$SCAN" "$SRC" --lang python --format md > "$MAP" 2>"$TMP/scan.err"; RC=$?
[ "$RC" -eq 0 ] || { sed 's/^/  scan-stderr: /' "$TMP/scan.err" >&2; fail "mapping_scan.py exited $RC"; }
[ -s "$MAP" ]   || fail "mapping_scan.py produced an empty subsystem-map.md"
echo "scan -> $MAP:"; sed 's/^/  | /' "$MAP"

rows="$(count_data_rows "$MAP")"
[ "$rows" -ge 3 ] || fail "scan produced only $rows data row(s); the contract requires >=3 (a real map)"
echo "scan produced $rows data row(s)."

# ---- 2) assemble the minimal kind:mapping skill (SKILL.md carries the mahoraga block + provenance)
cat > "$SKILL/SKILL.md" <<'MD'
---
name: settlement-svc-mapping
description: Maps the settlement service's core vocabulary (functions, constants, enums) to file:line evidence so downstream work grounds on real definitions. Regenerate with the provenance command. Do NOT use for spec authoring (that is the spec-style-forge).
allowed-tools: [Read, Grep]
mahoraga:
  kind: mapping
  grounding: file-line
  provenance: python3 core/lib/mapping_scan.py . --lang python
---

# Settlement service — subsystem map

Grounded vocabulary for the settlement service. Every name carries `file:line` evidence
produced by a deterministic scan; never trust a name here that lost its evidence.

Regenerate: `python3 core/lib/mapping_scan.py . --lang python`

## Names

The full grounded names table lives in
[references/subsystem-map.md](references/subsystem-map.md).
MD

# ---- 3) POSITIVE: the lint passes (only reachable via the mapping-kind branch) ------------------
OUT="$("$NODE" "$LINT" "$SKILL" --repo "$SRC" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  lint: /'
[ "$RC" -eq 0 ] || fail "POSITIVE: expected exit 0 from conformance-lint, got $RC"
printf '%s\n' "$OUT" | grep -q 'CONFORMANCE PASS' \
  || fail "POSITIVE: exit 0 but no 'CONFORMANCE PASS' line — mapping-kind branch did not confirm"
echo "POSITIVE: PASS (kind:mapping skill passes conformance-lint)"

# each mandated new symbol must be present AND grounded with a real file:line
assert_grounded "settle_open_invoice"   "$MAP"
assert_grounded "SettlementState"       "$MAP"
assert_grounded "MAX_SETTLEMENT_BATCH"  "$MAP"
echo "GROUNDING: PASS (settle_open_invoice / SettlementState / MAX_SETTLEMENT_BATCH each carry file:line)"

# ---- 4) NEGATIVE: a bogus, non-path:line evidence cell must make the lint FAIL ------------------
BAD="$TMP/settlement-svc-mapping-bad"
mkdir -p "$BAD/references"
cp "$SKILL/SKILL.md" "$BAD/SKILL.md"
doctor_evidence "$MAP" "$BAD/references/subsystem-map.md"
grep -q 'BOGUS_NOT_A_LOCATION' "$BAD/references/subsystem-map.md" \
  || fail "NEGATIVE: could not doctor an evidence cell (table shape unexpected)"
OUT_NEG="$("$NODE" "$LINT" "$BAD" --repo "$SRC" 2>&1)"; RC_NEG=$?
printf '%s\n' "$OUT_NEG" | sed 's/^/  lint: /'
[ "$RC_NEG" -ne 0 ] || fail "NEGATIVE: bogus evidence row still passed the lint (expected non-zero exit)"
printf '%s\n' "$OUT_NEG" | grep -qi 'FAIL' \
  || fail "NEGATIVE: lint exited $RC_NEG but printed no CONFORMANCE FAIL line"
echo "NEGATIVE: PASS (bogus non-path:line evidence rejected; exit $RC_NEG)"

# ---- 5) cross-language bonus (guarded): a fresh TypeScript export is found with file:line --------
if [ "$TS_MODE" = "skip" ]; then
  echo "TS: SKIP (MAPPING_TEST_TS=skip)"
else
  TSSRC="$TMP/ts-demo"; mkdir -p "$TSSRC/src"
  cat > "$TSSRC/src/reconcile.ts" <<'TS'
export const MAX_RECONCILE_WINDOW = 30;

export enum ReconcileState { Pending, Settled }

export function reconcileLedgerBatch(entries: number[]): number {
  return entries.length;
}
TS
  TSMAP="$TMP/ts-subsystem-map.md"
  "$PY" "$SCAN" "$TSSRC" --lang typescript --format md > "$TSMAP" 2>"$TMP/ts-scan.err"; RC_TS=$?
  if [ "$RC_TS" -eq 0 ] && [ -s "$TSMAP" ]; then
    sed 's/^/  ts | /' "$TSMAP"
    assert_grounded "reconcileLedgerBatch" "$TSMAP"
    echo "TS: PASS (cross-language scan grounds an exported TS function; )"
  else
    sed 's/^/  ts-scan-stderr: /' "$TMP/ts-scan.err" >&2
    fail "TS: mapping_scan.py --lang typescript exited $RC_TS or produced no output (set MAPPING_TEST_TS=skip to bypass)"
  fi
fi

echo "MAPPING-TEST PASS"
