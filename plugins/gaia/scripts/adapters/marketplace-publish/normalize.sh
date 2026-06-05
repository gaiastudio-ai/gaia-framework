#!/usr/bin/env bash
# adapters/marketplace-publish/normalize.sh — output normalizer for the
# marketplace-publish adapter.
#
# Reads the JSON response from `gh release create` on stdin and emits a
# normalized JSON object on stdout containing at least:
#   { "release_url": "<url>", "tag": "<tag_name>", "draft": <bool> }
#
# gh release create JSON shape (gh ≥ 2.x):
#   { "url": "...", "tag_name": "...", "isDraft": true|false, "name": "...", ... }

set -euo pipefail
LC_ALL=C
export LC_ALL

if ! command -v jq >/dev/null 2>&1; then
  echo "normalize.sh: jq required" >&2
  exit 2
fi

jq -c '{
  release_url: (.url // .html_url // ""),
  tag:         (.tag_name // .tag // ""),
  draft:       (.isDraft // .draft // false)
}'
