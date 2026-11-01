#!/usr/bin/env bash
# tests/oracle_floor_test.sh — the behavioural-oracle floor, end to end.
#
# Proves the "behavioural-oracle floor" contract on a FRESH, hermetic fixture the scanner has
# never seen, then exercises the verify SMOKE rung and the N-arm ablation the floor feeds:
#
#   1. oracle_scan.py --self-test passes (its own built-in unit checks, mirroring mapping_scan).
#   2. On a temp fixture holding ONE real-assertion test (a concrete expected literal) and ONE STUB
#      test, the scan emits the real oracle's `expected` literal + `test-file:line` at tier WITNESSED,
#      classifies the stub as STUB (NOT counted), and prints the counted real/total/files denominator.
#   3. Determinism: two scans of the same tree are byte-identical.
#   4. verify run_oracle is HONEST — a green mined oracle -> pass (verdict climbs to SMOKE-VERIFIED
#      when the full test_cmd did not run), a not-runnable oracle -> n/a (never a fake pass) and the
#      verdict stays UNVERIFIED.
#   5. A THREE-arm aggregate (baseline + harness + a `mapping+oracle` arm via score.mapping+oracle.json)
#      yields aggregate.arms with 3 entries + aggregate.arm_deltas for the two non-baseline arms (and
#      keeps ablation_delta = harness − baseline), and the rendered report shows all three arms.
#   6. The prove_ablation_test STILL passes (harness − baseline ablation_delta intact).
#
# Depends on:
#   * core/lib/oracle_scan.py — deterministic behavioural-oracle scan, the FORMAT
#   * core/adapters/verify/command.sh — run_oracle verb + the SMOKE-VERIFIED verdict rung
#   * core/lib/aggregate_scores.py — N-arm arms + arm_deltas
#   * core/lib/{report_ablation,build_report}.py — renders every arm
#   * tests/prove_ablation_test.sh + its deps (examples/py-service, cutoff_label.py) — 
#
# Hermetic: every path lives under one mktemp dir, cleaned up on exit. Needs only python3 + PyYAML
# (the one allowed runtime dep) + git (for the delegated test) + coreutils. NO node, NO network.
#
# Run from the repo root:  bash tests/oracle_floor_test.sh    # exit 0 = pass, non-zero = failure
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/core/lib"
SCAN="$LIB/oracle_scan.py"
VERIFY="$ROOT/core/adapters/verify/command.sh"
AGG="$LIB/aggregate_scores.py"
REPORT="$LIB/build_report.py"
PROVE="$ROOT/tests/prove_ablation_test.sh"
PY="${PYTHON:-python3}"

