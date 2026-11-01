#!/usr/bin/env bash
# tests/gitea_adapter_test.sh — the gitea tracker is a WORKING pure-git tracker.
#
# Gitea is another host of git, so the fork_point / list_units / reference_diff logic is pure git on a
# Gitea checkout — the Gitea-REST PR-metadata/labels layer is a documented TODO(+), out of CI scope.
# This test proves the git-host model: it reuses examples/ts-app/setup-fixture.sh to build a throwaway
# repo whose tip is the unit of work, then drives core/adapters/tracker/gitea.sh both via the
# adapters.sh dispatch (tracker.adapter=gitea) and directly with PROJECT_YAML, and ASSERTS:
#
#   list_units      surfaces the feature commit (the unit)
#   fork_point      resolves to a full 40-char sha == the fixture's merge-base parent (pure-git)
#   reference_diff  is a non-empty unified diff of the human's shipped change (the refund feature)
#
# This mirrors the github_pr pure-git behaviour exercised by tests/e2e_ts_app_test.sh — the two
# adapters must agree on the git-host model. No `gh`, no Gitea instance, no network.
#
# Hermetic: the fixture + config live under one mktemp dir, cleaned up on exit. Needs git + python3 +
# PyYAML (the one allowed runtime dep — config reads only).
# Depends on: core/adapters/tracker/gitea.sh — authored against
# the contract.
#
# Run from the repo root:  bash tests/gitea_adapter_test.sh   (exit 0 = pass, non-zero = failure)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/core/lib"
EX="$ROOT/examples/ts-app"
GITEA="$ROOT/core/adapters/tracker/gitea.sh"

fail() { printf 'GITEA FAIL: %b\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
indent() { sed 's/^/  /'; }

# ---- required upstream artifacts --------------------
for f in "$LIB/adapters.sh" "$EX/setup-fixture.sh" "$EX/PROJECT.yaml" "$ROOT/core/adapters/vcs/git.sh"; do
  [ -e "$f" ] || fail "missing dependency: $f"
done
if [ ! -f "$GITEA" ]; then
  [ -f "$ROOT/core/adapters/tracker/gitea.stub.sh" ] \
    && fail "core/adapters/tracker/gitea.sh not present — only the stub exists"
  fail "missing core/adapters/tracker/gitea.sh"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mahoraga-gitea.XXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
FIXPARENT="$TMP/fixture"; LOGS="$TMP/logs"; mkdir -p "$FIXPARENT" "$LOGS"

step "1. setup-fixture.sh — a throwaway git repo whose tip is the unit (git only; no gh/network)"
FIX_OUT="$(bash "$EX/setup-fixture.sh" "$FIXPARENT" 2>"$LOGS/setup.err")" \
  || { cat "$LOGS/setup.err" >&2; fail "setup-fixture.sh exited non-zero"; }
printf '%s\n' "$FIX_OUT" | indent
kv() { printf '%s\n' "$FIX_OUT" | sed -n "s/^$1=//p" | head -1; }
FROOT="$(kv root)"; FREPO="$(kv repo)"; UNIT="$(kv unit)"; FORK_EXPECTED="$(kv fork)"
[ -n "$FROOT" ] && [ -d "$FROOT" ]      || fail "setup-fixture printed no usable root= ($FROOT)"
[ -n "$FREPO" ] && [ -d "$FREPO/.git" ] || fail "setup-fixture printed no git repo= ($FREPO)"
printf '%s' "$UNIT" | grep -qE '^[0-9a-f]{7,40}$' || fail "setup-fixture printed no unit sha ($UNIT)"

step "2. synthesize a hermetic PROJECT.yaml with tracker.adapter=gitea (pure-git; no literal host)"
CFG="$TMP/PROJECT.yaml"
FROOT="$FROOT" EXAMPLE="$EX/PROJECT.yaml" SB="$TMP/sandboxes" python3 - "$CFG" <<'PY'
import os, sys, yaml
out = sys.argv[1]
d = yaml.safe_load(open(os.environ["EXAMPLE"])) or {}
d.setdefault("project", {})["root"] = os.environ["FROOT"]
tr = d.setdefault("tracker", {})
tr["adapter"] = "gitea"                 # dispatch to core/adapters/tracker/gitea.sh
cfg = tr.setdefault("config", {})
cfg["repo"] = ""                        # EMPTY => the pure-git path (no Gitea REST; no base_url needed)
cfg["base_branch"] = "main"
cfg["merge_strategy"] = "squash"        # pure-git: last N non-merge first-parent commits
cfg.setdefault("labels_exclude", [])
d.setdefault("output", {})["sandbox_root"] = os.environ["SB"]
yaml.safe_dump(d, open(out, "w"), sort_keys=False)
PY
[ -f "$CFG" ] || fail "could not synthesize the runtime PROJECT.yaml"
grep -q 'adapter: gitea' "$CFG" || fail "synthesized config did not select tracker.adapter=gitea"
export PROJECT_CONFIG="$CFG"
export MAHORAGA_REPO_DIR="$FREPO"   # the pure-git tracker honours this directly (repo: "" => pure-git)
export MAHORAGA_NO_GH=1             # belt-and-suspenders: never touch any host CLI for this fixture

step "3. via adapters.sh dispatch — tracker_fn list_units (gitea)"
# shellcheck source=/dev/null
source "$LIB/adapters.sh" || fail "could not source adapters.sh"
declare -F tracker_fn >/dev/null 2>&1 || fail "adapters.sh defined no tracker_fn"
LU="$(tracker_fn list_units 2>"$LOGS/list_units.err")" || { cat "$LOGS/list_units.err" >&2; fail "tracker_fn list_units failed (is gitea.sh a working pure-git tracker?)"; }
printf '%s\n' "$LU" | indent
printf '%s\n' "$LU" | grep -qF "$UNIT" || fail "gitea list_units did not surface the unit $UNIT"

step "4. via adapters.sh dispatch — tracker_fn fork_point (merge-base parent, pure-git)"
FORK_GOT="$(tracker_fn fork_point "$UNIT" 2>"$LOGS/fork.err")" || { cat "$LOGS/fork.err" >&2; fail "tracker_fn fork_point failed"; }
printf '%s' "$FORK_GOT" | grep -qE '^[0-9a-f]{40}$' || fail "fork_point is not a full sha: $FORK_GOT"
echo "  fork_point($UNIT) = $FORK_GOT"
case "$FORK_GOT" in "$FORK_EXPECTED"*) : ;; *) fail "fork_point ($FORK_GOT) != fixture-reported fork ($FORK_EXPECTED)";; esac

