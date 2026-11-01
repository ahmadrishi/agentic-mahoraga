#!/usr/bin/env bash
# adapter-security-check.sh — the ADAPTER SUPPLY-CHAIN GATE.
#
# Adapters (docs/ADAPTER-CONTRACT.md) are executable shell that runs in EVERY user's
# repo, so a contributed adapter is a supply-chain surface: a malicious or careless one
# could phone home, run attacker-supplied strings, or exfiltrate secrets. This gate
# statically scans adapter shell files for the red-flag SHAPES a contributed adapter
# must not have, and fails (non-zero) with the offending file:line so a reviewer — and
# CI — catches them before merge. It is a coarse, high-signal net, NOT a full analyzer:
# it errs toward flagging, and a clean adapter (local git + `gh` + config reads) passes.
#
# WHAT IT FLAGS (per SECURITY.md §5, "Adapter security review")
#   1. Raw network to a LITERAL host — curl/wget/nc/ncat/ssh/scp targeting an
#      http(s)://<literal-host>, a literal IP, or a literal user@host. `git`/`gh` are
#      ALLOWED (they legitimately reach a host), and a host that comes from config
#      (e.g. curl "$base_url/…") is ALLOWED — the point is: no vendor host baked into code.
#   2. `eval` of shell/tool input — eval (or a python `eval(`) is an arbitrary-code
#      surface an adapter never needs; any use is a finding.
#   3. Secret-exfiltration shapes —
#        a. a secret-looking value ($…TOKEN/SECRET/PASSWORD/…KEY/CREDENTIAL) handed to
#           `base64`, or piped into a network sink (curl/wget/nc/ncat);
#        b. reading a credential/key file (~/.ssh, id_rsa, .env, .aws/credentials,
#           .netrc, .git-credentials, credentials) on a line that also invokes such a sink.
#
# WHAT IT SCANS
#   Default: every *.sh under core/adapters/ (the reviewed adapter surface).
#   A path ARG overrides: a directory (its *.sh, recursively) or a single file (scanned
#   regardless of extension — so a seeded fixture can be checked directly).
#   Comments are stripped before matching (quote-aware), so prose that merely mentions a
#   red flag — including this header — does not trip the gate.
#
# Usage:  bash scripts/adapter-security-check.sh [PATH]
# Exit:   0 = clean · 1 = at least one finding · 2 = usage/environment error
#
# Stdlib only: bash + awk + coreutils (find/sort). No new runtime deps.
set -u

# ---- resolve target -----------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-$ROOT/core/adapters}"

case "$TARGET" in
  -h|--help) sed -n '2,45p' "$0"; exit 0;;
esac

declare -a FILES=()
if [ -f "$TARGET" ]; then
  FILES=("$TARGET")                       # an explicit single file: scan it as-is
elif [ -d "$TARGET" ]; then
  # a directory: every *.sh under it (adapters, including .stub.sh)
  while IFS= read -r f; do FILES+=("$f"); done < <(find "$TARGET" -type f -name '*.sh' | LC_ALL=C sort)
else
  echo "adapter-security-check: no such file or directory: $TARGET" >&2
  exit 2
fi

echo "adapter-security-check: scanning ${#FILES[@]} adapter file(s) under $TARGET"
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "ADAPTER-SECURITY PASS: no adapter shell files to scan."
  exit 0
fi