fail() { printf 'ORACLE-FLOOR FAIL: %b\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
need() { [ -e "$1" ] || fail "missing dependency: $1 ($2)"; }

# ---- required upstream artifacts + toolchain ----------------------------------------------------
need "$SCAN"    "core/lib/oracle_scan.py"
need "$VERIFY"  "verify/command.sh (run_oracle + SMOKE rung)"
need "$AGG"     "aggregate_scores.py (N-arm)"
need "$REPORT"  "build_report.py"
need "$PROVE"   "the prove_ablation_test (must still pass)"
command -v "$PY" >/dev/null 2>&1 || fail "python3 not found"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# awk: extract one oracle-library data row by its `oracle` name -> "expected<TAB>tier<TAB>evidence".
# The fixed FORMAT table is `| oracle | expected | tier | evidence |` (with -F'|' the content cells are
# fields 2..5). Header (oracle=="oracle") and separator rows (only |,-,:,space) are skipped.
orow() { # <oracle-name> <map-file>
  awk -F'|' -v s="$1" '
    function trim(x){ sub(/^[ \t]+/,"",x); sub(/[ \t]+$/,"",x); return x }
    NF>=5 && $0 ~ /^[ \t]*\|/ && $0 !~ /^[ \t]*\|[ \t:|-]*$/ {
      if (trim($2)==s){ print trim($3) "\t" trim($4) "\t" trim($5); exit }
    }' "$2"
}

# =================================================================================================
step "1. oracle_scan.py --self-test (the scanner's own unit checks)"
ST_OUT="$("$PY" "$SCAN" --self-test 2>&1)"; ST_RC=$?
printf '%s\n' "$ST_OUT" | sed 's/^/  /'
[ "$ST_RC" -eq 0 ] || fail "oracle_scan.py --self-test exited $ST_RC (expected 0)"
printf '%s' "$ST_OUT" | grep -qi 'pass' || fail "oracle_scan.py --self-test printed no PASS marker"
echo "  self-test: PASS"

# =================================================================================================
step "2. scan a fixture (one REAL oracle + one STUB) — witnessed literal, STUB not counted, denominator"
FIX="$TMP/oracle-fixture"                # a fresh repo the scanner has never seen
mkdir -p "$FIX/tests"
# ONE real-assertion test (a concrete expected literal, 4200 = (30-15)*280) + ONE stub (empty body).
cat > "$FIX/tests/test_ledger.py" <<'PY'
def test_computes_prorated_refund():
    assert compute_prorated_refund(30, 15) == 4200


def test_placeholder():
    pass
PY

MD1="$TMP/scan1.md"
"$PY" "$SCAN" "$FIX" --lang python --format md > "$MD1" 2>"$TMP/scan1.err"; SC_RC=$?
[ "$SC_RC" -eq 0 ] || { sed 's/^/  scan-stderr: /' "$TMP/scan1.err" >&2; fail "oracle_scan.py exited $SC_RC"; }
[ -s "$MD1" ] || fail "oracle_scan.py produced an empty oracle-library.md"
sed 's/^/  | /' "$MD1"

# --- the REAL oracle: expected literal 4200, tier WITNESSED, evidence = a real test-file:line -----
REAL_ROW="$(orow "test_computes_prorated_refund" "$MD1")"
[ -n "$REAL_ROW" ] || fail "the real oracle 'test_computes_prorated_refund' is not a data row in the scan"
R_EXP="$(printf '%s' "$REAL_ROW" | cut -f1)"
R_TIER="$(printf '%s' "$REAL_ROW" | cut -f2)"
R_EV="$(printf '%s' "$REAL_ROW" | cut -f3)"
[ "$R_EXP" = "4200" ]      || fail "real oracle expected literal is '$R_EXP', want '4200'"
[ "$R_TIER" = "WITNESSED" ] || fail "real oracle tier is '$R_TIER', want 'WITNESSED'"
printf '%s' "$R_EV" | grep -Eq '^[^[:space:]]*test_ledger\.py:[0-9]+$' \
  || fail "real oracle evidence '$R_EV' is not a test-file:line (want e.g. tests/test_ledger.py:2)"
echo "  REAL: test_computes_prorated_refund | expected=$R_EXP | $R_TIER | $R_EV"

# --- the STUB: classified STUB (tier STUB) --------------------------------------------------------
STUB_ROW="$(orow "test_placeholder" "$MD1")"
[ -n "$STUB_ROW" ] || fail "the stub 'test_placeholder' is not a data row in the scan (must be listed as STUB)"
S_TIER="$(printf '%s' "$STUB_ROW" | cut -f2)"
[ "$S_TIER" = "STUB" ] || fail "stub 'test_placeholder' tier is '$S_TIER', want 'STUB'"
echo "  STUB: test_placeholder | $S_TIER"

# --- the counted denominator: `Behavioural grounding: <real> real / <total> test / <files> file` ---
GL="$(grep -i '^Behavioural grounding:' "$MD1" | head -1)"
[ -n "$GL" ] || fail "no 'Behavioural grounding:' denominator line in the scan output"
read -r G_REAL G_TOTAL G_FILES G_STUB <<EOF
$(printf '%s' "$GL" | grep -oE '[0-9]+' | tr '\n' ' ')
EOF
echo "  denominator: real=$G_REAL total=$G_TOTAL files=$G_FILES stubs=$G_STUB   ($GL)"
[ "$G_REAL"  = "1" ] || fail "counted REAL oracles = '$G_REAL', want 1 (the stub must NOT be counted)"
[ "$G_TOTAL" = "2" ] || fail "counted total tests = '$G_TOTAL', want 2 (real + stub)"
[ "$G_FILES" = "1" ] || fail "counted files = '$G_FILES', want 1"
[ "${G_STUB:-}" = "1" ] || fail "counted stubs = '${G_STUB:-}', want 1"
echo "  denominator OK — the stub is listed but excluded from the real count"

# =================================================================================================
step "3. determinism — a second scan of the same tree is byte-identical"
MD2="$TMP/scan2.md"
"$PY" "$SCAN" "$FIX" --lang python --format md > "$MD2" 2>/dev/null || fail "second scan exited non-zero"
diff -q "$MD1" "$MD2" >/dev/null || { diff "$MD1" "$MD2" | sed 's/^/  /' >&2; fail "scan output is not deterministic"; }
echo "  two scans identical (deterministic)"

# =================================================================================================
step "4. verify run_oracle — green -> pass / SMOKE-VERIFIED; not-runnable -> n/a / UNVERIFIED (no fake pass)"
VREPO="$TMP/verify/svc"; mkdir -p "$VREPO"          # a plain repo dir (no git needed)
OLOG="$TMP/oracle.log"                               # ABSOLUTE (R12)

# 4a. the run_oracle VERB directly (fixed signature: run_oracle <repo> <oracle_spec> <abs_log>).
#     PROJECT_YAML must exist (the adapter guards on it); a repo entry lets it read an oracle_marker.
CFG_VERB="$TMP/verb.yaml"
cat > "$CFG_VERB" <<'YAML'
repos:
  - name: svc
    language: python
YAML
GREEN='python3 -c "assert (30-15)*280 == 4200"'     # exit 0 -> pass
BROKEN='mahoraga_nonexistent_oracle_runner_xyz'     # command not found (rc 127) -> n/a, NEVER pass

RO_GREEN="$(PROJECT_YAML="$CFG_VERB" bash "$VERIFY" run_oracle "$VREPO" "$GREEN" "$OLOG" 2>/dev/null)"; RO_G_RC=$?
echo "  run_oracle(green)        -> '$RO_GREEN' (rc=$RO_G_RC)"
case "$RO_GREEN" in pass*) : ;; *) fail "run_oracle on a green oracle must be 'pass', got '$RO_GREEN'";; esac
[ "$RO_G_RC" -eq 0 ] || fail "run_oracle(green) returned rc=$RO_G_RC, want 0"

