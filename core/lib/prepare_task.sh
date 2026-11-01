#!/usr/bin/env bash
# prepare_task.sh <RUN_DIR> <UNIT_KEY>
# Produce the reviewer-only artifacts for one unit: the fork-point, the CLEAN human reference diff
# (the unit's own change), the changed-file list, and the meta.lines the stager/extractor consume.
# Writes under $RUN_DIR/<KEY>/. Blind implementers never see these.
#
# DISPATCH (adapter boundary): the unit's fork-point / changed files / reference diff come from the
# TRACKER ADAPTER named in PROJECT.yaml (tracker.adapter), via the dispatch shim in adapters.sh:
#   github-pr | file | none  -> tracker_fn fork_point|change_files|reference_diff|metadata <unit>
# except for jira: core/adapters/tracker/jira.sh exists but is not yet called here — tracker.adapter=jira
# still runs the old inline branch/commit-grep resolution PRESERVED below.
# TODO: route jira through the shim (core/adapters/tracker/jira.sh) and delete the inline fallback;
# the core will then dispatch every tracker uniformly.
#
# Artifacts written per repo (unchanged names/shape so stage_sandbox.sh + extract_ai_diff.sh + the
# leak gate keep working): human_<repo>.diff, human_<repo>_files.txt, and a meta.lines row
#   <repo>|fork=<sha>|endpoint=<sha>|files=N|commits=N|method=<method>|stat=<shortstat>
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/adapters.sh"   # tracker_fn / spec_fn / verify_fn / vcs_fn (re-source of lib.sh is guarded)

RUN_DIR="$1"; KEY="$2"
OUT="$RUN_DIR/$KEY"; mkdir -p "$OUT"
SUMMARY="$OUT/prepare_summary.txt"; : > "$SUMMARY"
: > "$OUT/meta.lines"

ADAPTER="$(cfg_get tracker.adapter)"

