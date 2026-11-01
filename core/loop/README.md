# `core/loop/` — the closed improve loop

The code that turns IMPROVE from prose into a measured loop: an edit to the agent's always-on
guidance is **kept only when it measurably helps on tickets the loop never learned from**. The sealed
keep/revert rule is in [`docs/LOOP.md`](../../docs/LOOP.md).

**What is here:** the runner and the arm boundary, a code-launched blind PROVE, the kill test, the held-out gate
and the loop itself: `mahoraga loop preflight`, `prove`, `insample`, `gate`, `run`, `promote` and `status`.

| Module | What it does |
|---|---|
| `executor.py` | Runs one headless Claude Code job (Docker = enforced boundary, local = instructed) and classifies it; asserts the init event against what was staged |
| `egress_proxy.py` | The arm's only way out: a CONNECT proxy that allows the model API and logs everything else |
| `scan.py` | Credential / honey / tripwire scans and the symlink + special-file census |
| `preflight.py` | Free checks, the model-free boundary probe, the paid canary (a staged skill fires; a GUARD-sized always-on `CLAUDE.md` is obeyed to its last line) |
| `snapshot.py` | Each arm's staged content (`bare` = none; `pre` = an always-on `CLAUDE.md` with the GUARD pack's full text, plus a floor index generated at the unit's fork) and the derived PROJECT_CONFIG that stages it, with builds wrapped in a network-less container |
| `rollout.py` | One (unit, arm, rep): stage → strip → launch → artifact checks → extract → filter → compile → scan |
| `score.py` | Frozen criteria per unit; one blind, schema-constrained grading session per rollout; `scorer_failed` is None, never 0 |
| `ledger.py` | Append-once rows, runkeys, DONE markers (resume), the USD cap checked before every launch |
| `campaign.py` | The `prove` driver (setup, criteria, implement, score) and the pieces every protocol shares, including the `--jobs` pool (the first failure stops new launches; Ctrl-C cancels the queue) |
| `jobs.py` | What a campaign is configured with: PROJECT.yaml's fields, the job templates (arm, Claude scorer, Codex scorer, editor) and their init expectations, the Codex binary, and the cost priors (each role's paid cost history from the project's other campaigns, pooled into the launch check's 95th percentile) |
| `insample.py` | The kill test: prereg, `pre` k=6, editor candidates (`post_U`: a unit's own unlabelled attempts; `post_P`: earlier units only, labelled), `post` k=3, Rules A/B → `decision.json` |
| `propose.py` | The editor (propose v0): a contained session rewrites the two always-on overlay files from copy-in evidence; validator v0 (surface, caps, content, fork-stable identifiers) with one fed-back retry; tripwire → exit 2 |
| `split.py` | The held-out split: first-parent order (never dates), model-free vetting with every drop's reason, spent units (any campaign's first score) never held out, 6 train / 1 gap / 10 val with the ancestry invariant |
| `decide.py` | The sealed rule as a pure function: v2 current, v1 kept on record (their shas are in [`docs/LOOP.md`](../../docs/LOOP.md)); the re-score agreement and the power model |
| `heldout.py` | `mahoraga loop gate` and `run`: prereg → (`run` only: train evidence → the contained editor writes the candidate) → held-out staging (a leak-gate hit rejects the candidate before any val rollout) → val × {pre, post} × k, a seeded 20% re-scored → the sealed rule → `decision.json` |
| `promote.py` | `mahoraga loop promote`: refuses anything but a valid, proposer-made KEEP whose records agree with the bytes on disk; re-validates at HEAD, shows the diff, needs a typed confirmation; writes the overlay plus `PROVENANCE.json` |
| `stats.py` | G, Δ_U, Δ_P, Rules A/B, the exact sign-flip p and rule v1's effect clauses, all None-aware |
| `report.py` | `calib.json`, the console table, and `final/` rendered by the unchanged `aggregate_scores.py` + `build_report.py` |
| `loop.py` | The `mahoraga loop` CLI |
| `prompts/*.md` | The implement, criteria, grade and propose prompts (the first three identical in every arm; all hashed into the campaign identity) |

