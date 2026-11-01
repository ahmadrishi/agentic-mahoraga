#!/usr/bin/env bash
# tests/quickstart_test.sh — the the "clone-and-go" quickstart, proven mechanically.
#
# A stranger clones the repo, follows the README, and gets: a drafted PROJECT.yaml + CLAUDE.md, a
# forged <project>-mapping skill + the universal GUARD pack, and a first ABLATED, cutoff-labelled eval
# report. This test walks that exact mechanical quickstart (no LLM session needed) on a THROWAWAY COPY
# of the repo, so the live checkout is never touched:
#
#   COPY               cp -r the repo to a scratch temp dir (via tar; .git / build cruft excluded)
#   (1) init           bash cli/mahoraga init  ->  assert PROJECT.yaml + CLAUDE.md drafted
#   (2) forge mapping  python3 core/lib/mapping_scan.py <copy>/core/lib --lang python  (the deterministic
#                      grounding step under /mahoraga-adapt)  ->  scaffold <project>-mapping (SKILL.md
#                      kind:mapping + references/subsystem-map.md)  ->  node scripts/conformance-lint.mjs PASS
#   (3) GUARD present  assert the universal GUARD pack ships (skills/guard/**/SKILL.md)
#   (4) two-arm prove  run the CANONICAL mechanical two-arm prove against the copy — the 
#                      test tests/prove_ablation_test.sh — which stubs the implementers, writes
#                      score.json / score.baseline.json (each carrying a cutoff_label from
#                      core/lib/cutoff_label.py + a decontam_confidence), aggregates, builds the report,
#                      and ASSERTS an ablated report (ablation_delta>0, both arms, a per-unit
#                      cutoff_label chip + a decontam_confidence chip). Reused rather than duplicated
#                      (this repo ships a reuse-before-create guard): it is the single source of truth
#                      for the mechanical prove, so the quickstart cannot drift from the gate.
#
# The mechanical demo path here MUST agree with README §Quickstart. The REAL adaptive path is the
# agentic /mahoraga-adapt + /mahoraga-prove; the scan + the stub prove are the deterministic steps under
# them, exercised so a stranger can see the loop close without a full model session.
#
# Hermetic: everything lives under one mktemp dir (the delegated prove makes its own, self-cleaned),
# removed on exit; the live repo is asserted untouched. Needs git + python3 + PyYAML + node (all present
# in CI's tests job; node is pre-installed on ubuntu-latest). No network.
#
# Depends on:
#   * cli/mahoraga, core/lib/{mapping_scan.py, gen_claude_md.py, cutoff_label.py, aggregate_scores.py,
#     build_report.py, adapters.sh, prepare_task.sh, stage_sandbox.sh}
#   * scripts/conformance-lint.mjs
#   * examples/py-service/** + skills/guard/**
#
# Run from anywhere:  bash tests/quickstart_test.sh   (exit 0 = pass, non-zero = failure)
set -u

LIVE="$(cd "$(dirname "$0")/.." && pwd)"          # the live checkout — MUST stay untouched
PY="${PYTHON:-python3}"
NODE="${NODE:-node}"

