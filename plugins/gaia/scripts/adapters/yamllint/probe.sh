#!/usr/bin/env bash
# adapters/yamllint/probe.sh — tri-state probe.
#
# Returns the tri-state availability JSON:
#   { "available": true|false, "version": "<version-string>", "failure_kind": null|"<enum>" }
#
# Provider is the `yamllint` binary (per adapter.json). When `yamllint` is on
# PATH, returns available=true and parses the version from `yamllint --version`
# (format: "yamllint 1.35.1"). When absent, returns available=false with
# failure_kind="not_installed" and exit 1.

set -euo pipefail
LC_ALL=C
export LC_ALL

if command -v yamllint >/dev/null 2>&1; then
  raw="$(yamllint --version 2>&1 | head -n 1 || true)"
  ver="$(printf '%s' "$raw" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?/) { print $i; exit }
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
