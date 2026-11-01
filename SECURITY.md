<!-- Identity is defined once in branding.yaml; this file mirrors it. -->

# Security Policy

Agentic Mahoraga's core function is to **auto-generate and auto-edit code-executing skills inside
your repository**, and its Prove stage sends **your private merged work to a third-party model API**.
That makes security a design constraint, not an afterthought. This document
states the threat model, the controls, and how to report a vulnerability.

> Status: pre-1.0. The controls below that are **enforced in code** are marked *(enforced)*; the ones
> that are **process/discipline** are marked *(process)*. We do not describe a discipline as a hard
> control.

Companion docs: [`docs/DECONTAMINATION.md`](docs/DECONTAMINATION.md) (the eval's integrity),
[`docs/ADAPTER-CONTRACT.md`](docs/ADAPTER-CONTRACT.md) (the reviewed adapter surface),
[`docs/SKILL-SCHEMA.md`](docs/SKILL-SCHEMA.md) (the least-privilege frontmatter contract), and
[`CONTRIBUTING.md`](CONTRIBUTING.md) (the contributor-facing security checklist). The docs index is
[`docs/README.md`](docs/README.md).

---

## 1. Threat model — what could go wrong

| Asset at risk | Threat |
|---|---|
| Your source repositories | A forged or edited skill executes code, writes files, or exfiltrates data while running in your checkout. |
| Your private merged work | Prove uploads diffs, specs, and business requirements to a model API. |
| Every downstream user | A community adapter or a plugin update ships executable code that runs in *their* repo. |
| The eval's integrity | Contaminated inputs make a score meaningless (see [`docs/DECONTAMINATION.md`](docs/DECONTAMINATION.md)). |

Three of these are supply-chain or data-exposure risks; the fourth is measurement integrity, covered
separately by the decontamination methodology.

---

## 2. Least-privilege skills *(process)*

The emitted-skill schema ([`core/schema/SKILL.schema.md`](core/schema/SKILL.schema.md)) recommends
an `allowed-tools` list in every skill's frontmatter. The intended posture:

- **Default deny network and shell.** A skill gets `Read`, `Grep`, `Glob` unless its job genuinely
  needs more. `mahoraga init` drafts this as `PROJECT.yaml → security.default_allowed_tools`, but
  **no code reads that key yet**, and the deterministic scan emits no frontmatter — setting
  `allowed-tools` on a forged skill is a review responsibility.
- **The forge is read-only on your source, tracker, and docs — by instruction.** In your repo it writes
  only the forged skill files and `CLAUDE.md` (plus working files, such as the harvested corpus, in its
  scratchpad). The rule lives in the forge prose; `security.forge_read_only`
  is drafted by `init` but read by no code, and the forge skills declare `Write`/`Edit` (they must,
  to write the skill).
- **No lint checks a forged skill's privileges.** The conformance lint checks structure only. The
  schema gate ([`scripts/skill-schema-lint.py`](scripts/skill-schema-lint.py)) **warns** when a
  behavioral (`kind: guard`) skill declares no `allowed-tools`, and CI runs it over Mahoraga's own
  `skills/` only. The frontmatter contract is [`docs/SKILL-SCHEMA.md`](docs/SKILL-SCHEMA.md) (§1);
  the forge that emits it is [`docs/FORGING.md`](docs/FORGING.md).

If a skill needs a broader tool (say, a shell command to run a build), that is a visible, reviewable
line in its frontmatter — not an implicit capability.

## 3. Human-diff approval is the gate — but not the only control *(process; enforced for the loop)*

Every skill **add or edit** produced by Adapt or `/mahoraga-improve` is meant to reach you as a
**diff you approve** before it lands. The commands instruct the model to do this; what actually stops
a write is Claude Code's own permission prompt — which is **absent** in bypass-permissions or headless
runs, so run Adapt and Improve with prompts on. This is the primary human checkpoint. It is necessary
but **not sufficient on its own** — a reviewer can miss a subtle change — so it is backed by the
automated gates below.

**The measured loop moves the gate to `mahoraga loop promote`** *(enforced)*. The loop's editor
writes only a candidate inside its own campaign directory; nothing reaches your project until
`promote` writes it. `promote` refuses unless the campaign's decision is a valid KEEP of a candidate
the contained proposer wrote, measured with enforced isolation and not a stub run, with its records
agreeing with the bytes on disk. It then re-validates the candidate against your repo's HEAD, shows
the diff and needs a typed confirmation at a terminal. There is no override flag.

## 4. Supply chain *(process, hardening in progress)*

- **SHA-pinned marketplace *(planned)*.** The public catalog entry will pin the plugin to a **commit
  SHA**, not a moving tag, so an install resolves to bytes you can audit. Today the in-repo
  marketplace's source is the repo itself (`"./"`).
- **Signed releases *(planned)*.** Releases are not signed yet.
- **Executable-surface changes are gated.** Any change to **hooks or core** — code that runs with no
  per-invocation approval — requires a [`CHANGELOG.md`](CHANGELOG.md) entry and an explicit review
  checkpoint. A version bump must **never** silently push new executable hooks into installed repos.
- **No undeclared dependencies.** The core is held to a committed dependency allowlist
  ([`deps-allowlist.txt`](deps-allowlist.txt), checked by
  [`scripts/check-deps-allowlist.py`](scripts/check-deps-allowlist.py)) *(enforced)*. Adding a
  dependency fails CI until the allowlist is updated in the same change, so a new third-party package
  cannot slip in unreviewed.
- **No company/private data in the tree.** [`scripts/leak-scan.sh`](scripts/leak-scan.sh) greps the
  tracked files for credential and token shapes, personal paths and private-host markers, and fails CI on
  any hit *(enforced)*. It reads the tracked regular files (contents, binary files included) and matches
  their names, not history. A list it cannot parse, or a grep that errors, is exit 3, never a pass. In CI
  a finding prints its location only, never the matched text. You can add patterns that name your own
  organisation with a private list (`$LEAK_SCAN_EXTRA`, or `~/.config/mahoraga/leak-scan.extra`; one
  `NAME | fail|warn | ci|cs | ERE` line per pattern). Without a list the scan runs the generic layer and says
  so, and `LEAK_SCAN_REQUIRE_EXTRA=1` makes a missing list fail instead. Pull requests from forks get no CI
  secret, so they run the generic layer. The scan runs in CI on every push and pull request — after the
  push, not before it (there is no pre-push hook), so run it locally first (§7).

## 5. Community adapters are executable code *(enforced + process)*

Adapters ([`docs/ADAPTER-CONTRACT.md`](docs/ADAPTER-CONTRACT.md)) run in **every user's repo**. The
growth path — community-contributed tracker adapters — must not become an un-vetted supply-chain
vector. Every contributed adapter passes a **contribution security review** before merge:

1. **No undeclared network or shell.** An adapter declares the tools/network it needs; anything
   undeclared is a finding.
2. **No secret exfiltration.** Config, tokens, and diffs must stay on the machine except for the one
   declared destination (a vendor API the adapter is explicitly a client for).
3. **Reads config, not literals.** Every hostname, key, and project id comes from `PROJECT.yaml`.
   CI checks this coarsely: the adapter gate below flags a literal host handed to a network tool,
   and leak-scan denylists *known-private* hosts — neither proves the absence of every literal.
4. **A fixture-backed CI test** of the adapter before it is trusted — the rule for new adapters;
   not yet true of every shipped one (see [`CONTRIBUTING.md`](CONTRIBUTING.md)).

### Adapter security review *(enforced)*

The mechanical part of the first three is backed by an automated static gate,
[`scripts/adapter-security-check.sh`](scripts/adapter-security-check.sh), run over every `*.sh` under
`core/adapters/` in CI (and locally, see §7). Why a dedicated gate: an adapter is **executable shell
that runs unattended in every downstream repo**, so a single contributed file is a supply-chain foothold —
it can phone home, run an attacker-supplied string, or read a secret and send it out. The gate scans for
the shapes that betray those, and **fails the build with the offending `file:line`**:

- **Raw network to a literal host** — `curl`/`wget`/`nc`/`ncat`/`ssh`/`scp` targeting an
  `http(s)://<literal-host>`, a literal IP, or a literal `user@host`. `git` and `gh` are allowed (they
  legitimately reach a host), and a host that comes from config (`curl "$base_url/…"`) is allowed. What
  is **not** allowed is a vendor host baked into code — that is the "reads config, not literals" rule
  made mechanical, complementing leak-scan's denylist of *known-private* hosts with a shape that catches
  *any* literal one.
- **`eval` of shell/tool input** — `eval` (or a Python `eval(`) is an arbitrary-code surface an adapter
  never needs; any use is a finding.
- **Secret-exfiltration shapes** — a secret-looking value (`$…TOKEN`/`SECRET`/`PASSWORD`/`…KEY`/
  `CREDENTIAL`) handed to `base64` or piped into a network sink; or reading a credential/key file
  (`~/.ssh`, `id_rsa`, `.env`, `.aws/credentials`, `.netrc`, `.git-credentials`) on a line that also
  egresses data.

It is a **coarse, high-signal net, not a full analyzer** — it is line-based and comment-aware (prose that
merely mentions a red flag, including code comments, does not trip it), and it errs toward flagging. A
clean adapter (local `git` + `gh` + config reads) passes; the built-in adapters pass. It does **not**
replace the human diff review (§3) or the sandboxed fixture run — it makes the cheap, mechanical checks
un-skippable so review effort goes to judgment.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the contributor-facing checklist.

## 5b. The improve loop's runner *(enforced on Linux Docker)*

`mahoraga loop` ([`core/loop/README.md`](core/loop/README.md)) is the Mahoraga code that launches Claude
Code and Codex itself. With the default `--runner docker`, every model session it starts runs in the
boundary below: the implementer arms, the scorer and the editor of `preflight --paid`, `prove`,
`insample`, `gate` and `run`. `--runner local` has no boundary; such a campaign is recorded as
`isolation: instructed` and can never be promoted.

- **Credential.** An Anthropic API key from a `0600` file you own named by `MAHORAGA_ANTHROPIC_KEY_FILE`
  (passed to the arm as `ANTHROPIC_API_KEY`, billed per token), or a subscription token from
  `CLAUDE_CODE_OAUTH_TOKEN` (e.g. `claude setup-token`) or a `0600` file named by `MAHORAGA_TOKEN_FILE`. Mahoraga never reads Claude Code's credentials file.
  Inside the arm the token is readable via `/proc`, so every transcript is scanned for it, redacted on
  disk, and a hit makes the run invalid. Using a subscription plan for automated runs is subject to
  that plan's terms — check them before any batch run.
- **Boundary.** Docker with an internal network, an allowlist egress proxy (the model API only), a
  read-only root and dropped capabilities; see `docs/DECONTAMINATION.md` §2. Proven by a free escape
  probe in CI. Docker-group membership is root-equivalent — run it only where that is acceptable.
- **No permission bypass.** Arms run with `--permission-mode acceptEdits`, an explicit `--tools` set
  and no MCP servers; `--dangerously-skip-permissions` is never used.
- **The scorer** (Codex with `--scorer codex`, checked by `loop preflight --scorer-check`) runs in the
  same boundary with only its view (read-only) and output dir mounted and only `api.openai.com` allowed. Its OpenAI key comes from a `0600`
  file named by `MAHORAGA_OPENAI_KEY_FILE`, passes by env name, and is scanned for and redacted like the
  Claude token. Codex's code-execution helper is not mounted, so the scorer cannot run code. The
  default Claude scorer (every campaign command) is tools-less and schema-constrained in the same
  boundary; it shares the implementer's family, so it decides nothing (`gate`/`run` are INVALID with
  it, `insample` is advisory).
