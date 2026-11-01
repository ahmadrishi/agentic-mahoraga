# Emitted-skill schema — v0.1.0 (semver'd)

The contract every skill Mahoraga **forges** or **ships** conforms to. It is a strict superset of
Anthropic's Agent Skills format, so a Mahoraga skill is a valid Claude Code skill unchanged. Extra
fields are forward-compatible: any consumer that doesn't know them ignores them. This schema is
versioned (`branding.yaml: skill_schema_version`); breaking changes bump the major.

## Frontmatter (YAML)

```yaml
---
name: <lowercase-hyphen>          # REQUIRED. ≤64 chars, [a-z0-9-] only, matches the folder name,
                                  #           must NOT contain "anthropic" or "claude" (reserved).
description: <one line>           # REQUIRED. ≤1024 chars, third person, states WHAT it does AND WHEN
                                  #           to use it (this is the retrieval key). End with a
                                  #           "Do NOT use for … (that is <sibling-skill>)" router when a sibling exists.
allowed-tools: [Read, Grep, ...]  # RECOMMENDED (Mahoraga extension surfaced): least privilege.
                                  #           Default deny network/shell unless the skill's job requires them (SECURITY.md).
license: MIT                      # optional
mahoraga:                         # optional Mahoraga block (ignored by plain Claude Code)
  kind: guard | mapping | spec | meta      # guard=behavioral; mapping/spec=forged; meta=engine (stripped from sandboxes)
  grounding: file-line | counted | none    # mapping/spec skills MUST be file:line- or count-grounded
  provenance: <regenerate command>         # how to rebuild this skill's facts
---
```

## Body (Markdown)

- **Progressive disclosure, 3 tiers.** Keep `SKILL.md` **< 500 lines / < 5k tokens**. Deep material
  goes in `references/*` (loaded only when read), determinism in `scripts/*` (run via bash — code
  never enters context, only output does). Keep references one level deep.
- **House shape** (matches the studied library): thesis → when/rule → numbered steps → Key types &
  classes → worked examples → anti-patterns → related skills.
- **Grounding is the point.** Every system noun a forged skill teaches carries `file:line` evidence
  or is explicitly marked `UNVERIFIED`. A confident wrong name is worse than no skill.
- **Prescription vs description.** When the skill prescribes something the corpus does only half the
  time, say so ("improves on observed practice") — never present a prescription as an observed convention.

## Conformance

`scripts/conformance-lint` checks the *container* (frontmatter validity, size budget, references one
level deep, resolved cross-links). Forged **mapping** and **spec** skills additionally get a
kind-specific lint (a names table with a mandatory evidence column, a regenerate command). A skill
that fails conformance does not ship.
