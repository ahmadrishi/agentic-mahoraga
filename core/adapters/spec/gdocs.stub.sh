#!/usr/bin/env bash
# spec/gdocs.stub.sh — STUB. Spec = a Google Doc. DEGRADED: TEXT-EXTRACT-ONLY.
#
# NOT YET IMPLEMENTED. Google Docs specs are non-trivial and partly browser-only, so this
# adapter ships TEXT-EXTRACT-ONLY (degraded): it exports the doc's text into SPEC.md and
# does NOT reconstruct embedded drawings, comments, or suggestions. A doc that needs sign-in
# and cannot be exported is reported thin (the core cannot open a browser). VISUAL specs
# (Figma / Balsamiq / Whimsical) are OUT OF SCOPE and must be pre-transcribed
# (docs/ADAPTER-CONTRACT.md §2).
#
# It will be EITHER a REST client (Google Docs/Drive API + token from PROJECT.yaml) OR an
# orchestrator fetch-step via an MCP connector that exports the doc and writes SPEC.md.
# Either way the core consumes the file on disk and calls no vendor API.
#
# Config it will read (from $PROJECT_YAML spec.config; NO literal hostnames):
#   base_url   Docs/Drive base url (from config, never hard-coded)
#   locator    how to find the doc for a unit (a doc-id / query template, {{unit}} injected)
#
# Contract functions to implement (see markdown.sh / issue_body.sh for the shape):
#   fetch_spec      <unit> <out_dir>   export the located doc -> <out_dir>/SPEC.md;
#                                      report thin if export is blocked or body is empty
#   is_transcribable <fmt>             false for visual-only formats (excluded)
set -u
fn="${1:-}"
case "$fn" in
  fetch_spec|is_transcribable)
    echo "gdocs.stub.sh: '$fn' not implemented (degraded, text-extract-only). Use spec.adapter=markdown|issue-body|none for now." >&2
    exit 64 ;;
  ""|-h|--help) sed -n '2,24p' "$0" ;;
  *) echo "gdocs.stub.sh: unknown fn '$fn' (fetch_spec|is_transcribable)" >&2; exit 2 ;;
esac
