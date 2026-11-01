<!-- Identity is defined once in branding.yaml; this file mirrors it. -->

# Decontamination methodology

Agentic Mahoraga's whole value rests on **trustworthy measurement**. Prove blind-reimplements your
shipped units of work and scores the result against the human's change *as a reference, never a match
target*. That number is worth nothing if the "blind" agent could see the answer. This document is the
honest, inspectable account of how we keep the eval blind — and where that guarantee is still partial.

> **Read this honestly.** Decontamination is the *target*, not yet complete. What runs as code today is an **identifier-level** leak gate, a history-free sandbox, and a
> manifest strip-set. It does not catch a paraphrased answer. On the slash-command path the
> implementer's isolation from the live repo is a prompt instruction; under `mahoraga loop` it is
> enforced by a container (§2). Cutoff labels are computed per unit, but nothing in code
> filters the headline by them yet. The eval is dependable today only on **private / post-cutoff**
> work; we do not present a public-repo number as blind.

---

## 1. Two kinds of contamination

| Class | The leak | Where it is handled |
|---|---|---|
| **Context leakage** (in-run) | The answer reaches the implementer through the sandbox — a skill that names the fix, a git history, the ticket id, a stray diff. | §2–§6 (in-run controls; staging is code; implementer launch is model-instructed on the slash-command path, code under `mahoraga loop`) |
| **Pretraining contamination** | The model **memorized a public repo's merged changes during pretraining**, so the "blind" reimplementation is recall, not reasoning. | §7 (cutoff holdout — the honest fix) |

Earlier designs of this eval handled only the first. A "blind" eval on a public repo the model has already seen is **not blind**
for exactly the repos an open-source demo uses. Both classes must be addressed for a score to mean
what it claims.

---

## 2. Fresh-not-fork implementers *(model-instructed on the slash-command path; code under `mahoraga loop`)*

A **forked** agent inherits the parent's context — including the answer. Only a **fresh
`general-purpose` agent**, given nothing but the two inputs (the spec and the business requirement),
is blind. The `blind-eval` and `sandbox-isolation` skills instruct the orchestrating model never to fork
the implementer, and to make no `Skill` tool calls (plugin and live-repo skills load session-wide, so
the sandbox's skill files must be the arm's only skills). Both rules are prose a model follows; no
script launches or constrains PROVE's implementer.

**The loop's arm boundary (`core/loop/`) — built; used by every `mahoraga loop` command
that runs a model (`preflight --paid`, `prove`, `insample`, `gate`, `run`).** The closed improve loop launches implementers
from code, inside an OS boundary. What exists today and what each control actually guarantees:

