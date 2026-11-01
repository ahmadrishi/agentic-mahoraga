"""preflight.py — what must be true before any decision-bearing run.

  free_checks   docker reachable, images present (digests recorded), binary copied + hashed,
                loop.root outside any git work tree — every failure collected, then exit 3
  arm_network   an --internal Docker network whose only way out is the egress-proxy sidecar
  boundary      the model-free escape agent inside the real container config: 0 of 4 escapes, and
                its planted symlink caught by the host census
  canary        (paid) a sentinel skill must fire on its description alone in every run, with the
                init event exactly as staged; also records whether nested .claude/skills load
"""
import contextlib
import json
import os
import secrets as rnd
import shutil
import subprocess
import time

import egress_proxy
import executor
import scan
import snapshot

ARM_TOOLS = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "Skill"]
ARM_TELEMETRY = ("http-intake.logs.us5.datadoghq.com",)  # Claude Code's log intake, seen at the canary; refused
HERE = os.path.dirname(os.path.abspath(__file__))


def _ok(argv):
    return subprocess.run(argv, capture_output=True, text=True).returncode == 0


def free_checks(o, docker=True):
    """[problems], plus o['digests'] and o['binary_sha'] filled in on success. docker=False is the
    instructed local runner (tests): no daemon or image checks."""
    problems, o["digests"] = [], {}
    if docker and (not shutil.which("docker") or not _ok(["docker", "info"])):
        return ["docker is not installed or its daemon is unreachable"]
    images = [o["image"], o["proxy_image"]] + ([o["build_image"]] if o.get("build_image") else [])
    for image in images if docker else []:
        r = subprocess.run(["docker", "image", "inspect", image, "--format", "{{index .RepoDigests 0}}"],
                           capture_output=True, text=True)
        if r.returncode:
            problems.append("image %s is not present (docker pull it)" % image)
        o["digests"][image] = r.stdout.strip()
    if not o["binary"] or not os.access(o["binary"], os.X_OK):
        problems.append("claude binary not found or not executable: %r" % o["binary"])
    else:
        o["binary"], o["binary_sha"] = executor.install_binary(o["binary"], o["root"])
    if _ok(["git", "-C", o["root"], "rev-parse", "--is-inside-work-tree"]):
        problems.append("loop.root %s is inside a git work tree (its files would vanish from scans)" % o["root"])
    return problems


@contextlib.contextmanager
def arm_network(o, tag):
    """Yield (network, proxy_url, proxy_log): an internal network plus the allowlist proxy sidecar."""
    net, name = "mh-int-" + tag, "mh-proxy-" + tag
    logdir = os.path.join(o["root"], "proxy", tag)
    os.makedirs(logdir, exist_ok=True)
    open(os.path.join(logdir, "proxy.log"), "a").close()
    subprocess.run(["docker", "network", "create", "--internal", net], check=True, capture_output=True)
    try:
        subprocess.run(["docker", "run", "-d", "--rm", "--name", name, "--user", "%d:%d" % (os.getuid(), os.getgid()),
                        "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                        "--mount", "type=bind,src=%s,dst=/proxy.py,readonly" % os.path.join(HERE, "egress_proxy.py"),
                        "--mount", "type=bind,src=%s,dst=/log" % logdir, o["proxy_image"], "python3", "/proxy.py",
                        "--listen", "0.0.0.0:3128", "--allow", ",".join(o["allow"]), "--log", "/log/proxy.log"],
                       check=True, capture_output=True)
        subprocess.run(["docker", "network", "connect", net, name], check=True, capture_output=True)
        log = os.path.join(logdir, "proxy.log")
        deadline = time.time() + 30  # never launch an arm before the proxy accepts connections
        while "READY" not in open(log).read():
            if time.time() > deadline:
                raise executor.LoopError(3, "egress proxy did not become ready within 30 s")
            time.sleep(0.1)
        yield net, "http://%s:3128" % name, log
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        subprocess.run(["docker", "network", "rm", net], capture_output=True)


def _job(o, work, out, prompt, **kw):
    job = {"runner": "docker", "binary": o["binary"], "work": work, "out": out, "prompt": prompt,
           "token_env": o.get("token_env", executor.TOKEN_ENV),
           "model": o["model"], "tools": ARM_TOOLS, "max_turns": 6, "timeout_s": 300, "image": o["image"]}
    job.update(kw)
    return job


