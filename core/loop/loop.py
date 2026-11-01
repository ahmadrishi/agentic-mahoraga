#!/usr/bin/env python3
"""loop.py — `mahoraga loop`: the closed improve loop's CLI: `preflight`, `prove`.

Exit codes: 0 ok · 2 contamination (leak, secret, boundary breach) · 3 fail loud (precondition,
canary) · 4 budget/rate/auth (resumable) · 5 INVALID · 6 identity/state · 64 usage.

    mahoraga loop preflight [--paid] [--model M] [--runs N] [--root DIR] [--binary PATH]
    mahoraga loop preflight --scorer-check [--scorer-model M]   # Codex scorer in the boundary (OpenAI $)
    mahoraga loop prove --config PROJECT.yaml --campaign NAME --units SHA1,SHA2 --arms bare,pre --k 3 \
                        --budget-usd N [--dry-run]                 # blind PROVE, code-launched (Anthropic $)

The arm's credential is an Anthropic API key from a 0600 file named by MAHORAGA_ANTHROPIC_KEY_FILE
(passed as ANTHROPIC_API_KEY; billed per token), else a subscription token from CLAUDE_CODE_OAUTH_TOKEN
(e.g. `claude setup-token`) or a 0600 file named by MAHORAGA_TOKEN_FILE. This code never reads Claude Code's own credentials file. The scorer check
reads an OpenAI key from a 0600 file named by MAHORAGA_OPENAI_KEY_FILE.
"""
import argparse
import json
import os
import shutil
import stat
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import executor  # noqa: E402
import preflight  # noqa: E402

CODEX_MODEL = "gpt-5.4-mini-2026-03-17"  # verified in the boundary (scorer check)
TESTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tests", "loop")


class _Parser(argparse.ArgumentParser):
    def error(self, message):  # usage is 64, so that 2 always means contamination
        self.print_usage(sys.stderr)
        sys.stderr.write("mahoraga loop: %s\n" % message)
        sys.exit(64)


def _secret(file_var, env_names):
    """Load a credential from the 0600 file named by $file_var into env_names (this process only).
    Exit 3 if it is absent, not yours, readable by others, or Claude Code's own credentials file."""
    path = os.environ.get(file_var)
    if path:
        st = os.stat(path)
        if os.path.basename(path) == ".credentials.json" or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
            raise executor.LoopError(3, "%s must be your own 0600 file (not .credentials.json)" % file_var)
        for name in env_names:
            os.environ[name] = open(path).read().strip()
    if not os.environ.get(env_names[0]):
        raise executor.LoopError(3, "no credential: set %s or %s" % (env_names[0], file_var))
    return os.environ[env_names[0]]


def _credentials(a, o):
    """Load what this run needs; return [problems]. The arm's credential is an Anthropic API key
    (MAHORAGA_ANTHROPIC_KEY_FILE -> ANTHROPIC_API_KEY, billed per token) if one is given, else a
    subscription token (MAHORAGA_TOKEN_FILE -> CLAUDE_CODE_OAUTH_TOKEN)."""
    api_key = bool(os.environ.get("MAHORAGA_ANTHROPIC_KEY_FILE") or os.environ.get("ANTHROPIC_API_KEY"))
    o["token_env"] = "ANTHROPIC_API_KEY" if api_key else executor.TOKEN_ENV
    arm_file = "MAHORAGA_ANTHROPIC_KEY_FILE" if api_key else "MAHORAGA_TOKEN_FILE"
    problems = []
    for wanted, file_var, names, slot in ((a.paid, arm_file, (o["token_env"],), "token"),
                                          (a.scorer_check, "MAHORAGA_OPENAI_KEY_FILE", executor.CODEX_KEY_ENVS, "openai_key")):
        try:
            if wanted:
                o[slot] = _secret(file_var, names)
        except executor.LoopError as exc:
            problems.append(str(exc))
    return problems


