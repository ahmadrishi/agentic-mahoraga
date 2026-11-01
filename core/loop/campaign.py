"""campaign.py — `mahoraga loop prove`: a blind PROVE run launched by code, end to end.

  setup      identity in loop.json (a changed model, binary, image, template or config is exit 6).
             Per unit: prepare_task (its fork checked against git), SPEC/BR from loop.inputs_dir,
             each arm's snapshot + derived config, and a dry staging. Floor rows that trip the
             gate (curated tokens, case-variant auto tokens) are dropped and counted.
  criteria   one frozen criteria session per unit, before any arm runs
  implement  units × arms × k, arm order a seeded shuffle. A resume skips DONE jobs; the cap is
             checked before every launch; infra_failed is retried once, then the unit is dropped
             from every arm
  score      one blind session per rollout, in seeded order
  report     calib.json, then final/ rendered by the unchanged aggregate_scores.py + build_report.py
"""
import concurrent.futures
import contextlib
import fcntl
import glob
import hashlib
import json
import os
import random
import secrets as rnd
import shutil
import subprocess
import threading

import executor
import ledger as ledger_mod
import preflight
import report
import rollout
import score
import snapshot
from jobs import _codex, _config, _jobs, _priors  # noqa: F401  (re-exported: campaign._config is used by promote)

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib")
OK = ("ok", "truncated", "empty")
FAILED = ("infra_failed", "aborted", "integrity_failed")


def _sha(path):
    return executor.sha256_file(path) if os.path.isfile(path) else None


def _json(path, default=None):
    try:
        return json.load(open(path)) if os.path.isfile(path) else default
    except ValueError:
        raise executor.LoopError(6, "%s is corrupt" % path)


def _seal(cdir, o, inputs):
    prompts = os.path.join(HERE, "prompts")
    ident = {k: o[k] for k in ("model", "scorer_model", "binary_sha", "digests", "runner", "units", "arms", "k", "seed",
                               "max_turns", "stub", "per_job_usd", "scorer_per_job_usd", "timeout_s", "max_sandbox_mb")}
    ident.update(config_sha=_sha(o["config"]), scorer=o.get("scorer", "claude"), codex_sha=o.get("codex_sha"), templates={f: _sha(os.path.join(prompts, f)) for f in sorted(os.listdir(prompts))},
                 inputs={u[:12]: [_sha(os.path.join(inputs, u, f)) for f in ("SPEC.md", "BUSINESS_REQUIREMENT.md")] for u in o["units"]})
    path = os.path.join(cdir, "loop.json")
    if os.path.isfile(path):
        old = _json(path)
        changed = sorted(k for k in set(old) | set(ident) if old.get(k) != ident.get(k))
        if changed:
            raise executor.LoopError(6, "campaign identity changed (%s); start a new --campaign" % ", ".join(changed))
    with open(path, "w") as fh:
        json.dump(ident, fh, indent=2, sort_keys=True)


def seal_prereg(ctx, p):
    """prereg.json, hashed into the ledger before anything is launched: it is row 0, or follows only
    the criteria sessions whose hashes it records (they read SPEC, BR and the human diff, never a
    candidate). A resume whose protocol differs, or any other row first, is exit 6."""
    path, text = os.path.join(ctx["cdir"], "prereg.json"), json.dumps(p, indent=2, sort_keys=True)
    if os.path.isfile(path) and open(path).read() != text:
        raise executor.LoopError(6, "prereg.json differs from this command's protocol; start a new --campaign")
    with open(path, "w") as fh:
        fh.write(text)
    rows, sha = [r for r in ctx["ledger"].rows if r.get("kind") != "criteria"], hashlib.sha256(text.encode()).hexdigest()
    if not rows:
        ctx["ledger"].append({"kind": "prereg", "runkey": sha, "status": "sealed", "usd": None}, final=False)
    elif rows[0].get("kind") != "prereg" or rows[0]["runkey"] != sha:
        raise executor.LoopError(6, "ledger row 0 is not this campaign's prereg")
    return sha