| Control | Status |
|---|---|
| Filesystem | **Enforced** (Docker runner): the arm sees only its sandbox at `/work`, a throwaway `$HOME`/`/tmp`, a read-only root and the hashed binary; caps dropped, `no-new-privileges`. |
| Network | **Enforced**: an `--internal` network whose only way out is the CONNECT-allowlist proxy sidecar (`core/loop/egress_proxy.py`, model API only); every ALLOW/DENY is logged. |
| Proof | `tests/loop_isolation_test.sh` (its own CI job): a model-free escape agent in the real config fails 0/4 escapes, its planted symlink is caught by the host census, and the same agent *without* the container does read the host file (negative control). |
| Init event | **Checked per run**: skills, plugins, MCP servers, tools, model and version must equal what was staged, or the run is `integrity_failed`. |
| Credential | **Residual**: the token reaches the arm by env name and is readable via `/proc` inside the container; every transcript is scanned for it and redacted, and a hit invalidates the run. |
| Scorer | **Enforced** view: Codex runs in the same boundary with only its view (read-only) and output dir mounted, and cannot execute code (its code-mode helper is absent). Verified with a real model on a known-answer view. |
| Org instructions, built-in skills | **Present in every arm**, `bare` included — with an API key too (the canary saw org remote settings, hash stable across runs). Disclosed, not removed; a decision requires one org-settings hash per phase. |
| Leak gate (`loop prove`) | **Parsed, fail-closed**: the verdict is read from the gate's output; only `0 hits across N>0` stages an arm (`NOTHING CHECKED`, no verdict or a non-zero exit drops it). The output names answer tokens, so it goes to a host-private log only. The `pre` arm's always-on `CLAUDE.md` is staged through the skills dir, so the gate scans it too (a hermetic test plants a token in it and the arm is dropped). |
| AI-written code builds | **Enforced**: every verify command runs in a container with no network, a read-only root, dropped caps and only read-only mounts besides the repo. AI code never builds on the host. |
| Host-side diff | **Guarded**: a planted symlink or special file is `integrity_failed` before the host-side `diff` runs, and nothing is extracted. The repo's own `.claude/` and `CLAUDE.md` are stripped before launch and filtered from the diff. |
| Scorer (`loop prove`) | **Same family, descriptive**: Claude, tools-less and schema-constrained, in the same boundary; one candidate per session from an opaque view with no arm, unit id or slug. Shares the implementer's family, so `prove` results are flagged and never decide anything. |
| Editor (`loop run`) | **Enforced view**: a copy-in workspace (the parent overlay, the repo at the split's last train merge without `.git`, and evidence from the train units only: SPEC/BR, human diff, up to one scored attempt), no `Bash`. No held-out unit's data is in it. Unit ids and honey tokens in its output are a tripwire (exit 2). |
| Held-out units | **Code**: the split follows first-parent order, never dates; held-out units come after every train unit and a gap unit, and a unit any campaign has scored is never held out again. Before any held-out rollout, the candidate is staged through each held-out unit's leak gate; a hit **rejects** it with no retry and no feedback. |
| Platform | Linux Docker only. Membership of the `docker` group is root-equivalent. |

## 3. The sandbox is history-free *(code)*; isolation is instructed

Each touched repo is staged at its **fork-point** with **no `.git`** (a `git archive` of the
fork-point tree, not a clone — `core/lib/stage_sandbox.sh`). The sandbox holds the fork-point tree, the
project's skills, `SPEC.md` and `BUSINESS_REQUIREMENT.md` — no human diff, no eval data. Its directory
is named by an **opaque slug**; staging aborts if the slug contains the unit id. The id is also
stripped from the copied SPEC/BR, but that step **fails open** (`|| true`): if it errors, staging
continues.

On the slash-command path the sandbox is a directory, not a jail: the live repo, the run dir (which
holds the human diff) and the session's loaded skills stay reachable, and keeping the implementer
inside the sandbox is a prompt instruction (§2). Under `mahoraga loop` the arm's container sees the
sandbox, a throwaway home and the pinned binary, and nothing else of the host (§2).

## 4. The leak-gate: auto-derived answer tokens minus the fork-point *(code)*

Before an implementer runs, the sandbox's skills (`.claude/skills` only — not `SPEC.md` /
`BUSINESS_REQUIREMENT.md`) are grepped for the unit's **answer tokens**. There are two sources, and the second is what makes the gate track the *real* answer instead of a guess:

1. **Curated tokens** — an optional per-unit list in `PROJECT.yaml`
   (`decontamination.answer_tokens[<unit_id>]`), exact and false-positive-free.
2. **Auto-derived tokens** — distinctive identifiers taken from the human diff's **added** lines,
   **minus every symbol that already existed at the fork-point.** A symbol present at fork-point is
   pre-existing vocabulary the human merely referenced; a symbol *absent* at fork-point was
   introduced as part of the answer, so a skill that names it has leaked the answer.

