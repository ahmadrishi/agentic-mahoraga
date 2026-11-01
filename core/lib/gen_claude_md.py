#!/usr/bin/env python3
"""gen_claude_md.py — deterministic generator of a tight (<200-line) CLAUDE.md from a PROJECT.yaml.

Reads the same config as core/lib/cfgquery.py plus the repo on disk and emits an agent-orientation
CLAUDE.md to stdout (or --out): the project name + a one-line what-it-is, the per-repo build/verify
commands (from repos[].verify.*), the repo layout (from repos[]), a "conventions" pointer to the
forged "<id>-mapping" skill when it exists on disk, and a short GUARD "how we work here" pointer.

stdlib + PyYAML only (the one allowed core dep; no jq/yq). Deterministic (no timestamps/randomness),
grounded (invents no facts), importable (load_config / generate_claude_md / mapping_skill_path) and a
CLI:  python3 core/lib/gen_claude_md.py <PROJECT.yaml> [--out CLAUDE.md]
"""
import argparse, os, sys

import yaml

# Per-repo verify fields rendered, in a fixed order, with their human labels.
_VERIFY = [("build_cmd", "build"), ("typecheck_cmd", "typecheck"), ("test_cmd", "test"), ("success_marker", "success marker")]

_GUARD = """## How we work here (GUARD)

This project ships the GUARD behavioral pack. Follow it:

- **small-diff-surgical-change** — smallest diff that solves the task; touch only what it requires.
- **verification-before-advance** — climb the highest verification rung you can before claiming done.
- **honesty-vocabulary** — close with BUILD-VERIFIED / SMOKE-VERIFIED / UNVERIFIED; never "tested" unless tests ran.

The full pack (assumptions, simplicity, reuse, trace-to-consumer, …) installs with the plugin."""


def load_config(path):
    """Load a PROJECT.yaml into a dict ({} when the file is empty)."""
    with open(path) as fh:
        return yaml.safe_load(fh) or {}


def _get(d, *keys, default=None):
    """Safe nested lookup: _get(cfg, 'project', 'id') -> value or default."""
    cur = d
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur


def mapping_skill_path(cfg, repo_root="."):
    """Configured path to the forged "<id>-mapping" skill dir if it exists on disk under
    skills.source_dir, else None. A relative source_dir is resolved against repo_root only to test
    existence; the returned string is the path as written in the config (what the human sees)."""
    pid, src = _get(cfg, "project", "id"), _get(cfg, "skills", "source_dir")
    if not pid or not src:
        return None
    rel = os.path.join(src, "%s-mapping" % pid)
    probe = rel if os.path.isabs(rel) else os.path.join(repo_root, rel)
    return rel if os.path.isdir(probe) else None


def _verify_block(r):
    rn, lang = r.get("name", "?"), r.get("language", "unknown")
    v = r.get("verify") if isinstance(r.get("verify"), dict) else {}
    rows = ["- %s: `%s`" % (label, v[key]) for key, label in _VERIFY if v.get(key)]
    if not rows:
        rows = ["- no verify commands configured (add `repos[].verify.*` in PROJECT.yaml)"]
    elif not v.get("test_cmd"):
        rows.append("- no `test_cmd`: a pass here is BUILD-VERIFIED, never behavior-verified.")
    return "### %s (%s)\n%s" % (rn, lang, "\n".join(rows))


def generate_claude_md(cfg, repo_root="."):
    """Render the CLAUDE.md text (ending in one newline) from a loaded config dict. repo_root is the
    base for resolving a relative skills.source_dir when probing for the mapping skill."""
    pid = _get(cfg, "project", "id", default="project")
    name = _get(cfg, "project", "name", default=pid)
    root = _get(cfg, "project", "root")
    repos = [x for x in (cfg.get("repos") or []) if isinstance(x, dict)] if isinstance(cfg, dict) else []
    langs = list(dict.fromkeys(r.get("language") for r in repos if r.get("language")))

    meta = ["`%s`" % pid]
    if repos:
        meta.append("%d %s" % (len(repos), "repo" if len(repos) == 1 else "repos"))
    if langs:
        meta.append(", ".join(langs))

    sec = ["# %s\n\n> %s\n\nOrientation for an agent working in this codebase — generated from `PROJECT.yaml`; edit that and regenerate rather than hand-editing here." % (name, " · ".join(meta))]

    if repos:
        rows = "\n".join("- **%s/** — %s" % (r.get("name", "?"), r.get("language", "unknown")) for r in repos)
        sec.append("## Repo layout\n\n%s%s" % (("Under `%s`:\n\n" % root) if root else "", rows))
        blocks = "\n\n".join(_verify_block(r) for r in repos)
        sec.append("## Build & verify\n\nPer repo, from its root. A green build is BUILD-VERIFIED; without a `test_cmd` it is NOT behavior-verified — say so (see honesty-vocabulary below).\n\n%s" % blocks)
    else:
        sec.append("## Repo layout\n\n- (no repos configured — add `repos[]` to PROJECT.yaml)")
        sec.append("## Build & verify\n\nNo repos configured, so no verify commands.")

    skill = mapping_skill_path(cfg, repo_root)
    if skill:
        sec.append("## Conventions\n\nThe real names, statuses, routes and integrations for this codebase are grounded in the **`%s-mapping`** skill (`%s`). Consult it before guessing what something is called — a confident wrong name is worse than looking it up." % (pid, skill))
    else:
        sec.append("## Conventions\n\nNo **`%s-mapping`** skill is present yet. Forge one (the *adapt* step) to ground the real names / statuses / routes / integrations before speccing against them." % pid)

    sec.append(_GUARD)
    return "\n\n".join(sec) + "\n"


def main(argv=None):
    p = argparse.ArgumentParser(prog="gen_claude_md.py", description="Generate a tight CLAUDE.md from a PROJECT.yaml.")
    p.add_argument("config", help="path to the PROJECT.yaml to read")
    p.add_argument("--out", help="write CLAUDE.md here instead of stdout")
    p.add_argument("--repo-root", help="base for resolving a relative skills.source_dir (default: the current directory, matching stage_sandbox.sh)")
    args = p.parse_args(argv)

    if not os.path.isfile(args.config):
        sys.stderr.write("gen_claude_md: config not found: %r\n" % args.config)
        return 2
    repo_root = args.repo_root or "."   # CWD = repo root, matching stage_sandbox.sh / sanitize_skills.sh
    text = generate_claude_md(load_config(args.config), repo_root=repo_root)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        sys.stderr.write("gen_claude_md: wrote %s (%d lines)\n" % (args.out, text.count("\n")))
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
