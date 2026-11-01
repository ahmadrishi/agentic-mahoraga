#!/usr/bin/env bash
# tests/plugin_validate_test.sh — the plugin manifest validates --strict.
#
# ALWAYS: install resolution (python3, no CLI) — every skill family is listed in plugin.json
# "skills", commands + engine skills reach plugin files via ${CLAUDE_PLUGIN_ROOT}/…, and GUARD skills
# stay free of it (they are copied into other agents). See the section below for why.
#
# PRIMARY GATE: `claude plugin validate --strict` MUST exit 0 for the marketplace (repo root) and the
# plugin manifest. --strict treats warnings (unrecognized fields, missing metadata, malformed
# hooks.json) as errors, so a green run means the shipped manifests + hooks/hooks.json are clean. The
# test prepends ~/.local/bin to PATH so a native-installed CLI is found; CI installs a pinned CLI.
#
# DEGRADED GATE: if the claude CLI is absent at runtime (and MAHORAGA_REQUIRE_CLAUDE_CLI is not 1),
# the test degrades — with a printed NOTE — to a structural JSON check done in python3
# (no jq): plugin.json parses and names a plugin; hooks/hooks.json parses and wires both a PreToolUse
# and a PostToolUse command hook; and every referenced ${CLAUDE_PLUGIN_ROOT}/hooks/*.sh script exists
# and is executable. This keeps the gate meaningful without the CLI, while the real CLI runs wherever
# it is present.
#
# Hermetic: reads only the repo's committed manifest + hooks; writes nothing. Needs bash + python3.
# Depends on: .claude-plugin/plugin.json + hooks/hooks.json + hooks/*.sh — authored
# against the documented contract.
#
# Run from the repo root:  bash tests/plugin_validate_test.sh   (exit 0 = pass, non-zero = failure)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

fail() { printf 'PLUGIN-VALIDATE FAIL: %b\n' "$*" >&2; exit 1; }

# ---- required upstream artifacts ---------------
[ -f "$ROOT/.claude-plugin/plugin.json" ] || fail "missing .claude-plugin/plugin.json"
[ -f "$ROOT/hooks/hooks.json" ]           || fail "missing hooks/hooks.json"

# =================================================================================================
# ALWAYS: install resolution — what `claude plugin validate` does not check
# =================================================================================================
# (1) Claude Code auto-discovers only skills/<name>/SKILL.md, so every skills/<family>/ dir holding
#     skills must be listed in plugin.json "skills" — else the pack silently fails to load.
# (2) Commands + engine skills run from the user's repo, not this one: every plugin-internal path
#     must be written ${CLAUDE_PLUGIN_ROOT}/… (Claude Code substitutes the install dir).
# (3) GUARD skills are copied unchanged into other agents (mahoraga install), which never
#     substitute ${CLAUDE_PLUGIN_ROOT} — so GUARD must not use it.
ROOT="$ROOT" python3 - <<'PY' || exit 1
import glob, json, os, re, sys

root = os.environ["ROOT"]
errs = []

listed = json.load(open(os.path.join(root, ".claude-plugin/plugin.json"))).get("skills") or []
listed = {os.path.normpath(p) for p in ([listed] if isinstance(listed, str) else listed)}
for d in sorted(listed):
    if not os.path.isdir(os.path.join(root, d)):
        errs.append(f"plugin.json skills: '{d}' is not a directory")
families = {os.path.relpath(os.path.dirname(os.path.dirname(p)), root)
            for p in glob.glob(os.path.join(root, "skills/*/*/SKILL.md"))}
for fam in sorted(families - listed):
    errs.append(f"plugin.json skills: '{fam}/' holds skills but is not listed — they will not load")

bare = re.compile(r'(?<![\w/.$}-])(core/(?:lib|schema|adapters)/|scripts/conformance-lint\.mjs'
                  r'|docs/[A-Z][\w-]*\.md|cli/mahoraga\b|skills/(?:guard|prove|adapt)/)')
def body(path):
    text = open(path, encoding="utf-8").read()
    return text[text.index("\n---\n", 4) + 5:] if text.startswith("---\n") else text
engine = sorted(glob.glob(os.path.join(root, "commands/*.md"))
                + glob.glob(os.path.join(root, "skills/prove/*/SKILL.md"))
                + glob.glob(os.path.join(root, "skills/adapt/*/SKILL.md")))
for p in engine:
    for m in bare.finditer(body(p)):
        errs.append(f"{os.path.relpath(p, root)}: bare plugin path '{m.group(1)}…' — write ${{CLAUDE_PLUGIN_ROOT}}/{m.group(1)}…")
for p in sorted(glob.glob(os.path.join(root, "skills/guard/*/SKILL.md"))):
    if "${CLAUDE_PLUGIN_ROOT}" in open(p, encoding="utf-8").read():
        errs.append(f"{os.path.relpath(p, root)}: GUARD skills are cross-agent — no ${{CLAUDE_PLUGIN_ROOT}}")