def _honey(dirs):
    out = []
    for d in dirs:
        found = glob.glob(os.path.join(d, ".honey-*"))
        if not found:
            found = [os.path.join(d, ".honey-" + rnd.token_hex(4))]
            with open(found[0], "w") as fh:
                fh.write("mh-honey-" + rnd.token_hex(12))
        out.append(open(found[0]).read().strip())
    return out


def _git(repo, *args):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)
    if r.returncode or not r.stdout.split():
        raise executor.LoopError(3, "git %s failed in %s: %s" % (" ".join(args), repo, r.stderr.strip()[-200:]))
    return r.stdout.split()


def _fork_of(repo, unit):
    parents = _git(repo, "rev-list", "--parents", "-n1", unit)
    if len(parents) < 2:
        raise executor.LoopError(3, "unit %s is a root commit: it has no fork to stage" % unit[:12])
    return _git(repo, "merge-base", parents[1], parents[2])[0] if len(parents) > 2 else parents[1]


def prepare(ctx, unit, cfg):
    udir, meta = os.path.join(ctx["units_dir"], unit), os.path.join(ctx["units_dir"], unit, "meta.lines")
    if not (os.path.isfile(meta) and open(meta).read().strip()):
        rollout.lib("prepare_task.sh", [ctx["units_dir"], unit], cfg, os.path.join(ctx["cdir"], "private", "prepare.log"))
    rows = [ln.strip().split("|") for ln in open(meta) if ln.strip()] if os.path.isfile(meta) else []
    if not rows:
        raise executor.LoopError(3, "prepare_task produced no meta.lines for unit %s" % unit[:12])
    forks = {}
    for r in rows:
        fork, want = dict(x.split("=", 1) for x in r[1:] if "=" in x).get("fork", ""), _fork_of(os.path.join(ctx["root"], r[0]), unit)
        if fork != want:
            raise executor.LoopError(3, "unit %s: meta.lines fork %s is not its fork %s" % (unit[:12], fork[:12], want[:12]))
        forks[r[0]] = fork
    for f in ("SPEC.md", "BUSINESS_REQUIREMENT.md"):
        src = os.path.join(ctx["inputs"], unit, f)
        if not os.path.isfile(src):
            raise executor.LoopError(3, "missing %s: write it from the ticket text before the run" % src)
        shutil.copyfile(src, os.path.join(udir, f))
    ctx["repos"][unit] = sorted(forks)
    return forks


def _dry(ctx, unit, arm):
    slug = "d" + hashlib.sha256((arm + unit).encode()).hexdigest()[:15]
    g = rollout.stage(ctx, unit, slug, ctx["cfg"][(arm, unit)])
    shutil.rmtree(os.path.join(ctx["sandbox_root"], slug), ignore_errors=True)
    return g


def _floor(ctx, o, unit, forks):
    """(rows, curated tokens, language) for the unit's fork, computed once per unit."""
    if unit not in ctx["floor"]:
        if len(forks) > 1:
            raise executor.LoopError(3, "unit %s touches %d repos; the floor is built for one repo only" % (unit[:12], len(forks)))
        repo, fork = sorted(forks.items())[0]
        tree = snapshot.fork_tree(os.path.join(ctx["root"], repo), fork, os.path.join(ctx["cdir"], "trees", fork))
        drop = subprocess.run(["python3", os.path.join(LIB, "cfgquery.py"), "tokens", unit], capture_output=True, text=True,
                              env=dict(os.environ, PROJECT_CONFIG=o["config"])).stdout.split("\n")
        ctx["floor"][unit] = (snapshot.floor_rows(tree, o["langs"].get(repo, "")), drop, o["langs"].get(repo, ""))
        ctx["forks"][unit] = tree
    return ctx["floor"][unit]


