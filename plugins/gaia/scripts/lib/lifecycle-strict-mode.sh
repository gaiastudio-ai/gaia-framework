#!/usr/bin/env bash
# lifecycle-strict-mode.sh — Canonical reader for the
# `lifecycle.strict_mode` toggle.
#
# Precedence (highest first):
#   1. GAIA_STRICT_LIFECYCLE env var (1 → ON, 0 → OFF) — set by the
#      orchestrator's `--strict-lifecycle` / `--no-strict-lifecycle` flag.
#   2. `lifecycle.strict_mode` key in project-config.yaml (yq-resolved).
#   3. Default: ON.
#
# Exit codes:
#   0 — strict mode is ON
#   1 — strict mode is OFF
#
# Usage:
#   if lifecycle_strict_mode_enabled; then ...; fi
#   bash scripts/lib/lifecycle-strict-mode.sh lifecycle_strict_mode_enabled

set -euo pipefail

lifecycle_strict_mode_enabled() {
  # Tier 1: env var override.
  if [ "${GAIA_STRICT_LIFECYCLE:-}" = "1" ]; then
    return 0
  fi
  if [ "${GAIA_STRICT_LIFECYCLE:-}" = "0" ]; then
    return 1
  fi

  # Tier 2: project-config.yaml.
  local config="${PROJECT_CONFIG:-.gaia/config/project-config.yaml}"
  if [ -f "$config" ] && command -v yq >/dev/null 2>&1; then
    local val
    val="$(yq eval '.lifecycle.strict_mode // "null"' "$config" 2>/dev/null || echo "null")"
    case "$val" in
      true) return 0 ;;
      false) return 1 ;;
      *) ;;  # fall through to default
    esac
  fi

  # Tier 3: default ON.
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-lifecycle_strict_mode_enabled}"
  shift || true
  case "$cmd" in
    lifecycle_strict_mode_enabled)
      if lifecycle_strict_mode_enabled; then
        echo "strict_mode: ON"
        exit 0
      else
        echo "strict_mode: OFF"
        exit 1
      fi
      ;;
    *)
      printf 'usage: %s lifecycle_strict_mode_enabled\n' "$0" >&2
      exit 2
      ;;
  esac
fi
