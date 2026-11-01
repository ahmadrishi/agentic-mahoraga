---
description: The measured improve loop — the contained proposer writes an always-on overlay from shipped history, and a sealed held-out gate decides whether it is kept. Code-launched, Docker-isolated, resumable.
argument-hint: "[project-id] [--budget-usd N]"
allowed-tools: [Read, Grep, Glob, Bash, Write]
---

Run the closed improve loop on **$ARGUMENTS** (default: the project described by `./PROJECT.yaml`,
which needs a `loop:` block: `inputs_dir`, `build.image`, `build.mounts`, `overlay_dir`). The loop is
code (`${CLAUDE_PLUGIN_ROOT}/core/loop/`); your job is preparation and reporting, never judging.

1. **Units.** List candidate units: merges (or squash commits) on the base branch, oldest first,
   each one ticket, with a usable ticket. You may read tickets; you must **not** read the units'
   diffs, commits or code while doing this.
2. **SPEC/BR.** For every unit without them, write `<inputs_dir>/<full sha>/SPEC.md` and
   `BUSINESS_REQUIREMENT.md` from the **ticket text only**. Remove personal data. Skip tickets about a
   single record, data corrections, and tickets whose requirement lives only in an unreadable
   document. Do not invent requirements.
3. **Preflight.** `${CLAUDE_PLUGIN_ROOT}/cli/mahoraga loop preflight --paid` (the boundary probe plus
   the canary; pass its `canary.json` as `--builtins` below).
4. **Dry run.** `${CLAUDE_PLUGIN_ROOT}/cli/mahoraga loop run --config PROJECT.yaml --campaign <name>
   --units <shas, oldest first> --scorer codex --scorer-model gpt-5.4 --budget-usd <N> --builtins <canary.json> --dry-run`.
   Show the user the split, every drop with its reason, the job count, the projected cost and the
   rule's power. Ask for the budget before spending anything.
5. **Run.** The same command without `--dry-run` (add `--jobs 3` to parallelise). It is resumable:
   on exit 4 (budget, rate or auth), rerun the same command later.
6. **Report** `decision.json` exactly as written: the verdict, mean d, p, the per-unit d and every
   validity fact. A REVERT is "no resolved effect at this power", never "no effect". Never restate a
   KEEP more strongly than the decision.
7. **Promote** only if the user asks: `${CLAUDE_PLUGIN_ROOT}/cli/mahoraga loop promote --config
   PROJECT.yaml --campaign <name>` is interactive: the user runs it in their own terminal, not
   through you (it needs a real terminal and a typed confirmation). It refuses anything but a valid,
   proposer-made, isolated KEEP whose records agree and whose parent is the current overlay.

Exit codes: 0 ok · 2 contamination · 3 fail loud · 4 budget, rate or auth (resume) · 5 INVALID ·
6 identity or state · 64 usage. The sealed rule is in `${CLAUDE_PLUGIN_ROOT}/docs/LOOP.md`.
