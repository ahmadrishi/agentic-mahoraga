# Adapter contract

Everything vendor-specific in Agentic Mahoraga lives behind an **adapter**: the core calls the
adapter named in `PROJECT.yaml`. Two known exceptions remain — `core/lib/prepare_task.sh` routes
`tracker.adapter=jira` to an inline fallback instead of `tracker/jira.sh`, and the `issue-body` /
`none` spec adapters branch on `tracker.adapter=github-pr` to fetch a PR body with `gh`. Adapters
take every hostname, key, and project id from that file. CI checks for literal hosts coarsely:
`scripts/adapter-security-check.sh` flags a literal host handed to a network tool in an adapter, and
`scripts/leak-scan.sh` denylists known-private hosts across the tree.

There are four adapter families. Each is a small, self-contained module under
`core/adapters/<family>/<name>`. A new adapter is a **community contribution reviewed for security**
(SECURITY.md) — for trackers it is genuinely small; spec adapters vary a lot in difficulty.

---

## 1. `tracker` — the unit of work

The unit of work is a **merged PR**, a **ticket-with-branch**, or a **tagged commit** — never
hard-coded to a branch. This is the fix for the old Jira-shaped `resolve_branch(key)` contract, which
was meaningless for the squash/PR teams that are the first target.

```
list_units(since, n, filters)   -> [Unit]          # recently shipped units of varying size
fork_point(unit)                -> sha             # merge-base(base_branch, unit) for a PR;
                                                     # parent-of-oldest-ticket-commit for a branch
change_files(unit)              -> [path]          # files the unit legitimately touched
reference_diff(unit)            -> unified diff    # the human's shipped change — a REFERENCE, never a match target
metadata(unit)                  -> {id, title, labels, merged_at, ...}
```

Reference adapters shipped: `github-pr` (git + PR metadata; merge-base fork-point for a PR head or
merge commit, the parent for a squash commit), `file` (a CSV of `unit_id,fork_point,ref` for any
workflow the built-ins miss), `none` (last N merged PRs, no ticket metadata), `gitea` (pure-git; the
REST metadata layer is not built), and `jira` (git-driven, branch-per-ticket — reached through `adapters.sh` for `list_units`/`metadata`,
but `prepare_task.sh` still resolves jira fork-points and diffs with its inline fallback). `linear` and `azure-devops` are stubs.

## 2. `spec` — the design/requirement half of the dual input

```
fetch_spec(unit, out_dir) -> writes SPEC.md into out_dir on disk (or reports "thin")
is_transcribable(fmt)-> bool                          # false for visual-only specs (excluded)
```

**How a vendor-coupled fetch actually works** — an adapter is EITHER:
- **(a) a REST client** that shells out to a vendor API with a token, OR
- **(b) an orchestrator fetch-step** that uses an MCP connector to retrieve the doc and writes
  `SPEC.md` to disk.

Either way **the core consumes files on disk and calls no vendor API.** Spec adapters are *not*
uniformly cheap: `markdown` (a repo file) and `issue-body` are trivial; `confluence` / `notion` /
`gdocs` are non-trivial and partly browser-only — today they are **stubs** (not implemented); the
plan is text-extract-only. **Visual specs (Figma / Balsamiq / Whimsical) are out of scope** and must
be pre-transcribed.

**Who calls `fetch_spec`:** no pipeline code yet. `core/lib/adapters.sh` defines `spec_fn`, but
`prepare_task.sh` never calls it; run the adapter directly with
`PROJECT_CONFIG=$PWD/PROJECT.yaml bash core/lib/adapters.sh spec fetch_spec <unit> <out_dir>`.

When the spec is thin (`none` / `issue-body` with only a PR description), the run is flagged
`attribution-ambiguous`: the dual-input probe's skill-gap-vs-spec-gap signal is weaker, and
spec-fidelity is not scored as if an independent spec existed.

## 3. `vcs` — version control (host-agnostic local git)

Only `git`. GitHub / GitLab / Gitea are *hosts of git*, handled by the tracker adapter; the vcs
layer does `archive`, `log`, `rev-parse`, `diff`, `merge-base`, `for-each-ref` on a full local
checkout. Requires history reaching each fork-point (no shallow-clone path yet — a roadmap item).
The gap is **not detected**: on a shallow clone (or a root commit) the `github-pr` squash path emits
`<sha>^` as the fork-point instead of failing, so unshallow first (`git fetch --unshallow`).

## 4. `verify` — build / typecheck / test

Per-repo (not one global command). Declared in `PROJECT.yaml` `repos[].verify`:

```
build(repo)            -> BUILD_SUCCESS | BUILD_FAILURE | n/a   # grep success_marker; else the exit code
typecheck(repo)        -> pass | fail | n/a                     # verdict is the exit code
test(repo)             -> pass | fail | n/a                     # OPTIONAL; absent => BUILD-VERIFIED, not behavior-verified
run_oracle(repo, spec) -> pass | fail | n/a                     # OPTIONAL; one mined oracle => SMOKE-VERIFIED
```

The **honesty verdict** is mandatory: never imply tests ran when they did not. Ladder:
`UNVERIFIED < BUILD-VERIFIED < SMOKE-VERIFIED < behavior-verified`. Real test execution in the
history-free sandbox needs provisioning (deps, network, fixtures/DB) and is a follow-on, not an
adapter one-liner. (The PROVE skills currently verify through `core/lib/compile_gate.sh`, which runs
the build — or the typecheck when there is no `build_cmd` — and never `test` or `run_oracle`; unlike
`build()` here, it refuses to run without a `success_marker`.)

---

## Writing an adapter

1. Create `core/adapters/<family>/<name>` implementing the family's functions.
2. Read all config from the `config:` block for your adapter in `PROJECT.yaml`. No literal hostnames.
3. Declare any tools/network you need; the security review checks for undeclared network/shell and
   secret exfiltration before merge.
4. Add a fixture-backed test (required for new adapters; some shipped ones still lack one — see
   CONTRIBUTING.md). The core stays vendor-agnostic — your adapter is the only thing that knows the vendor.
