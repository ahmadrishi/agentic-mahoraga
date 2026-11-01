#!/usr/bin/env python3
# build_report.py <RUN_DIR>
# Project-agnostic HTML report: split-diff (human left, AI right) + scoreboard + adversarial
# evidence + weakness blocks. Reads <RUN_DIR>/scores.json (from aggregate_scores.py) and each
# unit's on-disk artifacts. Theme-aware, self-contained, responsive. Credential scan before write.
# Stdlib only. Emits report.html + report_artifact.html (body-only).
import os, re, html, json, glob, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report_ablation import ablation_sections, unit_chips  # sibling (keeps this file under the LOC cap)

def main(argv):
    if not argv:
        sys.exit("usage: build_report.py <RUN_DIR>")
    RUN_DIR = os.path.abspath(argv[0])
    OUT = os.path.join(RUN_DIR, "report.html")
    sp = os.path.join(RUN_DIR, "scores.json")
    if not os.path.isfile(sp):
        sys.exit(f"no scores.json in {RUN_DIR} — run aggregate_scores.py first")
    SCORES = json.load(open(sp))
    agg = SCORES.get("aggregate", {})
    tasks_all = SCORES.get("tasks", [])
    # The scoreboard + per-unit sections render the HARNESS arm only (the primary result); the
    # baseline arm is surfaced in the aggregate Ablation panel. Absent arm => harness (back-compat).
    tasks = [t for t in tasks_all if not t.get("documented_only")
             and str(t.get("arm") or "harness").strip().lower() != "baseline"]
    documented = [t for t in tasks_all if t.get("documented_only")]
    project_name = agg.get("project_name") or "Project"

    def esc(s): return html.escape(str(s), quote=True)
    ab_css, ab_html = ablation_sections(agg, esc)  # ablation / distributions / sampling-frame

    def _clean_path(s):
        s = s.split('\t')[0].strip()
        for pre in ("a/", "b/"):
            if s.startswith(pre): s = s[2:]
        # strip the sandbox-root prefix (…/<project>-mahoraga-sandboxes/<slug>/) and any UNIT-key dir
        s = re.sub(r'^.*/[^/]*-mahoraga-sandboxes/[^/]+/', '', s)
        s = re.sub(r'^.*/[A-Z]+-\d+/', '', s)
        return s

    def parse_diff(path):
        if not path or not os.path.isfile(path): return []
        try: raw = open(path, encoding="utf-8", errors="replace").read()
        except Exception: return []
        if not raw.strip(): return []
        files = []; cur = None; oldn = newn = 0
        for ln in raw.splitlines():
            if ln.startswith('diff '):
                cur = {'name': None, 'adds': 0, 'dels': 0, 'hunks': []}; files.append(cur)
                m = re.search(r' a/(\S+) b/\S+$', ln)
                if m: cur['name'] = m.group(1)
                else:
                    paths = [t for t in ln.split()[1:] if not t.startswith('-')]
                    if paths: cur['name'] = _clean_path(paths[0])
                oldn = newn = 0; continue
            if cur is None: continue
            if ln.startswith('--- '):
                p = _clean_path(ln[4:])
                if (not cur['name'] or cur['name'] == '/dev/null') and p != '/dev/null': cur['name'] = p
                continue
            if ln.startswith('+++ '):
                p = _clean_path(ln[4:])
                if p and p != '/dev/null': cur['name'] = p
                continue
            if re.match(r'^(index |new file|deleted file|similarity|rename |copy |old mode|new mode|Binary files|\\ )', ln):
                continue
            m = re.match(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$', ln)
            if m:
                oldn = int(m.group(1)); newn = int(m.group(2))
                cur['hunks'].append({'header': m.group(3).strip(), 'lines': []}); continue
            if not cur['hunks']: continue
            h = cur['hunks'][-1]
            if ln.startswith('+'): h['lines'].append(('', newn, 'add', ln[1:])); newn += 1; cur['adds'] += 1
            elif ln.startswith('-'): h['lines'].append((oldn, '', 'del', ln[1:])); oldn += 1; cur['dels'] += 1
            else:
                txt = ln[1:] if ln.startswith(' ') else ln
                h['lines'].append((oldn, newn, 'ctx', txt)); oldn += 1; newn += 1
        return files

    def files_to_html(files):
        if not files: return '<div class="empty">— no changes captured —</div>'
        out = []
        for f in files:
            name = f['name'] or 'file'
            if '/' in name:
                d, b = name.rsplit('/', 1); nm = f'<span class="fdir">{esc(d)}/</span><b>{esc(b)}</b>'
            else: nm = f'<b>{esc(name)}</b>'
            stat = ''
            if f['adds']: stat += f'<span class="cadd">+{f["adds"]}</span>'
            if f['dels']: stat += f'<span class="cdel">&minus;{f["dels"]}</span>'
            rows = []
            for h in f['hunks']:
                hdr = esc(h['header']) if h['header'] else ''
                rows.append(f'<tr class="hunkrow"><td class="ln"></td><td class="ln"></td><td class="mk"></td><td class="code">@@ {hdr}</td></tr>')
                for (o, n, t, txt) in h['lines']:
                    disp = txt if len(txt) <= 500 else txt[:500] + ' …'
                    mk = '+' if t == 'add' else ('&minus;' if t == 'del' else '')
                    rows.append(f'<tr class="{t}"><td class="ln">{o}</td><td class="ln">{n}</td><td class="mk">{mk}</td><td class="code">{esc(disp) or "&nbsp;"}</td></tr>')
            out.append(f'<div class="fcard"><div class="fhead"><span class="fname">{nm}</span><span class="fstat">{stat}</span></div>'
                       f'<div class="fbody"><table class="dt">{"".join(rows)}</table></div></div>')
        return ''.join(out)

    def pct_badge(v):
        if v is None: return '<span class="badge grey">not measured</span>'
        try: v = int(round(float(v)))
        except Exception: return f'<span class="badge grey">{esc(v)}</span>'
        c = "green" if v >= 85 else ("amber" if v >= 65 else "red")
        return f'<span class="badge {c}">{v}%</span>'

    def score_badge(v):
        try: v = int(round(float(v)))
        except Exception: return f'<span class="badge grey">{esc(v)}</span>'
        c = "green" if v >= 85 else ("amber" if v >= 70 else "red")
        return f'<span class="badge {c}">{v}</span>'

    def verdict_badge(v):
        v = (v or "").lower()
        if v.startswith("better"): return '<span class="badge green">better</span>'
        if v.startswith("equal") or v.startswith("par"): return '<span class="badge slate">equal</span>'
        if v.startswith("worse"): return '<span class="badge red">worse</span>'
        if v.startswith("mixed"): return '<span class="badge amber">mixed</span>'
        return f'<span class="badge grey">{esc(v or "—")}</span>'

    def sec_badge(v):
        v = (v or "").lower()
        if "net-new" in v or "net new" in v or v.startswith("threat"): return '<span class="badge red">net-new threat</span>'
        if "none" in v or "parity" in v or "better" in v: return '<span class="badge green">none · parity/better</span>'
        if "n/a" in v: return '<span class="badge slate">n/a</span>'
        return f'<span class="badge grey">{esc(v or "—")}</span>'

    def compile_badge(v):
        v = (v or "").upper()
        if "SUCCESS" in v: return '<span class="badge green">✓ compiles</span>'
        if "FAIL" in v: return '<span class="badge red">✗ fails</span>'
        if "N/A" in v or "NA" in v: return '<span class="badge slate">n/a</span>'
        return f'<span class="badge grey">{esc(v or "—")}</span>'

    def crit_verdict_cls(v):
        v = (v or "").lower()
        if v.startswith("full") or v == "yes": return ("full", "✓ full")
        if v.startswith("part"): return ("part", "◑ partial")
        if v.startswith("non") or v.startswith("no"): return ("none", "✗ not met")
        return ("na", esc(v or "—"))

    def g(k, d="—"): return agg.get(k, d)
    tiles = [(str(g("n_tasks", len(tasks))), "shipped units (blind, spec + business req)"),
             (str(g("compile_backend")), "backend builds that compile"),
             (str(g("business_req_avg")) if g("business_req_avg") is not None else "not measured", "avg business-requirement achieved %"),
             (str(g("reuse_better_equal")), "reuse ≥ human (better/equal)"),
             (f"{g('hallucinations', 0)} / {g('overeng', 0)}", "hallucinated / over-engineered"),
             (str(g("security_net_new")), "net-new security threats vs human")]
    hero = "".join(f'<div class="tile"><div class="tnum">{esc(n)}</div><div class="tlbl">{esc(l)}</div></div>' for n, l in tiles)

    def block(label, txt, cls):
        if not txt or str(txt).strip().lower() in ("none", "n/a", "-", ""): return ""
        return f'<div class="assess {cls}"><b>{esc(label)}</b> {esc(txt)}</div>'

    def _none_like(v):
        s = str(v).strip().lower()
        return (not s) or s.startswith("none") or s in ("n/a", "na", "-", "parity")

    def wblock(label, txt, cls):
        if _none_like(txt): return ""
        return f'<div class="assess {cls}"><b>{esc(label)}</b> {esc(txt)}</div>'

    def read_excerpt(path, n=2600):
        if not path or not os.path.isfile(path): return ""
        try: s = open(path, encoding="utf-8", errors="replace").read().strip()
        except Exception: return ""
        return s if len(s) <= n else s[:n] + "\n…(truncated)…"

    def evidence(tid, t):
        arts = t.get("artifacts", {}) or {}
        pieces = []
        for label, key, default in (("Reviewer", "reviewer", "review_reviewer.md"),
                                    ("Red-team", "redteam", "review_redteam.md"),
                                    ("Verifier (reconciled)", "verifier", "review_verifier.md")):
            path = arts.get(key) or os.path.join(RUN_DIR, tid, default)
            if not os.path.isabs(path): path = os.path.join(RUN_DIR, tid, path)
            ex = read_excerpt(path)
            if ex:
                pieces.append(f'<div class="evrole">{esc(label)}</div><pre class="ev">{esc(ex)}</pre>')
        if not pieces: return ""
        return ('<details class="eviddetails"><summary>Adversarial review evidence '
                '(reviewer → red-team → reconciling verifier)</summary>' + "".join(pieces) + '</details>')

    # scoreboard rows
    rows = []
    for t in tasks:
        cq = t.get("code_quality", {}) or {}
        rows.append(f'''<tr>
          <td class="tid"><a href="#{esc(t.get("id"))}">{esc(t.get("id"))}</a></td>
          <td>{esc(t.get("complexity", t.get("size", "")))}</td>
          <td class="mono">{esc((t.get("artifacts", {}) or {}).get("repo", t.get("repo", "")))}</td>
          <td class="ctr">{pct_badge(t.get("business_req_pct"))}</td>
          <td class="ctr">{verdict_badge(cq.get("overall"))}</td>
          <td class="ctr">{sec_badge((t.get("security") or {}).get("verdict"))}</td>
          <td class="ctr">{compile_badge(t.get("compile"))}</td>
          <td class="ctr">{score_badge(t.get("spec_fidelity"))}</td>
          <td class="rv">{esc(t.get("verdict", ""))}</td>
        </tr>''')

    def crit_table(crits):
        if not crits: return ""
        r = []
        for c in crits:
            cls, label = crit_verdict_cls(c.get("status", c.get("verdict")))
            r.append(f'<tr class="cr-{cls}"><td class="crv">{label}</td><td class="crc">{esc(c.get("criterion", ""))}</td><td class="cre">{esc(c.get("evidence", ""))}</td></tr>')
        return ('<table class="crit"><thead><tr><th>Verdict</th><th>Acceptance criterion (from business requirement / spec)</th><th>Code evidence</th></tr></thead>'
                f'<tbody>{"".join(r)}</tbody></table>')

    def cq_grid(cq):
        if not cq: return ""
        dims = [("Reuse", "reuse"), ("Architecture / layering", "architecture"),
                ("Patterns / conventions", "patterns"), ("Maintainability / complexity", "maintainability")]
        cells = []
        for label, key in dims:
            v = cq.get(key, ""); note = cq.get(key + "_note", "")
            cells.append(f'<div class="cqcell"><div class="cqk">{esc(label)} {verdict_badge(v)}</div><div class="cqn">{esc(note)}</div></div>')
        return f'<div class="cqgrid">{"".join(cells)}</div>'

    sections = []
    for t in tasks:
        tid = t.get("id"); brp = t.get("business_req_pct", 0) or 0
        try: brpv = float(brp)
        except Exception: brpv = 0
        accent = "green" if brpv >= 85 else ("amber" if brpv >= 65 else "red")
        human_files = sum((parse_diff(p) for p in sorted(glob.glob(os.path.join(RUN_DIR, tid, "human_*.diff")))), [])
        ai_files = sum((parse_diff(p) for p in sorted(glob.glob(os.path.join(RUN_DIR, tid, "ai_*.diff")))), [])
        human_html = files_to_html(human_files); ai_html = files_to_html(ai_files)
        cq = t.get("code_quality", {}) or {}; sec = t.get("security", {}) or {}
        weak = (wblock("Hallucination:", t.get("hallucination"), "red")
                + wblock("Over-engineering:", t.get("overeng"), "amber")
                + wblock("Lost context (had spec + business req, still missed):", t.get("lost_context"), "amber"))
        extra = (block("Caught a spec / business-req issue:", t.get("caught_spec_error"), "good")
                 + block("Divergence from human (reference):", t.get("divergence"), "slate")
                 + block("Value added (surfaced, not over-built):", t.get("value_add"), "good")
                 + block("Evaluator note:", t.get("eval_note"), "slate"))
        sections.append(f'''
        <section class="task {accent}" id="{esc(tid)}">
          <div class="thead">
            <h3>{esc(tid)} <span class="ttitle">{esc(t.get("complexity", t.get("size", "")))} · {esc(t.get("title", t.get("type", "")))}</span></h3>
            <div class="tmeta">
              {unit_chips(t, esc)}
              <span class="chip">AI {esc(t.get("ai_stat", ""))}</span>
              <span class="chip">human {esc(t.get("human_stat", ""))}</span>
            </div>
          </div>
          <div class="scorestrip">
            <span>Business req <b>{pct_badge(t.get("business_req_pct"))}</b></span>
            <span>Code quality <b>{verdict_badge(cq.get("overall"))}</b></span>
            <span>Security <b>{sec_badge(sec.get("verdict"))}</b></span>
            <span>Compile <b>{compile_badge(t.get("compile"))}</b></span>
            <span>Spec-fidelity <b>{score_badge(t.get("spec_fidelity"))}</b></span>
          </div>
          <h4>1 · Business requirement achieved — {pct_badge(t.get("business_req_pct"))}</h4>
          {crit_table(t.get("business_criteria", t.get("business_req_table")))}
          <h4>2 · Code quality (vs human reference)</h4>
          {cq_grid(cq)}
          {block("Overall code-quality verdict:", (str(cq.get("overall", "")) + (" — " + cq.get("rationale", "") if cq.get("rationale") else "")), "slate")}
          <h4>3 · Security</h4>
          {block("Verdict:", str(sec.get("verdict", "")) + (" — " + sec.get("evidence", "") if sec.get("evidence") else ""), "good" if "none" in (str(sec.get("verdict", "")).lower()) else "red")}
          <h4>Named weaknesses &amp; notes</h4>
          {weak or '<div class="assess good"><b>None found</b> — no hallucination, over-engineering, or lost-context surfaced by the review loop.</div>'}{extra}
          {evidence(tid, t)}
          <div class="verdict"><b>Reconciled verdict</b> · {esc(t.get("verdict", ""))}</div>
          <h4>Human (shipped) vs AI (blind) — split diff</h4>
          <div class="splitwrap">
            <div class="col"><div class="colh human"><span class="dot"></span>HUMAN — shipped (reference)</div><div class="diff">{human_html}</div></div>
            <div class="col"><div class="colh ai"><span class="dot"></span>AI — blind, from spec + business requirement + skills</div><div class="diff">{ai_html}</div></div>
          </div>
        </section>''')

    doc_sections = []
    for t in documented:
        doc_sections.append(f'''<section class="task slate" id="{esc(t.get("id"))}">
          <div class="thead"><h3>{esc(t.get("id"))} <span class="ttitle">documented · not scored</span></h3></div>
          <div class="assess slate"><b>{esc(t.get("verdict", ""))}</b> {esc(t.get("eval_note", t.get("note", "")))}</div>
        </section>''')
    doc_html = ('<h2>Attempted units — documented, not scored</h2>' + "".join(doc_sections)) if doc_sections else ""

    CSS = """
:root{--bg:#eef1f5;--ink:#151b23;--mut:#5b6672;--line:#e2e6eb;--card:#fff;--soft:#f7f9fb;
 --blue:#0b6bce;--green:#127a3b;--red:#cf222e;--amber:#9a6700;--slate:#64748b;
 --addbg:#e9fbef;--addln:#d6f5e0;--addmk:#127a3b;--delbg:#fdecee;--delln:#ffdce0;--delmk:#cf222e;--hunk:#eef4ff;
 --grad1:#0f2740;--grad2:#1b4a76;--fh:#f3f6f9;}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
 --bg:#0d1117;--ink:#e6edf3;--mut:#9aa7b4;--line:#232b36;--card:#141b23;--soft:#0f151d;
 --addbg:#0f2b1c;--addln:#123524;--addmk:#3fb950;--delbg:#2d151a;--delln:#3b1a20;--delmk:#f85149;--hunk:#111a2e;--fh:#0f1620;}}
:root[data-theme="dark"]{
 --bg:#0d1117;--ink:#e6edf3;--mut:#9aa7b4;--line:#232b36;--card:#141b23;--soft:#0f151d;
 --addbg:#0f2b1c;--addln:#123524;--addmk:#3fb950;--delbg:#2d151a;--delln:#3b1a20;--delmk:#f85149;--hunk:#111a2e;--fh:#0f1620;}
*{box-sizing:border-box}
body{margin:0;font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Inter,sans-serif;color:var(--ink);background:var(--bg)}
.wrap{max-width:1340px;margin:0 auto;padding:0 20px 90px}
header{background:linear-gradient(135deg,var(--grad1),var(--grad2));color:#fff;padding:34px 0 30px;margin-bottom:22px}
header .wrap{padding-bottom:0}
h1{margin:0 0 8px;font-size:26px;letter-spacing:-.4px}
.sub{color:#c3d4e6;font-size:13.5px;max-width:1040px}
.hero{display:grid;grid-template-columns:repeat(6,1fr);gap:12px;margin-top:22px}
.tile{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.14);border-radius:12px;padding:14px}
.tnum{font-size:23px;font-weight:800;letter-spacing:-.5px}
.tlbl{font-size:11px;color:#c3d4e6;margin-top:3px;line-height:1.35}
h2{font-size:12.5px;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);margin:34px 0 14px;padding-bottom:7px;border-bottom:1px solid var(--line)}
h4{font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--mut);margin:16px 0 8px}
table.board{width:100%;border-collapse:separate;border-spacing:0;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden;font-size:13px}
.board th{background:var(--soft);text-align:left;padding:11px 10px;font-size:10.5px;text-transform:uppercase;letter-spacing:.05em;color:var(--mut)}
.board td{padding:10px 10px;border-top:1px solid var(--line);vertical-align:top}
.board td.tid{font-weight:800;white-space:nowrap}.board td.ctr{text-align:center}
.board td.tid a{color:var(--ink);text-decoration:none;border-bottom:1px dotted var(--mut)}
.board td.rv{font-size:12px;color:var(--mut);max-width:340px;line-height:1.45}
.mono{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:12px;color:var(--mut)}
.badge{display:inline-block;min-width:30px;text-align:center;padding:2px 9px;border-radius:20px;font-weight:800;font-size:11px;color:#fff}
.badge.green{background:var(--green)}.badge.amber{background:var(--amber)}.badge.red{background:var(--red)}.badge.grey{background:#8b97a5}.badge.slate{background:var(--slate)}
.note{font-size:12.5px;color:var(--mut);margin-top:10px;line-height:1.55}
section.task{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--slate);border-radius:12px;padding:18px 20px;margin:18px 0}
section.task.green{border-left-color:var(--green)}section.task.amber{border-left-color:var(--amber)}section.task.red{border-left-color:var(--red)}
.thead{display:flex;justify-content:space-between;align-items:flex-start;gap:14px;flex-wrap:wrap}
section.task h3{margin:0;font-size:17px;letter-spacing:-.2px}
.ttitle{font-weight:500;color:var(--mut);font-size:13.5px;margin-left:6px}
.tmeta{display:flex;flex-wrap:wrap;gap:9px;font-size:12px;color:var(--mut);align-items:center}
.chip{background:var(--soft);border:1px solid var(--line);border-radius:20px;padding:3px 10px;font-size:11.5px;color:var(--ink)}
.scorestrip{display:flex;flex-wrap:wrap;gap:16px;margin:12px 0 4px;padding:10px 12px;background:var(--soft);border:1px solid var(--line);border-radius:8px;font-size:12.5px}
.verdict{font-size:12.5px;background:var(--soft);border:1px solid var(--line);border-left:3px solid var(--blue);border-radius:8px;padding:8px 12px;margin:12px 0 4px}
.assess{font-size:12.5px;border-radius:8px;padding:7px 11px;margin:7px 0;line-height:1.5}
.assess.amber{background:#fff8e6;border:1px solid #f0e2ad;color:#6b5200}
.assess.red{background:#fdecee;border:1px solid #f4c9cf;color:#8a1c25}
.assess.slate{background:var(--soft);border:1px solid var(--line);color:var(--ink)}
.assess.good{background:#e9fbef;border:1px solid #bfe9cd;color:#0d5a2b}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .assess.amber{background:#241d07;border-color:#4d3d0e;color:#e3c766}
 :root:not([data-theme="light"]) .assess.red{background:#2a1114;border-color:#5c2027;color:#f0a0a8}
 :root:not([data-theme="light"]) .assess.good{background:#0f2b1c;border-color:#123524;color:#7fd7a0}}
:root[data-theme="dark"] .assess.amber{background:#241d07;border-color:#4d3d0e;color:#e3c766}
:root[data-theme="dark"] .assess.red{background:#2a1114;border-color:#5c2027;color:#f0a0a8}
:root[data-theme="dark"] .assess.good{background:#0f2b1c;border-color:#123524;color:#7fd7a0}
table.crit{width:100%;border-collapse:collapse;font-size:12.5px;margin:2px 0 4px}
.crit th{text-align:left;background:var(--soft);color:var(--mut);font-size:10.5px;text-transform:uppercase;letter-spacing:.04em;padding:6px 8px;border:1px solid var(--line)}
.crit td{padding:6px 8px;border:1px solid var(--line);vertical-align:top}
.crit td.crv{white-space:nowrap;font-weight:800;font-size:11.5px}
.crit td.crc{width:44%}.crit td.cre{color:var(--mut);font-family:ui-monospace,Menlo,monospace;font-size:11px}
.cr-full td.crv{color:var(--green)}.cr-part td.crv{color:var(--amber)}.cr-none td.crv{color:var(--red)}
.cqgrid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:4px 0}
.cqcell{background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:8px 10px}
.cqk{font-size:12px;font-weight:700;margin-bottom:3px}
.cqn{font-size:12px;color:var(--mut);line-height:1.45}
.eviddetails{margin:8px 0;border:1px solid var(--line);border-radius:8px;background:var(--soft);padding:4px 10px}
.eviddetails summary{cursor:pointer;font-size:12px;font-weight:700;color:var(--mut);padding:4px 0}
.evrole{font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:var(--blue);font-weight:800;margin:8px 0 3px}
pre.ev{white-space:pre-wrap;font-family:ui-monospace,Menlo,monospace;font-size:11px;line-height:1.5;background:var(--card);border:1px solid var(--line);border-radius:6px;padding:8px 10px;max-height:320px;overflow:auto;margin:0 0 6px}
.splitwrap{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:6px}
.col{border:1px solid var(--line);border-radius:10px;overflow:hidden;min-width:0;background:var(--card)}
.diff{overflow:auto;max-height:640px}
.colh{position:sticky;top:0;z-index:3;display:flex;align-items:center;gap:8px;font-size:11px;font-weight:800;letter-spacing:.05em;padding:8px 12px;color:#fff}
.colh .dot{width:8px;height:8px;border-radius:50%;background:rgba(255,255,255,.85)}
.colh.human{background:#54606d}.colh.ai{background:#0b6bce}
.fcard{border-bottom:1px solid var(--line)}
.fhead{display:flex;justify-content:space-between;align-items:center;gap:10px;padding:7px 12px;background:var(--fh);border-bottom:1px solid var(--line);font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:11.5px}
.fname b{font-weight:700}.fdir{color:var(--mut)}
.fstat{white-space:nowrap;font-weight:800}.cadd{color:var(--green);margin-left:8px}.cdel{color:var(--red);margin-left:8px}
.fbody{overflow-x:auto}
table.dt{border-collapse:collapse;width:100%;font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:11.5px;line-height:1.6}
.dt td{padding:0 8px;vertical-align:top}
.dt td.ln{width:1%;white-space:nowrap;text-align:right;color:#9aa7b4;background:var(--soft);border-right:1px solid var(--line);user-select:none;font-size:11px}
.dt td.mk{width:1%;text-align:center;color:#9aa7b4;background:var(--soft)}
.dt td.code{white-space:pre;color:var(--ink);tab-size:2}
.dt tr.add td.code{background:var(--addbg)}.dt tr.add td.ln{background:var(--addln)}.dt tr.add td.mk{background:var(--addbg);color:var(--addmk);font-weight:800}
.dt tr.del td.code{background:var(--delbg)}.dt tr.del td.ln{background:var(--delln)}.dt tr.del td.mk{background:var(--delbg);color:var(--delmk);font-weight:800}
.dt tr.hunkrow td{background:var(--hunk);color:var(--slate);font-size:11px;padding:3px 8px;border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
.empty{padding:18px;color:var(--mut);font-style:italic;font-size:12.5px}
.legend{display:flex;gap:18px;flex-wrap:wrap;font-size:12px;color:var(--mut);margin:6px 2px 0}
.legend i{display:inline-block;width:11px;height:11px;border-radius:3px;vertical-align:-1px;margin-right:5px}
footer{margin-top:40px;font-size:12px;color:var(--mut);text-align:center}
@media(max-width:1000px){.hero{grid-template-columns:repeat(3,1fr)}.splitwrap,.cqgrid{grid-template-columns:1fr}}
@media(max-width:560px){.hero{grid-template-columns:repeat(2,1fr)}}
"""
    CSS = CSS + ab_css  # ablation/distributions/sampling-frame styles (theme-aware, same palette vars)

    BODY = f"""<title>{esc(project_name)} — Agentic Eval</title><style>{CSS}</style>
<header><div class="wrap">
  <h1>{esc(project_name)} — Agentic Setup Evaluation</h1>
  <div class="sub">{esc(agg.get('headline', ''))}</div>
  <div class="sub" style="margin-top:8px">Protocol: each unit is re-implemented by a fresh <b>blind</b> agent given <b>both the SPEC and the original business requirement</b>, in a git-history-free sandbox at the unit's fork-point, with the project's skills, and scored by the scorer named in the headline above. The human branch is the comparison reference — <b>not</b> a match target.</div>
  <div class="hero">{hero}</div>
</div></header>
<div class="wrap">
{ab_html}
<h2>Scoreboard</h2>
<table class="board"><thead><tr>
<th>Unit</th><th>Size</th><th>Repo(s)</th><th>Business&nbsp;req</th><th>Code&nbsp;quality</th><th>Security</th><th>Compile</th><th>Spec-fid</th><th>Reconciled verdict</th>
</tr></thead><tbody>
{''.join(rows)}
</tbody></table>
<div class="note">{esc(agg.get('scoreboard_note', ''))}</div>
<h2>Per-unit — business requirement, code quality, security, weaknesses, and the split diff</h2>
<div class="legend"><span><i style="background:var(--addbg);border:1px solid var(--addln)"></i>added</span><span><i style="background:var(--delbg);border:1px solid var(--delln)"></i>removed</span><span><i style="background:var(--hunk);border:1px solid var(--line)"></i>hunk context</span><span>Left = human&nbsp;· Right = AI (blind)</span></div>
{''.join(sections)}
{doc_html}
<footer>Generated from on-disk artifacts (SPEC.md · BUSINESS_REQUIREMENT.md · human/ai diffs · review transcripts (if any) · compile logs · scores.json). Blind agents saw only the spec + business requirement + skills; scoring compared against the shipped human branch as a reference.</footer>
</div>"""

    # assemble head + body explicitly from BODY (which begins <title>…<style>…</style>)
    title = f"{esc(project_name)} — Agentic Eval"
    style = BODY.split("<style>", 1)[1].split("</style>", 1)[0]
    page_body = BODY.split("</style>", 1)[1]
    FULL = (f'<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{title}</title><style>{style}</style></head><body>{page_body}</body></html>')

    # credential scan — redact obvious secrets before writing
    redactions = 0
    def redact(s):
        nonlocal redactions
        # cover BOTH raw and html-escaped forms — the report content is html.escape()'d, so a
        # settings.xml <password>…</password> arrives as &lt;password&gt;…&lt;/password&gt;.
        pats = [r'(?i)<password>.*?</password>', r'(?i)&lt;password&gt;.*?&lt;/password&gt;',
                r'(?i)<username>.*?</username>', r'(?i)&lt;username&gt;.*?&lt;/username&gt;',
                r'(?i)password\s*[:=]\s*\S+', r'(?i)authorization:\s*\S+',
                r'(?i)aws_secret\S*\s*[:=]\s*\S+']
        for p in pats:
            s, k = re.subn(p, '[REDACTED]', s)
            redactions += k
        return s
    FULL = redact(FULL)
    art_body = redact(f'<title>{title}</title><style>{style}</style>{page_body}')

    open(OUT, "w", encoding="utf-8").write(FULL)
    open(os.path.join(RUN_DIR, "report_artifact.html"), "w", encoding="utf-8").write(art_body)
    print(f"wrote {OUT} ({len(FULL)} bytes, {len(tasks)} units, {len(documented)} documented) + report_artifact.html")
    if redactions:
        print(f"  {redactions} credential-like pattern(s) redacted")

if __name__ == "__main__":
    main(sys.argv[1:])