```bash
bash cli/mahoraga loop preflight              # free: docker, images, binary hash, boundary probe
MAHORAGA_TOKEN_FILE=~/.config/mahoraga/token \
  bash cli/mahoraga loop preflight --paid     # + the skill canary (a few cents on haiku)

# a blind PROVE: needs a PROJECT.yaml with a `loop:` block (inputs_dir, build.image, build.mounts)
bash cli/mahoraga loop prove --config PROJECT.yaml --campaign c1 --units <sha>,<sha> --budget-usd 40 --dry-run
MAHORAGA_ANTHROPIC_KEY_FILE=~/.config/mahoraga/anthropic-key \
  bash cli/mahoraga loop prove --config PROJECT.yaml --campaign c1 --units <sha>,<sha> --arms bare,pre --k 3 --budget-usd 40
```

The kill test takes four units in history order, an editor model and, for a decision that
can count, the Codex scorer (`MAHORAGA_OPENAI_KEY_FILE`):

```bash
MAHORAGA_TOKEN_FILE=~/.config/mahoraga/claude-token MAHORAGA_OPENAI_KEY_FILE=~/.config/mahoraga/openai-key \
  bash cli/mahoraga loop insample --config PROJECT.yaml --campaign k1 --units u1,u2,u3,u4 --scorer codex --budget-usd 20
```

The held-out gate judges a frozen overlay (`--candidate DIR`, practice.md + conventions.md) on
units it was not derived from; `--dry-run` prints the split, every drop, the job count and the rule's
power at the calibrated noise, with no model call:

```bash
bash cli/mahoraga loop gate --config PROJECT.yaml --campaign g1 --units <shas…> --candidate ./overlay --scorer codex --budget-usd 20 --dry-run
bash cli/mahoraga loop status --project <id> --campaign g1      # progress only: status never prints a score
```

The loop is the gate with the candidate written in-run: train evidence (the parent's attempts
on the train units, scored), then the contained editor, then the same held-out measurement. Only a
KEEP of such a candidate can be promoted, and `promote` asks for a typed confirmation:

```bash
bash cli/mahoraga loop run --config PROJECT.yaml --campaign r1 --units <shas, oldest first> --scorer codex \
  --scorer-model gpt-5.4 --budget-usd 45 --builtins canary.json --jobs 3 --dry-run
bash cli/mahoraga loop promote --config PROJECT.yaml --campaign r1 --dry-run   # the checks and the diff; writes nothing
```

`--dry-run` prepares every unit, builds the snapshots and dry-stages each arm through the leak gate,
with no model call. Rerunning the same command resumes; a changed model, binary, image, template or
config on the same campaign is exit 6. `prove`'s default scorer is Claude, the implementer's own
family, so a `prove` run is **descriptive**: it measures cost, variance and skill use; it decides
nothing. `gate` and `run` decide only with another family's scorer (`--scorer codex`).

**Exit codes:** 0 ok · 2 contamination (leak, secret, boundary breach) · 3 fail loud · 4 budget, rate
or auth · 5 INVALID · 6 identity or state · 64 usage.

**Rules for this package:** stdlib plus PyYAML (the one allow-listed dependency, used only by
`snapshot.derive_config` and `jobs.py`'s config reader); its own LOC cap in `scripts/loc-budget.py` (raised only
with a written reason); a blocking complexity ceiling. The loop wraps the `core/lib`
scripts and adds its guards around them; it changes them only for a reviewed fix it needs.

**Attribution.** Several mechanisms built here are ported as *ideas* from Google Research's Harness²
([arXiv:2610.14224](https://arxiv.org/abs/2610.14224), CC BY 4.0;
[google-research/harness2](https://github.com/google-research/harness2), Apache-2.0): the budget
ledger and campaign identity (`ledger.py`, `campaign.py`), validate-and-retry (`propose.py`), the
invariant/domain split (as the two overlay files, `practice.md` and `conventions.md`), prefix-only
visibility (the chronological split, `split.py`) and the context tripwire (`propose.tripwire`). Its
edit-verdict vocabulary is not built. No Harness² code is copied (Google Research, [arXiv 2610.14224](https://arxiv.org/abs/2610.14224)).
