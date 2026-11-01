"""executor.py — launch one headless Claude Code job and classify exactly what happened.

The first Mahoraga code that launches a model. A job is a plain dict:

  runner      "docker" (enforced: OS boundary) | "local" (instructed: fresh HOME only)
  binary      the copied, hashed claude binary (install_binary); agent_bin overrides it (CI fakes,
              the model-free escape agent)
  work        the sandbox dir (cwd; mounted at /work under docker)
  prompt      sent on STDIN — never on argv (--tools/--allowedTools are variadic and swallow it)
  model, tools, max_turns, max_budget_usd, timeout_s
  image, network, proxy                   docker only
  token_env   name of the env var carrying the credential (default CLAUDE_CODE_OAUTH_TOKEN)
  out         where transcript.jsonl, stderr.txt and result.json are written

run(job, expect) returns a result dict with status ok | truncated | infra_failed | integrity_failed,
the cost, the init-event breaches, Skill calls and scan hits. It never reads credential files.
"""
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time

import scan

TOKEN_ENV = "CLAUDE_CODE_OAUTH_TOKEN"


class LoopError(Exception):
    """A fail-loud stop; `code` is the CLI exit code."""

    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def install_binary(src, root):
    """Copy the claude binary to <root>/bin/<sha256>/claude: identity is the hash, not the version
    string, and an auto-update cannot change a campaign's binary underneath it."""
    sha = sha256_file(os.path.realpath(src))
    dst = os.path.join(root, "bin", sha, "claude")
    if not os.path.isfile(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(os.path.realpath(src), dst + ".part")
        os.chmod(dst + ".part", 0o755)
        os.replace(dst + ".part", dst)
    return dst, sha


def claude_args(job):
    tools = ",".join(job["tools"])
    args = ["-p", "--model", job["model"], "--tools", tools, "--allowedTools", tools,
            "--permission-mode", "acceptEdits", "--setting-sources", "project", "--strict-mcp-config",
            "--no-session-persistence", "--output-format", "stream-json", "--verbose",
            "--max-turns", str(job["max_turns"])]
    if job.get("max_budget_usd"):
        args += ["--max-budget-usd", str(job["max_budget_usd"])]
    if job.get("json_schema"):  # the tools-less scorer: output is result.structured_output
        args += ["--json-schema", json.dumps(job["json_schema"])]
    return args


def docker_base(job, binary, dst, env_names):
    """The boundary every container job shares: internal network + proxy, read-only root, no caps,
    throwaway $HOME and /tmp, the binary mounted read-only. Credentials pass by env NAME only."""
    argv = ["docker", "run", "--rm", "-i", "--name", job["container"], "--network", job["network"],
            "--user", "%d:%d" % (os.getuid(), os.getgid()), "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--read-only", "--pids-limit", "512", "--memory", "4g",
            "--mount", "type=bind,src=%s,dst=%s,readonly" % (os.path.realpath(binary), dst),
            "--mount", "type=tmpfs,dst=/home/arm", "--mount", "type=tmpfs,dst=/tmp",
            "-e", "HOME=/home/arm", "-e", "HTTPS_PROXY=" + job["proxy"]]
    for name in env_names:
        argv += ["-e", name]
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME") + tuple(env_names) or k.startswith("DOCKER_")}
    return argv, env


def argv_env(job, cfg):
    """(argv, env, cwd) for the job. The prompt is not in argv by construction."""
    token_env = job.get("token_env", TOKEN_ENV)
    binary = job.get("agent_bin") or job["binary"]
    if job["runner"] == "docker":
        argv, env = docker_base(job, binary, "/opt/claude", [token_env])
        argv += ["--mount", "type=bind,src=%s,dst=/work" % os.path.realpath(job["work"]),
                 "--mount", "type=bind,src=%s,dst=/home/arm/cfg" % cfg, "-w", "/work",
                 "-e", "CLAUDE_CONFIG_DIR=/home/arm/cfg", job["image"], "/opt/claude"] + claude_args(job)
        return argv, env, None
    home = os.path.join(cfg, "home")  # removed with cfg after the run
    os.makedirs(home)
    env = {"HOME": home, "PATH": "/usr/bin:/bin", "TERM": "dumb", "CLAUDE_CONFIG_DIR": cfg, "TMPDIR": home}
    if os.environ.get(token_env):
        env[token_env] = os.environ[token_env]
    return [binary] + claude_args(job), env, job["work"]


def parse(stdout):
    """The facts a decision needs from a stream-json transcript."""
    out = {"init": None, "result": None, "hooks": [], "skill_calls": [], "tool_uses": [], "rate": None, "bad": 0}
    for line in stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            out["bad"] += 1
            continue
        kind, sub = ev.get("type"), str(ev.get("subtype") or "")
        if kind == "system" and sub == "init":
            out["init"] = ev
        elif kind == "system" and "hook" in sub:
            out["hooks"].append(sub)
        elif kind == "result":
            out["result"] = ev
        elif kind == "rate_limit_event":
            out["rate"] = ev.get("rate_limit_info")
        elif kind == "assistant":
            _tool_uses(ev, out)
    return out


def _tool_uses(ev, out):
    blocks = [b for b in (ev.get("message") or {}).get("content") or [] if isinstance(b, dict)]
    for block in (b for b in blocks if b.get("type") == "tool_use"):
        out["tool_uses"].append(block.get("name"))
        if block.get("name") == "Skill":
            out["skill_calls"].append(str((block.get("input") or {}).get("skill", "")))


def classify(parsed, rc, timed_out):
    """(status, reason). Auth failures are infra_failed with reason 'auth' (the caller exits 4)."""
    r = parsed["result"]
    if timed_out:
        return "infra_failed", "timeout"
    if r is None:
        return "infra_failed", "no-result-rc%d" % rc
    sub, text = str(r.get("subtype") or ""), str(r.get("result") or "").lower()
    if r.get("is_error") and ("login" in text or r.get("api_error_status") in (401, 403)):
        return "infra_failed", "auth"
    if sub == "success" and not r.get("is_error"):
        return "ok", str(r.get("terminal_reason") or "completed")
    if "max_turns" in sub or "budget" in sub or r.get("terminal_reason") == "max_turns":
        return "truncated", sub or str(r.get("terminal_reason"))
    return "infra_failed", sub or "error"


def init_breaches(parsed, expect):
    """Everything in the init event (and the run) that differs from what the arm was staged with.
    expect: {skills, builtin_skills, tools, model, version} — any breach makes the run integrity_failed."""
    init = parsed["init"]
    if init is None:
        return ["no-init-event"]
    have, want = set(init.get("skills") or []), set(expect["skills"])
    builtin = expect["builtin_skills"]  # None = not pinned yet (the canary's first run pins it)
    out = [] if builtin is None else ["skill:+" + s for s in sorted(have - want - set(builtin))]
    out += ["skill:-" + s for s in sorted(want - have)]
    out += ["plugin:" + str(p.get("name")) for p in init.get("plugins") or [] if p.get("path") != "builtin"]
    out += ["mcp:" + str(m.get("name", m)) for m in init.get("mcp_servers") or []]
    tools = set(init.get("tools") or [])
    if tools != set(expect["tools"]):
        out.append("tools:+%s-%s" % (",".join(sorted(tools - set(expect["tools"]))),
                                     ",".join(sorted(set(expect["tools"]) - tools))))
    for key, field in (("model", "model"), ("version", "claude_code_version")):
        if expect.get(key) and init.get(field) != expect[key]:
            out.append("%s:%s" % (key, init.get(field)))
    return out + ["hook:" + h for h in parsed["hooks"]]


def run(job, expect=None, secrets=()):
    """Run one job; write transcript.jsonl, stderr.txt and result.json under job['out']."""
    os.makedirs(job["out"], exist_ok=True)
    cfg = tempfile.mkdtemp(prefix="cfg-", dir=job["out"])
    job.setdefault("container", "mh-arm-" + os.path.basename(cfg)[4:].lower())
    argv, env, cwd = argv_env(job, cfg)
    start, timed_out = time.time(), False
    try:
        proc = subprocess.run(argv, input=job["prompt"].encode(), capture_output=True, env=env, cwd=cwd,
                              timeout=job.get("timeout_s", 900))
        stdout, stderr, rc = proc.stdout.decode("utf-8", "replace"), proc.stderr.decode("utf-8", "replace"), proc.returncode
    except subprocess.TimeoutExpired as exc:
        stdout, stderr, rc, timed_out = (exc.stdout or b"").decode("utf-8", "replace"), "timeout", -1, True
        if job["runner"] == "docker":  # killing the client does not stop the container
            subprocess.run(["docker", "rm", "-f", job["container"]], capture_output=True)
    remote = os.path.join(cfg, "remote-settings.json")
    org_sha = sha256_file(remote) if os.path.isfile(remote) else None
    shutil.rmtree(cfg, ignore_errors=True)
    hits = scan.find(stdout + stderr, secrets=secrets)
    with open(os.path.join(job["out"], "transcript.jsonl"), "w") as fh:
        fh.write(scan.redact(stdout, secrets))
    with open(os.path.join(job["out"], "stderr.txt"), "w") as fh:
        fh.write(scan.redact(stderr, secrets))
    parsed = parse(stdout)
    status, reason = classify(parsed, rc, timed_out)
    breaches = init_breaches(parsed, expect) if expect and status != "infra_failed" else []
    if breaches or hits:
        status = "integrity_failed"
    r, init = parsed["result"] or {}, parsed["init"] or {}
    result = {"status": status, "reason": reason, "rc": rc, "wall_s": round(time.time() - start, 2),
              "usd": r.get("total_cost_usd"), "usage": r.get("usage"), "turns": r.get("num_turns"),
              "model": init.get("model"), "version": init.get("claude_code_version"),
              "isolation": "enforced" if job["runner"] == "docker" else "instructed",
              "init_sha": hashlib.sha256(json.dumps(init, sort_keys=True).encode()).hexdigest() if init else None,
              "org_sha": org_sha, "skill_calls": parsed["skill_calls"], "breaches": breaches,
              "scan_hits": hits, "rate": parsed["rate"], "bad_lines": parsed["bad"]}
    with open(os.path.join(job["out"], "result.json"), "w") as fh:
        json.dump(result, fh, indent=2)
    if job.get("max_budget_usd") and result["usd"] is None and status != "infra_failed":
        raise LoopError(3, "a budget cap is set but the run reported no total_cost_usd")
    return result


CODEX_KEY_ENVS = ("CODEX_API_KEY", "OPENAI_API_KEY")
CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"  # Codex trusts the system roots; the image has none


def _codex_events(out):
    usage, errors = None, []
    for line in out.splitlines():
        ev = json.loads(line) if line.startswith("{") else {}
        if ev.get("type") == "turn.completed":
            usage = ev.get("usage")
        elif ev.get("type") in ("error", "turn.failed"):
            errors.append(str(ev.get("message") or ev.get("error"))[:200])
    return usage, errors


def _read_json(path):
    try:
        return json.load(open(path)) if os.path.isfile(path) else None
    except ValueError:
        return None


def _scorer_status(rc, parsed, errors):
    if rc == 0 and isinstance(parsed, dict):
        return "ok", "completed"
    if rc is None:
        return "infra_failed", "timeout"
    if any("401" in e or "nauthorized" in e for e in errors):
        return "infra_failed", "auth"
    return "infra_failed", "tls" if any("certificate" in e for e in errors) else "no-output-rc%s" % rc


def run_scorer(job, secrets=()):
    """Run the Codex scorer in the same boundary: only `view` (read-only) and `out` are mounted, the
    output is schema-constrained (view/schema.json) and read from -o, never from the event stream.
    Codex's code-mode helper is deliberately absent, so the scorer cannot execute code."""
    os.makedirs(job["out"], exist_ok=True)
    if os.path.isfile(os.path.join(job["out"], "last.json")):  # never read a previous session's output as this one's
        os.remove(os.path.join(job["out"], "last.json"))
    job.setdefault("container", "mh-scorer-" + os.path.basename(tempfile.mkdtemp(dir=job["out"]))[-8:].lower())
    argv, env = docker_base(job, job["binary"], "/opt/codex", CODEX_KEY_ENVS)
    argv += ["--mount", "type=bind,src=%s,dst=%s,readonly" % (CA_BUNDLE, CA_BUNDLE), "-e", "SSL_CERT_FILE=" + CA_BUNDLE,
             "--mount", "type=bind,src=%s,dst=/view,readonly" % os.path.realpath(job["view"]),
             "--mount", "type=bind,src=%s,dst=/out" % os.path.realpath(job["out"]), "-w", "/view",
             "-e", "CODEX_HOME=/home/arm/codex", job["image"], "bash", "-c",
             'mkdir -p "$CODEX_HOME" && m="$1" && shift && exec /opt/codex exec --json --ephemeral --ignore-user-config '
             '--skip-git-repo-check -s read-only -m "$m" "$@" --output-schema /view/schema.json -o /out/last.json -',
             "scorer", job["model"]] + [x for kv in job.get("codex_config") or [] for x in ("-c", kv)]
    start, rc = time.time(), None
    try:
        proc = subprocess.run(argv, input=job["prompt"].encode(), capture_output=True, env=env,
                              timeout=job.get("timeout_s", 300))
        out, err, rc = proc.stdout.decode("utf-8", "replace"), proc.stderr.decode("utf-8", "replace"), proc.returncode
    except subprocess.TimeoutExpired as exc:
        out, err = (exc.stdout or b"").decode("utf-8", "replace"), "timeout"
        subprocess.run(["docker", "rm", "-f", job["container"]], capture_output=True)
    hits = scan.find(out + err, secrets=secrets)
    with open(os.path.join(job["out"], "events.jsonl"), "w") as fh:
        fh.write(scan.redact(out, secrets))
    usage, errors = _codex_events(out)
    parsed = _read_json(os.path.join(job["out"], "last.json"))
    status, reason = _scorer_status(rc, parsed, errors)
    if hits:
        status = "integrity_failed"
    result = {"status": status, "reason": reason, "rc": rc, "wall_s": round(time.time() - start, 2),
              "model": job["model"], "family": job.get("family", "gpt"), "family_basis": "declared",
              "usage": usage, "usd": None, "usd_source": "unpriced", "output": parsed,
              "errors": errors[-5:], "scan_hits": hits, "isolation": "enforced"}
    with open(os.path.join(job["out"], "result.json"), "w") as fh:
        json.dump(result, fh, indent=2)
    return result
