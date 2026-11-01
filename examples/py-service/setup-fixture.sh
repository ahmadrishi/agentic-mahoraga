#!/usr/bin/env bash
# examples/py-service/setup-fixture.sh
#
# Build a throwaway git repo the `github-pr` tracker adapter (pure-git fallback) can drive end-to-end:
# a BASE commit (the "before" tree) plus ONE feature commit — the unit of work. The feature adds a
# small, self-contained function (`compute_prorated_refund`) so the adapter discovers the last
# non-merge commit as the unit and `fork_point` = its parent.
#
# Dependency-free: git + coreutils only. No `gh`, no `pip`, no network. Mirrors the shape of
# examples/ts-app/setup-fixture.sh (read that for the reference).
#
# Usage:  setup-fixture.sh [PARENT_DIR]
#   PARENT_DIR  optional. The fixture repo is created at PARENT_DIR/py-service; PARENT_DIR is the value
#               to use as PROJECT.yaml `project.root`. If omitted, a fresh mktemp dir is used.
#
# Prints machine-readable `key=value` lines to STDOUT (human diagnostics go to STDERR):
#   root=<parent>                    == PROJECT.yaml project.root for the run
#   repo=<parent>/py-service         the git checkout == MAHORAGA_REPO_DIR for the github-pr adapter
#   skills=<parent>/.claude/skills   the staged skills library (for stage_sandbox.sh)
#   unit=<sha>                       the feature commit — the unit of work
#   fork=<sha>                       its parent — the fork-point the sandbox is staged at
#   base_branch=main
set -eu

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

PARENT="${1:-}"
if [ -z "$PARENT" ]; then
  PARENT="$(mktemp -d "${TMPDIR:-/tmp}/py-service-fixture.XXXXXX")"
else
  mkdir -p "$PARENT"
  PARENT="$(cd "$PARENT" && pwd)"
fi
REPO="$PARENT/py-service"
rm -rf "$REPO"
mkdir -p "$REPO/src"

# --- base tree: the committed app files (NOT the fixture script or PROJECT.yaml) ------------------
cp "$SRC/SPEC.md" "$SRC/BUSINESS_REQUIREMENT.md" "$REPO/"
cp "$SRC/src/__init__.py" "$SRC/src/ledger.py" "$REPO/src/"

# --- stage the project's skills library next to the checkout (a complete project.root) ------------
if [ -d "$SRC/.claude/skills" ]; then
  mkdir -p "$PARENT/.claude"
  rm -rf "$PARENT/.claude/skills"
  cp -R "$SRC/.claude/skills" "$PARENT/.claude/skills"
fi

# --- init git (portable: no `git init -b`, which needs git >= 2.28) -------------------------------
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main        # force the initial branch to main, any git
git -C "$REPO" config user.email "fixture@example.invalid"
git -C "$REPO" config user.name  "Mahoraga Fixture"
git -C "$REPO" config commit.gpgsign false

# --- base commit ----------------------------------------------------------------------------------
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "Base: money model, ledger, and package surface"
FORK="$(git -C "$REPO" rev-parse HEAD)"

# --- ONE feature commit = the unit of work --------------------------------------------------------
cat > "$REPO/src/refund.py" <<'PY'
# refund.py — the unit under test: prorate a refund over the unused part of a term.
"""Prorated-refund calculation for the billing service."""

from __future__ import annotations

from .ledger import Money


def compute_prorated_refund(paid: Money, total_days: int, used_days: int) -> Money:
    """Return the refundable amount for the unused portion of a paid term.

    The refund is the paid amount scaled by the fraction of the term left
    unused, in the same currency as the payment. A term with ``total_days <= 0``
    or a fully-used (or over-used) term refunds zero — never negative — and the
    result is rounded to whole cents.
    """
    if total_days <= 0:
        return Money(amount_cents=0, currency=paid.currency)
    remaining = max(0, total_days - used_days)
    refund_cents = round(paid.amount_cents * remaining / total_days)
    return Money(amount_cents=refund_cents, currency=paid.currency)
PY
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "Add prorated refund calculation"
UNIT="$(git -C "$REPO" rev-parse HEAD)"

# --- human diagnostics (stderr) -------------------------------------------------------------------
{
  echo "py-service fixture ready:"
  echo "  parent (project.root) : $PARENT"
  echo "  repo   (checkout)     : $REPO"
  echo "  unit   (feature sha)  : $UNIT"
  echo "  fork   (parent sha)   : $FORK"
} >&2

# --- machine-readable report (stdout) -------------------------------------------------------------
echo "root=$PARENT"
echo "repo=$REPO"
echo "skills=$PARENT/.claude/skills"
echo "unit=$UNIT"
echo "fork=$FORK"
echo "base_branch=main"
