#!/usr/bin/env bash
# spec/confluence.stub.sh — STUB. Spec = a Confluence wiki page. DEGRADED: TEXT-EXTRACT-ONLY.
#
# NOT YET IMPLEMENTED. Confluence specs are non-trivial and partly browser-only, so this
# adapter ships TEXT-EXTRACT-ONLY (degraded): it captures the page's readable text into
# SPEC.md and does NOT reconstruct embedded diagrams, macros, attachments, or inline
# comments. VISUAL specs (Figma / Balsamiq / Whimsical) are OUT OF SCOPE and must be
# pre-transcribed (docs/ADAPTER-CONTRACT.md §2).
#
# It will be EITHER a REST client (Confluence API + token from PROJECT.yaml) OR an
# orchestrator fetch-step via an MCP connector that retrieves the page and writes SPEC.md
# to disk. Either way the core consumes the file on disk and calls no vendor API.
#
# Config it will read (from $PROJECT_YAML spec.config; NO literal hostnames):
#   base_url   Confluence site base url (from config, never hard-coded)
#   locator    how to find the page for a unit — a CQL template with {{unit}} injected
#
# Contract functions to implement (see markdown.sh / issue_body.sh for the shape):
#   fetch_spec      <unit> <out_dir>   text-extract the located page -> <out_dir>/SPEC.md.
#                                      If only visual/macro content exists, report thin.
#   is_transcribable <fmt>             false for visual-only formats (excluded)
set -u
fn="${1:-}"
case "$fn" in
  fetch_spec|is_transcribable)
    echo "confluence.stub.sh: '$fn' not implemented (degraded, text-extract-only). Use spec.adapter=markdown|issue-body|none for now." >&2
    exit 64 ;;
  ""|-h|--help) sed -n '2,24p' "$0" ;;
  *) echo "confluence.stub.sh: unknown fn '$fn' (fetch_spec|is_transcribable)" >&2; exit 2 ;;
esac
