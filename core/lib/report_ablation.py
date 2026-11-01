#!/usr/bin/env python3
# report_ablation.py — the report additions, factored out of build_report.py to honor the
# per-file legibility budget. Pure string building: it renders the harness-vs-baseline
# Ablation panel, the Distributions row, the Sampling-frame line, and the per-unit cutoff/decontam
# chips from the aggregate + per-unit score dicts. Stdlib only, no side effects.
#
# Theme-aware by construction: the CSS below uses ONLY the palette variables already defined in
# build_report.py's stylesheet (--card, --line, --soft, --green, --amber, --red, --slate, --ink,
# --mut) and is concatenated into the SAME <style> block, so it inherits light/dark automatically.
# The caller passes its own `esc` (html.escape) so every interpolated value is escaped here.

ABLATION_CSS = """
.m3wrap{margin:2px 0 6px}
.m3card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:12px 0}
.m3card h3{margin:0 0 2px;font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--mut)}
.m3meaning{font-size:12px;color:var(--mut);margin-top:9px;line-height:1.5}
table.ablt{width:100%;border-collapse:collapse;font-size:12.5px;margin-top:8px}
.ablt th{text-align:left;background:var(--soft);color:var(--mut);font-size:10.5px;text-transform:uppercase;letter-spacing:.04em;padding:6px 10px;border:1px solid var(--line)}
.ablt th.num,.ablt th.dl{text-align:center}
.ablt td{padding:6px 10px;border:1px solid var(--line);vertical-align:top}
.ablt td.num{text-align:center;font-variant-numeric:tabular-nums}
.ablt td.dl{text-align:center;font-weight:800;font-variant-numeric:tabular-nums}
.dl.pos{color:var(--green)}.dl.neg{color:var(--red)}.dl.zero{color:var(--mut)}
.distrow{display:flex;flex-wrap:wrap;gap:10px;margin-top:8px}
.distpill{background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:7px 12px;font-size:12px;line-height:1.5}
.distpill b{font-size:14px}
.mmm{font-variant-numeric:tabular-nums;color:var(--ink)}
.frameline{font-size:12.5px;color:var(--ink);line-height:1.55}
.frameline.mut{color:var(--mut)}
ul.excl{margin:7px 0 0;padding-left:18px;font-size:12px;color:var(--mut);line-height:1.5}
.chip.clean{background:var(--green);color:#fff;border:0}
.chip.unver{background:var(--amber);color:#fff;border:0}
.chip.decon{background:var(--slate);color:#fff;border:0}
"""


def _delta(n):
    """(css-class, signed-text) for a delta where positive is always the good direction."""
    try:
        n = int(n)
    except Exception:
        return ("zero", "—")
    if n > 0:
        return ("pos", "+%d" % n)
    if n < 0:
        return ("neg", str(n))
    return ("zero", "0")


def _shown(v):
    return "not measured" if v is None else v  # None is never a zero (score_hygiene.py)


def _ablation_panel(agg, esc):
    arms = agg.get("arms") or {}
    delta = agg.get("ablation_delta")
    # Guard: only when BOTH arms produced scores (a single-arm run renders nothing here).
    if not delta or "harness" not in arms or "baseline" not in arms:
        return ""
    h, b = arms["harness"], arms["baseline"]
    metric_rows = [
        ("Business req achieved (avg %)", h.get("business_req_avg"), b.get("business_req_avg"), delta.get("business_req_avg")),
        ("Lost-context defects", h.get("lost_context"), b.get("lost_context"), delta.get("lost_context")),
        ("Hallucinations", h.get("hallucinations"), b.get("hallucinations"), delta.get("hallucinations")),
        ("Over-engineering", h.get("overeng"), b.get("overeng"), delta.get("overeng")),
    ]
    rows = []
    for lbl, hv, bv, dv in metric_rows:
        cls, txt = _delta(dv)
        hv, bv = _shown(hv), _shown(bv)
        rows.append('<tr><td>%s</td><td class="num">%s</td><td class="num">%s</td>'
                    '<td class="dl"><span class="dl %s">%s</span></td></tr>'
                    % (esc(lbl), esc(hv), esc(bv), cls, esc(txt)))
    return ('<div class="m3card"><h3>Ablation — harness vs baseline (attribution)</h3>'
            '<table class="ablt"><thead><tr><th>Metric</th>'
            '<th class="num">Harness (n=%s)</th><th class="num">Baseline (n=%s)</th>'
            '<th class="dl">&Delta;</th></tr></thead><tbody>%s</tbody></table>'
            '<div class="m3meaning"><b>What it means:</b> %s</div></div>'
            % (esc(h.get("n")), esc(b.get("n")), "".join(rows), esc(delta.get("note", ""))))