RO_BROKEN="$(PROJECT_YAML="$CFG_VERB" bash "$VERIFY" run_oracle "$VREPO" "$BROKEN" "$OLOG" 2>/dev/null)"; RO_B_RC=$?
echo "  run_oracle(not-runnable) -> '$RO_BROKEN' (rc=$RO_B_RC)"
case "$RO_BROKEN" in pass*) fail "HONESTY VIOLATION: run_oracle faked a pass on a not-runnable oracle";; esac
case "$RO_BROKEN" in n/a*) : ;; *) fail "run_oracle on a not-runnable oracle should be 'n/a', got '$RO_BROKEN'";; esac
[ "$RO_B_RC" -ne 0 ] || fail "run_oracle(not-runnable) returned rc=0 (must be non-zero — no fake pass)"

# 4b. the VERDICT ladder: a green oracle + passing gate + NO test_cmd climbs to SMOKE-VERIFIED.
CFG_SMOKE="$TMP/smoke.yaml"
cat > "$CFG_SMOKE" <<'YAML'
repos:
  - name: svc
    language: python
    verify:
      typecheck_cmd: 'python3 -c "pass"'
      oracle_cmd: 'python3 -c "assert (30-15)*280 == 4200"'
YAML
V_SMOKE="$(PROJECT_YAML="$CFG_SMOKE" bash "$VERIFY" verdict "$VREPO" "$TMP/smokelogs" 2>/dev/null | tail -1)"
echo "  verdict(green oracle, no test_cmd) -> '$V_SMOKE'"
[ "$V_SMOKE" = "SMOKE-VERIFIED" ] || fail "expected SMOKE-VERIFIED for a green oracle w/o test_cmd, got '$V_SMOKE'"

# 4c. a not-runnable oracle with nothing else to verify stays UNVERIFIED (never lifts the verdict).
CFG_UNV="$TMP/unverified.yaml"
cat > "$CFG_UNV" <<'YAML'
repos:
  - name: svc
    language: python
    verify:
      oracle_cmd: 'mahoraga_nonexistent_oracle_runner_xyz'
YAML
V_UNV="$(PROJECT_YAML="$CFG_UNV" bash "$VERIFY" verdict "$VREPO" "$TMP/unvlogs" 2>/dev/null | tail -1)"
echo "  verdict(not-runnable oracle only) -> '$V_UNV'"
[ "$V_UNV" = "UNVERIFIED" ] || fail "expected UNVERIFIED for a not-runnable oracle, got '$V_UNV'"

