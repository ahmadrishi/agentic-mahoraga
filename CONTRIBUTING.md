<!-- Identity is defined once in branding.yaml; this file mirrors it. -->

# Contributing to Agentic Mahoraga

Thanks for helping build this. The project is **early (pre-1.0)** and its whole value rests on
*trustworthy measurement*, so contributions are held to two bars above the usual: **security** (your
code runs in every user's repo) and the **legibility budget** (the core must stay small enough to
read). CI enforces the security gates, the dependency allowlist, and the LOC budget; the complexity
ceiling is reported but non-blocking. You can run every check locally before you push.

By contributing you agree your work is released under the project [`LICENSE`](LICENSE) (MIT).

---

## Ways to contribute

- **New tracker adapters** are small and the most welcome contribution — see
  [`docs/ADAPTER-CONTRACT.md`](docs/ADAPTER-CONTRACT.md). A tracker adapter is genuinely a small,
  self-contained module. Spec adapters vary a lot in difficulty; visual specs are out of scope.
- **GUARD disciplines / gates** — a stack-agnostic mistake models make, plus the gate that catches it.
- **Portability and language coverage** — e.g. the language-aware decontamination heuristics
  ([`docs/DECONTAMINATION.md`](docs/DECONTAMINATION.md) §4).
- **Docs, examples, and honest bug reports.**

If you are planning something larger than a bug fix or a single adapter, **open an issue first** so we
can agree on the shape before you spend the effort.

---

## Development setup

The gates are **standard-library / POSIX only** — no install step. The core's one third-party dependency
is PyYAML (it reads `PROJECT.yaml`; `pip install pyyaml`). You need `bash`, `git`, and `python3` (3.8+).

```bash
git clone <your-fork-url> && cd agentic-mahoraga
# run the full local gate suite (same as CI):
bash    scripts/leak-scan.sh                  # company/private-data denylist — must be clean
bash    scripts/adapter-security-check.sh     # adapter supply-chain gate — must be clean
python3 scripts/check-deps-allowlist.py       # no dependency outside deps-allowlist.txt
python3 scripts/loc-budget.py                 # core within the legibility budget
python3 scripts/complexity-ceiling.py         # runaway-complexity report for core/lib (non-blocking)
python3 scripts/skill-schema-lint.py          # every skills/**/SKILL.md meets the emitted-skill schema
bash    scripts/zero-residue-sandbox-test.sh  # eval meta-skills are stripped from blind sandboxes
# the mechanical quickstart (stub scores, no model) + the rest of the test suite:
bash    tests/quickstart_test.sh              # init -> mapping scan -> stub two-arm report, on a repo copy
for t in tests/*_test.sh; do bash "$t"; done  # the per-feature tests (quickstart + mapping-forge need node and fail without it)
# syntax:
find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \;
find . -name '*.py' -not -path './.git/*' -exec python3 -m py_compile {} \;
```

A **forged** mapping or spec skill additionally passes the container gate — run it on the forged
skill's directory (Node stdlib, no install). It is not for Mahoraga's own `skills/` (guard/meta
kinds): those fail its spec-blueprint checks by design and are gated by `skill-schema-lint.py`.

```bash
node scripts/conformance-lint.mjs <forged-skill-dir> --repo <repo>   # PASS or the exact violations
```