def stage_arm(ctx, o, unit, arm, overlay=None):
    """Snapshot + derived config + dry gate for one arm of one unit; return the gate result."""
    sdir = os.path.join(ctx["cdir"], "snapshots", "%s-%s" % (arm, unit[:12]))
    rows, drop, lang = ctx["floor"][unit] if arm != "bare" else ([], [], "")
    man = snapshot.materialize(sdir, arm, o["project"], lang, rows, drop, overlay)
    # derived after materialize: an always-on CLAUDE.md in the snapshot becomes skills.index_file
    ctx["cfg"][(arm, unit)] = snapshot.derive_config(o["config"], sdir + ".yaml", sdir, ctx["sandbox_root"], o["build"])
    g = _dry(ctx, unit, arm)
    if arm != "bare" and not g["ok"] and g["hits"] and not overlay:  # case-variant auto tokens (leak_gate.sh:102 vs :28)
        ctx["floor"][unit] = (rows, drop + g["hits"], lang)
        man = dict(snapshot.materialize(sdir, arm, o["project"], lang, rows, drop + g["hits"]), gate_hit_tokens=len(set(g["hits"])))
        g = _dry(ctx, unit, arm)
    man["gate"] = {k: g[k] for k in ("ok", "reason", "n_tokens")}
    ctx["manifest"][(arm, unit)] = man
    ctx["expect"].setdefault(arm, dict(ctx["expect_base"]))["skills"] = man["skills"]
    with open(sdir + ".manifest.json", "w") as fh:
        json.dump(man, fh, indent=2)
    return g


def arm_setup(ctx, o, unit, forks):
    """Stage each campaign arm for the unit; return a drop reason, or None."""
    _floor(ctx, o, unit, forks)
    for arm in o["arms"]:
        g = stage_arm(ctx, o, unit, arm)
        if not g["ok"]:
            return "gate:%s:%s" % (arm, g["reason"])
    return None


def _rk(ctx, o, unit, arm, rep):
    udir = os.path.join(ctx["units_dir"], unit)
    return ledger_mod.runkey({
        "inputs": {f: _sha(os.path.join(udir, f)) for f in ("meta.lines", "SPEC.md", "BUSINESS_REQUIREMENT.md", "criteria.json")},
        "snapshot": ctx["manifest"][(arm, unit)]["hash"], "arm": arm, "rep": rep, "label": o["campaign"], "model": o["model"],
        "binary": o["binary_sha"], "image": o["digests"].get(o["image"]), "prompt": hashlib.sha256(ctx["prompt"].encode()).hexdigest()})


def _pin(ctx, arm, row, rk):
    """Pin the built-in skills from the first clean rollout; every later init is checked against them."""
    if ctx["builtins"] is not None or row["status"] not in OK:
        return
    init = executor.parse(open(os.path.join(ctx["ledger"].run_dir(rk), "transcript.jsonl")).read())["init"] or {}
    ctx["builtins"] = sorted(set(init.get("skills") or []) - set(ctx["manifest"][(arm, row["unit"])]["skills"]))
    with open(os.path.join(ctx["cdir"], "builtins.json"), "w") as fh:
        json.dump(ctx["builtins"], fh)
    for e in list(ctx["expect"].values()) + [ctx["expect_base"]]:
        e["builtin_skills"] = ctx["builtins"]


def _attempt(ctx, unit, arm, rep, rk, check):
    L = ctx["ledger"]
    row = dict(rollout.run(ctx, unit, arm, rep, rk), attempt=1)
    if row["status"] == "infra_failed" and row["reason"] != "auth":
        L.append(row, final=False)
        check()  # attempt 1 is now spent (or charged its cap); the retry must still fit
        shutil.rmtree(L.run_dir(rk) + ".a1", ignore_errors=True)
        os.replace(L.run_dir(rk), L.run_dir(rk) + ".a1")
        row = dict(rollout.run(ctx, unit, arm, rep, rk), attempt=2)
    L.append(row, final=row["reason"] != "auth")
    if row["reason"] == "auth":
        raise executor.LoopError(4, "the arm could not authenticate; fix the credential and resume")
    if row.get("scan_hits"):
        raise executor.LoopError(2, "a credential or honey string reached a rollout's output (redacted); run INVALID")
    if ((row.get("rate") or {}).get("utilization") or 0) >= 0.9:
        raise executor.LoopError(4, "rate-limit utilisation >= 0.9; resume later")
    return row