- **The editor** (`loop run`, `loop insample`) gets `Read`, `Glob`, `Grep`, `Edit` and `Write`, no
  `Bash`, and a workspace built by copy-in only: the parent overlay, a repo tree without `.git`, and
  evidence (earlier units only, in `run` and in `insample`'s labelled arm; in its unlabelled arm, the
  same unit's SPEC/BR and unscored attempts). Its output must pass a validator (exactly the two overlay files, size
  caps, no `file:line`, eval tells or environment advice); a unit id, a honey token or a score-file
  name in it is a tripwire (exit 2). Before any held-out spend, the candidate is staged through every held-out
  unit's leak gate, and a hit rejects it with no feedback.
- **Spend.** `--budget-usd` is checked before every launch against the ledger, counting jobs in
  flight. Claude sessions enforce their own per-job cap; Codex scorer sessions do not, so a campaign
  can overrun its cap by a few cents per scoring session in flight.

## 6. Data governance — what leaves your machine *(process)*

Prove sends **private merged changes plus their business requirements to a third-party model API**.
Be explicit with your team about this before pointing Mahoraga at proprietary code:

- **What leaves:** the reference diff, the fetched spec, and the business requirement for each
  selected unit, plus the forged skills, are sent to the configured model API as prompt content.
  Under `mahoraga loop`, the implementer (Anthropic) sees the unit's fork-point tree, SPEC/BR and its
  arm's staged guidance;
  the scorer sees SPEC/BR, the criteria, the human diff and the candidate's diff, which with
  `--scorer codex` go to **OpenAI**; the editor (Anthropic) sees, in `run`, earlier units' SPEC/BR and
  human diffs with up to one scored attempt each (its criteria and their statuses), and a repo tree.