# =================================================================================================
step "5. three-arm aggregate (baseline + harness + mapping+oracle) + a report that shows all three"
RUN="$TMP/run"; UNIT="ORACLE-1"; UDIR="$RUN/$UNIT"; mkdir -p "$UDIR"
UDIR="$UDIR" "$PY" - <<'PY'
import os, json
udir = os.environ["UDIR"]
base = {
    "id": "ORACLE-1", "title": "prorated refund — oracle floor three-arm",
    "scorer": "stub", "complexity": "small", "compile": "n/a",
    "code_quality": {"overall": "equal", "reuse": "equal", "rationale": "stub score for the three-arm test"},
    "security": {"verdict": "none — parity/better", "severity": "none", "reachable": False},
    "hallucination": "none", "overeng": "none", "lost_context": "none", "spec_fidelity": 90,
    "eval_note": "STUB score for the three-arm aggregate (mechanical, not real scoring).",
}
def w(name, arm, br, lost):
    d = dict(base); d["arm"] = arm; d["business_req_pct"] = br
    d["code_quality"] = dict(base["code_quality"])
    if lost:
        d["lost_context"] = lost
    d["title"] = "prorated refund — %s arm" % arm
    json.dump(d, open(os.path.join(udir, name), "w"), indent=2)

w("score.json",              "harness",       90, None)
w("score.baseline.json",     "baseline",      60, "refund emitted in major units but the consumer reads whole cents")
w("score.mapping+oracle.json","mapping+oracle", 95, None)
print("wrote score.json (harness=90) + score.baseline.json (baseline=60) + score.mapping+oracle.json (95)")
PY
for f in score.json score.baseline.json "score.mapping+oracle.json"; do
  [ -s "$UDIR/$f" ] || fail "did not write $f"
done

AGG_OUT="$("$PY" "$AGG" "$RUN" 2>&1)"; AGG_RC=$?
printf '%s\n' "$AGG_OUT" | sed 's/^/  /'
[ "$AGG_RC" -eq 0 ] || fail "aggregate_scores.py exited $AGG_RC"
[ -s "$RUN/scores.json" ] || fail "aggregate produced no scores.json"

# assert: 3 arms, arm_deltas for the two non-baseline arms, ablation_delta = harness − baseline (>0).
SCORES="$RUN/scores.json" "$PY" - <<'PY' || fail "three-arm aggregate assertions failed"
import os, json, sys
agg = json.load(open(os.environ["SCORES"]))["aggregate"]
arms = agg.get("arms", {})
assert set(arms) == {"harness", "baseline", "mapping+oracle"}, "arms != 3 expected: %r" % sorted(arms)
assert len(arms) == 3, "aggregate.arms must have 3 entries, got %d" % len(arms)
deltas = agg.get("arm_deltas") or {}
assert set(deltas) == {"harness", "mapping+oracle"}, "arm_deltas should cover the non-baseline arms: %r" % sorted(deltas)
for a, d in deltas.items():
    for k in ("business_req_avg", "lost_context", "hallucinations", "overeng"):
        assert k in d, "arm_deltas[%s] missing %s" % (a, k)
assert deltas["mapping+oracle"]["business_req_avg"] == 95 - 60, "mapping+oracle Δbr wrong: %r" % deltas["mapping+oracle"]
ad = agg.get("ablation_delta")
assert isinstance(ad, dict) and ad.get("business_req_avg") == 90 - 60, "ablation_delta (harness−baseline) not intact: %r" % ad
print("  arms=%s | arm_deltas=%s | ablation_delta.br=%s" % (
    sorted(arms), sorted(deltas), ad.get("business_req_avg")))
PY

BR_OUT="$("$PY" "$REPORT" "$RUN" 2>&1)"; BR_RC=$?
printf '%s\n' "$BR_OUT" | sed 's/^/  /'
[ "$BR_RC" -eq 0 ] || fail "build_report.py exited $BR_RC"
[ -s "$RUN/report.html" ] || fail "build_report produced no report.html"
for arm in harness baseline "mapping+oracle"; do
  grep -qF "$arm" "$RUN/report.html" || fail "report.html does not render the '$arm' arm"
done
echo "  report.html renders all three arms (harness / baseline / mapping+oracle)"

# =================================================================================================
step "6. the prove_ablation_test still passes (harness − baseline ablation intact)"
# Run it in a clean env so this test's PROJECT_YAML/PROJECT_CONFIG never leak into the pipeline.
if ( unset PROJECT_YAML PROJECT_CONFIG MAHORAGA_REPO_DIR; bash "$PROVE" ) > "$TMP/prove.out" 2>&1; then
  echo "  prove_ablation_test: PASS"
else
  sed 's/^/  prove: /' "$TMP/prove.out" >&2
  fail "the prove_ablation_test regressed (must still pass under the changes)"
fi

printf '\nORACLE-FLOOR PASS\n'
echo "  fixture=$FIX"
echo "  report=$RUN/report.html"
