#!/usr/bin/env bash
# adapters/markdownlint/probe.sh — FR-415 + ADR-089 tri-state probe.
#
# Returns the ADR-078 / ADR-089 tri-state availability JSON:
#   { "available": true|false, "version": "<version-string>", "failure_kind": null|"<enum>" }
#
# Provider preference: `markdownlint-cli2` (canonical, declared in adapter.json)
# with a fallback to `markdownlint` (the older v1 CLI). When either is on
# PATH, returns available=true and parses the version string. When both are
# absent, returns available=false with failure_kind="not_installed" and exit 1.

set -euo pipefail
LC_ALL=C
export LC_ALL

bin=""
if command -v markdownlint-cli2 >/dev/null 2>&1; then
  bin="markdownlint-cli2"
elif command -v markdownlint >/dev/null 2>&1; then
  bin="markdownlint"
fi

if [ -n "$bin" ]; then
  raw="$("$bin" --version 2>/dev/null | head -n 1 || true)"
  ver="$(printf '%s' "$raw" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^v?[0-9]+\.[0-9]+\.[0-9]+/) { sub(/^v/, "", $i); print $i; exit }
    }
  }')"
  ver="${ver:-unknown}"
  jq -nc \
    --arg version "$ver" \
    '{ available: true, version: $version, failure_kind: null }'
  exit 0
fi

jq -nc '{ available: false, version: "", failure_kind: "not_installed" }'
exit 1