if errs:
    print("INSTALL-RESOLUTION CHECK FAILED:", file=sys.stderr)
    for e in errs:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print(f"  ok: {len(families)} skill families listed in plugin.json; {len(engine)} command/engine files "
      "use ${CLAUDE_PLUGIN_ROOT} paths; GUARD stays portable")
PY

# =================================================================================================
# PRIMARY: the real CLI gate
# =================================================================================================
if command -v claude >/dev/null 2>&1; then
  echo "plugin-validate: claude CLI found ($(claude --version 2>/dev/null | head -1)) — running the real --strict gate"
  # The repo root validates the marketplace; the plugin manifest is validated on its own as well.
  for target in "$ROOT" "$ROOT/.claude-plugin/plugin.json"; do
    OUT="$(claude plugin validate "$target" --strict 2>&1)"; RC=$?
    printf '%s\n' "$OUT" | sed 's/^/  /'
    [ "$RC" -eq 0 ] || fail "claude plugin validate ${target#"$ROOT"/} --strict exited $RC (expected 0)"
  done
  echo "PLUGIN-VALIDATE PASS (claude plugin validate --strict -> exit 0 for marketplace + plugin manifest)"
  exit 0
fi
# CI installs a pinned CLI and sets this, so a missing CLI there is a failure, not a quiet downgrade.
[ "${MAHORAGA_REQUIRE_CLAUDE_CLI:-0}" = 1 ] && fail "MAHORAGA_REQUIRE_CLAUDE_CLI=1 but no claude CLI on PATH"

# =================================================================================================
# DEGRADED: structural JSON check (no CLI on this host)
# =================================================================================================
echo "NOTE: claude CLI not on PATH — degrading to a structural JSON check of plugin.json + hooks.json."
echo "      (the real 'claude plugin validate . --strict' gate runs wherever the CLI is installed)"

ROOT="$ROOT" python3 - <<'PY' || exit 1
import json, os, sys

root = os.environ["ROOT"]
errs = []

def load(rel):
    p = os.path.join(root, rel)
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:  # noqa: BLE001 — any parse/read failure is a structural failure
        errs.append(f"{rel}: does not parse as JSON ({exc})")
        return None

# --- plugin.json: must be an object naming a plugin -------------------------------------------
pj = load(".claude-plugin/plugin.json")
if isinstance(pj, dict):
    if not isinstance(pj.get("name"), str) or not pj["name"].strip():
        errs.append("plugin.json: missing/empty required string field 'name'")
elif pj is not None:
    errs.append("plugin.json: top-level value must be a JSON object")

# --- hooks.json: PreToolUse + PostToolUse command hooks pointing at real executable scripts ----
hj = load("hooks/hooks.json")
if isinstance(hj, dict):
    hooks = hj.get("hooks")
    if not isinstance(hooks, dict):
        errs.append("hooks.json: missing 'hooks' object")
    else:
        for event in ("PreToolUse", "PostToolUse"):
            entries = hooks.get(event)
            if not isinstance(entries, list) or not entries:
                errs.append(f"hooks.json: '{event}' must be a non-empty array")
                continue
            found_cmd = False
            for entry in entries:
                for hk in (entry or {}).get("hooks", []) if isinstance(entry, dict) else []:
                    if not isinstance(hk, dict) or hk.get("type") != "command":
                        continue
                    cmd = hk.get("command")
                    if not isinstance(cmd, str) or not cmd:
                        errs.append(f"hooks.json: '{event}' has a command hook with no command string")
                        continue
                    found_cmd = True
                    # resolve ${CLAUDE_PLUGIN_ROOT}/hooks/foo.sh -> <root>/hooks/foo.sh
                    rel = cmd.replace("${CLAUDE_PLUGIN_ROOT}", "").replace('"', "").strip()
                    rel = rel.lstrip("/")
                    script = os.path.join(root, rel)
                    if not os.path.isfile(script):
                        errs.append(f"hooks.json: '{event}' references a missing script: {rel}")
                    elif not os.access(script, os.X_OK):
                        errs.append(f"hooks.json: referenced script is not executable (chmod +x): {rel}")
                    else:
                        print(f"  ok: {event} -> {rel} (exists, executable)")
            if not found_cmd:
                errs.append(f"hooks.json: '{event}' has no type=command hook")
elif hj is not None:
    errs.append("hooks.json: top-level value must be a JSON object")

if errs:
    print("STRUCTURAL CHECK FAILED:", file=sys.stderr)
    for e in errs:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print("  ok: plugin.json names a plugin; hooks.json wires PreToolUse + PostToolUse command hooks")
PY

echo "PLUGIN-VALIDATE PASS (structural JSON check — CLI absent; real --strict gate deferred to a CLI host)"
