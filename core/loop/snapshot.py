"""snapshot.py — the skill set each arm is staged with, and the derived PROJECT_CONFIG that stages it.

  tree_hash      sha256 over the sorted lines `relpath\\0sha256(bytes)\\n`
  fork_tree      `git archive <fork>` under loop.root, outside any work tree, so the floor scan walks
                 real files instead of trusting an empty `git ls-files` (red-team F-D)
  floor_rows     mapping_scan.py at the unit's own fork; exit 3 or zero rows is fatal
  materialize    `bare` = nothing; `pre` = an ALWAYS-ON `CLAUDE.md` (the pinned GUARD pack's full text +
                 a pointer to the floor) and the floor index, minus every row that holds a dropped token
                 (the unit's curated tokens, and the gate's case-variant hits). Always-on, because the
                 first real run showed Sonnet invoking a staged skill in 0 of 6 rollouts: content
                 behind the Skill tool never reached the model
  derive_config  the loop's only YAML writer: a copy of PROJECT.yaml that points at the arm's skills
                 and the loop's sandbox root, with each verify command wrapped in a network-less
                 container, so AI-written code never builds on the host
"""
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess

import executor

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
GUARD = os.path.join(REPO, "skills", "guard")
MAPPING = os.path.join(REPO, "core", "lib", "mapping_scan.py")
FLOOR_SKILL = """---
name: %(name)s
description: Index of the %(n)d classes, methods, constants and types defined in this codebase, each with its file:line. Use it to find where a name is defined, or whether something already exists, before searching or changing the code.
---

# Where names are defined

`names.md`, next to this file, has one row per name defined in the %(lang)s source:
`| name | kind | file:line |`. Grep it for a name, or part of one, then open the file at that line.
"""
ALWAYS_ON = """# Working agreements for this codebase

## Where names are defined

`.claude/skills/%(floor)s/names.md` lists the %(n)d classes, methods, constants and types defined in
the %(lang)s source, one row each: `| name | kind | file:line |`. Grep it for a name, or part of one,
before searching the tree, to find where something is defined or whether it already exists.
%(overlay)s%(guard)s"""
OVERLAY = {"practice.md": "## Process habits for this codebase", "conventions.md": "## Conventions of this codebase"}


def overlay_text(odir):
    """The editable overlay: two files, appended as sections of the always-on file."""
    parts = []
    for name, head in OVERLAY.items():
        path = os.path.join(odir or "", name)
        text = open(path).read().strip() if odir and os.path.isfile(path) else ""
        if text:
            parts.append("\n%s\n\n%s\n" % (head, text))
    return "".join(parts)


def guard_text():
    """The GUARD pack's full text for the always-on file: frontmatter and cross-links dropped,
    headings demoted one level so each skill is a section."""
    out = []
    for name in sorted(os.listdir(GUARD)):
        path = os.path.join(GUARD, name, "SKILL.md")
        if os.path.isfile(path):
            body = open(path).read().split("---", 2)[2]
            body = re.split(r"(?m)^## Related skills", body)[0].strip()
            out.append(re.sub(r"(?m)^(#+) ", r"#\1 ", body))
    return "".join("\n" + b + "\n" for b in out)


def tree_hash(root):
    lines = []
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for f in files:
            p = os.path.join(dirpath, f)
            lines.append("%s\0%s\n" % (os.path.relpath(p, root), executor.sha256_file(p)))
    return hashlib.sha256("".join(sorted(lines)).encode()).hexdigest()


def fork_tree(repo_dir, fork, dst):
    if not os.path.isdir(dst):
        part = dst + ".part"
        shutil.rmtree(part, ignore_errors=True)
        os.makedirs(part)
        subprocess.run("git -C %s archive %s | tar -x -C %s" % (shlex.quote(repo_dir), fork, shlex.quote(part)),
                       shell=True, check=True)
        os.replace(part, dst)
    return dst