def boundary(o):
    """{escapes: [...], symlink_caught: bool, attempts: [...]} from the escape agent in the real config."""
    tag = "bp" + rnd.token_hex(4)
    base = os.path.join(o["root"], "preflight", tag)
    work, decoy = os.path.join(base, "work"), os.path.join(base, "host-decoy.txt")
    os.makedirs(work)
    with open(decoy, "w") as fh:
        fh.write(rnd.token_hex(16))
    before = scan.census(work)
    with arm_network(o, tag) as (net, proxy, log):
        spec = {"decoy": decoy, "proxy": proxy.split("//")[1], "deny_host": "example.com"}
        executor.run(_job(o, work, os.path.join(base, "out"), json.dumps(spec), network=net, proxy=proxy,
                          agent_bin=o["agent_bin"], timeout_s=120))
        # "the proxy refused" must be observed, not inferred: an unreachable proxy also looks like a refusal
        denied = egress_proxy.classify(log, o["allow"])["other_denies"] == ["example.com:443"]
        proxy_log = open(log).read().splitlines()
    lines = open(os.path.join(base, "out", "transcript.jsonl")).read().splitlines()
    attempts = [json.loads(x) for x in lines if x.startswith("{")]
    return {"attempts": attempts, "escapes": [a["attempt"] for a in attempts if a.get("escaped")],
            "symlink_caught": "innocent.txt" in scan.census_breaches(before, scan.census(work)),
            "complete": len(attempts) == 5 and denied, "proxy_log": proxy_log}


def _sandbox(base, i, nested=False):
    work = os.path.join(base, "run%d" % i)
    skill_root = os.path.join(work, "repo") if nested else work
    name = "mh-nested" if nested else "mh-canary"
    sdir = os.path.join(skill_root, ".claude", "skills", name)
    os.makedirs(sdir)
    nonce = rnd.token_hex(8)
    with open(os.path.join(sdir, "SKILL.md"), "w") as fh:
        fh.write("---\nname: %s\ndescription: Use when asked to verify the canary checkpoint.\n---\n\n"
                 "# Canary checkpoint\n\nWrite a file named CANARY_FIRED.txt in the current directory "
                 "containing exactly: %s\n" % (name, nonce))
    return work, nonce


def _always_on(o, base, i, net, proxy, secrets):
    """The `pre` arm's always-on file must reach the model whole: a CLAUDE.md the size of the GUARD
    pack, with the instruction only at its END, must be obeyed."""
    work, nonce = os.path.join(base, "run%d" % i), rnd.token_hex(8)
    os.makedirs(work)
    with open(os.path.join(work, "CLAUDE.md"), "w") as fh:
        fh.write(snapshot.guard_text() + "\n## Memory checkpoint\n\nWhen asked to verify the memory checkpoint, write a "
                 "file named MEMORY_FIRED.txt in the current directory containing exactly: %s\n" % nonce)
    r = executor.run(_job(o, work, work + ".out", "Please verify the memory checkpoint.", network=net, proxy=proxy,
                          max_budget_usd=o["per_run_usd"]), secrets=secrets)
    path = os.path.join(work, "MEMORY_FIRED.txt")
    return {"fired": os.path.isfile(path) and open(path).read().strip() == nonce, "status": r["status"],
            "bytes": os.path.getsize(os.path.join(work, "CLAUDE.md")), "usd": r["usd"]}


