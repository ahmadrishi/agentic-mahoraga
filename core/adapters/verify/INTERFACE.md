# `verify` adapter interface

Build / typecheck / test — **per-repo, not one global command**. Full contract:
[`docs/ADAPTER-CONTRACT.md §4`](../../../docs/ADAPTER-CONTRACT.md). Each repo declares its own
commands in `PROJECT.yaml` `repos[].verify`; the adapter runs them and emits the mandatory
**honesty verdict**.

## Functions

`command.sh <fn> <repo_dir> [log]`, with `PROJECT_YAML` in the environment. The config row is matched
by the **basename of `<repo_dir>`** against `repos[].name`.

| Function | Args | Output |
|---|---|---|
| `build` | `<repo_dir> <abs_log>` | `BUILD_SUCCESS` \| `BUILD_FAILURE` \| `n/a` |
| `typecheck` | `<repo_dir> <abs_log>` | `pass` \| `fail` \| `n/a` (verdict = exit code) |
| `test` | `<repo_dir> <abs_log>` | `pass` \| `fail` \| `n/a` (verdict = exit code) |
| `run_oracle` | `<repo_dir> <oracle_spec> <abs_log>` | `pass` \| `fail` \| `n/a` — one mined behavioural oracle (verdict = `oracle_marker` grep, else exit code) |
| `verdict` | `<repo_dir> [log_dir]` | **`UNVERIFIED` \| `BUILD-VERIFIED` \| `SMOKE-VERIFIED` \| `behavior-verified`** (rationale on stderr) |

`repos[].verify` keys: `build_cmd`, `typecheck_cmd`, `test_cmd`, `oracle_cmd`, `oracle_marker` (all
optional), `success_marker`.

## Rules

- **Build verdict = grep of `success_marker`, not the wrapper exit code** — a build tool can exit 0
  while the compile failed. If `success_marker` is omitted, the build verdict falls back to the exit
  code (declare a marker when the build produces no reliable exit code).
- **Absolute log (R12).** `build`/`typecheck`/`test` `cd` into the repo, so any `<log>` you pass must
  be an absolute path or the log write fails before the build runs.
- **Typecheck/test verdict = exit code.** `tsc --noEmit`, `pytest`, etc. have no marker line.

## The honesty verdict (mandatory)

Composed by `verdict`, which runs the declared steps and **never implies tests ran when they did
not**:

| Situation | Verdict |
|---|---|
| build/typecheck passed **and** tests ran and passed | `behavior-verified` |
| no `test_cmd`, but a declared `oracle_cmd` ran and passed | `SMOKE-VERIFIED` |
| build/typecheck passed, **no `test_cmd` declared** (and no runnable oracle) | `BUILD-VERIFIED` |
| build/typecheck failed, tests ran and failed, or the oracle ran and failed | `UNVERIFIED` |
| nothing declared to run | `UNVERIFIED` |

Real test execution in the history-free sandbox needs provisioning (deps / network / fixtures / DB)
and is a **follow-on (not built)**, not an adapter one-liner — hence a repo with no `test_cmd` tops
out at `SMOKE-VERIFIED` (with a runnable oracle) or `BUILD-VERIFIED`. The PROVE skills currently
verify through `core/lib/compile_gate.sh` (build or typecheck only), not this `verdict`.

## Conventions

- Commands run via `bash -lc` from inside the repo (a login shell, so a profile-managed toolchain is
  on `PATH`). Dependency-light: bash + `python3`+PyYAML (config only). No `yq`/`jq`.
- Never echo credential file contents (e.g. a `settings`/token path) into a log.