# ----------------------------------------------------------------------------------------------------
# ADAPTER-DRIVEN PATH — github-pr | file | none (and, fail-closed, anything not jira: the shim errors
# clearly on an unimplemented/missing adapter, so the run aborts rather than proceeding under-resolved).
# ----------------------------------------------------------------------------------------------------
prepare_via_adapter() {
  # The <repo> for an adapter-driven unit is the adapter's repo: tracker.config.repo basename, else
  # the first configured repo. Single-repo is sufficient here.
  local cfgrepo repo R fork tip endpoint title meta nfiles ins del statA total method
  cfgrepo="$(cfg_get tracker.config.repo)"
  repo="${cfgrepo##*/}"
  [ -n "$repo" ] || repo="$(repos_names | head -1)"
  [ -n "$repo" ] || { echo "prepare_task: cannot determine repo (set tracker.config.repo or repos[]) — nothing prepared" | tee -a "$SUMMARY"; return 0; }

  # repo dir: mirror the adapters' resolution (MAHORAGA_REPO_DIR override -> project.root/<repo>) so
  # our commit-count / sha normalization agrees with what the adapter used.
  if [ -n "${MAHORAGA_REPO_DIR:-}" ]; then R="$MAHORAGA_REPO_DIR"; else R="$PROJECT_ROOT/$repo"; fi

  # 1) fork-point (the contract call). Empty / failure => log and leave meta.lines empty (fail-closed:
  #    stage_sandbox.sh aborts on a missing meta.lines row).
  fork="$(tracker_fn fork_point "$KEY")" || { echo "$repo: tracker fork_point failed for '$KEY' (adapter=$ADAPTER)" | tee -a "$SUMMARY"; return 0; }
  [ -n "$fork" ] || { echo "$repo: tracker returned an empty fork_point for '$KEY' (adapter=$ADAPTER)" | tee -a "$SUMMARY"; return 0; }

  # endpoint (tip) + title from adapter metadata (the tracker exposes the human endpoint here)
  meta="$(tracker_fn metadata "$KEY" 2>/dev/null || true)"
  tip="$(printf '%s\n' "$meta" | sed -n 's/^tip=//p' | head -1)"
  title="$(printf '%s\n' "$meta" | sed -n 's/^title=//p' | head -1)"

  # normalize fork/tip to full shas when the checkout is local git, so meta.lines carries hex the
  # stager's `|fork=\([0-9a-f]*\)|` extraction (and extract_ai_diff.sh's) can read.
  if [ -d "$R/.git" ]; then
    fork="$(git -C "$R" rev-parse "$fork" 2>/dev/null || printf '%s' "$fork")"
    [ -n "$tip" ] && tip="$(git -C "$R" rev-parse "$tip" 2>/dev/null || printf '%s' "$tip")"
  fi
  endpoint="${tip:-$fork}"   # keep the meta row well-formed even if the adapter exposes no endpoint

  # 2) reference diff + changed files (the human's shipped change — a REFERENCE, never a match target)
  tracker_fn reference_diff "$KEY" > "$OUT/human_${repo}.diff"       2>/dev/null || true
  tracker_fn change_files   "$KEY" > "$OUT/human_${repo}_files.txt"  2>/dev/null || true
  nfiles=$(grep -c . "$OUT/human_${repo}_files.txt" 2>/dev/null); nfiles=${nfiles:-0}

  # shortstat computed FROM the produced diff (adapter-agnostic; no re-run of git needed). Added lines
  # start with '+' but not the '+++' file header; removed with '-' but not '---'.
  # NB: `grep -c` already PRINTS "0" on no-match (and exits 1); a `|| echo 0` would double-emit "0\n0"
  # and blow up the $(( )) below on an empty diff — so capture the count and default with ${x:-0} only
  # for the file-absent case (empty stdout), never `|| echo`.
  addl=$(grep -c '^+' "$OUT/human_${repo}.diff" 2>/dev/null); addl=${addl:-0}
  hdrp=$(grep -c '^+++' "$OUT/human_${repo}.diff" 2>/dev/null); hdrp=${hdrp:-0}
  reml=$(grep -c '^-' "$OUT/human_${repo}.diff" 2>/dev/null); reml=${reml:-0}
  hdrm=$(grep -c '^---' "$OUT/human_${repo}.diff" 2>/dev/null); hdrm=${hdrm:-0}
  ins=$(( addl - hdrp )); del=$(( reml - hdrm ))
  [ "$ins" -lt 0 ] && ins=0; [ "$del" -lt 0 ] && del=0
  statA="$nfiles files changed, $ins insertions(+), $del deletions(-)"

  # commit count in fork..endpoint — for the over-capture warning and meta (when the checkout is local
  # git and the adapter exposed an endpoint).
  total=0
  if [ -n "$tip" ] && [ -d "$R/.git" ]; then
    total=$(git -C "$R" rev-list --count "$fork..$tip" 2>/dev/null || echo 0); total=${total:-0}
  fi

  method="adapter:$ADAPTER"
  {
    echo "$repo:"
    echo "  fork=${fork:0:9}  human_endpoint=${endpoint:0:9}${title:+  title=$title}"
    echo "  files=$nfiles  method=$method  fork..endpoint_commits=$total"
    echo "  human_stat: $statA"
  } | tee -a "$SUMMARY"

  # diff-range over-capture warning — kept where the adapter EXPOSES AN ENDPOINT (tip). github-pr's
  # fork is an exact merge-base (over-capture impossible), but the `file` adapter takes a HAND-SPECIFIED
  # fork_point/ref, so a fork set too far back over-captures unrelated commits and inflates the human
  # stat — warn so the reviewer regenerates from the genuine range. (>20 is the original absolute floor;
  # the old unit-vs-range ratio does not apply once the tracker abstracts the unit's own commit list.)
  if [ -n "$tip" ] && [ "$total" -gt 20 ]; then
    echo "  DIFF-RANGE WARNING: $total commits in fork..endpoint for unit '$KEY' — verify human_${repo}.diff isn't over-capturing unrelated changes; regenerate from the genuine range if so." | tee -a "$SUMMARY"
  fi
  if [ ! -s "$OUT/human_${repo}.diff" ]; then
    echo "  NOTE: empty reference diff — the tracker adapter ($ADAPTER) reported no changes for unit '$KEY'." | tee -a "$SUMMARY"
  fi

  echo "${repo}|fork=${fork}|endpoint=${endpoint}|files=${nfiles}|commits=${total}|method=${method}|stat=${statA}" >> "$OUT/meta.lines"
}

