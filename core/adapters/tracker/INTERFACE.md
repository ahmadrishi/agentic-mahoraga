# `tracker` adapter interface

Defines the **unit of work**. Full contract: [`docs/ADAPTER-CONTRACT.md §1`](../../../docs/ADAPTER-CONTRACT.md).
The unit is a **merged PR**, a **ticket-with-branch**, or a **tagged commit** — never hard-coded to a
branch. The core calls the adapter named in `PROJECT.yaml` (`tracker.adapter`) — except for `jira`,
which `core/lib/prepare_task.sh` still routes to its inline fallback — and adapters read every
hostname / repo / key from `tracker.config`. **No literal hostnames live in an adapter.**

## Functions

Each adapter is one executable invoked as `<adapter>.sh <fn> [args]`, with `PROJECT_YAML` in the
environment. A **unit id** returned by `list_units` is accepted by every other function.

| Function | Args | Output |
|---|---|---|
| `list_units` | `[since] [n] [filters]` | one unit per line: `id⇥title⇥merged_at⇥labels` (tab-separated; `labels` may be empty) |
| `fork_point` | `<unit>` | one sha — `merge-base(base_branch, unit)` for a PR; parent-of-oldest-ticket-commit for a branch |
| `change_files` | `<unit>` | one changed path per line (files the unit legitimately touched) |
| `reference_diff` | `<unit>` | a unified diff — the human's shipped change. **A REFERENCE, never a match target.** |
| `metadata` | `<unit>` | `key=value` lines: `id,title,labels,merged_at,base,fork,tip` (as available) |

`fork` and `tip` are chosen so that `reference_diff` = `fork..tip` lines up with the fork-point tree
the sandbox is staged at (the vcs adapter does `git archive <fork>`). For a squash PR that is
`parent..commit`; for a merge commit it is `merge-base(base,feature)..feature`.

## Shipped reference adapters

| Adapter | File | Unit | `tracker.config` keys |
|---|---|---|---|
| `github-pr` | `github_pr.sh` | merged PR | `repo` ("owner/name"), `base_branch`, `labels_exclude`, `merge_strategy` (fallback only) |
| `gitea` | `gitea.sh` | merged PR (pure-git) | `base_url` (REST layer not built), `repo`, `base_branch`, `labels_exclude` (REST layer not built), `merge_strategy` |
| `file` | `file.sh` | a CSV row | `path` (CSV of `unit_id,fork_point,ref`), `repo` (optional) |
| `none` | `none.sh` | last N units of `base_branch` | `n`, `merge_strategy` (`squash`\|`merge`), `base_branch` |
| `jira` | `jira.sh` | a ticket on a branch-per-ticket workflow (pure-git) | `project_key`, `branch_is_key`, `branch_glob`, `commit_grep`, `labels_exclude` + `cloud_id`/`base_url` (REST layer not built) |

- **`github-pr`** uses the `gh` CLI when present (PR listing + labels); otherwise a **documented
  pure-git fallback** (last N first-parent commits on `base_branch`; labels unavailable). The
  fork-point is a real `git merge-base` for a PR head or a merge commit, and the parent for a squash
  commit. It needs history back to that parent: on a shallow clone or a root commit the squash path
  emits `<sha>^` instead of failing (not yet detected).
- **`jira`** resolves a ticket's fork-point, files, and diff from its branch/commits in local git.
  It is shipped but **not yet called** by `prepare_task.sh`, which still uses its inline jira
  fallback; it has no test yet.
- **`gitea`** is a **working pure-git tracker** over the same git-host model (Gitea is another host
  of git): `list_units`/`fork_point`/`change_files`/`reference_diff`/`metadata` all come from local
  git via the vcs adapter, exactly like `github-pr`'s pure-git path. The Gitea-REST PR-metadata/labels
  layer (unit id = PR number, `labels_exclude` filtering) is not implemented — it needs a live instance +
  token (out of CI scope). Until then the unit id is a git commit sha and `labels_exclude` is a no-op.
- **`file`** is the escape hatch for any workflow the built-ins miss — you supply the units.
- **`none`** needs no tracker at all; pair it with the `none` **spec** adapter (attribution-ambiguous).

## Peer stubs (not yet implemented)

`linear.stub.sh`, `azure_devops.stub.sh` carry the contract signatures and a not-implemented note.
Each needs a vendor API to map its unit (ticket / issue / PR#) to a git ref — EITHER a REST client
(token from `PROJECT.yaml`) OR an orchestrator fetch-step via an MCP connector; the fork-point and diffs
always come from local git. Each contract fn exits non-zero (`64`) with a clear "not implemented",
and the dispatch shim treats a `.stub.sh` as declared-but-unimplemented (fail-closed; the adapter name is
mapped to the filename by `-`→`_`, so `azure-devops` → `azure_devops.stub.sh`). `gitea` and `jira`
graduated from stubs to the pure-git adapters above; `github-pr`'s pure-git path likewise works on a GitLab checkout.

## Conventions

- Repo dir = `MAHORAGA_REPO_DIR` (env) → `project.root/<basename of tracker.config.repo>` →
  `project.root/<first repos[].name>`.
- All git touches go through the vcs adapter (`../vcs/git.sh`) — adapters never grow their own git logic.
- Dependency-light: POSIX sh / bash + `git` + `python3`+PyYAML (config only). No `yq`/`jq`.
- A new adapter is a community contribution **reviewed for security** (declare any network/shell).