This subtraction is the key idea (worth preserving verbatim from the origin harness): when Improve
writes a new skill from findings, that skill can easily name the fix's symbols; the auto-derivation
catches exactly that, with no manual token list; the loop's editor candidate goes through the same
gate for every held-out unit (§2). It catches **identifiers only** — a skill that paraphrases the fix
in prose, or names a file path or a PascalCase type (except in Go/C#), passes. `skills.index_file` is staged twice, at
the sandbox root and inside `.claude/skills`; the gate checks it through the second copy, which a
strip or a sanitize removes if the index sits inside a stripped or derived skill dir.

The gate aborts staging on any hit, and is honest about coverage: "0 hits" with **no tokens to check**
is reported as `NOTHING CHECKED`, distinct from a verified-clean `0 hits` — but it still **exits 0**,
so staging proceeds. Bug-fix units that add few new identifiers can land here unless curated
`answer_tokens` are configured. Implemented in `core/lib/leak_gate.sh` and exercised by CI; the
whole-tree company-data denylist is a separate gate, [`scripts/leak-scan.sh`](../scripts/leak-scan.sh).

### Language-aware tokens — the top-priority generalization

The origin auto-token heuristic keeps distinctive `lowerCamelCase` and `CONSTANT_CASE` identifiers
and **excludes `PascalCase`** (framework type-names are the main false-positive source). That is tuned
to one JVM/JS idiom. On other languages it was **silently blind**: Python `snake_case` and Go
`MixedCaps` were dropped, so on a Python service the auto leak-gate barely fired.

**The fix (shipped):** per-language identifier heuristics in `core/lib/lang_profiles.py`,
**selected by the repo's declared `language`** (`PROJECT.yaml → repos[].language`):

| Language | Distinctive-symbol heuristic |
|---|---|
| python / ruby / rust | `snake_case` with ≥2 underscores and ≥12 chars; `CONSTANT_CASE` with ≥2 underscores and ≥12 chars |
| typescript / javascript / java / kotlin / scala | `lowerCamelCase` with ≥2 humps (or 1 hump and ≥18 chars); `CONSTANT_CASE` as above |
| go / csharp | identifiers with ≥2 humps (≥12 chars if capitalised); `CONSTANT_CASE` as above |

**PascalCase is not matched for Python/Ruby/Rust or the camelCase family** (deliberately: type names are
the main false-positive source); Go and C# do match capitalised MixedCaps with ≥2 humps and ≥12 chars, and there is no Ruby `:symbol` handling. A newly-introduced class name, or a short identifier
like `apply_discount`, is invisible to the auto gate — cover those with curated `answer_tokens`.

> Until a language's heuristic ships, an eval on that language relies on **curated `answer_tokens`**,
> and a run with neither reports `NOTHING CHECKED` rather than a false "clean."

## 5. Whole-directory sanitize of derived skills *(code, fail-closed)*

A skill **derived from eval tasks** can leak an answer through an un-tokenised worked example. For
every `skills.derived_skills` entry, staging (`core/lib/sanitize_skills.sh`) overwrites the sandbox
copy of `SKILL.md` with a curated **method-only** `SKILL.sanitized.md`, then **removes every other file**
in that skill's sandbox directory (`references/`, examples). A curated `references.sanitized/` next to
the source skill, if present, is swapped in as `references/`. A derived skill **without** a sanitized
copy aborts staging (fail-closed).

This covers only skills *listed* as derived. A skill that is not listed — for example a forged skill
whose prose happens to paraphrase a unit's fix — is copied as-is and is only checked by the
identifier gate (§4).

## 6. Manifest-driven strip-set + zero-residue CI test *(enforced)*

Mahoraga's **own** meta-skills describe the eval itself (how staging, scoring, and decontamination
work). If one survives into a blind sandbox, the implementer can tell it is being tested and can read
the methodology as an answer key — a decontamination **tell**.

The origin harness hard-coded the list of skills to strip inside the staging script, so a rename or a
new meta-skill silently left it in the sandbox. The fix:

- The strip-set is a **manifest**, [`core/schema/STRIP_SET.manifest`](../core/schema/STRIP_SET.manifest),
  matched by directory basename anywhere under the staged skills tree. The staging code **reads the
  manifest**; it does not hard-code the list.
- A **zero-residue acceptance test**,
  [`scripts/zero-residue-sandbox-test.sh`](../scripts/zero-residue-sandbox-test.sh), runs in CI and
  asserts (A) every manifest name resolves to a real skill directory (so the strip-set cannot go
  stale under a rename) and (B) the staging code actually reads the manifest (so the hard-coded-list
  regression cannot come back).

Add every new Mahoraga-own meta-skill to the manifest. The GUARD behavioral pack is **not** stripped:
those are stack-agnostic disciplines the implementer is meant to have, not descriptions of the eval.

## 7. Pretraining-cutoff holdout — protecting the "decontaminated" claim

