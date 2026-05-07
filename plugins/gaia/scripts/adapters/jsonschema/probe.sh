#!/usr/bin/env bash
# adapters/jsonschema/probe.sh — FR-415 + ADR-089 tri-state probe.
#
# Returns the ADR-078 / ADR-089 tri-state availability JSON:
#   { "available": true|false, "version": "<version-string>", "failure_kind": null|"<enum>" }
#
# Provider is the `check-jsonschema` binary (per adapter.json). When
# `check-jsonschema` is on PATH, returns available=true and parses the version
# from `check-jsonschema --version`. When absent, returns available=false with
# failure_kind="not_installed" and exit 1.
#
# Invoked by tool-availability-probe.sh (E77-S3) in adapter-dir mode and may
# also be called directly by callers wanting tri-state JSON.

set -euo pipefail
LC_ALL=C
export LC_ALL

if command -v check-jsonschema >/dev/null 2>&1; then
  raw="$(check-jsonschema --version 2>/dev/null | head -n 1 || true)"
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