step "5. via adapters.sh dispatch — tracker_fn reference_diff (the human's shipped change)"
RD="$(tracker_fn reference_diff "$UNIT" 2>"$LOGS/refdiff.err")" || { cat "$LOGS/refdiff.err" >&2; fail "tracker_fn reference_diff failed"; }
[ -n "$RD" ] || fail "reference_diff produced an empty diff"
printf '%s' "$RD" | grep -qE 'refund\.ts' || fail "reference_diff does not mention the unit's file (refund.ts)"
printf '%s' "$RD" | grep -qE '^\+.*computeProratedRefund' || fail "reference_diff does not add the shipped symbol"
echo "  reference_diff: $(printf '%s\n' "$RD" | grep -c '^[+-]') +/- lines; touches refund.ts"

step "6. direct invocation (PROJECT_YAML=…  gitea.sh <fn>) — mirrors the standalone adapter contract"
D_LU="$(PROJECT_YAML="$CFG" bash "$GITEA" list_units 2>"$LOGS/direct_lu.err")" || { cat "$LOGS/direct_lu.err" >&2; fail "direct gitea.sh list_units failed"; }
printf '%s\n' "$D_LU" | grep -qF "$UNIT" || fail "direct gitea.sh list_units did not surface the unit"
D_FORK="$(PROJECT_YAML="$CFG" bash "$GITEA" fork_point "$UNIT" 2>"$LOGS/direct_fork.err")" || { cat "$LOGS/direct_fork.err" >&2; fail "direct gitea.sh fork_point failed"; }
[ "$D_FORK" = "$FORK_GOT" ] || fail "direct gitea.sh fork_point ($D_FORK) != dispatch fork_point ($FORK_GOT)"
echo "  direct invocation agrees with the dispatch"

printf '\nGITEA PASS\n'
echo "  unit=$UNIT"
echo "  fork_point=$FORK_GOT (== fixture fork $FORK_EXPECTED)"
echo "  gitea.sh drives the git-host model as a working pure-git tracker"
