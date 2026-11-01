"""score.py — frozen criteria per unit, then one blind grading session per rollout.

The scorer is Codex (`--scorer codex`: another family, read-only view, priced from its token
counts) or Claude (tools-less, `--json-schema`; the implementer's family, so its scores are
flagged and never decide anything). Both run in the same boundary, on the same schema. Each grading session sees one candidate, built only from a fresh opaque view holding the
candidate diff, the reference diff, SPEC, BR and the frozen criteria; no arm, unit id, slug or
snapshot. business_req_pct is recomputed in code. An incomplete grade is scorer_failed: retried
once, then None, never 0. Defects are {present, note}: counted from the boolean, never from prose.

Criteria are frozen per unit ACROSS campaigns: stored under <root>/<project>/criteria/<unit>/<key>/,
key = hash of SPEC, BR, the human diff and the criteria prompt, so every campaign on the same inputs
grades against the same yardstick.
"""
import shutil
import hashlib
import json
import os
import re
import sys

import executor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from score_hygiene import recompute  # noqa: E402

MAX_DIFF = 120000
CODEX_PRICES = {"gpt-5.4-mini": (0.75, 0.075, 4.50), "gpt-5.4": (2.50, 0.25, 15.0),  # $/1M input, cached, output
                "gpt-5.5": (5.00, 0.50, 30.0)}  # list prices as published by aggregators, 2026-10


def codex_usd(model, usage):
    p = next((CODEX_PRICES[k] for k in sorted(CODEX_PRICES, key=len, reverse=True) if model.startswith(k)), None)
    if not p or not usage:
        return None
    cached = usage.get("cached_input_tokens") or 0
    return round(((usage.get("input_tokens", 0) - cached) * p[0] + cached * p[1] + usage.get("output_tokens", 0) * p[2]) / 1e6, 6)
_S = {"type": "string"}
_DEFECT = {"type": "object", "additionalProperties": False, "required": ["present", "note"],
           "properties": {"present": {"type": "boolean"}, "note": _S}}
CRITERIA_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["criteria"], "properties": {
    "criteria": {"type": "array", "items": {"type": "object", "additionalProperties": False,
                 "required": ["id", "criterion", "source", "weight"],
                 "properties": {"id": _S, "criterion": _S, "source": _S, "weight": {"type": "integer", "enum": [1, 2, 3]}}}}}}
GRADE_SCHEMA = {"type": "object", "additionalProperties": False,
                "required": ["criteria", "hallucination", "overeng", "lost_context", "code_quality", "security"],
                "properties": {
                    "criteria": {"type": "array", "items": {"type": "object", "additionalProperties": False,
                                 "required": ["id", "status", "evidence"],
                                 "properties": {"id": _S, "evidence": _S,
                                                "status": {"type": "string", "enum": ["full", "partial", "none"]}}}},
                    "hallucination": _DEFECT, "overeng": _DEFECT, "lost_context": _DEFECT,
                    "code_quality": {"type": "object", "additionalProperties": False, "required": ["overall", "rationale"],
                                     "properties": {"rationale": _S, "overall": {"type": "string",
                                                    "enum": ["better", "equal", "worse", "mixed"]}}},
                    "security": {"type": "object", "additionalProperties": False, "required": ["verdict"],
                                 "properties": {"verdict": _S}}}}
TEXT_FIELDS = ("hallucination", "overeng", "lost_context")


def _read(path, cap=None):
    text = open(path, errors="replace").read() if os.path.isfile(path) else ""
    return text if cap is None or len(text) <= cap else text[:cap] + "\n[... truncated at %d chars]\n" % cap


def _prompt(template, sections):
    body = open(os.path.join(HERE, "prompts", template)).read()
    return body + "".join("\n\n===== %s =====\n%s" % (k, v) for k, v in sections)


def _session(ctx, out, prompt, schema):
    """(result, structured output or None) from one scorer session on the configured backend."""
    work = os.path.join(out, "w")
    os.makedirs(work, exist_ok=True)
    if ctx["scorer"] == "codex":  # only `work` (holding the schema) is mounted, read-only
        with open(os.path.join(work, "schema.json"), "w") as fh:
            json.dump(schema, fh)
        job = dict(ctx["codex_job"], view=work, out=out, prompt=prompt)
        r = executor.run_scorer(job, secrets=ctx["secrets"])
        r.update(usd=codex_usd(job["model"], r["usage"]), breaches=[], cap=job["max_budget_usd"])
        return r, (r["output"] if r["status"] == "ok" else None)
    job = dict(ctx["scorer_job"], work=work, out=out, prompt=prompt, json_schema=schema)
    r = dict(executor.run(job, expect=ctx["expect"]["scorer"], secrets=ctx["secrets"]), cap=job["max_budget_usd"])
    parsed = executor.parse(open(os.path.join(out, "transcript.jsonl")).read())
    return r, ((parsed["result"] or {}).get("structured_output") if r["status"] == "ok" else None)


