#!/usr/bin/env bash
# check-manifest-sentinel.sh — E17-S35 (FR-499, ADR-110)
#
# Layer 0 readiness guard: inspect a .gaia/config/test-environment.yaml manifest
# for the canonical GAIA-MANIFEST-TEMPLATE sentinel comment. Detection of the
# sentinel means the user copied the .example template without customizing —
# FAIL Layer 0 readiness with an actionable error and surface
# `bridge_status: manifest_unmodified_template` per architecture §10.20.11.6.
#
# Sentinel match is a literal `grep -qF` against `# GAIA-MANIFEST-TEMPLATE`.
# Robust against future punctuation drift in the trailing prose.
#
# Usage:
#   check-manifest-sentinel.sh --manifest <path>
#   check-manifest-sentinel.sh --help
#
# Exit codes:
#   0  manifest is sentinel-free (Layer 0 readiness PASSES for this check)
#   1  manifest contains the sentinel (Layer 0 readiness FAILS)
#   2  usage error / manifest file missing
#
# Traces: E17-S35, FR-499, ADR-110.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="check-manifest-sentinel.sh"
SENTINEL_PREFIX='# GAIA-MANIFEST-TEMPLATE'

manifest=""

usage() {
  cat <<'USAGE'
Usage: check-manifest-sentinel.sh --manifest <path>

Inspect a .gaia/config/test-environment.yaml manifest for the canonical
GAIA-MANIFEST-TEMPLATE sentinel comment. Layer 0 readiness guard.

Exit codes:
  0  sentinel absent (PASSES)
  1  sentinel present (FAILS)
  2  usage error / manifest missing
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      [ $# -ge 2 ] || { printf '%s: --manifest requires a value\n' "$SCRIPT_NAME" >&2; exit 2; }
      manifest="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf '%s: unexpected argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
done

[ -n "${manifest}" ] || { printf '%s: --manifest is required\n' "$SCRIPT_NAME" >&2; usage >&2; exit 2; }

if [ ! -f "${manifest}" ]; then
  printf '%s: ERROR: manifest file not found: %s\n' "$SCRIPT_NAME" "${manifest}" >&2
  exit 2
fi

if grep -qF "${SENTINEL_PREFIX}" "${manifest}"; then
  printf 'Layer 0 readiness FAILED: %s contains the unmodified-template sentinel (GAIA-MANIFEST-TEMPLATE). Either run /gaia-bridge-enable to regenerate against current detection signals, or edit %s directly to populate stack-specific runners.\n' \
    "${manifest}" "${manifest}" >&2
  printf 'bridge_status: manifest_unmodified_template\n' >&2
  exit 1
fi

exit 0