def _scorer(o):
    """Run the scorer check; return an exit code on failure, else None."""
    s = preflight.scorer_check(o)
    print("  scorer: %s %s model=%s correct=%s usage=%s proxy=%s" % (s["status"], s["reason"], s["model"],
          s["correct"], s["usage"], json.dumps(s["proxy"])))
    if s["scan_hits"] or s["proxy"]["allow_breach"]:
        return 2
    if not s["passed"]:
        print("SCORER CHECK FAIL — the Codex scorer did not run or grade correctly in the boundary.", file=sys.stderr)
        return 3
    print("SCORER CHECK PASS (Codex %s in the boundary; family declared: gpt)" % s["model"])
    return None


def _canary(o, runs):
    c = preflight.canary(o, runs)
    for i, r in enumerate(c["runs"], 1):
        print("  canary %d: %s fired=%s usd=%s breaches=%s skill_calls=%s"
              % (i, r["status"], r["fired"], r["usd"], r["breaches"], r["skill_calls"]))
    print("  nested .claude/skills discovered: %s" % c["nested"]["loaded"])
    print("  always-on CLAUDE.md (%d bytes, instruction at the end) obeyed: %s" % (c["always_on"]["bytes"], c["always_on"]["fired"]))
    if not c["passed"]:
        print("CANARY FAIL — staged skills or the always-on file did not reach the model; arms would collapse "
              "to bare. STOP.", file=sys.stderr)
        return 3
    print("CANARY PASS (%d/%d)" % (len(c["runs"]), runs))
    return 0


def cmd_preflight(a):
    o = {"root": os.path.abspath(a.root), "image": a.image, "proxy_image": a.proxy_image, "model": a.model,
         "binary": a.binary or shutil.which("claude"), "allow": a.allow.split(","), "per_run_usd": a.per_run_usd,
         "agent_bin": os.path.abspath(a.agent_bin), "codex_binary": a.codex_binary or shutil.which("codex"),
         "scorer_model": a.scorer_model}
    os.makedirs(o["root"], exist_ok=True)
    problems = preflight.free_checks(o) + _credentials(a, o)
    if problems:
        for p in problems:
            print("PREFLIGHT FAIL: " + p, file=sys.stderr)
        return 3
    print("preflight: docker ok · binary %s… · images %s" % (o["binary_sha"][:12], json.dumps(o["digests"])))
    b = preflight.boundary(o)
    for x in b["attempts"]:
        print("  boundary: %s" % json.dumps(x))
    if b["escapes"] or not b["symlink_caught"] or not b["complete"]:
        print("BOUNDARY BREACH: escapes=%s symlink_caught=%s complete=%s proxy_log=%s"
              % (b["escapes"], b["symlink_caught"], b["complete"], b["proxy_log"]), file=sys.stderr)
        return 2
    print("preflight: boundary held — 0/4 escapes, planted symlink caught")
    code = _scorer(o) if a.scorer_check else None
    if code is not None:
        return code
    return _canary(o, a.runs) if a.paid else 0


def _options(a):
    """The option dict every campaign protocol reads, from the parsed arguments."""
    keys = ("campaign", "budget_usd", "model", "per_job_usd", "scorer_per_job_usd", "max_turns", "timeout_s", "image",
            "proxy_image", "runner", "max_sandbox_mb", "inputs", "dry_run", "agent_bin", "scorer_bin", "builtins", "scorer", "jobs")
    o = {k: getattr(a, k) for k in keys}
    o.update(config=os.path.abspath(a.config), root=os.path.abspath(a.root), units=a.units.split(","),
             scorer_model=a.scorer_model or (CODEX_MODEL if a.scorer == "codex" else a.model), allow=a.allow.split(","),
             binary=a.binary or shutil.which("claude"), codex_binary=a.codex_binary or shutil.which("codex"),
             seed=a.seed or a.campaign, stub=bool(a.agent_bin or a.scorer_bin or getattr(a, "editor_bin", None)))
    if a.cmd == "prove":
        o.update(arms=a.arms.split(","), k=a.k)
    elif a.cmd in ("gate", "run"):
        o.update(k=a.k, candidate=a.cmd == "gate" and os.path.abspath(a.candidate), parent=a.parent and os.path.abspath(a.parent),
                 veto=sorted(a.veto.split(",")) if a.veto else [], allow_noop=a.allow_noop, control_fixture=a.control_fixture,
                 editor_model=getattr(a, "editor_model", None) or a.model, editor_per_job_usd=getattr(a, "editor_per_job_usd", 0.5),
                 editor_bin=getattr(a, "editor_bin", None))
    else:
        o.update(editor_model=a.editor_model or a.model, editor_per_job_usd=a.editor_per_job_usd, editor_bin=a.editor_bin)
    return o


