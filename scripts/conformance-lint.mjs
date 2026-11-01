#!/usr/bin/env node
// conformance-lint.mjs — the structural gate spec-skill-forge Phase 6 is missing.
// Checks a generated <module>-spec skill against the unified blueprint (fixed 8-file,
// split-by-read-trigger manifest). Content is never judged — this checks the container only.
// Usage: node conformance-lint.mjs <path-to-skill-dir> [--repo <dir>]...
// Exits 0 and prints "CONFORMANCE PASS" only if every structural rule holds; else lists
// violations and exits 1. For a mapping skill it also resolves every path:line in every names
// table against the repo root(s): --repo (repeatable, one per repo of a multi-repo map), else the
// directory holding the skill's .claude/, else the nearest git root. A row passes when, under some
// root, the file exists inside it (symlinks resolved), the line exists, and the name is on it.
import { readFileSync, existsSync, readdirSync, statSync, realpathSync } from 'node:fs';
import { join, basename, dirname, resolve, relative, isAbsolute, sep } from 'node:path';

const USAGE = 'usage: node conformance-lint.mjs <skill-dir> [--repo <dir>]...';
const args = process.argv.slice(2);
const repos = [];
for (let i = 0; i < args.length;) {
  const m = args[i].match(/^--repo(?:=(.*))?$/);
  if (!m) { i++; continue; }
  const v = m[1] !== undefined ? m[1] : args[i + 1];
  args.splice(i, m[1] !== undefined ? 1 : 2);
  if (!v) { console.error(USAGE); process.exit(2); }
  repos.push(v);
}
const dir = args[0];
if (!dir) { console.error(USAGE); process.exit(2); }

const V = [];
const fail = (m) => V.push(m);
const mdFiles = (p) => (existsSync(p) ? readdirSync(p).filter((f) => f.endsWith('.md')).sort() : null);
const lineCount = (p) => readFileSync(p, 'utf8').split('\n').length;
// only real fence LINES open/close a block (a ``` mentioned in prose must not hide a table)
const stripFences = (t) => t.replace(/^[ \t]*```[^\n]*\n[\s\S]*?^[ \t]*```[^\n]*$/gm, '').replace(/^[ \t]*~~~[^\n]*\n[\s\S]*?^[ \t]*~~~[^\n]*$/gm, '');
const readIf = (p) => (existsSync(p) ? readFileSync(p, 'utf8') : '');

