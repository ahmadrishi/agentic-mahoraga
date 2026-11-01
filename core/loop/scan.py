"""scan.py — string scans every loop artifact passes before a scorer, report or proposer sees it.

Three kinds of hit:
  secret   — the exact credential string(s) in play, or anything shaped like an Anthropic key/token
             (the arm can read its own token via /proc, so a diff may carry it)
  honey    — per-campaign honey strings planted outside the arm's view; seeing one means a leak
  tripwire — held-out ids, paths and score field names that must never reach a proposer

Plus the symlink/special-file census used to catch an arm that plants `innocent.txt -> ~/.ssh/...`
for the host-side diff to follow.
"""
import os
import re
import stat

KEY_SHAPE = re.compile(r"sk-ant-[A-Za-z0-9_\-]{16,}")


def find(text, secrets=(), honey=(), tripwires=()):
    """[(kind, label)] for every hit in `text`. Labels never contain the secret itself."""
    hits = [("secret", "credential#%d" % i) for i, s in enumerate(secrets) if s and s in text]
    if KEY_SHAPE.search(text):
        hits.append(("secret", "sk-ant-shaped"))
    hits += [("honey", "honey#%d" % i) for i, h in enumerate(honey) if h and h in text]
    hits += [("tripwire", t) for t in tripwires if t and t in text]
    return hits


def redact(text, secrets=()):
    for s in secrets:
        if s:
            text = text.replace(s, "[REDACTED]")
    return KEY_SHAPE.sub("[REDACTED]", text)


def census(root):
    """{relpath: entry} for every symlink (entry = its target) and special file (entry = its kind)
    under `root`; regular files and dirs are omitted. Never follows a link."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                out[rel] = "link->" + os.readlink(path)
            elif not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                out[rel] = "special"
    return out


def census_breaches(before, after):
    """Entries that are new or changed since `before` — any of them makes a rollout integrity_failed."""
    return sorted(rel for rel, entry in after.items() if before.get(rel) != entry)