def cmd_campaign(a):
    """`prove`, `insample` and `gate`: build the options, load the credentials, run."""
    o = _options(a)
    a.paid, a.scorer_check = not a.dry_run, a.scorer == "codex" and not a.dry_run
    problems = _credentials(a, o)
    if problems:
        for p in problems:
            print("%s FAIL: %s" % (a.cmd.upper(), p), file=sys.stderr)
        return 3
    if a.runner != "docker" or o["stub"]:
        print("BANNER: %s — not decision-grade" % ", ".join(
            x for x in ("isolation instructed (local runner)" if a.runner != "docker" else "", "STUB RUN" if o["stub"] else "") if x))
    import campaign  # here, not at the top: `preflight` stays stdlib-only (campaigns need PyYAML)
    import heldout
    import insample
    return {"prove": campaign.prove, "insample": insample.run, "gate": heldout.run, "run": heldout.run}[a.cmd](o)


def cmd_status(a):
    """Progress by kind, arm and status — never a score, so status leaks no held-out number."""
    import collections
    path = os.path.join(os.path.abspath(a.root), a.project, "c-" + a.campaign, "ledger.jsonl")
    if not os.path.isfile(path):
        print("no campaign %s in project %s" % (a.campaign, a.project), file=sys.stderr)
        return 3
    rows = [json.loads(ln) for ln in open(path) if ln.strip()]
    for (kind, arm, status), n in sorted(collections.Counter((r["kind"], r.get("arm") or "-", r["status"]) for r in rows).items()):
        print("  %-9s %-7s %-17s %d" % (kind, arm, status, n))
    return 0


def _campaign_args(v):
    v.add_argument("--config", required=True, help="PROJECT.yaml with a loop: block (build image, inputs_dir)")
    v.add_argument("--campaign", required=True, help="campaign name; rerun the same command to resume")
    v.add_argument("--units", required=True, help="comma-separated unit ids (merge or commit shas)")
    v.add_argument("--budget-usd", type=float, required=True)
    v.add_argument("--model", default="claude-sonnet-5-5")
    v.add_argument("--scorer", choices=["claude", "codex"], default="claude")
    v.add_argument("--scorer-model", help="default: %s with --scorer codex, else --model" % CODEX_MODEL)
    v.add_argument("--codex-binary")
    v.add_argument("--per-job-usd", type=float, default=3.0)
    v.add_argument("--scorer-per-job-usd", type=float, default=0.5)
    v.add_argument("--max-turns", type=int, default=80)
    v.add_argument("--timeout-s", type=int, default=2400)
    v.add_argument("--max-sandbox-mb", type=int, default=2048)
    v.add_argument("--runner", choices=["docker", "local"], default="docker")
    v.add_argument("--inputs", help="dir with <unit>/SPEC.md + BUSINESS_REQUIREMENT.md (default: loop.inputs_dir)")
    v.add_argument("--seed")
    v.add_argument("--jobs", type=int, default=1, help="rollouts and scoring sessions run at once (each budget check counts the ones in flight)")
    v.add_argument("--dry-run", action="store_true", help="prepare, snapshot and dry-stage only: no model call")
    v.add_argument("--builtins", help="canary.json (or a JSON list) pinning the built-in skills; else the first rollout pins them")
    v.add_argument("--agent-bin", help=argparse.SUPPRESS)   # test stub for the implementer: stamps STUB RUN
    v.add_argument("--scorer-bin", help=argparse.SUPPRESS)  # test stub for the scorer: stamps STUB RUN
    _common(v)