CI runs the gates and tests above on every push and pull request
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)); `quickstart_test.sh` and
`mapping_forge_python_test.sh` need Node and fail without it (CI's ubuntu runner has it).

---

## The two hard bars

### 1. Zero company / private data

The repo is public and **must contain zero company or private data**. [`scripts/leak-scan.sh`](scripts/leak-scan.sh)
greps the tracked files for credential and token shapes, personal paths and private-host markers, and
**fails CI** on any hit (the project's CI may also apply a private list of organisation-specific names, so
keep examples vendor-neutral even where the generic scan would pass) — CI runs after the push, so run it locally before you push. Use **generic, vendor-neutral** examples in code and docs (a fictional
`billing` or `payments` module; GitHub + `npm`/`pytest`); never a real internal hostname, ticket key,
credential path, or personal home path. Every hostname/key/project id in an adapter must come from
`PROJECT.yaml`, never a literal in code.

### 2. The legibility budget

The core is deliberately small so a newcomer can read it. Two enforced checks and one reported one:

- **Dependency allowlist** — adding a runtime dependency fails CI until you add it to
  [`deps-allowlist.txt`](deps-allowlist.txt) **in the same change**, with a justification. The core's
  only permitted third-party dependency is PyYAML.
- **LOC budget** — a per-file cap and a `core/lib` total cap
  ([`scripts/loc-budget.py`](scripts/loc-budget.py)). Split a file rather than let it balloon.
- **Complexity ceiling** — a per-function cyclomatic / nesting / length ceiling over `core/lib`
  ([`scripts/complexity-ceiling.py`](scripts/complexity-ceiling.py)). **Non-blocking in CI** — some
  ported `core/lib` functions are over it today — so don't add new offenders; split a tangled
  function into named steps.

If you must raise a threshold, do it **visibly in the same change** with a one-line justification —
the point is that the budget moves only on purpose.

---

## Contributing an adapter (security review)

Adapters are executable code that runs in **every user's repo**, so each one passes a **contribution
security review** before merge (see [`SECURITY.md`](SECURITY.md) §5). Your adapter must:

1. **Declare** every tool and network destination it uses; anything undeclared is a finding.
2. **Not exfiltrate secrets** — config, tokens, and diffs stay local except the one declared vendor
   destination the adapter is explicitly a client for.
3. **Read all config from `PROJECT.yaml`** — no literal vendor hostnames, keys, or project ids in code.
4. **Ship a fixture-backed test** so the core stays vendor-agnostic and CI can exercise the adapter.
   This is required for new adapters, but several shipped ones still lack a test — the `jira` tracker
   (merged without one), the `file` and `none` trackers and all three spec adapters (`markdown`, `issue-body`,
   `none`) — tests for these are welcome contributions.

**Run the adapter gate before you submit** — it is the mechanical half of the review, so clear it
locally rather than in CI:

```bash
bash scripts/adapter-security-check.sh                 # scans every core/adapters/**/*.sh
bash scripts/adapter-security-check.sh core/adapters/tracker/your-adapter.sh   # or just yours
```

It fails with a `file:line` on a raw-network-to-a-literal-host, an `eval` of input, or a
secret-exfiltration shape (see [`SECURITY.md`](SECURITY.md) §5 for the full list and rationale). `git`
and `gh` are fine; a host read from config (`curl "$base_url/…"`) is fine — a **literal** vendor host,
key, or IP baked into code is not. The gate is coarse by design; passing it is necessary, not
sufficient — the human diff review and the fixture run still apply.

Implement the family's functions exactly as in the [adapter contract](docs/ADAPTER-CONTRACT.md).

---

## Emitted skills

Any skill you add or that the forge emits must conform to the **semver'd emitted-skill contract** —
normative source [`core/schema/SKILL.schema.md`](core/schema/SKILL.schema.md), explained in
[`docs/SKILL-SCHEMA.md`](docs/SKILL-SCHEMA.md): valid frontmatter, a least-privilege `allowed-tools`
list (recommended), the size budget, references one level deep, and — for forged mapping/spec
skills — `file:line` grounding for every system noun (or an explicit `UNVERIFIED` marker). A
confident wrong name is worse than no skill. Two lints check parts of this:

- **Schema lint** ([`scripts/skill-schema-lint.py`](scripts/skill-schema-lint.py)) — a CI gate over
  Mahoraga's own `skills/**/SKILL.md` (run it by hand on a forged skill's parent dir): `name` valid,
  ≤ 64 chars, matches its folder and is not reserved (`anthropic`/`claude`); `description` present
  and ≤ 1024 chars; `mahoraga.kind` in `{guard, mapping, spec, meta}`; body ≤ 500 lines. It
  **warns** if a `kind: guard` skill omits `allowed-tools`.
- **Conformance lint** ([`scripts/conformance-lint.mjs`](scripts/conformance-lint.mjs)) — for forged
  skills only. **Mapping kind:** `mahoraga.grounding: file-line`, a `name | kind | evidence` table
  (in that order, ≥ 3 rows) whose evidence cells match `path:line` or are exactly `UNVERIFIED`, and a
  `Regenerate:` line or `mahoraga.provenance` key, and that every `path:line` in every names table
  resolves (`--repo <dir>` per repo, default the dir holding the skill's `.claude/`, else the nearest git root): the file is source inside the repo (not the skill's own files), the line exists,
  and the row's first word is on it. Not the
  frontmatter, size, links or `allowed-tools`. **Spec kind:** the fixed
  8-reference + 2-template manifest, required sections and phases, description length and voice,
  cross-links and anchors. Neither lint judges truth: a wrong fact passes, which is why forged
  skills also get the [forge's](docs/FORGING.md) adversarial audit (model-instructed).

A new Mahoraga-own **meta**-skill (one that describes the eval) must also be added to
[`core/schema/STRIP_SET.manifest`](core/schema/STRIP_SET.manifest).

---

## Pull-request checklist

- [ ] The full local gate suite above passes (including `skill-schema-lint.py` and `quickstart_test.sh`).
- [ ] New/changed code uses only generic, vendor-neutral examples (leak-scan is clean).
- [ ] A new dependency (if any) is added to `deps-allowlist.txt` in this PR, with justification.
- [ ] A new adapter declares its tools/network, reads config from `PROJECT.yaml`, has a fixture test,
      and passes `scripts/adapter-security-check.sh`.
- [ ] A new/edited skill passes `skill-schema-lint.py` (and `conformance-lint.mjs` if it is a forged
      mapping/spec skill); a new meta-skill is in `STRIP_SET.manifest`.
- [ ] A change to **hooks or core** (runs without per-invocation approval) has a `CHANGELOG.md` entry.
- [ ] Docs and cross-links updated; claims are honest (`shipped` vs `in progress`), not aspirational.

## Commits

- Keep commits focused and messages descriptive (what changed and why).
- We are considering a sign-off / DCO requirement for a later release; watch `CHANGELOG.md`.
- Be excellent to each other — see [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