def _arm_matrix(agg, esc):
    """Render EVERY arm with its delta-vs-baseline. Shown only for a run with an arm BEYOND the
    classic harness/baseline pair (_ablation_panel covers 2-arm; single-arm renders nothing)."""
    arms = agg.get("arms") or {}
    deltas = agg.get("arm_deltas") or {}
    if "baseline" not in arms:
        return ""
    others = sorted(a for a in arms if a not in ("harness", "baseline"))
    if not others:
        return ""
    order = [a for a in ("harness",) if a in arms] + others + ["baseline"]
    metric_rows = [
        ("Business req achieved (avg %)", "business_req_avg"),
        ("Lost-context defects", "lost_context"),
        ("Hallucinations", "hallucinations"),
        ("Over-engineering", "overeng"),
    ]
    head = "".join('<th class="num">%s (n=%s)</th>' % (esc(a), esc(arms[a].get("n"))) for a in order)
    body = []
    for lbl, key in metric_rows:
        cells = []
        for a in order:
            val = esc(_shown(arms[a].get(key)))
            if a == "baseline":
                cells.append('<td class="num">%s</td>' % val)
            else:
                cls, txt = _delta((deltas.get(a) or {}).get(key))
                cells.append('<td class="num">%s <span class="dl %s">%s</span></td>'
                             % (val, cls, esc(txt)))
        body.append('<tr><td>%s</td>%s</tr>' % (esc(lbl), "".join(cells)))
    return ('<div class="m3card"><h3>Ablation — all arms vs baseline (attribution)</h3>'
            '<table class="ablt"><thead><tr><th>Metric</th>%s</tr></thead><tbody>%s</tbody></table>'
            '<div class="m3meaning"><b>What it means:</b> each non-baseline arm is shown with its '
            'delta vs the baseline arm (skills stripped to empty): a positive business-req delta means '
            'that arm did better; a positive defect-count delta means it has fewer than baseline.</div>'
            '</div>' % (head, "".join(body)))


def _distributions(agg, esc):
    dists = agg.get("distributions") or {}
    pills = []
    for key, lbl in (("business_req", "Business requirement achieved %"),
                     ("spec_fidelity", "Spec fidelity")):
        d = dists.get(key)
        if not d:
            continue
        pills.append('<div class="distpill">%s<br><span class="mmm">min <b>%s</b> · '
                     'median <b>%s</b> · max <b>%s</b></span></div>'
                     % (esc(lbl), esc(d.get("min")), esc(d.get("median")), esc(d.get("max"))))
    if not pills:
        return ""
    return ('<div class="m3card"><h3>Distributions (harness arm — not just the mean)</h3>'
            '<div class="distrow">%s</div></div>' % "".join(pills))


def _sampling_frame(agg, esc):
    sf = agg.get("sampling_frame")
    if not isinstance(sf, dict):
        return ('<div class="m3card"><h3>Sampling frame</h3>'
                '<div class="frameline mut">Sampling frame not recorded — no selection.json for this '
                'run; the reported units are not claimed to be a vetted sample.</div></div>')
    excl = [e for e in (sf.get("excluded") or []) if isinstance(e, dict)]
    parts = ['<div class="m3card"><h3>Sampling frame</h3>',
             '<div class="frameline"><b>%s</b> candidate(s) considered · <b>%s</b> selected · '
             '<b>%s</b> excluded.</div>'
             % (esc(sf.get("candidates")), esc(sf.get("selected")), esc(len(excl)))]
    if excl:
        items = "".join('<li><b>%s</b> — %s</li>' % (esc(e.get("unit", "")), esc(e.get("reason", "")))
                        for e in excl)
        parts.append('<ul class="excl">%s</ul>' % items)
    parts.append('</div>')
    return "".join(parts)


def ablation_sections(agg, esc):
    """Return (css, html) for the aggregate sections. html is "" only if there is nothing to show
    (there always is — the sampling-frame line renders even when absent)."""
    body = (_ablation_panel(agg, esc) + _arm_matrix(agg, esc)
            + _distributions(agg, esc) + _sampling_frame(agg, esc))
    if not body:
        return ("", "")
    return (ABLATION_CSS, '<div class="m3wrap">%s</div>' % body)


def unit_chips(t, esc):
    """Per-unit cutoff_label + decontam_confidence chips. Empty string when neither is present."""
    chips = []
    cl = t.get("cutoff_label")
    if cl:
        cls = "clean" if str(cl).strip().lower() == "cutoff-clean" else "unver"
        reason = t.get("cutoff_reason", "")
        title = ' title="%s"' % esc(reason) if reason else ""
        chips.append('<span class="chip %s"%s>%s</span>' % (cls, title, esc(cl)))
    dc = t.get("decontam_confidence")
    if dc:
        chips.append('<span class="chip decon">decontam: %s</span>' % esc(dc))
    return "".join(chips)