def _common(f):
    f.add_argument("--root", default=os.path.join(os.environ.get("XDG_STATE_HOME") or
                                                  os.path.expanduser("~/.local/state"), "mahoraga", "loop"))
    f.add_argument("--binary")
    f.add_argument("--image", default="ubuntu:24.04")
    f.add_argument("--proxy-image", default="python:3.12-alpine")
    f.add_argument("--allow", default="api.anthropic.com")


def main(argv):
    p = _Parser(prog="mahoraga loop")
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=_Parser)
    f = sub.add_parser("preflight", help="free checks + boundary probe; --paid adds the canary")
    f.add_argument("--paid", action="store_true")
    f.add_argument("--model", default="haiku")
    f.add_argument("--runs", type=int, default=3)
    f.add_argument("--per-run-usd", type=float, default=0.5)
    _common(f)
    f.add_argument("--scorer-check", action="store_true")
    f.add_argument("--scorer-model", default=CODEX_MODEL)
    f.add_argument("--codex-binary")
    f.add_argument("--agent-bin", default=os.environ.get("MAHORAGA_LOOP_AGENT_BIN",
                                                         os.path.join(TESTS, "escape_agent.sh")))
    v = sub.add_parser("prove", help="blind PROVE: units x arms x k, code-launched, scored, reported")
    _campaign_args(v)
    v.add_argument("--arms", default="bare,pre")
    v.add_argument("--k", type=int, default=3)
    g = sub.add_parser("gate", help="the held-out gate: split, a frozen candidate, val x {pre, post} x k, the sealed rule")
    r = sub.add_parser("run", help="the loop: train evidence -> the contained proposer writes a candidate -> the held-out gate")
    for x in (g, r):
        _campaign_args(x)
        x.add_argument("--parent", help="the parent overlay dir (default: none, i.e. S0)")
        x.add_argument("--k", type=int, default=3, help=argparse.SUPPRESS)  # protocol constant; tests lower it (recorded in prereg)
        x.add_argument("--veto", help="comma-separated unit ids the owner excludes (hashed into the prereg)")
        x.add_argument("--allow-noop", action="store_true", help=argparse.SUPPRESS)       # an A/A control: candidate = parent
        x.add_argument("--control-fixture", action="store_true", help=argparse.SUPPRESS)  # hand-pinned criteria are honoured
    g.add_argument("--candidate", required=True, help="dir with practice.md and conventions.md (session-written: never promotable)")
    r.add_argument("--editor-model")
    r.add_argument("--editor-per-job-usd", type=float, default=0.5)
    r.add_argument("--editor-bin", help=argparse.SUPPRESS)  # test stub for the editor: stamps STUB RUN
    p_ = sub.add_parser("promote", help="write a VALID, proposer-made KEEP into the project's overlay dir (interactive)")
    p_.add_argument("--config", required=True)
    p_.add_argument("--campaign", required=True)
    p_.add_argument("--root", default=os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                                                   "mahoraga", "loop"))
    p_.add_argument("--dry-run", action="store_true", help="check and show the diff; write nothing")
    s = sub.add_parser("status", help="a campaign's progress, without any score")
    s.add_argument("--project", required=True)
    s.add_argument("--campaign", required=True)
    s.add_argument("--root", default=os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                                                  "mahoraga", "loop"))
    i = sub.add_parser("insample", help="the kill test: pre k=6, editor candidates, post k=3, Rules A/B")
    _campaign_args(i)
    i.add_argument("--editor-model")
    i.add_argument("--editor-per-job-usd", type=float, default=0.5)
    i.add_argument("--editor-bin", help=argparse.SUPPRESS)  # test stub for the editor: stamps STUB RUN
    a = p.parse_args(argv)
    try:
        if a.cmd == "status":
            return cmd_status(a)
        if a.cmd == "promote":
            import promote
            return promote.cmd(a)
        return cmd_campaign(a) if a.cmd in ("prove", "insample", "gate", "run") else cmd_preflight(a)
    except executor.LoopError as exc:
        print("mahoraga loop: %s" % exc, file=sys.stderr)
        return exc.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
