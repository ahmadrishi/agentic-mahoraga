"""propose.py — the editor (propose v0): one contained session rewrites the overlay from evidence,
then a validator chain decides whether the candidate may be measured (the overlay is two
always-on files, not skills).

The workspace is built by copy-in only: overlay/ (the parent's two files), repo/ (the target unit's
fork tree, no .git) and evidence/ (opaque dirs, contents chosen by the caller). The session gets
Read, Glob, Grep, Edit and Write, no Bash, and nothing else is mounted.

Validator v0 (all errors collected): surface (exactly the two files, regular; repo/ and evidence/
unchanged), caps (4 KB each, 80 changed lines), content (no file:line, eval tells or environment
advice), fork-stable identifiers (every distinctive identifier exists in the pristine fork). Errors
go back verbatim, with the task, for one retry; a second failure is `fell_back`. A failed session is
never a fall-back: exit 4 (auth, rate, infra; resumable) or 5 (integrity). The tripwire (unit and
fork ids, honey, score fields) is exit 2, no retry.
The caller then dry-stages the candidate through the target unit's leak gate (no feedback on a hit).
"""
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

import executor
import snapshot

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import lang_profiles  # noqa: E402

EDITOR_TOOLS = ["Read", "Glob", "Grep", "Edit", "Write"]
FILES = ("practice.md", "conventions.md")
MAX_BYTES, MAX_LINES = 4096, 80
TELLS = re.compile(r"(?i)\b(mahoraga\w*|held[- ]?out\w*|benchmark\w*|blind\w*|eval(?:s|uat\w*)?)\b")
ENV = re.compile(r"(?i)(/work\b|\bdocker\b|\bcontainers?\b|\bsandbox\w*|\boffline\b|no network|\.git\b|git log)")
PATH_LINE = re.compile(r"[\w./-]+\.\w+(?::\d+|#L\d+)")
FORBIDDEN = re.compile(r"business_req_pct|p_signflip|criteria\.json|score[\w.]*\.json|human_\w+\.diff|\.blind-key|decision\.json")


def workspace(wdir, parent, repo_tree, evidence):
    """evidence: [{name: text}] in order; each becomes evidence/e<i>/."""
    os.makedirs(os.path.join(wdir, "overlay"))
    for name in FILES:
        src = os.path.join(parent or "", name)
        shutil.copyfile(src, os.path.join(wdir, "overlay", name)) if parent and os.path.isfile(src) else \
            open(os.path.join(wdir, "overlay", name), "w").close()
    shutil.copytree(repo_tree, os.path.join(wdir, "repo"), symlinks=True)
    for i, files in enumerate(evidence, 1):
        edir = os.path.join(wdir, "evidence", "e%d" % i)
        os.makedirs(edir)
        for name, text in files.items():
            with open(os.path.join(edir, name), "w") as fh:
                fh.write(text)


def _changed(old, new):
    return sum(1 for ln in difflib.unified_diff(old.splitlines(), new.splitlines(), n=0, lineterm="")
               if ln[:1] in "+-" and not ln.startswith(("+++", "---")))


def _in_repo(token, repo):
    r = subprocess.run(["grep", "-rqF", "--", token, repo], capture_output=True)
    if r.returncode > 1:  # grep could not search the fork: a broken check, not an absent identifier
        raise executor.LoopError(3, "cannot search the fork tree for identifiers: %s" % r.stderr.decode(errors="replace")[:200])
    return r.returncode == 0


def validate(wdir, parent, lang, fork):
    """[errors] for the candidate in wdir/overlay against the parent dir (None = empty). Identifiers
    are checked against the pristine fork tree, never the workspace copy the editor can write to."""
    odir, errors = os.path.join(wdir, "overlay"), []
    names = sorted(os.listdir(odir)) if os.path.isdir(odir) else []
    if names != sorted(FILES) or any(os.path.islink(os.path.join(odir, n)) or not os.path.isfile(os.path.join(odir, n)) for n in names):
        return ["overlay/ must hold exactly practice.md and conventions.md, as regular files (found: %s)" % names]
    old = {n: open(os.path.join(parent, n)).read() if parent and os.path.isfile(os.path.join(parent, n)) else "" for n in FILES}
    new = {n: open(os.path.join(odir, n), errors="replace").read() for n in FILES}
    errors += ["%s is %d bytes; the limit is %d" % (n, len(t.encode()), MAX_BYTES) for n, t in new.items() if len(t.encode()) > MAX_BYTES]
    changed = sum(_changed(old[n], new[n]) for n in FILES)
    if changed > MAX_LINES:
        errors.append("%d lines changed; the limit is %d" % (changed, MAX_LINES))
    for n, t in new.items():
        errors += ["%s: no file:line references (%r)" % (n, m) for m in sorted(set(PATH_LINE.findall(t)))]
        errors += ["%s: remove %r (a word about how this work is measured)" % (n, m) for m in sorted(set(TELLS.findall(t)))]
        errors += ["%s: remove %r (advice about this environment, not the codebase)" % (n, m) for m in sorted(set(ENV.findall(t)))]
        absent = sorted(m for m in set(re.findall(r"[A-Za-z_][A-Za-z0-9_]{3,}", t))
                        if lang_profiles.distinctive(lang, m) and not _in_repo(m, fork))
        errors += ["%s: %r does not exist in repo/ — name only identifiers the codebase has" % (n, m) for m in absent]
    return errors


def tripwire(wdir, wires):
    """Labels of tripwire hits in the overlay or notes.md (never the strings themselves)."""
    paths = [os.path.join(wdir, "overlay", n) for n in FILES] + [os.path.join(wdir, "notes.md")]
    text = "".join(open(p, errors="replace").read() for p in paths if os.path.isfile(p))
    return ["wire#%d" % i for i, w in enumerate(wires) if w and w in text] + (["score-field"] if FORBIDDEN.search(text) else [])