# ----------------------------------------------------------------------------------------------------
# JIRA INLINE FALLBACK — PRESERVED VERBATIM (until jira routes through core/adapters/tracker/jira.sh). This is the
# old branch/commit-grep resolution: the `jira` tracker adapter's fork_point + change_files +
# reference_diff expressed inline. It reads tracker.config.* exactly as the ADAPTER-CONTRACT specifies
# for jira. A github-pr unit resolves its fork-point via merge-base in the adapter instead.
# ----------------------------------------------------------------------------------------------------
prepare_via_jira_inline() {
  local GREP_RE BRANCH_IS_KEY
  GREP_RE="$(cfg_interp "$(cfg_get tracker.config.commit_grep)" "$KEY")"
  BRANCH_IS_KEY="$(cfg_get tracker.config.branch_is_key)"

  resolve_branch() {  # echo a rev-parseable branch ref for $KEY in repo $1, or empty
    local R="$1" cand
    if [ "$BRANCH_IS_KEY" = "true" ]; then
      for cand in "origin/$KEY" "$KEY"; do
        git -C "$R" rev-parse "$cand" >/dev/null 2>&1 && { echo "$cand"; return; }
      done
    else
      local glob; glob="$(cfg_interp "$(cfg_get tracker.config.branch_glob)" "$KEY")"
      # guard: an empty glob would match refs/remotes/origin/ + refs/heads/ = ALL branches -> head -1
      # silently picks an arbitrary branch (e.g. main). branch_glob is required when branch_is_key=false.
      [ -z "$glob" ] && { echo "resolve_branch: tracker.config.branch_glob is empty but branch_is_key=false ($KEY)" >&2; return; }
      cand="$(git -C "$R" for-each-ref --format='%(refname:short)' "refs/remotes/origin/$glob" "refs/heads/$glob" 2>/dev/null | head -1)"
      [ -n "$cand" ] && echo "$cand"
    fi
  }

  local repo R B TC NEW OLD FORK FILES FILE_ARR statA method ncommits nfiles total TIP
  for repo in $(repos_names); do
    R="$PROJECT_ROOT/$repo"
    [ -d "$R/.git" ] || { echo "$repo: NOT A GIT REPO ($R)" | tee -a "$SUMMARY"; continue; }
    B="$(resolve_branch "$R")"
    [ -z "$B" ] && { echo "$repo: NO BRANCH for $KEY" | tee -a "$SUMMARY"; continue; }
    TC=$(git -C "$R" log --no-merges --format='%H %s' "$B" | grep -iE "$GREP_RE" | awk '{print $1}')
    [ -z "$TC" ] && { echo "$repo: branch exists but no $KEY commits" | tee -a "$SUMMARY"; continue; }
    NEW=$(echo "$TC" | head -1); OLD=$(echo "$TC" | tail -1)
    # fork-point = parent of the OLDEST unit commit. Assumes the unit's commits are contiguous from the
    # branch start; if non-unit commits precede them this over-reaches — the diff-range warning below
    # surfaces that. (A merge-base against a configured base branch would be exact but needs that base.)
    FORK=$(git -C "$R" rev-parse "${OLD}^")
    FILES=$(for c in $TC; do git -C "$R" show --no-merges --name-only --format='' "$c"; done | sort -u | grep -v '^$')
    echo "$FILES" > "$OUT/human_${repo}_files.txt"
    # build a real argv array from the newline list so paths WITH SPACES aren't word-split away
    # (bash 3.2-safe: no mapfile). Pass as -- "${FILE_ARR[@]}" instead of an unquoted $(… | tr).
    FILE_ARR=()
    while IFS= read -r _f; do [ -n "$_f" ] && FILE_ARR+=("$_f"); done <<< "$FILES"
    git -C "$R" diff "$FORK" "$NEW" -- "${FILE_ARR[@]}" > "$OUT/human_${repo}.diff" 2>/dev/null
    statA=$(git -C "$R" diff --shortstat "$FORK" "$NEW" -- "${FILE_ARR[@]}" 2>/dev/null)
    method="A(fork..newestUnitCommit)"
    if [ ! -s "$OUT/human_${repo}.diff" ]; then
      TIP=$(git -C "$R" rev-parse "$B")
      git -C "$R" diff "$FORK" "$TIP" -- "${FILE_ARR[@]}" > "$OUT/human_${repo}.diff" 2>/dev/null
      statA=$(git -C "$R" diff --shortstat "$FORK" "$TIP" -- "${FILE_ARR[@]}" 2>/dev/null)
      method="B(fork..branchTip)"; NEW="$TIP"
    fi
    ncommits=$(echo "$TC" | grep -c .); nfiles=$(echo "$FILES" | grep -c .)
    total=$(git -C "$R" rev-list --count "$FORK..$NEW" 2>/dev/null || echo 0)
    {
      echo "$repo:"
      echo "  fork=$(git -C "$R" rev-parse --short "$FORK")  human_endpoint=$(git -C "$R" rev-parse --short "$NEW")"
      echo "  unit_commits=$ncommits  files=$nfiles  method=$method  fork..endpoint_commits=$total"
      echo "  human_stat: $statA"
    } | tee -a "$SUMMARY"
    # diff-range sanity: warn if the endpoint range dwarfs the unit's own commits (possible over-capture)
    if [ "$total" -gt "$((ncommits*3))" ] && [ "$total" -gt 20 ]; then
      echo "  DIFF-RANGE WARNING: $total commits in fork..endpoint vs $ncommits unit commits — verify human_${repo}.diff isn't over-capturing unrelated changes; regenerate from genuine commits if so." | tee -a "$SUMMARY"
    fi
    echo "${repo}|fork=$(git -C "$R" rev-parse "$FORK")|endpoint=$(git -C "$R" rev-parse "$NEW")|files=$nfiles|commits=$ncommits|method=$method|stat=${statA}" >> "$OUT/meta.lines"
  done
}

case "$ADAPTER" in
  jira) prepare_via_jira_inline ;;
  *)    prepare_via_adapter ;;   # github-pr | file | none (and fail-closed on stubs/unknowns via the shim)
esac

echo "---- $KEY prepared ----" | tee -a "$SUMMARY"
