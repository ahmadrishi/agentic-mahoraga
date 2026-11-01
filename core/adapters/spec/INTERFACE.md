# `spec` adapter interface

The **design/requirement half** of the dual input. Full contract:
[`docs/ADAPTER-CONTRACT.md §2`](../../../docs/ADAPTER-CONTRACT.md). The core consumes a `SPEC.md`
file **on disk** and calls no vendor API. Adapters read every hostname / locator from
`PROJECT.yaml` (`spec.config`); **no literal hostnames live in an adapter.**

## Functions

`<adapter>.sh <fn> [args]`, with `PROJECT_YAML` in the environment.

| Function | Args | Behavior |
|---|---|---|
| `fetch_spec` | `<unit> <out_dir>` | writes `<out_dir>/SPEC.md`; prints `SPEC: OK` or `SPEC: THIN (...)` |
| `is_transcribable` | `<fmt>` | exit `0` (true) / `1` (false). False for visual-only specs (excluded). |

### Thin / attribution-ambiguous

When the spec is thin (`none`, or `issue-body` with only a short PR description), the adapter writes
`<out_dir>/.attribution-ambiguous` (a one-line reason) and prints `SPEC: THIN`. Downstream, the run
is flagged: the dual-input probe's skill-gap-vs-spec-gap signal is weaker, and **spec-fidelity is not
scored as if an independent spec existed.** A missing spec with nothing to write returns exit `3`.

## How a vendor-coupled fetch works

An adapter is EITHER **(a) a REST client** shelling to a vendor API with a token from config, OR
**(b) an orchestrator fetch-step** that uses an MCP connector to retrieve the doc and writes
`SPEC.md`. Either way **the core reads the file and calls no vendor API.**

## Shipped reference adapters

| Adapter | File | Source | `spec.config` |
|---|---|---|---|
| `markdown` | `markdown.sh` | a repo file by glob (verbatim → SPEC.md) | `glob` (`{{unit}}` interpolated) |
| `issue-body` | `issue_body.sh` | the tracker unit's own body; flags thin when short | — |
| `none` | `none.sh` | PR description as a thin spec; **always** flags attribution-ambiguous | — |

`issue-body`/`none` read the body from the same place the tracker does: the PR description
(`tracker.adapter=github-pr` + `gh`) or the unit commit's full message.

No pipeline code calls `fetch_spec` yet (`prepare_task.sh` does not); run it with
`PROJECT_CONFIG=$PWD/PROJECT.yaml bash core/lib/adapters.sh spec fetch_spec <unit> <out_dir>`. None of these adapters has a test yet.

## Peer stubs — not implemented

`confluence.stub.sh`, `notion.stub.sh`, `gdocs.stub.sh` exit non-zero with "not implemented". These
sources are non-trivial and partly browser-only, so the plan is **text-extract-only (degraded)**:
readable text into `SPEC.md`, no embedded diagrams/macros/comments. **Visual specs (Figma / Balsamiq
/ Whimsical) are out of scope** and must be pre-transcribed. `spec.untranscribable` lists formats
that force task exclusion; every implemented adapter's `is_transcribable` honors it.