fail() { printf 'QUICKSTART FAIL: %b\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
indent() { sed 's/^/  /'; }

# ---- preflight: toolchain + the upstream artifacts the quickstart drives -------------------------
command -v git      >/dev/null 2>&1 || fail "git not found (the mechanical prove builds a git fixture)"
command -v "$PY"    >/dev/null 2>&1 || fail "python3 not found (init, forge, and prove all need it)"
command -v "$NODE"  >/dev/null 2>&1 || fail "node not found (scripts/conformance-lint.mjs needs it)"
command -v tar      >/dev/null 2>&1 || fail "tar not found (used to copy the repo)"
"$PY" -c 'import yaml' 2>/dev/null  || fail "PyYAML not importable — the one allowed core dep (pip install pyyaml)"

for f in "cli/mahoraga" "core/lib/mapping_scan.py" "core/lib/gen_claude_md.py" \
         "scripts/conformance-lint.mjs" "tests/prove_ablation_test.sh" \
         "examples/py-service/setup-fixture.sh" "branding.yaml"; do
  [ -e "$LIVE/$f" ] || fail "missing dependency: $f"
done
[ -d "$LIVE/skills/guard" ] || fail "missing dependency: skills/guard (the universal GUARD pack)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mahoraga-quickstart.XXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# ---- COPY: a throwaway clone-shaped tree (fixed basename so project.id is deterministic) ----------
# Named 'agentic-mahoraga' so `mahoraga init` derives project.id == "agentic-mahoraga" from the dir
# basename (matching a real clone). .git and build cruft are excluded — a stranger's clone works the
# same, and the copy stays small. tar-through-tar leaves the source read-only (live repo untouched).
step "0. cp -r the repo to a scratch temp dir (live checkout untouched)"
COPY="$TMP/agentic-mahoraga"
mkdir -p "$COPY"
( cd "$LIVE" && tar -cf - \
    --exclude=.git --exclude=node_modules --exclude=__pycache__ \
    --exclude='*.pyc' --exclude=eval-run --exclude='*.egg-info' . ) \
  | ( cd "$COPY" && tar -xf - ) \
  || fail "could not copy the repo into the scratch dir"
[ -f "$COPY/branding.yaml" ] && [ -x "$COPY/cli/mahoraga" ] \
  || fail "the repo copy is incomplete (branding.yaml / executable cli/mahoraga missing)"
echo "  copied -> $COPY"

# ---- (1) init: draft PROJECT.yaml + CLAUDE.md -----------------------------------------------------
step "1. bash cli/mahoraga init — draft PROJECT.yaml + CLAUDE.md (the one setup gate)"
INIT_OUT="$(cd "$COPY" && bash "$COPY/cli/mahoraga" init 2>&1)"; INIT_RC=$?
printf '%s\n' "$INIT_OUT" | indent
[ "$INIT_RC" -eq 0 ]          || fail "mahoraga init exited $INIT_RC"
[ -s "$COPY/PROJECT.yaml" ]   || fail "init produced no PROJECT.yaml"
[ -s "$COPY/CLAUDE.md" ]      || fail "init produced no CLAUDE.md (needs python3 + PyYAML)"
[ "$(wc -l < "$COPY/CLAUDE.md")" -lt 200 ] || fail "CLAUDE.md exceeded the <200-line budget"
grep -q '^project:' "$COPY/PROJECT.yaml" || fail "PROJECT.yaml has no 'project:' block"
# the live checkout must not have gained these files — the quickstart operated only on the copy
[ "$COPY/PROJECT.yaml" != "$LIVE/PROJECT.yaml" ] || fail "internal: copy path collided with live"
{ [ ! -e "$LIVE/PROJECT.yaml" ] && [ ! -e "$LIVE/CLAUDE.md" ]; } \
  || fail "the live checkout gained a PROJECT.yaml/CLAUDE.md — the run was NOT hermetic"
echo "  drafted PROJECT.yaml + CLAUDE.md in the copy; live checkout untouched"

# read the project.id init drafted; the forge names the mapping skill after it (init -> forge continuity)
PROJ_ID="$(CFG="$COPY/PROJECT.yaml" "$PY" -c \
  'import os,yaml;print((yaml.safe_load(open(os.environ["CFG"])) or {}).get("project",{}).get("id","") or "")')"
[ -n "$PROJ_ID" ] || fail "could not read project.id from the drafted PROJECT.yaml"
printf '%s' "$PROJ_ID" | grep -Eq '^[a-z0-9-]+$' \
  || fail "project.id '$PROJ_ID' is not a valid skill-name stem (^[a-z0-9-]+\$)"
echo "  project.id = $PROJ_ID  ->  mapping skill will be '$PROJ_ID-mapping'"

# ---- (2) forge the mapping skill deterministically ------------------------------------------------
step "2. forge mapping — mapping_scan.py -> scaffold '$PROJ_ID-mapping' -> conformance-lint PASS"
MAP_SKILL="$COPY/.claude/skills/$PROJ_ID-mapping"
mkdir -p "$MAP_SKILL/references"
MAP="$MAP_SKILL/references/subsystem-map.md"
# scan the copy's engine (all Python) — the deterministic file:line grounding step under ADAPT
"$PY" "$COPY/core/lib/mapping_scan.py" "$COPY/core/lib" --lang python --format md --title "$PROJ_ID" \
  > "$MAP" 2>"$TMP/scan.err"; SCAN_RC=$?
[ "$SCAN_RC" -eq 0 ] || { sed 's/^/  scan-stderr: /' "$TMP/scan.err" >&2; fail "mapping_scan.py exited $SCAN_RC"; }
[ -s "$MAP" ]        || fail "mapping_scan.py produced an empty subsystem-map.md"

# count data rows in the grounded names table (>=3 = a real map, not a stub)
ROWS="$(awk -F'|' '
  function trim(x){ sub(/^[ \t]+/,"",x); sub(/[ \t]+$/,"",x); return x }
  NF>=4 && $0 ~ /^[ \t]*\|/ && $0 !~ /^[ \t]*\|[ \t:|-]*$/ {
    n=trim($2); if (n!="name" && n!="") c++
  } END { print c+0 }' "$MAP")"
[ "$ROWS" -ge 3 ] || fail "scan produced only $ROWS grounded row(s); a real map needs >=3"
echo "  scanned $COPY/core/lib -> $ROWS grounded name(s) with file:line evidence"

# scaffold the SKILL.md (kind:mapping, grounding:file-line) — the container conformance-lint validates
cat > "$MAP_SKILL/SKILL.md" <<MD
---
name: $PROJ_ID-mapping
description: Maps $PROJ_ID's core vocabulary (functions, constants, classes, enums) to file:line evidence produced by a deterministic scan, so downstream work grounds on real definitions instead of guessed names. Regenerate with the provenance command. Do NOT use for spec authoring (that is the spec-style-forge).
allowed-tools: [Read, Grep]
mahoraga:
  kind: mapping
  grounding: file-line
  provenance: python3 core/lib/mapping_scan.py . --lang python
---

# $PROJ_ID — subsystem map

Grounded vocabulary for this project. Every name below carries \`file:line\` evidence produced by a
deterministic scan; never trust a name here that lost its evidence.

Regenerate: \`python3 core/lib/mapping_scan.py . --lang python\`

## Names

The full grounded names table lives in
[references/subsystem-map.md](references/subsystem-map.md).
MD
[ -s "$MAP_SKILL/SKILL.md" ] || fail "could not scaffold the mapping SKILL.md"

LINT_OUT="$("$NODE" "$COPY/scripts/conformance-lint.mjs" "$MAP_SKILL" --repo "$COPY/core/lib" 2>&1)"; LINT_RC=$?
printf '%s\n' "$LINT_OUT" | sed 's/^/  lint: /'
[ "$LINT_RC" -eq 0 ] || fail "conformance-lint exited $LINT_RC on the forged mapping skill (expected 0)"
printf '%s\n' "$LINT_OUT" | grep -q 'CONFORMANCE PASS' \
  || fail "conformance-lint exited 0 but printed no 'CONFORMANCE PASS' line"
echo "  forged '$PROJ_ID-mapping' passes conformance-lint (mapping-kind branch)"

# ---- (3) the universal GUARD pack ships -----------------------------------------------------------
step "3. GUARD pack present — the universal, stack-agnostic behavioral skills (skills/guard)"
GUARD_N="$(find "$COPY/skills/guard" -name SKILL.md 2>/dev/null | grep -c .)"
[ "$GUARD_N" -ge 1 ] || fail "skills/guard has no SKILL.md — the universal GUARD pack is missing"
echo "  skills/guard ships $GUARD_N behavioral skill(s) (installs unchanged, day one)"

# ---- (4) the first ablated, cutoff-labelled eval report -------------------------------------------
# Delegate to the canonical mechanical two-arm prove run against the COPY. It stages two
# history-free sandboxes at the same fork-point (harness=full skills / baseline=empty), stubs the
# implementers, writes score.json + score.baseline.json (each with a cutoff_label from cutoff_label.py
# and a decontam_confidence), aggregates + builds the report, and ASSERTS: ablation_delta.business_req_avg
# > 0, both arms present, and the report carries the Ablation panel + per-unit cutoff_label chip +
# decontam_confidence chip. Running it here proves the whole loop closes from a fresh clone.
step "4. two-arm prove -> ablated, cutoff-labelled report (delegated to the mechanical prove)"
PROVE_OUT="$(bash "$COPY/tests/prove_ablation_test.sh" 2>&1)"; PROVE_RC=$?
printf '%s\n' "$PROVE_OUT" | indent
[ "$PROVE_RC" -eq 0 ] || fail "the mechanical two-arm prove exited $PROVE_RC (see output above)"
printf '%s\n' "$PROVE_OUT" | grep -q 'PROVE-ABLATION PASS' \
  || fail "the two-arm prove did not report PROVE-ABLATION PASS"
# corroborate the ablated-report facts the names, from the delegated run's own log
printf '%s\n' "$PROVE_OUT" | grep -qi 'ablation_delta' \
  || fail "the prove log shows no ablation_delta (the harness-vs-baseline contrast)"
printf '%s\n' "$PROVE_OUT" | grep -q 'cutoff-clean' \
  || fail "the prove log shows no per-unit cutoff_label (cutoff-clean for the private py-service)"
printf '%s\n' "$PROVE_OUT" | grep -q 'decontam_confidence' \
  || fail "the prove log shows no decontam_confidence chip"
echo "  ablated report produced: ablation_delta>0, per-unit cutoff_label + decontam_confidence present"

printf '\nQUICKSTART PASS\n'
echo "  clone -> init (PROJECT.yaml + CLAUDE.md) -> forge $PROJ_ID-mapping -> GUARD pack -> ablated report"
echo "  copy=$COPY"
