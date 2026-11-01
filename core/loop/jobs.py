"""jobs.py — what a campaign is configured with: PROJECT.yaml's fields, the job templates (arm,
Claude scorer, Codex scorer, editor) with each one's init expectations, the Codex binary, and the
cost priors the budget projection starts from. Split from campaign.py (per-file legibility cap).
"""
import glob
import json
import os

import yaml

import executor
import preflight
import propose


def _read(path):
    try:
        return json.load(open(path)) if os.path.isfile(path) else {}
    except ValueError:
        return {}


def _config(o):
    """Read PROJECT.yaml once; put what the protocols need into o. Returns (config, its loop: block)."""
    cfgd = yaml.safe_load(open(o["config"])) or {}
    loopc, tracker = cfgd.get("loop") or {}, cfgd.get("tracker") or {}
    policy = (cfgd.get("decontamination") or {}).get("cutoff_policy") or {}
    o.update(project=cfgd["project"]["id"], langs={r.get("name"): r.get("language") or "" for r in cfgd.get("repos") or []},
             build=loopc.get("build"), build_image=(loopc.get("build") or {}).get("image"), tracker=tracker.get("adapter"),
             overlay_dir=os.path.expanduser(loopc.get("overlay_dir") or "") or None,
             repo=((cfgd.get("repos") or [{}])[0]).get("name"), visibility=policy.get("repo_visibility"),
             base=(tracker.get("config") or {}).get("base_branch") or (cfgd.get("vcs") or {}).get("base_branch") or "main")
    return cfgd, loopc


def _jobs(ctx, o, builtins):
    """The job templates (arm, Claude scorer, Codex scorer, editor) and each one's init expectations."""
    job = {"runner": o["runner"], "binary": o["binary"], "agent_bin": o.get("agent_bin"), "model": o["model"],
           "tools": preflight.ARM_TOOLS, "max_turns": o["max_turns"], "max_budget_usd": o["per_job_usd"],
           "timeout_s": o["timeout_s"], "image": o["image"], "token_env": o["token_env"]}
    ctx["job"] = job
    ctx["scorer_job"] = dict(job, model=o["scorer_model"], tools=[], max_turns=4, max_budget_usd=o["scorer_per_job_usd"],
                             timeout_s=600, agent_bin=o.get("scorer_bin"))
    ctx["scorer"] = o.get("scorer", "claude")
    ctx["scorer_family"] = "gpt" if ctx["scorer"] == "codex" else "claude"
    ctx["codex_job"] = {"binary": o.get("codex_binary"), "model": o["scorer_model"], "image": o["image"], "timeout_s": 600,
                        "max_budget_usd": o["scorer_per_job_usd"], "family": "gpt"}
    ctx["editor_job"] = dict(job, model=o.get("editor_model") or o["model"], tools=propose.EDITOR_TOOLS, max_turns=40,
                             max_budget_usd=o.get("editor_per_job_usd", 0.5), timeout_s=1200,
                             agent_bin=o.get("editor_bin") or o.get("agent_bin"))
    ctx["expect_base"] = {"skills": [], "builtin_skills": builtins, "tools": preflight.ARM_TOOLS, "model": o["model"], "version": None}
    ctx["expect"] = {a: dict(ctx["expect_base"]) for a in o["arms"]}
    ctx["expect"]["scorer"] = dict(ctx["expect_base"], tools=["StructuredOutput"], model=o["scorer_model"])
    ctx["expect"]["editor"] = dict(ctx["expect_base"], tools=propose.EDITOR_TOOLS, model=ctx["editor_job"]["model"])


def _codex(o):
    if o.get("scorer") != "codex":
        return []
    if o["runner"] != "docker":
        return ["--scorer codex needs the docker runner (its scorer runs only inside the boundary)"]
    if not o.get("codex_binary") or not os.access(o["codex_binary"], os.X_OK):
        return ["codex binary not found or not executable: %r" % o.get("codex_binary")]
    o["codex_binary"], o["codex_sha"] = executor.install_binary(o["codex_binary"], o["root"])
    return []


def _priors(o):
    """Per-role cost history for the budget projection: every cost of each role
    in this project's OTHER non-stub campaigns (finished or still running) that ran the same model in
    that role. The ledger pools it with the campaign's own rows. It only decides how early a launch is
    refused: the cap holds whatever it says, as long as each job's own cap holds (ledger.check)."""
    role, paid = {"implement": "model", "score": "scorer_model"}, {}
    for c in glob.glob(os.path.join(o["root"], o["project"], "c-*", "loop.json")):
        d, led = _read(c), os.path.join(os.path.dirname(c), "ledger.jsonl")
        own = os.path.basename(os.path.dirname(c)) == "c-" + o["campaign"]
        for r in _rows(led) if os.path.isfile(led) and not d.get("stub") and not own else []:
            usd = r.get("usd") if isinstance(r.get("usd"), (int, float)) else r.get("usd_estimate")  # unpriced: at its cap
            if r.get("kind") in role and d.get(role[r["kind"]]) == o.get(role[r["kind"]]) and isinstance(usd, (int, float)):
                paid.setdefault(r["kind"], []).append(usd)
    return paid


def _rows(path):
    """Another campaign's ledger rows, skipping a torn or blank line (it may be mid-write or killed)."""
    out = []
    for ln in open(path):
        try:
            r = json.loads(ln)
        except ValueError:
            continue
        if isinstance(r, dict):
            out.append(r)
    return out
