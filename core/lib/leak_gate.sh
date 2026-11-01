#!/usr/bin/env bash
# leak_gate.sh <SLUG> <UNIT_KEY> [RUN_DIR]
# Decontamination gate. The sandbox's skills must NOT contain the unit's answer.
# Two token sources:
#   1. curated decontamination.answer_tokens[<key>] from config — exact, no false positives.
#   2. distinctive identifiers AUTO-DERIVED from the unit's human diff, when RUN_DIR is given —
#      catches an answer leaked in PROSE via a symbol nobody tokenised (the improve→retest hole:
#      a skill written from the findings can name the fix's symbols without any configured token
#      matching). This is what makes the gate track the real answer, not a manual guess.
# Greps $SANDBOX_ROOT/<slug>/.claude/skills. Exit 0 iff ZERO matches; else exit 2.
# NOTE: uses process substitution (not pipes) so the hit counter survives in this shell.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
SLUG="$1"; KEY="$2"; RUN_DIR="${3:-}"
SKILLS="$SANDBOX_ROOT/$SLUG/.claude/skills"
[ -d "$SKILLS" ] || { echo "leak_gate: no skills dir at $SKILLS" >&2; exit 3; }

hits=0; ntok=0
grep_tokens() {   # <label> ; reads candidate tokens on stdin; runs in THIS shell (no subshell)
  local label="$1" tok f
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    ntok=$((ntok+1))
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      echo "LEAK[$label] $tok: $f"
      hits=$((hits+1))
    done < <(grep -rilF "$tok" "$SKILLS" 2>/dev/null)
  done
}

auto_tokens() {   # answer-SPECIFIC identifiers the human NEWLY introduced (absent from fork-point code)
  [ -z "$RUN_DIR" ] && return 0
  local dir="$RUN_DIR/$KEY"
  [ -d "$dir" ] || return 0
  # candidate = distinctive added identifier from the human diff, but ONLY if it does NOT already
  # exist in the sandbox's fork-point code. A symbol present at fork is pre-existing vocabulary the
  # human merely referenced (getMessage, toUpperCase, findById…) — NOT a leak signal. A symbol
  # absent at fork was introduced as part of the answer, so a skill naming it leaked the answer.

  # The distinctive-identifier net is LANGUAGE-AWARE. Each human_<repo>.diff is filtered with
  # THAT repo's repos[].language, using the shared lang_profiles.distinctive() heuristic (the SINGLE
  # source of truth, shared with the diff-exclude set) — so snake_case (python/ruby/rust, e.g. compute_prorated_refund),
  # MixedCaps (go/c#) and CONSTANT_CASE answers are caught too, not just Java/JS/TS lowerCamelCase.
  # The rest of the pipeline is UNCHANGED: candidates are still subtracted against every symbol present
  # at the fork-point tree, and the caller keeps the fail-closed / NOTHING-CHECKED honesty behavior.
  # Map each diff filename human_<repo>.diff back to <repo> here and pass a repo=language table in.
  local langmap _f _base _repo _lang
  langmap="$(mktemp)"
  for _f in "$dir"/human_*.diff; do
    [ -e "$_f" ] || continue
    _base="$(basename "$_f")"; _base="${_base#human_}"; _repo="${_base%.diff}"
    _lang="$(repo_field "$_repo" language)"
    printf '%s\t%s\n' "$_repo" "$_lang" >> "$langmap"
  done
  python3 - "$dir" "$SANDBOX_ROOT/$SLUG" "$HERE" "$langmap" <<'PY'
import sys, glob, re, os, subprocess, tempfile
diffdir, sbroot, libdir, langmapf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, libdir)
import lang_profiles   # SINGLE source of the per-language distinctive() heuristic — never inline it

# repo -> language, one "repo<TAB>lang" per line (lang may be empty -> lang_profiles falls back to camel)
lang_by_repo = {}
try:
    for line in open(langmapf, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        lang_by_repo[parts[0]] = parts[1] if len(parts) > 1 else ""
except Exception:
    pass

def repo_of(path):
    b = os.path.basename(path)
    if b.startswith("human_") and b.endswith(".diff"):
        return b[len("human_"):-len(".diff")]
    return ""

cands = set()
for f in glob.glob(os.path.join(diffdir, "human_*.diff")):
    lang = lang_by_repo.get(repo_of(f), "")   # per-repo language drives the distinctive() heuristic
    try: fh = open(f, encoding="utf-8", errors="replace")
    except Exception: continue
    for ln in fh:
        if ln.startswith('+') and not ln.startswith('+++'):
            for m in re.findall(r'[A-Za-z_][A-Za-z0-9_]{3,}', ln):
                if lang_profiles.distinctive(lang, m):
                    cands.add(m)
if not cands:
    sys.exit(0)
# fork-point subtraction (UNCHANGED): one grep pass per repo tree collects which candidates ALREADY
# exist at the fork-point tree staged in the sandbox; those are pre-existing vocabulary, not a leak.
repos = [d for d in (os.path.join(sbroot, x) for x in os.listdir(sbroot))
         if os.path.isdir(d) and os.path.basename(d) != ".claude"]
present = set()
with tempfile.NamedTemporaryFile("w", delete=False, suffix=".pat") as tf:
    tf.write("\n".join(sorted(cands)))
    patf = tf.name
try:
    for r in repos:
        out = subprocess.run(["grep", "-rhoFf", patf, r], capture_output=True, text=True).stdout
        for line in out.splitlines():
            present.add(line.strip())
finally:
    os.unlink(patf)
for m in sorted(cands - present):   # newly-introduced only = answer-specific
    print(m)
PY
  rm -f "$langmap"
}

grep_tokens configured    < <(cfg_tokens "$KEY")
grep_tokens auto-derived  < <(auto_tokens)

if [ "$hits" -eq 0 ]; then
  if [ "$ntok" -eq 0 ]; then
    # honesty: "0 hits" here means "checked nothing", not "verified clean" — surface it distinctly.
    echo "LEAK-GATE PASS ($KEY): WARN — NOTHING CHECKED (no configured answer_tokens and no distinctive symbols derivable from the human diff). For a retest, add answer_tokens for this unit."
  else
    echo "LEAK-GATE PASS ($KEY): 0 hits across $ntok answer token(s) in sandbox skills"
  fi
  exit 0
else
  echo "LEAK-GATE FAIL ($KEY): $hits hit(s) across $ntok answer token(s) in sandbox skills" >&2
  exit 2
fi