def floor_rows(tree, lang):
    r = subprocess.run(["python3", MAPPING, tree, "--lang", lang, "--format", "json"], capture_output=True, text=True)
    if r.returncode:
        raise executor.LoopError(3, "floor: mapping_scan exit %d: %s" % (r.returncode, r.stderr.strip()[-300:]))
    rows = json.loads(r.stdout)
    if not rows:
        raise executor.LoopError(3, "floor: mapping_scan found no names at the fork (%s)" % tree)
    return rows


def _row(r):
    return "| %s | %s | %s |\n" % (r["name"], r["kind"], r["evidence"])


def materialize(dst, arm, project, lang="", rows=(), drop=(), overlay=None):
    """Write arm's skills dir at dst; return its manifest. Every arm but `bare` is always-on, with the
    optional overlay dir's two files appended. Files are made read-only (an accident guard)."""
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst)
    low, kept = [t.lower() for t in drop if t], []
    if arm != "bare":
        kept = [r for r in rows if not any(t in _row(r).lower() for t in low)]
        with open(os.path.join(dst, "CLAUDE.md"), "w") as fh:  # staged to the sandbox root (index_file)
            fh.write(ALWAYS_ON % {"floor": project + "-floor", "n": len(kept), "lang": lang, "guard": guard_text(),
                                  "overlay": overlay_text(overlay)})
        floor = os.path.join(dst, project + "-floor")
        os.makedirs(floor)
        with open(os.path.join(floor, "SKILL.md"), "w") as fh:
            fh.write(FLOOR_SKILL % {"name": project + "-floor", "n": len(kept), "lang": lang})
        with open(os.path.join(floor, "names.md"), "w") as fh:
            fh.write("| name | kind | evidence |\n|---|---|---|\n" + "".join(_row(r) for r in kept))
    for dirpath, _, files in os.walk(dst):
        for f in files:
            os.chmod(os.path.join(dirpath, f), 0o444)
    always_on = os.path.join(dst, "CLAUDE.md")
    return {"arm": arm, "hash": tree_hash(dst), "skills": sorted(d for d in os.listdir(dst) if os.path.isdir(os.path.join(dst, d))),
            "always_on_bytes": os.path.getsize(always_on) if os.path.isfile(always_on) else 0,
            "overlay_sha": tree_hash(overlay) if overlay else None,
            "floor_rows": len(kept), "floor_dropped": len(rows) - len(kept) if arm != "bare" else 0}


def wrap(cmd, build):
    """`cmd` run inside build['image'] with no network, the repo at /w and build['mounts'] read-only."""
    mounts = "".join(" --mount type=bind,src=%s,dst=%s,readonly" % tuple(m.split(":", 1)) for m in build.get("mounts", []))
    return ('docker run --rm --network none --user %d:%d --cap-drop ALL --security-opt no-new-privileges '
            '--read-only --mount type=tmpfs,dst=/tmp -e HOME=/tmp --mount type=bind,src="$PWD",dst=/w%s -w /w %s bash -lc %s'
            % (os.getuid(), os.getgid(), mounts, build["image"], shlex.quote(cmd)))


def derive_config(src, out, skills_dir, sandbox_root, build=None):
    import yaml  # the loop's only YAML writer; importing here keeps `loop preflight` stdlib-only
    d = yaml.safe_load(open(src)) or {}
    s = d.setdefault("skills", {})
    s["source_dir"], s["derived_skills"] = skills_dir, []
    s.pop("index_file", None)
    if os.path.isfile(os.path.join(skills_dir, "CLAUDE.md")):  # stage_sandbox copies it to the sandbox root
        s["index_file"] = "CLAUDE.md"
    d.setdefault("decontamination", {})["exclusion"] = []
    d.setdefault("output", {})["sandbox_root"] = sandbox_root
    for repo in d.get("repos") or []:
        v = repo.get("verify") or {}
        for key in ("build_cmd", "typecheck_cmd"):
            if v.get(key) and build:
                v[key] = wrap(v[key], build)
    d.pop("loop", None)
    with open(out, "w") as fh:
        yaml.safe_dump(d, fh, sort_keys=False)
    return out