Context controls (§2–§6) do nothing about a model that **memorized a public repo during pretraining.**
Following the SWE-rebench line of work, the policy (`PROJECT.yaml → decontamination.cutoff_policy`):

- **Prefer units merged *after* the model's training cutoff** (`model_cutoff`). A unit merged after
  the cutoff is `cutoff-clean`.
- **Prefer private repositories** for the real signal (`repo_visibility: private`). The label trusts
  this declared value; nothing checks it against the repo's real visibility.
- **Label any public-repo eval `cutoff-unverified`.** The "decontaminated" claim is false for a public
  repo the model has seen, so we say so on the report rather than implying blindness.
- **A headline number must come from private / post-cutoff work**
  (`require_post_cutoff_for_headline: true`, a settled decision). This is a reporting
  rule: `aggregate_scores.py` does not yet filter the headline by `cutoff_label`. `examples/ts-app` is
  labelled `cutoff-unverified`; `examples/py-service` is configured `repo_visibility: private` (although
  it ships with Mahoraga itself as an open-source demo fixture) purely to exercise the `cutoff-clean` path — neither example's number
  is a result.

## 8. Per-unit decontamination-confidence label

Every Prove report has room for, **per unit**, a decontamination-confidence label so a reader can
weight the score. The orchestrating model writes it into `score.json` (no script computes it); the
report renders whatever is there:

- `auto-clean` — the language-aware leak-gate ran and found zero hits.
- `curated-clean` — curated `answer_tokens` were checked and clean (no auto heuristic for this
  language yet).
- `hand-mitigated` — a leak was found and manually removed before the blind run (disclose it; do not
  hide it).
- `nothing-checked` — no tokens were derivable and none curated; treat the unit's score as
  **unverified for contamination**.
- `cutoff-unverified` — a public repo the model may have seen at pretraining (§7).

> **Field vs. prose.** The above is the confidence *idea*. The machine field the report and
> `score.json` carry is defined authoritatively in §11 (`decontam_confidence`) and §10 (`cutoff_label`):
> the leak-gate axis and the pretraining-cutoff axis are two **separate** fields there, so
> `cutoff-unverified` is a `cutoff_label` value, not a `decontam_confidence` value.

## 9. The ablation arm — so a score is attributable

Decontamination makes a number *blind*; the **ablation arm** makes it *attributable*. The `blind-eval`
protocol runs a **baseline**: the same units, run by a bare agent with **no forged skills and no GUARD
pack**, and the report is the **harness-vs-baseline delta**, not an absolute percentage. Without it, a
high score is unattributable to the harness versus the base model's own capability. Aggregation and
the report's ablation panel are code (`aggregate_scores.py`, `report_ablation.py`); staging and
running both arms is model-instructed on the slash-command path and code under `mahoraga loop`.

Two caveats on "no GUARD" in the baseline of the slash-command path: the GUARD *skills* are kept out
only by the instruction that the implementer makes no `Skill` tool calls (§2), and the GUARD *hooks*
are session-wide, so in a live run they presumably fire in both arms (inferred, not yet measured).
Neither applies under `mahoraga loop`: each arm is a fresh config holding only its staged content,
and a hook firing in an arm fails the run's integrity check. Construct details:
`docs/EVAL-RUBRIC.md` §3.

---

## 10. `cutoff_label` — the scored field and its exact rule

§7 states the *policy*; this is the **field** the report and `score.json` carry, and the deterministic
rule that produces it. Each unit's `cutoff_label` + `cutoff_reason` are computed by
`core/lib/cutoff_label.py` from `merged_at` (tracker metadata), `cutoff_policy.repo_visibility`, and
`cutoff_policy.model_cutoff`, so the rule is testable and identical across runs. No pipeline script
calls it yet: the `blind-eval` skill instructs the orchestrating model to run it and copy the result
into `score.json`.
`cutoff_label ∈ {cutoff-clean, cutoff-unverified}`, evaluated in order:

1. `repo_visibility == private` → `cutoff-clean` (*"private repo — not in public pretraining"*).
2. else if `model_cutoff` **and** `merged_at` are set **and** `merged_at > model_cutoff` (ISO
   string compare) → `cutoff-clean` (*"merged `<merged_at>` after model cutoff `<model_cutoff>`"*).