def _reset(wdir, repo_tree, evidence):
    """Between sessions: drop anything that would load as configuration (a .claude/ or CLAUDE.md the
    editor wrote) and restore repo/ and evidence/ if it changed them. Returns [errors] to feed back."""
    for rel in (".claude", "CLAUDE.md"):
        p = os.path.join(wdir, rel)
        shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) and not os.path.islink(p) else \
            (os.remove(p) if os.path.lexists(p) else None)
    pristine = snapshot.tree_hash(repo_tree)
    if snapshot.tree_hash(os.path.join(wdir, "repo")) == pristine and _evidence_ok(wdir, evidence):
        return []
    for d in ("repo", "evidence"):
        shutil.rmtree(os.path.join(wdir, d), ignore_errors=True)
    shutil.copytree(repo_tree, os.path.join(wdir, "repo"), symlinks=True)
    for i, files in enumerate(evidence, 1):
        os.makedirs(os.path.join(wdir, "evidence", "e%d" % i))
        for name, text in files.items():
            with open(os.path.join(wdir, "evidence", "e%d" % i, name), "w") as fh:
                fh.write(text)
    return ["only overlay/practice.md, overlay/conventions.md and notes.md may change; repo/ and evidence/ were restored"]


def _evidence_ok(wdir, evidence):
    want = {"e%d/%s" % (i, n): t for i, files in enumerate(evidence, 1) for n, t in files.items()}
    root = os.path.join(wdir, "evidence")
    have = {os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root) for f in fs}
    return have == set(want) and all(open(os.path.join(root, k), errors="replace").read() == v for k, v in want.items())


def _session_failed(r):
    """A failed session is a stop, never a fall-back: 4 resumable (auth, rate, infra), 5 integrity."""
    if r["reason"] == "auth" or r["status"] == "infra_failed" or ((r.get("rate") or {}).get("utilization") or 0) >= 0.9:
        raise executor.LoopError(4, "an editor session failed (%s, %s); resume when it can run" % (r["status"], r["reason"]))
    if r["status"] == "integrity_failed":
        raise executor.LoopError(5, "an editor session's init differed from what was staged (%s); run INVALID" % r["breaches"])


def edit(ctx, out, rk, prompt, parent, repo_tree, evidence, lang, wires):
    """Run the editor; return {status: ok|noop|fell_back, attempts, errors, usd}; the accepted
    overlay is copied to out/overlay. Every session is ledgered under the caller's runkey. Only
    validator errors lead to fell_back; a failed session raises (no status is written)."""
    wdir = os.path.join(out, "workspace")
    shutil.rmtree(wdir, ignore_errors=True)
    workspace(wdir, parent, repo_tree, evidence)
    res, ask = {"attempts": 0, "errors": [], "usd": 0.0}, prompt
    for attempt in (1, 2):
        job = dict(ctx["editor_job"], work=wdir, out=os.path.join(out, "session-%d" % attempt), prompt=ask)
        r = executor.run(job, expect=ctx["expect"]["editor"], secrets=ctx["secrets"])
        res["attempts"], res["usd"] = attempt, res["usd"] + (r["usd"] or job["max_budget_usd"])
        ctx["ledger"].append({"kind": "propose", "runkey": rk, "attempt": attempt, "status": r["status"],
                              "reason": r["reason"], "usd": r["usd"], "usd_estimate": None if r["usd"] is not None else job["max_budget_usd"],
                              "turns": r["turns"], "wall_s": r["wall_s"], "breaches": r["breaches"], "scan_hits": r["scan_hits"]}, final=False)
        if r["scan_hits"] or tripwire(wdir, wires):
            shutil.rmtree(wdir, ignore_errors=True)
            raise executor.LoopError(2, "editor tripwire: a credential, honey string, unit id or score field reached the overlay or notes")
        _session_failed(r)
        res["errors"] = _reset(wdir, repo_tree, evidence) + validate(wdir, parent, lang, repo_tree)
        if not res["errors"]:
            break
        res.setdefault("rejected", []).append(res["errors"])
        ask = (prompt + "\n\nYour previous edit to overlay/ was rejected:\n" + "\n".join("- " + e for e in res["errors"]) +
               "\n\nFix the two overlay files. The workspace is as you left it.")
    if res["errors"]:
        shutil.rmtree(wdir, ignore_errors=True)
        return dict(res, status="fell_back")
    same = all(open(os.path.join(wdir, "overlay", n)).read() == (open(os.path.join(parent, n)).read()
               if parent and os.path.isfile(os.path.join(parent, n)) else "") for n in FILES)
    shutil.copytree(os.path.join(wdir, "overlay"), os.path.join(out, "overlay"), dirs_exist_ok=True)
    if os.path.isfile(os.path.join(wdir, "notes.md")):
        shutil.copyfile(os.path.join(wdir, "notes.md"), os.path.join(out, "notes.md"))
    shutil.rmtree(wdir, ignore_errors=True)
    return dict(res, status="noop" if same else "ok")


def overlay_sha(d):
    """sha256 of exactly the two overlay files' bytes (an absent dir or file counts as empty)."""
    h = hashlib.sha256()
    for n in FILES:
        p = os.path.join(d or "", n)
        h.update(n.encode() + b"\0" + (open(p, "rb").read() if d and os.path.isfile(p) else b"") + b"\0")
    return h.hexdigest()


def write_status(out, res):
    with open(os.path.join(out, "status.json"), "w") as fh:
        json.dump(res, fh, indent=2)