- **What does not:** credentials and obvious secrets are redacted from generated reports before they
  are written. Runtime output (`eval-run/`, sandboxes, fetched specs/diffs) stays on disk, but
  Mahoraga does **not** add ignore rules to your project — add `eval-run/` and your run/sandbox dirs
  to your `.gitignore` yourself (Mahoraga's own repo ignores them).
- **Retention and posture** are governed by **your model provider's** terms — review them. Mahoraga
  itself keeps run artifacts only under your local run directory.
- **Cold-start path.** Evaluate trust *before* exposing proprietary code: run first on a sample or
  public repository, then decide. The slash-command path runs inside your Claude Code session, under
  its model and provider settings. `mahoraga loop` picks its own models (`--model`, `--scorer`,
  `--scorer-model`, `--editor-model`) and launches its own sessions with the credential you give it.
  The models are part of the campaign's identity: resuming with a different one is refused (exit 6).

## 7. Running the security gates locally

All gates are standard-library / POSIX-only (no install step) and also run in CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)):

```bash
bash   scripts/leak-scan.sh                  # company/private-data denylist (generic + your private list) — run before you push
bash   scripts/adapter-security-check.sh     # adapter supply-chain gate (literal hosts / eval / secret egress)
python3 scripts/check-deps-allowlist.py      # no dependency outside deps-allowlist.txt
python3 scripts/loc-budget.py                # core stays within the legibility budget
python3 scripts/complexity-ceiling.py        # runaway-complexity report for core/lib (non-blocking in CI)
bash   scripts/zero-residue-sandbox-test.sh  # eval meta-skills are stripped from blind sandboxes
```

## 8. Reporting a vulnerability

**Please do not open a public issue for a security report.**

- Use **GitHub → Security → Report a vulnerability** (private security advisory) on the repository at
  <https://github.com/ahmadrishi/agentic-mahoraga> — this is the supported channel today.
- Include a description, affected version/commit, reproduction steps, and impact.
- We aim to acknowledge a report within a few business days and to coordinate a fix and disclosure
  timeline with you.

Reports that concern the **eval's integrity** (a way to contaminate or game a score) are in scope and
welcome — see [`docs/DECONTAMINATION.md`](docs/DECONTAMINATION.md) for the model we are hardening, and
[`docs/EVAL-RUBRIC.md`](docs/EVAL-RUBRIC.md) for the invariants a defensible number must satisfy.
