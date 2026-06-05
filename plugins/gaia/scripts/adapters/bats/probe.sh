#!/usr/bin/env bash
# adapters/bats/probe.sh — tri-state probe.
#
# Returns the tri-state availability JSON:
#   { "available": true|false, "version": "<version-string>", "failure_kind": null|"<enum>" }
#
# Provider is the `bats` binary (Bats Automated Testing System) per
# adapter.json. When `bats` is on PATH, returns available=true and parses the
# semver from `bats --version` (format: "Bats 1.13.0"). When absent, returns
# available=false with failure_kind="not_installed" and exit 1.
#
# This probe is invoked by tool-availability-probe.sh in adapter-dir
# mode and may also be called directly by callers wanting tri-state JSON.

set -euo pipefail
LC_ALL=C
export LC_ALL

if command -v bats >/dev/null 2>&1; then
  # `bats --version` prints something like "Bats 1.13.0". Extract the semver.
  raw="$(bats --version 2>/dev/null | head -n 1 || true)"
  ver="$(printf '%s' "$raw" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+/) { print $i; exit }
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
