#!/usr/bin/env bash
# framework-version.sh — shared framework_version resolution library (E86-S1).
#
# Story: E86-S1 — Shared `lib/framework-version.sh` extraction from
#                  `template-header.sh`.
# Traces: FR-472, TC-FVD-41..TC-FVD-44, SR-60.
# ADRs:   ADR-102 (Stale-Flag Marker Naming Convention — the version
#                  string produced here is suitable for byte-stable string
#                  comparison; no trailing newline).
#
# Trust Boundary (SR-60)
# ----------------------
# This library reads ONLY from `.claude-plugin/plugin.json` within the
# plugin distribution AND from `resolve-config.sh` when available. It
# does NOT read from user-controlled config files (e.g.,
# `config/project-config.yaml`) — that path goes through `resolve-config.sh`
# which has its own input-validation contract. The version string returned
# by this library is therefore plugin-authoritative, not project-authoritative,
# and is safe to use as the LHS of a drift-detection comparison.
#
# Contract
# --------
# This file is intended to be SOURCED, not executed. Sourcing makes
# `resolve_framework_version` available.
#
# Function: resolve_framework_version
#   Two-tier resolution:
#     1. Preferred: `resolve-config.sh` on PATH (or co-located at the
#        plugin's `scripts/` directory). Grep the `framework_version=`
#        line from its KEY='VALUE' output and strip quotes.
#     2. Fallback: read `plugin.json` directly via grep/sed (no jq
#        dependency).
#
#   Side effects:
#     - On success, exports `GAIA_FRAMEWORK_VERSION=<resolved-version>`
#       as a convenience for callers that want the value as a shell
#       variable (E86-S2 drift detection consumes this).
#
#   Stdout: the resolved version string (no trailing newline — required
#           for ADR-102 byte-stable string comparison).
#   Stderr: a diagnostic message on failure.
#
#   Returns:
#     0  Success.
#     1  plugin.json missing/unreadable AND resolve-config.sh unavailable.
#     2  plugin.json exists but `version` field is absent/empty.
#
# Cross-platform: bash 3.2+ on macOS, bash 4+ on Linux. No jq dependency.
# Locale-pinned by callers; this library does not export LC_ALL.

# ---- Source guard (canonical GAIA `_<UPPER_NAME>_SH_SOURCED` idiom) -------
if [ -n "${_FRAMEWORK_VERSION_SH_SOURCED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_FRAMEWORK_VERSION_SH_SOURCED=1

# Refuse direct execution — sourcing is the only supported entry point.
# Canonical bash idiom: when sourced, ${BASH_SOURCE[0]} != ${0}.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  printf 'framework-version.sh: must be sourced, not executed\n' >&2
  exit 1
fi

# resolve_framework_version
#
# See file header for the full contract. The function uses BASH_SOURCE to
# locate the library's own path so it works regardless of the caller's cwd.
resolve_framework_version() {
  local version=""

  # Resolve the library's own directory; from `plugins/gaia/scripts/lib/`
  # the plugin.json is at `../../.claude-plugin/plugin.json` (two `..`
  # segments: up to `scripts/`, up to `plugins/gaia/`, then `.claude-plugin/`).
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Preferred: resolve-config.sh on PATH or co-located in scripts/.
  local resolver=""
  if command -v resolve-config.sh >/dev/null 2>&1; then
    resolver="$(command -v resolve-config.sh)"
  elif [ -x "$here/../resolve-config.sh" ]; then
    resolver="$here/../resolve-config.sh"
  fi

  if [ -n "$resolver" ]; then
    # Use default KEY='VALUE' output and grep the line.
    local line
    if line="$("$resolver" 2>/dev/null | grep -E "^framework_version=" || true)"; then
      # Strip KEY= and the surrounding single quotes.
      version="${line#framework_version=}"
      version="${version#\'}"
      version="${version%\'}"
    fi
  fi

  # Fallback: read plugin.json directly. The library at `scripts/lib/`
  # resolves the manifest at `../../.claude-plugin/plugin.json`.
  local plugin_json="$here/../../.claude-plugin/plugin.json"
  if [ -z "$version" ]; then
    if [ -f "$plugin_json" ]; then
      # Grep-based extraction (no jq dependency). The sed pattern uses
      # `[^"]*` (not `+`) so that an explicit empty-string version
      # (`"version": ""`) extracts an empty match instead of returning
      # the unchanged input line — that distinction lets the AC3 check
      # below correctly fire exit 2 for absent/empty version fields.
      local extracted
      extracted="$(grep -E '"version"[[:space:]]*:' "$plugin_json" | head -n 1)"
      if [ -n "$extracted" ]; then
        version="$(printf '%s' "$extracted" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
        # If the sed substitution did not produce a quoted-string match
        # (e.g., `"version": null` or non-quoted forms), force empty so
        # the AC3 exit-2 path fires.
        if [ "$version" = "$extracted" ]; then
          version=""
        fi
      fi
    else
      # AC2: plugin.json missing AND resolve-config.sh unavailable.
      printf 'framework-version.sh: plugin.json not found at %s (resolve-config.sh unavailable)\n' \
        "$plugin_json" >&2
      return 1
    fi
  fi

  if [ -z "$version" ]; then
    # AC3: plugin.json existed but version field is absent or empty.
    printf 'framework-version.sh: framework_version is absent or empty in plugin.json (%s)\n' \
      "$plugin_json" >&2
    return 2
  fi

  # Export the resolved value as a convenience variable for callers that
  # want it as a shell var. The export is documented in the trust-boundary
  # block above (SR-60).
  export GAIA_FRAMEWORK_VERSION="$version"

  # No-trailing-newline stdout contract per ADR-102 (byte-stable string
  # comparison). Do NOT change to `printf '%s\n'`.
  printf "%s" "$version"
}