def _ask(ctx, out, prompt, schema, kind, rk, attempt):
    """One scorer session; ledger the attempt; return its structured output (or None)."""
    r, so = _session(ctx, out, prompt, schema)
    ctx["ledger"].append({"kind": kind, "runkey": rk, "attempt": attempt, "status": r["status"], "reason": r["reason"],
                          "usd": r["usd"], "usd_estimate": None if r["usd"] is not None else r["cap"],
                          "usage": r["usage"], "wall_s": r["wall_s"], "model": r["model"],
                          "family": {"value": ctx["scorer_family"], "basis": "declared"}, "breaches": r["breaches"],
                          "scan_hits": r["scan_hits"]}, final=False)
    if r["scan_hits"]:
        raise executor.LoopError(2, "a scorer transcript carried a credential (%s) — redacted; run INVALID" % kind)
    if r["reason"] == "auth":
        raise executor.LoopError(4, "the scorer could not authenticate")
    if r["status"] == "integrity_failed":
        raise executor.LoopError(5, "the %s session's init differed from what was staged (%s); run INVALID" % (kind, r["breaches"]))
    if r["status"] == "infra_failed":  # transient (429, 5xx, timeout): stop resumably, no DONE marker is written
        raise executor.LoopError(4, "a %s session failed (%s); resume to regrade" % (kind, r["reason"]))
    return so


def _norm(text):
    """Compare quotes by their words: markdown emphasis and quotation marks are dropped on both sides
    (Codex wraps every quoted source in quotation marks; the SPEC itself may contain some)."""
    return " ".join(re.sub(r"[`*\"\u201c\u201d\u2018\u2019']", "", str(text)).split()).lower()


def valid_criteria(so, ask):
    """The criteria if well-formed and each `source` is quoted from the SPEC/BR text `ask`; a
    criterion whose source is not in the ask is dropped (it came from the human diff, not the ask)."""
    crit = (so or {}).get("criteria") if isinstance(so, dict) else None
    if not isinstance(crit, list) or not 1 <= len(crit) <= 12:
        return None
    ids = [c.get("id") for c in crit if isinstance(c, dict)]
    if len(ids) != len(crit) or len(set(ids)) != len(ids) or \
            any(not str(c.get("criterion") or "").strip() or c.get("weight") not in (1, 2, 3) for c in crit):
        return None
    grounded = lambda c: len(_norm(c.get("source") or "")) >= 8 and _norm(c["source"]) in _norm(ask)  # noqa: E731
    kept = [{k: c[k] for k in ("id", "criterion", "source", "weight")} for c in crit if grounded(c)]
    return (kept, [c for c in crit if not grounded(c)]) if kept else None


def _load(path):
    try:
        return json.load(open(path))
    except ValueError:
        raise executor.LoopError(6, "%s is corrupt" % path)


def _freeze(src_dir, udir):
    for f in ("criteria.dropped.json", "criteria.json"):  # criteria.json last: its presence means frozen
        if os.path.isfile(os.path.join(src_dir, f)):
            shutil.copyfile(os.path.join(src_dir, f), os.path.join(udir, f + ".part"))
            os.replace(os.path.join(udir, f + ".part"), os.path.join(udir, f))


def criteria(ctx, unit):
    """The unit's frozen criteria: reused from the project store when the inputs match, else written
    once (before any arm is scored) to the store and the campaign, then only ever read."""
    udir = os.path.join(ctx["units_dir"], unit)
    path = os.path.join(udir, "criteria.json")
    if os.path.isfile(path):
        return _load(path)
    if os.path.isfile(os.path.join(udir, "criteria.failed")):  # decided once: a resume must not re-ask and change the prereg
        return None
    ref = "".join(_read(os.path.join(udir, f)) for f in sorted(os.listdir(udir)) if f.startswith("human_") and f.endswith(".diff"))
    prompt = _prompt("criteria.md", [("SPEC", _read(os.path.join(udir, "SPEC.md"))),
                                     ("BUSINESS REQUIREMENT", _read(os.path.join(udir, "BUSINESS_REQUIREMENT.md"))),
                                     ("REFERENCE DIFF", ref[:MAX_DIFF])])
    rk = hashlib.sha256(("criteria\0" + prompt).encode()).hexdigest()
    sdir = os.path.join(ctx["criteria_store"], unit, rk[:16])
    pinned = os.path.join(ctx["criteria_store"], unit, "pinned.json")  # written by hand: control fixtures only
    for src in ([pinned] if ctx.get("control_fixture") else []) + [os.path.join(sdir, "criteria.json")]:
        if os.path.isfile(src):
            shutil.copyfile(src, path + ".part")
            os.replace(path + ".part", path)
            return _load(path)
    ask = _read(os.path.join(udir, "SPEC.md")) + "\n" + _read(os.path.join(udir, "BUSINESS_REQUIREMENT.md"))
    for attempt in (1, 2):
        crit = valid_criteria(_ask(ctx, os.path.join(udir, "criteria-session-%d" % attempt), prompt, CRITERIA_SCHEMA,
                                   "criteria", rk, attempt), ask)
        if crit:
            os.makedirs(sdir, exist_ok=True)
            for f, data in (("criteria.dropped.json", crit[1]), ("criteria.json", crit[0])):
                with open(os.path.join(sdir, f + ".part"), "w") as fh:
                    json.dump(data, fh, indent=2)
                os.replace(os.path.join(sdir, f + ".part"), os.path.join(sdir, f))
            _freeze(sdir, udir)
            return crit[0]
    open(os.path.join(udir, "criteria.failed"), "w").close()
    return None


