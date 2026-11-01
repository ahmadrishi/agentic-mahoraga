"""ledger.py — a campaign's append-once record: one row per terminal job, DONE markers, the USD cap.

Each row is one JSON line, appended under flock and fsync'd. A job is keyed
by its runkey: the sha256 of everything that determines it, so a resume re-runs exactly the jobs
with no DONE marker. Before each launch, `check` refuses (exit 4, resumable) when spent so far plus
the projected cost of the remaining jobs exceeds the cap. An unreadable row is exit 6, never skipped.
"""
import fcntl
import hashlib
import json
import os

import executor

ROW_KEYS = ("kind", "runkey", "status")


def log_campaign(root, project, entry):
    """Append to <root>/<project>/campaigns.jsonl: every campaign, aborted ones included (no file drawer)."""
    os.makedirs(os.path.join(root, project), exist_ok=True)
    with open(os.path.join(root, project, "campaigns.jsonl"), "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.write(json.dumps(entry, sort_keys=True) + "\n")


def reserve(root, project, campaign, units):
    """Reserve held-out units for `campaign` in <root>/<project>/reserved.json, under a lock, before
    anything launches. Returns the units another campaign already holds (the caller refuses them)."""
    path = os.path.join(root, project, "reserved.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            held = json.load(open(path)) if os.path.isfile(path) else {}
        except ValueError:
            raise executor.LoopError(6, "%s is corrupt" % path)
        taken = sorted(u for u in units if held.get(u, campaign) != campaign)
        if not taken:
            held.update({u: campaign for u in units})
            with open(path + ".part", "w") as fh:
                json.dump(held, fh, indent=2, sort_keys=True)
            os.replace(path + ".part", path)
        return taken


def reserved(root, project):
    path = os.path.join(root, project, "reserved.json")
    return json.load(open(path)) if os.path.isfile(path) else {}


def runkey(parts):
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()


def quantile95(xs):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(0.95 * len(xs)))]


class Ledger:
    def __init__(self, cdir, cap_usd, priors=None):
        self.cdir, self.cap, self.priors = cdir, cap_usd, priors or {}
        self.path = os.path.join(cdir, "ledger.jsonl")
        self.rows = self._load()

    def _load(self):
        rows = []
        if not os.path.isfile(self.path):
            return rows
        for i, line in enumerate(open(self.path), 1):
            try:
                row = json.loads(line)
            except ValueError:
                row = None
            if not isinstance(row, dict) or any(k not in row for k in ROW_KEYS):
                raise executor.LoopError(6, "ledger %s line %d is corrupt — refusing to resume" % (self.path, i))
            rows.append(row)
        return rows

    def run_dir(self, rk):
        return os.path.join(self.cdir, "runs", rk[:16])

    def done(self, rk):
        """The terminal row for runkey `rk` if its DONE marker exists, else None."""
        if not os.path.isfile(os.path.join(self.run_dir(rk), "DONE")):
            return None
        rows = [r for r in self.rows if r["runkey"] == rk]
        if not rows:
            raise executor.LoopError(6, "DONE marker for %s has no ledger row" % rk[:16])
        return rows[-1]

    def append(self, row, final=True):
        """Write `row`; with final, also the run's DONE marker (after the row is durable)."""
        with open(self.path, "a") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            fh.write(json.dumps(row, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        self.rows.append(row)
        if final:
            os.makedirs(self.run_dir(row["runkey"]), exist_ok=True)
            open(os.path.join(self.run_dir(row["runkey"]), "DONE"), "w").close()

    def spent(self):
        """Priced cost, plus the per-job cap for every launched job that reported no cost."""
        cost = lambda r: r["usd"] if isinstance(r.get("usd"), (int, float)) else r.get("usd_estimate") or 0  # noqa: E731
        return sum(cost(r) for r in self.rows)

    def p95(self, kind, fallback):
        """The 95th-percentile cost of `kind` over this campaign's priced rows pooled with the project's
        history for the role (jobs._priors: a few early rows alone would make it their maximum), else
        `fallback` (the per-job cap)."""
        xs = [r["usd"] for r in self.rows if r["kind"] == kind and isinstance(r.get("usd"), (int, float))]
        xs += self.priors.get(kind, [])
        return quantile95(xs) if xs else fallback

    def check(self, remaining, inflight_usd=0.0):
        """remaining: {kind: (jobs_left, per_job_cap)}. Exit 4 before a launch the cap cannot cover. One
        job of each kind is projected at its full per-job cap and the rest at p95, so a launch that
        passes cannot take spend past the cap while each job's own --max-budget-usd holds."""
        projected = self.spent() + inflight_usd + sum(fb + (n - 1) * self.p95(kind, fb) for kind, (n, fb) in remaining.items() if n > 0)
        if projected > self.cap:
            raise executor.LoopError(4, "budget: spent $%.2f + projected remaining = $%.2f > cap $%.2f "
                                        "(resume with a higher --budget-usd)" % (self.spent(), projected, self.cap))
        return projected