SEVERITY = {2: 0, 5: 1, 6: 2, 3: 3, 4: 4}  # contamination outranks INVALID, state, fail-loud, then resumable stops


class Stopped(executor.LoopError):
    """A launch refused because another job already failed: a consequence, never the cause."""


def _rank(e):
    if isinstance(e, Stopped):
        return 9
    return SEVERITY.get(e.code, 9) if isinstance(e, executor.LoopError) else 3  # a crash ranks with fail-loud


def _pool(ctx, o, items, work):
    """Run work(i, item) for every item, o["jobs"] at a time. A failure (or Ctrl-C) stops new
    launches; the jobs already running finish, and the MOST severe failure is raised (a
    contamination exit must never be masked by a budget stop that happened to come first)."""
    jobs = max(1, int(o.get("jobs") or 1))
    if jobs == 1:
        for i, item in enumerate(items):
            work(i, item)
        return

    def run(i, item):
        try:
            return work(i, item)
        except BaseException:
            ctx["stop"] = True  # before this worker can pick up the next queued job
            raise
    errors = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run, i, item) for i, item in enumerate(items)]
        try:
            for f in concurrent.futures.as_completed(futures):
                if not f.cancelled() and f.exception():  # exception() on a cancelled future raises
                    errors.append(f.exception())
                    for g in futures:
                        g.cancel()
        except BaseException:  # Ctrl-C in the main thread: launch nothing more
            ctx["stop"] = True
            for g in futures:
                g.cancel()
            raise
    if errors:
        raise min(errors, key=_rank)


def _gate(ctx, remaining, cap):
    """Check the cap for one more launch, counting the jobs already in flight at their full per-job
    cap, and reserve this one's slot. Returns the function that releases it."""
    with ctx["budget_lock"]:
        if ctx.get("stop"):
            raise Stopped(4, "stopping: another job failed")
        ctx["ledger"].check(remaining, ctx["inflight"][0])
        ctx["inflight"][0] += cap

    def release():
        with ctx["budget_lock"]:
            ctx["inflight"][0] -= cap
    return release


def implement(ctx, o, plan, dropped, later=None):
    """Run every not-yet-DONE rollout of `plan` (o["jobs"] at a time). `later` adds the jobs of
    phases still to come to each budget projection, so an early phase cannot spend what a later one needs."""
    L = ctx["ledger"]
    todo = [p for p in plan if not L.done(p[3])]

    def work(i, p):
        unit, arm, rep, rk = p
        if unit in dropped:
            return
        remaining = _plus(later, {"implement": (len(todo) - i, o["per_job_usd"]), "score": (len(plan), o["scorer_per_job_usd"])})
        release = _gate(ctx, remaining, o["per_job_usd"])
        try:
            row = _attempt(ctx, unit, arm, rep, rk, lambda: _gate(ctx, remaining, 0)())
        finally:
            release()
        print("  implement %s %s r%d: %s %s $%s %ss compile=%s skills=%s" % (unit[:10], arm, rep, row["status"], row["reason"],
              row.get("usd"), row.get("wall_s"), row.get("compile"), len(row.get("skill_calls") or [])), flush=True)
        with ctx["budget_lock"]:
            if row["status"] == "infra_failed":
                dropped[unit] = "infra_failed:" + row["reason"]
            _pin(ctx, arm, row, rk)
    _pool(ctx, o, todo, work)


def _plus(later, now):
    out = dict(now)
    for kind, (n, cap) in (later or {}).items():
        out[kind] = (out.get(kind, (0, cap))[0] + n, cap)
    return out