// ---- kind dispatch: mapping-kind skills take a different branch ----
// Parse the SKILL.md frontmatter's mahoraga.kind. When it is 'mapping', validate against the
// grounded-names-table contract below and SKIP the spec-blueprint checks (a mapping skill has no
// 8-file manifest). Anything else (spec, meta, guard, or no mahoraga block) falls through to the
// existing spec-blueprint checks entirely unchanged.
function parseMahoraga(raw) {
  const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return {};
  const fm = m[1];
  const out = {};
  // inline flow form: `mahoraga: {kind: mapping, grounding: file-line}`
  const inline = fm.match(/^mahoraga:[ \t]*\{([^}]*)\}[ \t]*$/m);
  if (inline) {
    for (const pair of inline[1].split(',')) {
      const mm = pair.match(/^\s*([A-Za-z0-9_-]+)\s*:\s*([\s\S]*?)\s*$/);
      if (mm) out[mm[1]] = mm[2].replace(/^['"]|['"]$/g, '');
    }
    return out;
  }
  // block form: a `mahoraga:` line followed by indented `key: value` lines
  let inMah = false;
  for (const line of fm.split(/\r?\n/)) {
    if (/^mahoraga:[ \t]*$/.test(line)) { inMah = true; continue; }
    if (!inMah) continue;
    if (/^\S/.test(line)) break; // a new top-level key ends the mahoraga block
    const mm = line.match(/^[ \t]+([A-Za-z0-9_-]+):[ \t]*(.*)$/);
    if (mm) out[mm[1]] = mm[2].trim().replace(/^['"]|['"]$/g, '');
  }
  return out;
}

const skillRaw = readIf(join(dir, 'SKILL.md'));
const mah = parseMahoraga(skillRaw);

if (mah.kind === 'mapping') {
  // ---- grounded-names-table markdown helpers ----
  const cellsOf = (line) => {
    if (line == null) return null;
    let t = line.trim();
    if (!t.includes('|')) return null;
    if (t.startsWith('|')) t = t.slice(1);
    if (t.endsWith('|')) t = t.slice(0, -1);
    return t.split('|').map((c) => c.trim());
  };
  const isSep = (line) => {
    const c = cellsOf(line);
    return !!c && c.length > 0 && c.every((x) => /^:?-{1,}:?$/.test(x.replace(/\s/g, '')));
  };
  // Locate EVERY grounded-names table: a markdown table whose header carries name|kind|evidence,
  // immediately followed by a separator row (all of them — curation may group rows into several).
  // Fences are stripped first so an illustrative example table inside a ``` block is never mistaken
  // for a real one.
  const findTables = (text) => {
    const out = [];
    if (!text) return out;
    const lines = stripFences(text).split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (isSep(lines[i])) continue;
      const header = cellsOf(lines[i]);
      if (!header) continue;
      // near-miss headers (`**evidence**`, `evidence (path:line)`) are names tables too — checked, not skipped
      const lc = header.map((c) => c.toLowerCase().replace(/[*`]/g, '').replace(/\(.*?\)/g, '').trim());
      if (!(lc.includes('name') && lc.includes('kind') && lc.includes('evidence'))) continue;
      if (!isSep(lines[i + 1])) continue; // a real markdown table needs its separator row
      const rows = [];
      for (let j = i + 2; j < lines.length; j++) {
        if (isSep(lines[j])) continue;
        const rc = cellsOf(lines[j]);
        if (!rc) break; // first non-table line ends the table
        rows.push(rc);
      }
      out.push({ header, lc, rows });
      i += 1 + rows.length;
    }
    return out;
  };

  // (1) grounding must be file:line for a mapping skill
  if (mah.grounding !== 'file-line')
    fail(`frontmatter mahoraga.grounding must be "file-line" for a mapping skill (found ${mah.grounding ? '"' + mah.grounding + '"' : 'none'})`);

  // (2) the names table exists in SKILL.md OR references/subsystem-map.md
  const mapText = readIf(join(dir, 'references', 'subsystem-map.md'));
  const tables = [...findTables(skillRaw), ...findTables(mapText)];
  const EV = /^(\S(?:.*\S)?):(\d+)$/; // path:line (a path may contain spaces)
  const rows = []; // [name, evidence] across every table
  if (!tables.length) {
    fail('grounded-names table not found — a "| name | kind | evidence |" table (with a separator row) must exist in SKILL.md or references/subsystem-map.md');
  }
  for (const table of tables) {
    // (3) header columns are name, kind, evidence in that order — in every table
    if (!(table.lc[0] === 'name' && table.lc[1] === 'kind' && table.lc[2] === 'evidence'))
      fail(`names-table header must be "name | kind | evidence" in that order; found "${table.header.join(' | ')}"`);
    const evIdx = table.lc.indexOf('evidence');
    // (5) every data row's evidence is a path:line or exactly UNVERIFIED — report each offender
    table.rows.forEach((r, k) => {
      const nm = (r[0] ?? '').trim() || `#${k + 1}`;
      const ev = (r[evIdx] ?? '').trim();
      if (!(EV.test(ev) || ev === 'UNVERIFIED'))
        fail(`names-table row "${nm}" has evidence "${ev || '(empty)'}" — must be a path:line or exactly UNVERIFIED`);
      rows.push([nm, ev]);
    });
  }
  // (4) >= 3 data rows in total (a real map, not a stub)
  if (tables.length && rows.length < 3)
    fail(`names table has ${rows.length} data row${rows.length === 1 ? '' : 's'}; at least 3 are required (a real map, not a stub)`);

  // (5b) every path:line, in every table, resolves under some root: the file exists INSIDE it (after
  // resolving symlinks), the line exists, and the name is on that line. Shape alone let invented
  // evidence through. This proves the name appears on the cited line — not that it is defined there.
  if (rows.length) {
    let roots = repos.map((r) => resolve(r));
    if (!roots.length) {
      const abs = resolve(dir), k = abs.lastIndexOf(`${sep}.claude${sep}skills${sep}`);
      if (k >= 0) roots = [abs.slice(0, k)];
      else for (let d = abs; ; d = dirname(d)) {
        if (existsSync(join(d, '.git'))) { roots = [d]; break; }
        if (dirname(d) === d) break;
      }
    }
    roots.filter((r) => !existsSync(r) || !statSync(r).isDirectory()).forEach((r) => fail(`--repo ${r} is not a directory`));
    roots = roots.filter((r) => existsSync(r) && statSync(r).isDirectory()).map((r) => realpathSync(r));
    if (!roots.length && !V.some((v) => v.startsWith('--repo'))) {
      fail('evidence not checked — the skill is not under a <repo>/.claude/skills/ and has no git root above it; pass --repo <dir> (the directory the evidence paths are relative to)');
    } else if (roots.length) {
      const inside = (root, f) => { const r = relative(root, f); return r !== '..' && !r.startsWith('..' + sep) && !isAbsolute(r); };
      const cache = new Map();
      const skillReal = realpathSync(dir);
      // [lines] for a cited file, or a reason string: evidence must be source inside the root — never
      // a file of the skill itself or anything under a .claude/ dir (a row could cite its own line)
      const linesOf = (root, p) => {
        const f = resolve(root, p);
        if (!existsSync(f)) return `no such file under ${root}`;
        const real = realpathSync(f);
        if (!inside(root, real)) return `resolves outside ${root} (symlink)`;
        if (inside(skillReal, real) || relative(root, real).split(sep).includes('.claude'))
          return 'cites the skill or a .claude/ file, not source';
        if (!statSync(real).isFile()) return `not a file under ${root}`;
        if (!cache.has(real)) cache.set(real, readFileSync(real, 'utf8').normalize('NFKC').split(/\r\n|\r|\n/));
        return cache.get(real);
      };
      const ID = /[\p{L}_$][\p{L}\p{N}_$]*/gu;
      const W = /[\p{L}\p{N}_$]/u; // an identifier character: the token must not be part of a longer name
      const onLine = (tok, line) => {
        for (let i = line.indexOf(tok); i >= 0; i = line.indexOf(tok, i + 1))
          if (!W.test(line[i - 1] ?? ' ') && !W.test(line[i + tok.length] ?? ' ')) return true;
        return false;
      };
      const bad = [];
      for (const [nm, ev] of rows) {
        const m = ev.match(EV);
        if (!m) continue; // UNVERIFIED or a shape violation already reported by (5)
        const ln = Number(m[2]);
        // the name's identifier: the last one in its first word (`Ledger.post` → post); anything after
        // the first word is annotation and never counts
        const cell = nm.normalize('NFKC');
        const tok = ((cell.split(/\s+/)[0] || '').match(ID) || []).pop() || (cell.match(ID) || [])[0];
        let why = 'the name has no identifier';
        for (const root of tok ? roots : []) {
          const lines = linesOf(root, m[1]);
          if (typeof lines === 'string') { why = lines; continue; }
          if (ln < 1 || ln > lines.length) { why = `the file has ${lines.length} lines`; continue; }
          if (onLine(tok, lines[ln - 1])) { why = null; break; }
          why = 'the name is not on that line';
        }
        if (why) bad.push(`"${nm}" → ${ev}: ${why}`);
      }
      bad.slice(0, 10).forEach((b) => fail(`evidence does not resolve: ${b}`));
      if (bad.length > 10) fail(`… and ${bad.length - 10} more evidence row(s) that do not resolve`);
    }
  }

  // (6) a runnable Regenerate: command (in SKILL.md or subsystem-map.md) OR a mahoraga.provenance key
  const hasRegenerate = /(^|\n)[ \t]*Regenerate:[ \t]*\S/.test(skillRaw) || /(^|\n)[ \t]*Regenerate:[ \t]*\S/.test(mapText);
  const hasProvenance = typeof mah.provenance === 'string' && mah.provenance.trim().length > 0;
  if (!hasRegenerate && !hasProvenance)
    fail('no regenerate command — add a "Regenerate: <command>" line (SKILL.md or references/subsystem-map.md) or a mahoraga.provenance frontmatter key');

  // ---- report (mapping) — same PASS/FAIL shape + exit codes as the spec path ----
  const name = basename(dir);
  if (V.length === 0) {
    console.log(`CONFORMANCE PASS — ${name} (mapping)`);
    process.exit(0);
  } else {
    console.error(`CONFORMANCE FAIL — ${name} (${V.length} violation${V.length > 1 ? 's' : ''}):`);
    for (const v of V) console.error(`  • ${v}`);
    process.exit(1);
  }
}

// ---- canonical manifest (fixed set, one file per read-trigger) ----
const CANON_REFS = [
  'clarification-playbook.md', 'definition-of-done.md', 'glossary.md', 'house-style.md',
  'sources.md', 'spec-template.md', 'subsystem-map.md', 'worked-examples.md',
].sort();
const RENAME_HINT = {
  'names.md': 'split into subsystem-map.md + glossary.md',
  'template-and-style.md': 'split into spec-template.md + house-style.md + worked-examples.md',
  'template-style.md': 'split into spec-template.md + house-style.md + worked-examples.md',
  'process.md': 'split into sources.md + clarification-playbook.md + definition-of-done.md',
};

const refs = mdFiles(join(dir, 'references'));
if (refs === null) {
  fail('references/ directory is missing');
} else {
  const have = new Set(refs);
  for (const f of CANON_REFS) if (!have.has(f)) fail(`references/${f} is missing (required)`);
  for (const f of refs) {
    if (!CANON_REFS.includes(f)) {
      fail(`references/${f} is not a canonical file` + (RENAME_HINT[f] ? ` (${RENAME_HINT[f]})` : ' (remove or fold into a canonical file)'));
    }
  }
  // TOC for long reference files
  for (const f of refs) {
    const p = join(dir, 'references', f);
    if (lineCount(p) > 100) {
      const head = readFileSync(p, 'utf8').split('\n').slice(0, 20).join('\n');
      if (!/^##\s+Contents/mi.test(head)) fail(`references/${f} is >100 lines but has no "## Contents" TOC near the top`);
    }
  }
  // each reference file must have EXACTLY one H1 title (fence-aware) — a redundant 2nd H1 left by a
  // split, or a title deleted/demoted to zero, is exactly the defect a manifest+heading check misses
  for (const f of refs) {
    const h1 = stripFences(readFileSync(join(dir, 'references', f), 'utf8')).split('\n').filter((l) => /^#\s+\S/.test(l));
    if (h1.length !== 1) fail(`references/${f} has ${h1.length} H1 heading${h1.length === 1 ? '' : 's'}; a reference file must have exactly one H1 title (add one, or demote the extras to ## / bold)`);
  }
}

const tpls = mdFiles(join(dir, 'templates'));
const TPL = ['reality-ledger.md', 'spec-page-skeleton.md'];
if (tpls === null) fail('templates/ directory is missing');
else {
  if (JSON.stringify(tpls) !== JSON.stringify(TPL))
    fail(`templates/ must be exactly {${TPL.join(', ')}}; found {${tpls.join(', ')}}`);
  // a fill-in template may legitimately carry zero or one H1, but never two — a 2nd H1 is the
  // "lifted a block that brought its own # Title" hazard that a filenames-only check cannot see
  for (const f of tpls) {
    const h1 = stripFences(readFileSync(join(dir, 'templates', f), 'utf8')).split('\n').filter((l) => /^#\s+\S/.test(l));
    if (h1.length > 1) fail(`templates/${f} has ${h1.length} H1 headings; a template must have at most one H1 (a pasted block brought its own title — demote it)`);
  }
}

// ---- skill root holds only the manifest ----
// SKILL.md + references/ + templates/ (+ optional scripts/). A stray notes.md/scratch.md at the root
// breaks the manifest guardrail but is invisible to a references/+templates/-only enumeration.
{
  const ALLOWED = new Set(['SKILL.md', 'references', 'templates', 'scripts']);
  for (const e of readdirSync(dir)) {
    if (e.startsWith('.')) continue; // ignore .DS_Store and other dotfiles
    if (!ALLOWED.has(e)) fail(`skill root has a non-manifest entry "${e}" — the manifest is SKILL.md + references/ + templates/ (+ optional scripts/); remove it or fold it into a canonical file`);
  }
}

// ---- SKILL.md ----
const sp = join(dir, 'SKILL.md');
if (!existsSync(sp)) { fail('SKILL.md is missing'); }
else {
  const raw = readFileSync(sp, 'utf8');
  const noFence = raw.replace(/```[\s\S]*?```/g, '').replace(/~~~[\s\S]*?~~~/g, '');
  const lines = noFence.split('\n');
  const H = (re) => lines.filter((l) => re.test(l));
  const headings = lines.filter((l) => /^#{1,6}\s/.test(l));

  const h1 = H(/^#\s+\S/);
  if (h1.length !== 1) fail(`SKILL.md must have exactly one H1; found ${h1.length}${h1.length ? ' ('+h1.map(s=>s.trim()).join(' | ')+')' : ''}`);
  if (H(/^#\s+Workflow\b/).length) fail('"# Workflow" is an H1; it must be "## Workflow" (H2)');

  const reqH2 = ['## What makes a', '## Where you sit', '## Reference files', '## Workflow',
    '## Guardrails', '## Confidence and coverage'];
  for (const h of reqH2) {
    if (!lines.some((l) => l.startsWith(h))) fail(`missing required section: ${h}${h==='## What makes a' ? ' <MODULE> spec good' : ''}`);
  }

  // phases
  const phaseLines = lines.filter((l) => /^###\s+Phase\s+\d+\s+—/.test(l));
  if (!phaseLines.length) {
    if (lines.some((l) => /^###\s+\d+\s+—/.test(l))) fail('phases use "### N —" bare-number form; canonical is "### Phase N — <Name>"');
    else if (lines.some((l) => /^##\s+Phase\s+\d+\s+—/.test(l))) fail('phases are H2 ("## Phase N —"); canonical is H3 ("### Phase N —") under "## Workflow"');
    else fail('no "### Phase N — …" phase headings found');
  } else {
    const nums = phaseLines.map((l) => parseInt(l.match(/Phase\s+(\d+)/)[1], 10));
    if (nums[0] !== 0) fail(`phases must be 0-based; first phase is Phase ${nums[0]}`);
    for (let i = 1; i < nums.length; i++) if (nums[i] !== nums[i-1] + 1) fail(`phase numbering not contiguous: …Phase ${nums[i-1]} then Phase ${nums[i]}`);
    const p1 = phaseLines.find((l) => /^###\s+Phase\s+1\s+—/.test(l)) || '';
    if (!/Grounding/.test(p1)) fail('Phase 1 must be named "Grounding"');
    if (!/⭐/.test(p1)) fail('Phase 1 (Grounding) must carry the ⭐ centrepiece marker');
  }

  // ordering: Guardrails before Confidence, Confidence last
  const idx = (s) => headings.findIndex((l) => l.startsWith(s));
  const g = idx('## Guardrails'), c = idx('## Confidence and coverage');
  if (g !== -1 && c !== -1 && g > c) fail('"## Guardrails" must come before "## Confidence and coverage"');
  if (c !== -1) {
    const lastH2 = [...headings].reverse().find((l) => l.startsWith('## '));
    if (lastH2 && !lastH2.startsWith('## Confidence and coverage')) fail(`"## Confidence and coverage" must be the last section; last is "${lastH2.trim()}"`);
  }

  // the reference table must list all 8 canonical files (router lists them, one level deep)
  if (refs !== null) {
    for (const f of CANON_REFS) {
      if (!raw.includes(f)) fail(`SKILL.md reference table does not mention ${f} (every reference must be listed one level deep from the router)`);
    }
  }

  // structural choice-brackets must not survive (fill-in form flanks the separator with spaces)
  const choices = (noFence.match(/<[^>\n]*\s[/|]\s[^>\n]*>/g) || []).filter((s) => !/https?:/.test(s));
  if (choices.length) fail(`unresolved structural choice-brackets: ${[...new Set(choices)].slice(0,4).join(', ')}`);

  // deliverable skeleton must not be inlined as real sections (outside code fences)
  for (const h of ['## Reality Ledger', '## Readiness verdict', '## Suggested Jira description', '## Open decisions'])
    if (lines.some((l) => l.startsWith(h))) fail(`deliverable-skeleton section "${h}" is inlined in SKILL.md; it belongs in templates/`);

  // description: third person + length
  const fm = raw.match(/^---\n([\s\S]*?)\n---/);
  if (fm) {
    // capture only the description value: stop at the next top-level YAML key (or end of frontmatter),
    // and strip a leading block-scalar marker (>- / | …) so trailing keys don't inflate the count
    const dm = fm[1].match(/^description:[ \t]*([\s\S]*?)(?=\n[A-Za-z][\w-]*:|\s*$)/m);
    const d = (dm ? dm[1] : '').replace(/^[>|][+-]?/, '').replace(/\s+/g, ' ').trim();
    if (d.length > 1024) fail(`description is ${d.length} chars; max 1024`);
    if (/\b(I can|I will|you can use this)\b/i.test(d)) fail('description should be third person (avoid "I can"/"you can use this")');
  }
}

// ---- cross-reference resolution (SKILL.md + references + templates) ----
// Catches dangling pointers (a file/path that no longer resolves post-migration) and leftover
// pre-split filenames — the propagation-gap class a manifest+heading check cannot see. Templates
// are included precisely because that is where the dangling refs hid.
{
  const existing = new Set([
    ...(refs || []).map((f) => `references/${f}`),
    ...(tpls || []).map((f) => `templates/${f}`),
    'SKILL.md',
  ]);
  const PRESPLIT = ['names.md', 'process.md', 'template-and-style.md', 'template-style.md'];
  const scan = (rel, txt) => {
    if (!txt) return;
    for (const m of txt.matchAll(/\b(references|templates)\/([A-Za-z0-9._-]+\.md)\b/g)) {
      const target = `${m[1]}/${m[2]}`;
      if (!existing.has(target)) fail(`${rel} points to ${target}, which does not exist in the skill (dangling cross-reference)`);
    }
    for (const pre of PRESPLIT) {
      const re = new RegExp(`(^|[^A-Za-z0-9._/-])${pre.replace(/\./g, '\\.')}([^A-Za-z0-9]|$)`);
      if (re.test(txt)) fail(`${rel} contains the pre-split filename "${pre}" — repoint it to a canonical file`);
    }
  };
  scan('SKILL.md', readIf(sp));
  for (const f of (refs || [])) scan(`references/${f}`, readIf(join(dir, 'references', f)));
  for (const f of (tpls || [])) scan(`templates/${f}`, readIf(join(dir, 'templates', f)));
}

// ---- in-page anchor links must resolve (a stale "## Contents" entry after a heading rename) ----
// GitHub anchors: lowercase, drop non [word|space|hyphen], spaces→hyphens, dup headings get -1/-2…
{
  const anchorsOf = (txt) => {
    const set = new Set(); const seen = new Map();
    for (const l of stripFences(txt).split('\n')) {
      const m = l.match(/^#{1,6}\s+(.*\S)\s*$/);
      if (!m) continue;
      const base = m[1].toLowerCase().replace(/[^\w\s-]/g, '').trim().replace(/\s/g, '-');
      const n = seen.get(base) || 0; seen.set(base, n + 1);
      set.add(n ? `${base}-${n}` : base);
    }
    return set;
  };
  const checkAnchors = (rel, txt) => {
    if (!txt) return;
    const have = anchorsOf(txt);
    for (const m of txt.matchAll(/\]\(#([\w-]+)\)/g))
      if (!have.has(m[1])) fail(`${rel} links to #${m[1]}, which matches no heading in the file (stale TOC/anchor)`);
  };
  checkAnchors('SKILL.md', readIf(sp));
  for (const f of (refs || [])) checkAnchors(`references/${f}`, readIf(join(dir, 'references', f)));
  for (const f of (tpls || [])) checkAnchors(`templates/${f}`, readIf(join(dir, 'templates', f)));
}

// ---- report ----
const name = basename(dir);
if (V.length === 0) {
  console.log(`CONFORMANCE PASS — ${name}`);
} else {
  console.error(`CONFORMANCE FAIL — ${name} (${V.length} violation${V.length>1?'s':''}):`);
  for (const v of V) console.error(`  • ${v}`);
  process.exit(1);
}
