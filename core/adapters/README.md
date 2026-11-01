# `core/adapters/` — the vendor boundary

Everything vendor-specific in Agentic Mahoraga lives here, behind an **adapter**. The core calls the
adapter named in `PROJECT.yaml`, and adapters take every hostname, key, and project id from that
file. Two vendor branches remain outside this boundary (`prepare_task.sh`'s inline jira fallback;
the `issue-body`/`none` spec adapters' `github-pr` PR-body path) — see the contract. CI checks for
literal hosts coarsely (`scripts/adapter-security-check.sh`, `scripts/leak-scan.sh`).

> Read [`docs/ADAPTER-CONTRACT.md`](../../docs/ADAPTER-CONTRACT.md) first — it is the authority. This
> README is the map; each family's `INTERFACE.md` is the detail.

## The four families

| Family | What it abstracts | Shipped | Interface |
|---|---|---|---|
| [`tracker/`](tracker/INTERFACE.md) | the **unit of work** (merged PR / ticket-with-branch / tagged commit) | `github-pr`, `gitea`, `file`, `none`, `jira` (git-driven; not yet called by `prepare_task.sh`) (+ `linear`,`azure-devops` stubs) | [INTERFACE](tracker/INTERFACE.md) |
| [`spec/`](spec/INTERFACE.md) | the **design/requirement** half of the dual input | `markdown`, `issue-body`, `none` (+ `confluence`,`notion`,`gdocs` stubs) | [INTERFACE](spec/INTERFACE.md) |
| [`vcs/`](vcs/git.sh) | **version control** (host-agnostic local git) | `git` only | header of `git.sh` |
| [`verify/`](verify/INTERFACE.md) | **build / typecheck / test** + the honesty verdict | `command` (generic) | [INTERFACE](verify/INTERFACE.md) |

GitHub / GitLab / Gitea are *hosts of git*, handled by the **tracker** adapter; the **vcs** layer
only does `archive / log / rev-parse / diff / merge-base / for-each-ref` on a full local checkout.

## How adapters are called

Each adapter is one small executable invoked as `<adapter>.sh <fn> [args]`, with `PROJECT_YAML` in
the environment (the path to the project's `PROJECT.yaml`; see
[`core/schema/PROJECT.schema.yaml`](../schema/PROJECT.schema.yaml)). Config is read from that file —
`tracker.config`, `spec.config`, `repos[].verify`. Trackers/spec adapters route all git through
`vcs/git.sh` rather than growing their own git logic.

Dependency-light on purpose: POSIX sh / bash + `git` + `python3` (with PyYAML, config reads only).
No `yq`, no `jq`.

## Design principles (from the contract)

1. **Self-contained.** Each adapter is a small module you can read and security-review on its own.
2. **No hostnames in code.** Every URL/key/id comes from `PROJECT.yaml`.
3. **Honesty over optimism.** `verify` never implies tests ran when they did not; thin specs are
   flagged `attribution-ambiguous` instead of scored as real specs.
4. **Reference, not answer key.** A tracker's `reference_diff` is the human's shipped change used as
   a *reference*, never a match target.
5. **Least privilege.** A new adapter declares any network/shell it needs; the security review checks
   for undeclared network/shell and secret exfiltration before merge (SECURITY.md).

## Adding an adapter

1. Create `core/adapters/<family>/<name>.sh` implementing the family's functions.
2. Read all config from your `config:` block in `PROJECT.yaml`. No literal hostnames.
3. Declare tools/network you need; pass the security review.
4. Add a fixture-backed test (required for new adapters; some shipped ones still lack one — see
   `CONTRIBUTING.md`). The core stays vendor-agnostic — your adapter is the only thing that knows
   the vendor.