def canary(o, runs=3):
    """Paid. Every run must be ok, fire the sentinel (file content == nonce), match the staged init
    exactly and report its cost. Built-in skills are pinned from run 1 and asserted after it."""
    tag = "cn" + rnd.token_hex(4)
    base = os.path.join(o["root"], "preflight", tag)
    prompt, builtins, out = "Please verify the canary checkpoint.", None, {"runs": [], "nested": None}
    secrets = [o.get("token", "")]
    with arm_network(o, tag) as (net, proxy, log):
        for i in range(runs):
            work, nonce = _sandbox(base, i)
            expect = {"skills": ["mh-canary"], "builtin_skills": builtins, "tools": ARM_TOOLS,
                      "model": None, "version": None}  # run 1 pins the built-in skill list
            r = executor.run(_job(o, work, os.path.join(work + ".out"), prompt, network=net, proxy=proxy,
                                  max_budget_usd=o["per_run_usd"]), expect=expect, secrets=secrets)
            init = executor.parse(open(os.path.join(work + ".out", "transcript.jsonl")).read())["init"] or {}
            if builtins is None:
                builtins = sorted(set(init.get("skills") or []) - {"mh-canary"})
            fired = os.path.isfile(os.path.join(work, "CANARY_FIRED.txt")) and \
                open(os.path.join(work, "CANARY_FIRED.txt")).read().strip() == nonce
            out["runs"].append({"status": r["status"], "reason": r["reason"], "fired": fired, "usd": r["usd"],
                                "breaches": r["breaches"], "skill_calls": r["skill_calls"], "model": r["model"],
                                "version": r["version"], "tools": sorted(init.get("tools") or []),
                                "mcp": init.get("mcp_servers"), "org_sha": r["org_sha"]})
        work, nonce = _sandbox(base, runs, nested=True)
        r = executor.run(_job(o, work, work + ".out", prompt, network=net, proxy=proxy,
                              max_budget_usd=o["per_run_usd"]), secrets=secrets)
        init = executor.parse(open(os.path.join(work + ".out", "transcript.jsonl")).read())["init"] or {}
        out["nested"] = {"loaded": "mh-nested" in (init.get("skills") or []), "status": r["status"], "usd": r["usd"]}
        out["always_on"] = _always_on(o, base, runs + 1, net, proxy, secrets)
        out["proxy"] = egress_proxy.classify(log, o["allow"], ARM_TELEMETRY)
    out["builtin_skills"], out["passed"] = builtins, all(
        x["status"] == "ok" and x["fired"] and x["usd"] is not None for x in out["runs"]) \
        and not out["proxy"]["allow_breach"] and out["always_on"]["fired"]
    with open(os.path.join(base, "canary.json"), "w") as fh:
        json.dump(out, fh, indent=2)
    return out


SCORER_TELEMETRY = ("chatgpt.com", "ab.chatgpt.com", "api.github.com")  # seen in probes; refused, expected
_SCORE_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["criteria"], "properties": {
    "criteria": {"type": "array", "items": {"type": "object", "additionalProperties": False, "required": ["id", "status"],
                 "properties": {"id": {"type": "string"}, "status": {"type": "string", "enum": ["full", "partial", "none"]}}}}}}
_CANDIDATE = "--- a/calc.py\n+++ b/calc.py\n@@ -0,0 +1,2 @@\n+def add(a, b):\n+    return a + b\n"


def scorer_check(o):
    """Paid (OpenAI). Codex in the boundary grades a tiny view with a KNOWN answer — c1 is met by
    the candidate, c2 is not — so the check covers correctness, not just that it ran."""
    tag = "sc" + rnd.token_hex(4)
    base = os.path.join(o["root"], "preflight", tag)
    view = os.path.join(base, "view")
    os.makedirs(view)
    with open(os.path.join(view, "schema.json"), "w") as fh:
        json.dump(_SCORE_SCHEMA, fh)
    prompt = ("Grade the CANDIDATE diff against each criterion: full, partial or none. Use only the text below; "
              "do not run commands.\n\nCRITERIA:\n- c1: adds an add(a, b) function that returns a + b\n"
              "- c2: adds a subtract(a, b) function\n\nCANDIDATE:\n" + _CANDIDATE)
    with arm_network(dict(o, allow=["api.openai.com"]), tag) as (net, proxy, log):
        r = executor.run_scorer({"binary": o["codex_binary"], "view": view, "out": os.path.join(base, "out"),
                                 "prompt": prompt, "model": o["scorer_model"], "network": net, "proxy": proxy,
                                 "image": o["image"], "timeout_s": 300}, secrets=[o.get("openai_key", "")])
        r["proxy"] = egress_proxy.classify(log, ["api.openai.com"], SCORER_TELEMETRY)
    got = {c.get("id"): c.get("status") for c in (r.get("output") or {}).get("criteria", [])}
    r["correct"] = got == {"c1": "full", "c2": "none"}
    r["passed"] = r["status"] == "ok" and r["correct"] and not r["proxy"]["allow_breach"]
    with open(os.path.join(base, "scorer_check.json"), "w") as fh:
        json.dump(r, fh, indent=2)
    return r