# ---- the scanner (awk: comment-strip + shape matching) ------------------------------
# The program carries NO literal single-quote (SQ/DQ are built with sprintf) so it lives
# safely inside these bash single quotes. Regexes avoid {m,n} intervals for portability
# across awk implementations, and use [.] / [$] rather than backslash escapes.
out="$(
awk '
BEGIN {
  SQ = sprintf("%c", 39); DQ = sprintf("%c", 34)   # single / double quote characters

  # command-word boundaries (matched against a lowercased code line)
  NET     = "(^|[^a-z0-9_])(curl|wget|nc|ncat|ssh|scp)([^a-z0-9_]|$)"   # raw-network tools
  NETSINK = "(^|[^a-z0-9_])(curl|wget|nc|ncat|base64)([^a-z0-9_]|$)"    # data-egress sinks
  BASE64  = "(^|[^a-z0-9_])base64([^a-z0-9_]|$)"
  EVAL    = "(^|[^a-z0-9_])eval([[:space:]]|[(])"                       # eval " / eval(

  # literal-host signatures on a network line
  HTTPLIT = "https?://[[:alnum:]]"                                     # scheme + literal host
  IPLIT   = "(^|[^0-9])[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+([^0-9]|$)"    # dotted quad
  ATDOM   = "@[[:alnum:]][[:alnum:].-]*[.][[:alnum:]]"                 # user@literal.host

  # a secret-looking variable expansion, e.g. $TOKEN ${API_SECRET} $db_password
  SECRET  = "[$][{]?[a-z_]*(secret|token|password|passwd|api[_]?key|access[_]?key|access[_]?token|auth[_]?token|private[_]?key|secret[_]?key|credential)"

  # a credential / key file being read
  CRED    = "([.]ssh/|id_rsa|id_dsa|id_ecdsa|id_ed25519|[.]aws/credentials|[.]git-credentials|[.]netrc|[.]env([^a-z0-9]|$)|(^|[^a-z0-9])[.]env|credentials([^a-z0-9]|$))"
}

# strip a trailing/whole-line shell comment, quote-aware: cut at the first # that is at
# column 1 or preceded by whitespace and is NOT inside a single/double-quoted string.
# This protects ${var##pat}, $#, "text#frag" and embedded awk/python heredocs.
function strip_comment(s,   i, n, c, prev, inq, q, out) {
  n = length(s); out = ""; inq = 0; q = ""; prev = " "
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (inq) { out = out c; if (c == q) { inq = 0; q = "" } prev = c; continue }
    if (c == SQ || c == DQ) { inq = 1; q = c; out = out c; prev = c; continue }
    if (c == "#" && (i == 1 || prev == " " || prev == "\t")) break
    out = out c; prev = c
  }
  return out
}

function report(rule, why,   snip) {
  snip = code
  sub(/^[[:space:]]+/, "", snip)
  if (length(snip) > 120) snip = substr(snip, 1, 117) "..."
  printf "FAIL %s:%d: [%s] %s\n        %s\n", FILENAME, FNR, rule, why, snip
  FOUND++
}

{
  code = strip_comment($0)
  if (code ~ /^[[:space:]]*$/) next
  lc = tolower(code)

  # 1) raw network to a literal host (git/gh not in NET; config-sourced hosts pass)
  if (lc ~ NET) {
    if      (lc ~ HTTPLIT) report("net-literal-host", "network to a literal http(s) host (use git/gh, or a config-sourced base_url)")
    else if (lc ~ IPLIT)   report("net-literal-ip",   "network to a literal IP address (hosts must come from PROJECT.yaml)")
    else if (lc ~ ATDOM)   report("net-literal-host", "network to a literal user@host (hosts must come from PROJECT.yaml)")
  }

  # 2) eval of shell/tool input
  if (lc ~ EVAL) report("eval", "eval of shell/tool input (arbitrary-code-execution surface)")

  # 3a) secret value -> base64, or piped to a network sink
  if (lc ~ SECRET) {
    if      (lc ~ BASE64)                 report("secret-exfil", "secret-looking value handed to base64 (exfil-prep shape)")
    else if (index(code, "|") && lc ~ NETSINK) report("secret-exfil", "secret-looking value on a line piped to a network sink")
  }

  # 3b) reading a credential/key file on a line that also egresses data
  if (lc ~ CRED && lc ~ NETSINK) report("cred-exfil", "reads a credential/key file on a line that also invokes a network sink")
}

END { exit (FOUND + 0 > 0) ? 1 : 0 }
' "${FILES[@]}"
)"
rc=$?

# ---- report -------------------------------------------------------------------------
[ -n "$out" ] && printf '%s\n' "$out"
echo "----------------------------------------------------------------------"
if [ "$rc" -eq 0 ]; then
  echo "ADAPTER-SECURITY PASS: 0 supply-chain red flags across ${#FILES[@]} adapter file(s)."
  exit 0
else
  n="$(printf '%s\n' "$out" | grep -c '^FAIL ')"
  echo "ADAPTER-SECURITY FAIL: $n finding(s). An adapter must not embed literal hosts, eval input, or egress secrets." >&2
  echo "Fix the adapter (read hosts from PROJECT.yaml; drop eval; keep secrets local) or drop it from the change." >&2
  exit 1
fi