def score_all(ctx, o, plan, dropped, crit, later=None):
    L = ctx["ledger"]
    items = [p for p in plan if p[0] not in dropped and (L.done(p[3]) or {}).get("status") in OK]
    random.Random(o["seed"] + ":score").shuffle(items)

    def work(i, p):
        unit, arm, rep, rk = p
        srk = ledger_mod.runkey({"score": rk, "criteria": crit[unit], "model": o["scorer_model"],
                                 "prompt": _sha(os.path.join(HERE, "prompts", "grade.md"))})
        if L.done(srk):
            return
        # a grade may take two sessions: reserve both
        release = _gate(ctx, _plus(later, {"score": (len(items) - i, 2 * o["scorer_per_job_usd"])}), 2 * o["scorer_per_job_usd"])
        try:
            s = score.grade(ctx, rk, srk, unit, crit[unit], L.done(rk))
        finally:
            release()
        with open(os.path.join(L.run_dir(rk), "score.json"), "w") as fh:
            json.dump(s, fh, indent=2)
        L.append({"kind": "score", "runkey": srk, "of": rk, "unit": unit, "arm": arm, "rep": rep, "status": s["status"],
                  "usd": None, "pct": s["business_req_pct"]})
        print("  score %s %s r%d: %s pct=%s" % (unit[:10], arm, rep, s["status"], s["business_req_pct"]), flush=True)
    _pool(ctx, o, items, work)


def _proxy_log(ctx, log, allow):
    path = os.path.join(ctx["cdir"], "proxy_logs.json")
    logs = _json(path, []) + [[log, allow]]
    with open(path, "w") as fh:
        json.dump(logs, fh, indent=2)


def proxy_logs(ctx):
    """Every egress log of every session of this campaign (a resume must not forget a breach)."""
    return _json(os.path.join(ctx["cdir"], "proxy_logs.json"), [])


@contextlib.contextmanager
def _network(ctx, o):
    """Point every job at its egress: arms, editors and a Claude scorer share the model-API proxy; a
    Codex scorer gets its own network whose proxy allows only api.openai.com (so no arm can reach it)."""
    if o["runner"] != "docker":
        yield
        return
    with contextlib.ExitStack() as stack:
        net, proxy, log = stack.enter_context(preflight.arm_network(o, "pv" + rnd.token_hex(4)))
        _proxy_log(ctx, log, o["allow"])
        for job in (ctx["job"], ctx["scorer_job"], ctx["editor_job"]):
            job.update(network=net, proxy=proxy)
        if o.get("scorer") == "codex":
            snet, sproxy, slog = stack.enter_context(preflight.arm_network(dict(o, allow=["api.openai.com"]), "ps" + rnd.token_hex(4)))
            _proxy_log(ctx, slog, ["api.openai.com"])
            ctx["codex_job"].update(network=snet, proxy=sproxy)
        yield


def setup(o):
    cfgd, loopc = _config(o)
    os.makedirs(o["root"], exist_ok=True)
    problems = preflight.free_checks(o, docker=o["runner"] == "docker")
    if o["runner"] == "docker" and not o["build_image"]:
        problems.append("loop.build.image is required with the docker runner: AI-written code never builds on the host")
    problems += _codex(o)
    if problems:
        raise executor.LoopError(3, "; ".join(problems))
    cdir = os.path.join(o["root"], o["project"], "c-" + o["campaign"])
    os.makedirs(os.path.join(cdir, "units"), exist_ok=True)
    lock = open(os.path.join(cdir, ".lock"), "w")
    try:  # "rerun to resume" must never mean two processes on one campaign
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise executor.LoopError(6, "campaign %s is running in another process" % o["campaign"])
    inputs = os.path.expanduser(o["inputs"] or loopc.get("inputs_dir") or "")
    _seal(cdir, o, inputs)
    builtins = _json(os.path.join(cdir, "builtins.json"))
    if builtins is None and o.get("builtins"):  # pinned by the canary: checked from the very first session
        canary = _json(o["builtins"])
        if isinstance(canary, dict) and not canary.get("passed"):
            raise executor.LoopError(3, "%s is a canary that did not pass; run `loop preflight --paid` again" % o["builtins"])
        builtins = canary.get("builtin_skills") if isinstance(canary, dict) else canary
    ctx = {"cdir": cdir, "units_dir": os.path.join(cdir, "units"), "sandbox_root": os.path.join(cdir, "sb"), "lock": lock,
           "criteria_store": os.path.join(o["root"], o["project"], "criteria"),
           "root": os.path.expanduser(cfgd["project"]["root"]), "inputs": inputs,
           "ledger": ledger_mod.Ledger(cdir, o["budget_usd"], _priors(o)), "cfg": {}, "repos": {}, "manifest": {},
           "builtins": builtins, "floor": {}, "forks": {}, "seed": o["seed"], "max_sandbox_mb": o["max_sandbox_mb"],
           "budget_lock": threading.Lock(), "inflight": [0.0],
           "secrets": [o.get("token") or "", o.get("openai_key") or ""],
           "prompt": open(os.path.join(HERE, "prompts", "implement.md")).read()}
    _jobs(ctx, o, builtins)
    return ctx


