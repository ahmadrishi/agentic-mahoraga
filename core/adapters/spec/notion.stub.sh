#!/usr/bin/env bash
# spec/notion.stub.sh — STUB. Spec = a Notion page. DEGRADED: TEXT-EXTRACT-ONLY.
#
# NOT YET IMPLEMENTED. Notion specs are non-trivial and partly browser-only, so this
# adapter ships TEXT-EXTRACT-ONLY (degraded): it captures the page's readable text (and
# nested blocks it can reach) into SPEC.md and does NOT reconstruct embeds, databases, or
# visual layouts. VISUAL specs (Figma / Balsamiq / Whimsical) are OUT OF SCOPE and must be
# pre-transcribed (docs/ADAPTER-CONTRACT.md §2).
#
# It will be EITHER a REST client (Notion API + token from PROJECT.yaml) OR an
# orchestrator fetch-step via an MCP connector that retrieves the page and writes SPEC.md.
# Either way the core consumes the file on disk and calls no vendor API.
#
# Config it will read (from $PROJECT_YAML spec.config; NO literal hostnames):
#   base_url   Notion workspace/base url (from config, never hard-coded)
#   locator    how to find the page for a unit (a page-id template / query, {{unit}} injected)
#
# Contract functions to implement (see markdown.sh / issue_body.sh for the shape):
#   fetch_spec      <unit> <out_dir>   text-extract the located page -> <out_dir>/SPEC.md;
#                                      report thin if only visual content exists
#   is_transcribable <fmt>             false for visual-only formats (excluded)
set -u
fn="${1:-}"
case "$fn" in
  fetch_spec|is_transcribable)
    echo "notion.stub.sh: '$fn' not implemented (degraded, text-extract-only). Use spec.adapter=markdown|issue-body|none for now." >&2
    exit 64 ;;
  ""|-h|--help) sed -n '2,23p' "$0" ;;
  *) echo "notion.stub.sh: unknown fn '$fn' (fetch_spec|is_transcribable)" >&2; exit 2 ;;
esac
