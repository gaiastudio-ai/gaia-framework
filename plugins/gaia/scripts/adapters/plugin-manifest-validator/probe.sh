#!/usr/bin/env bash
# adapters/plugin-manifest-validator/probe.sh — FR-410 + ADR-089 tri-state probe.
#
# Returns the ADR-078 / ADR-089 tri-state availability JSON:
#   { "available": true|false|null, "version": "<version-string>", "failure_kind": null|"<enum>" }
#
# The provider for this adapter is shell-native: it depends on POSIX `awk`
# (manifest YAML parsing) and `jq` (JSON emission). Both are part of the GAIA
# baseline runtime — `awk` is universally available on POSIX systems and `jq`
# is required by every adapter under ADR-078. This probe checks `awk` (the
# canonical provider declared in adapter.json); production callers can layer
# additional checks on top via tool-availability-probe.sh.
#
# This probe is invoked by the generalized tool-availability-probe.sh (E77-S3)
# in adapter-dir mode, and may also be called directly by callers that want
# the tri-state JSON without going through the larger probe pipeline.

set -euo pipefail
LC_ALL=C
export LC_ALL

if command -v awk >/dev/null 2>&1; then
  # awk implementations vary widely (gawk, mawk, BSD awk). Take the first
  # token of `awk --version` (or `awk -W version` fallback) — best-effort.
  ver="$(awk --version 2>/dev/null | awk 'NR==1' || true)"
  if [ -z "$ver" ]; then
    ver="$(awk -W version 2>&1 | awk 'NR==1' || true)"
  fi
  ver="${ver:-unknown}"
  jq -nc \
    --arg version "$ver" \
    '{ available: true, version: $version, failure_kind: null }'
  exit 0
fi

jq -nc '{ available: false, version: "", failure_kind: "tool_missing" }'
exit 1