def setup_units(ctx, o, base):
    """Prepare + snapshot + dry-stage every unit; return {unit: drop reason}."""
    dropped = {}
    for unit in o["units"]:
        os.makedirs(os.path.join(ctx["units_dir"], unit), exist_ok=True)
        forks = prepare(ctx, unit, base)
        reason = arm_setup(ctx, o, unit, forks)
        if reason:
            dropped[unit] = reason
        m = ctx["manifest"].get(("pre", unit)) or {}
        print("  unit %s @ %s: %s · floor %s rows (%s dropped)" % (unit[:10], ",".join(f[:9] for f in forks.values()),
              reason or "every arm staged, gate 0 hits", m.get("floor_rows"), m.get("floor_dropped")), flush=True)
    ctx["honey"] = _honey([ctx["cdir"]] + [os.path.join(ctx["units_dir"], u) for u in o["units"]])
    return dropped


def make_plan(ctx, o, live, dropped):
    """Freeze each unit's criteria, then the (unit, arm, rep, runkey) list, arms in seeded order per rep."""
    crit, plan, n = {}, [], len(live) * len(o["arms"]) * o["k"]
    for i, unit in enumerate(live):
        if not os.path.isfile(os.path.join(ctx["units_dir"], unit, "criteria.json")):  # project every phase
            ctx["ledger"].check({"criteria": (len(live) - i, o["scorer_per_job_usd"]),
                                 "implement": (n, o["per_job_usd"]), "score": (n, o["scorer_per_job_usd"])})
        crit[unit] = score.criteria(ctx, unit)
        if crit[unit] is None:
            dropped[unit] = "criteria-failed"
    for rep in range(1, o["k"] + 1):
        for unit in (u for u in live if u not in dropped):
            arms = sorted(o["arms"])
            random.Random("%s:%s:%d" % (o["seed"], unit, rep)).shuffle(arms)
            plan += [(unit, arm, rep, _rk(ctx, o, unit, arm, rep)) for arm in arms]
    for unit, _, _, rk in plan:  # a resume keeps units an earlier session dropped
        if (ctx["ledger"].done(rk) or {}).get("status") == "infra_failed":
            dropped[unit] = "infra_failed"
    return plan, crit


ARMS = ("bare", "pre", "post_U", "post_P")


def prove(o):
    unknown = sorted(set(o["arms"]) - set(ARMS[:2]))
    if unknown:
        raise executor.LoopError(3, "unknown arm(s) %s: prove runs bare and pre" % unknown)
    ctx = setup(o)
    empty = os.path.join(ctx["cdir"], "snapshots", "empty")
    os.makedirs(empty, exist_ok=True)
    base = snapshot.derive_config(o["config"], os.path.join(ctx["cdir"], "base.yaml"), empty, ctx["sandbox_root"], o["build"])
    dropped = setup_units(ctx, o, base)
    live = [u for u in o["units"] if u not in dropped]
    print("prove: %d unit(s) × %s × k=%d = %d rollouts; cap $%.2f, per job $%.2f" % (
        len(live), ",".join(o["arms"]), o["k"], len(live) * len(o["arms"]) * o["k"], o["budget_usd"], o["per_job_usd"]))
    if o["dry_run"] or not live:
        return 0 if live else 3
    with _network(ctx, o):
        plan, crit = make_plan(ctx, o, live, dropped)
        implement(ctx, o, plan, dropped)
        score_all(ctx, o, plan, dropped, crit)
    return report.write(ctx, o, plan, dropped, base, len(live) * len(o["arms"]) * o["k"])