3. else → `cutoff-unverified`, with the specific reason: *no `model_cutoff` configured* / *merged ≤
   cutoff* / *`merged_at` unknown* / *public repo*.

`python3 core/lib/cutoff_label.py <merged_at> <repo_visibility> <model_cutoff>` prints
`label⇥reason`; importable as `label(merged_at, repo_visibility, model_cutoff) -> (label, reason)`.
The **honesty rule** (§7) keys off this field: when `require_post_cutoff_for_headline` is true, a
headline number should be computed only over `cutoff-clean` units. Today that is a reporting
instruction — the report renders a per-unit chip, but `aggregate_scores.py` does not filter by it.

## 11. `decontam_confidence` — the scored field enum

§8 describes the confidence *idea* in prose; this is the **enum the `score.json` field carries** (and
what the report chips render), aligned to `core/schema/SCORE.schema.json`. It records what the in-run
leak-gate (§4) actually checked, on an axis **orthogonal to `cutoff_label`** (pretraining-cutoff status
now lives entirely in `cutoff_label`, not here):

`decontam_confidence ∈ {auto+curated, auto-only, curated-only, hand-mitigated, nothing-checked}`

| Value | Leak-gate result | Maps from §8's prose |
|---|---|---|
| `auto+curated` | language-aware auto heuristic **and** curated `answer_tokens` both ran, 0 hits (strongest) | `auto-clean` + `curated-clean` together |
| `auto-only` | only the auto heuristic ran (no curated tokens), 0 hits | `auto-clean` |
| `curated-only` | only curated tokens checked (no auto heuristic for this language yet), 0 hits | `curated-clean` |
| `hand-mitigated` | a hit was found and removed before the blind run — disclosed | `hand-mitigated` |
| `nothing-checked` | nothing derivable and none curated → **unverified for contamination** | `nothing-checked` |

Note the refinement vs §8: the "clean" case is split by *which sources* verified it (`auto+curated` /
`auto-only` / `curated-only`), and the old `cutoff-unverified` value is **dropped from this field** — it
belongs to `cutoff_label` (§10), so the two decontamination axes never collide in one field.

---

## Summary — what is code today vs. instructed vs. not built

| Control | Status |
|---|---|
| Fresh-not-fork implementers, no `Skill` tool calls | model-instructed for the PROVE skill; **code** under `mahoraga loop prove` (one fresh container per rollout; there the `Skill` tool is how staged skills reach the arm) |
| History-free (`git archive`) sandbox, opaque-slug check | ✓ code |
| Unit-id strip from SPEC/BR | ◐ code, fails open |
| Implementer kept inside the sandbox | model-instructed for the PROVE skill; **enforced** under `mahoraga loop` (container, egress allowlist, a model-free escape probe in CI) |
| Leak-gate with fork-point subtraction (identifiers in `.claude/skills`) | ✓ code — `NOTHING CHECKED` exits 0; paraphrase, PascalCase (except Go/C#) and SPEC/BR text are not checked |
| Language-aware leak-gate tokens | ✓ code — thresholds in §4 |
| Fail-closed whole-directory derived-skill sanitize | ✓ code |
| Manifest strip-set + zero-residue CI test | ✓ code |
| Whole-tree company-data denylist gate | ✓ code (CI) |
| Pretraining-cutoff labels per unit | ◐ `core/lib/cutoff_label.py` computes the label when called (the model is instructed to call it); the headline is **not** filtered by it in code |
| `decontam_confidence` per unit | ◐ field + report chip exist; the model writes the value, no code computes it |
| Ablation arm (harness vs baseline) | ◐ aggregation + report panel are code. On the skill path, staging and running both arms is model-instructed and has run only with stub scores; under `mahoraga loop` both arms are code-launched and have run with real models on private repos |
| The editor sees only earlier units; its candidate is leak-gated against every held-out unit | ✓ code under `mahoraga loop run` |
| Distributions + sampling-frame disclosure in the report | ✓ code — `distributions`, `selection.json` |

If you find a way to contaminate or game a score, that is an in-scope security report — see
[`../SECURITY.md`](../SECURITY.md).