def view(ctx, rk, unit, crit):
    """A fresh opaque dir with the five things the scorer may see, and nothing that names the arm."""
    vdir = os.path.join(ctx["cdir"], "views", hashlib.sha256((ctx["seed"] + rk).encode()).hexdigest()[:16])
    os.makedirs(vdir, exist_ok=True)
    run, udir = ctx["ledger"].run_dir(rk), os.path.join(ctx["units_dir"], unit)
    parts = {"candidate.diff": "".join(_read(os.path.join(run, f)) for f in sorted(os.listdir(run)) if f.startswith("ai_")),
             "reference.diff": "".join(_read(os.path.join(udir, f)) for f in sorted(os.listdir(udir))
                                       if f.startswith("human_") and f.endswith(".diff")),
             "SPEC.md": _read(os.path.join(udir, "SPEC.md")), "BUSINESS_REQUIREMENT.md": _read(os.path.join(udir, "BUSINESS_REQUIREMENT.md")),
             "criteria.json": json.dumps(crit, indent=2)}
    for name, text in parts.items():  # the unit id (any prefix >= 7 hex) never reaches the scorer
        with open(os.path.join(vdir, name), "w") as fh:
            fh.write(re.sub(re.escape(unit[:7]) + "[0-9a-f]*", "", text))
    return vdir


def grade_prompt(vdir):
    v = lambda f, cap=None: _read(os.path.join(vdir, f), cap)  # noqa: E731
    return _prompt("grade.md", [("CRITERIA", v("criteria.json")), ("SPEC", v("SPEC.md")),
                                ("BUSINESS REQUIREMENT", v("BUSINESS_REQUIREMENT.md")),
                                ("REFERENCE DIFF", v("reference.diff", MAX_DIFF)), ("CANDIDATE DIFF", v("candidate.diff", MAX_DIFF))])


def merge(so, crit):
    """business_criteria if `so` grades every frozen criterion exactly once and every defect field is
    {present: bool, note: str}, else None."""
    if not isinstance(so, dict) or any(not isinstance(so.get(k), dict) or not isinstance(so[k].get("present"), bool)
                                       or not isinstance(so[k].get("note"), str) for k in TEXT_FIELDS):
        return None
    got = {c.get("id"): c for c in so.get("criteria") or [] if isinstance(c, dict)}
    if len(got) != len(so.get("criteria") or []) or set(got) != {c["id"] for c in crit}:
        return None
    return [dict(c, status=got[c["id"]].get("status"), evidence=str(got[c["id"]].get("evidence") or ""))
            for c in crit]


def grade(ctx, rk, srk, unit, crit, row, tag="score"):
    """The score dict for rollout `rk` (attempts ledgered under the score key `srk`). `empty` is
    code-scored: every criterion none, no session."""
    model = ctx["codex_job"]["model"] if ctx["scorer"] == "codex" else ctx["scorer_job"]["model"]
    base = {"compile": row.get("compile") or "n/a", "scorer": ctx["scorer"] + "-scorer", "scorer_model": model,
            "scorer_family": ctx["scorer_family"], "implementer_family": "claude", "business_req_pct": None}
    if row["status"] == "empty":
        so = {"criteria": [{"id": c["id"], "status": "none", "evidence": "absent"} for c in crit],
              **{k: {"present": False, "note": ""} for k in TEXT_FIELDS},
              "code_quality": {"overall": "worse", "rationale": "no change was produced"},
              "security": {"verdict": "none — parity/better"}}
        return recompute(dict(base, business_criteria=merge(so, crit), status="ok", scored_by="code", **_extras(so)))
    prompt = grade_prompt(view(ctx, rk, unit, crit))
    out = os.path.join(ctx["ledger"].run_dir(rk), tag)
    for attempt in (1, 2):
        so = _ask(ctx, "%s-%d" % (out, attempt), prompt, GRADE_SCHEMA, "score", srk, attempt)
        bc = merge(so, crit)
        if bc:
            return recompute(dict(base, business_criteria=bc, status="ok", scored_by="model", **_extras(so)))
    return dict(base, business_criteria=None, status="scorer_failed", scored_by="model",
                business_req_source="missing", hallucination=None, overeng=None, lost_context=None,
                code_quality={"overall": None}, security={"verdict": None})


def _extras(so):
    """Score fields for SCORE.schema: each defect as "none" or its note (never a note that reads as
    "none" when present), plus <field>_present, the boolean the loop counts."""
    out = {k: so[k] for k in ("code_quality", "security")}
    for k in TEXT_FIELDS:
        note = so[k]["note"].strip()
        out[k + "_present"] = so[k]["present"]
        out[k] = ("defect: " + note if not note or re.match(r"(?i)none\b", note) else note) if so[k]["present"] else "none"
    return out
