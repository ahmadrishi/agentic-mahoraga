# adapt — the forge engine skills

The engine (meta) skills that adapt Mahoraga to a project by forging grounded skills from its code and specs. Listed in `core/schema/STRIP_SET.manifest`, so they are stripped from every blind sandbox: `codebase-mapping-forge` (always available — forges a `<project>-mapping` skill from code), `spec-style-forge` (conditional — forges a `<project>-spec` skill where a doc corpus exists, delegating grounding to the mapping skill), `skill-editor` (surgical, conformance-preserving edits), `conformance-lint` (the structural ship gate).
