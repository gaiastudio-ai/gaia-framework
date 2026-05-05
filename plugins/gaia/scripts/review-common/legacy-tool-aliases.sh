#!/usr/bin/env bash
# legacy-tool-aliases.sh — backward-compat alias layer for E70-S2 static-tool migration.
#
# Story: E70-S2 — Migrate five existing static-tool integrations to adapter form
#        (Semgrep, gitleaks, radon, gocyclo, eslint-plugin-sonarjs) + backward-compat
#        alias layer (one-sprint deprecation window).
# Decisions: ADR-078 (Tool Adapter Framework).
# Refs: FR-RSV2-17, FR-RSV2-20.
#
# Purpose
# -------
# Provides shell-function shims (`run_<tool>_legacy`) that route legacy direct
# invocations of the five static-tool integrations to their canonical adapter
# `run.sh` entry points under `plugins/gaia/scripts/adapters/{tool}/run.sh`.
#
# Each shim:
#   1. Emits a single-line `DEPRECATION WARNING:` to stderr naming the canonical
#      adapter path so existing projects discover the migration target.
#   2. Forwards all caller arguments to the adapter `run.sh` via `exec`, so the
#      adapter's exit code propagates verbatim — zero functional regression.
#
# Deprecation Window
# ------------------
# This alias layer lives for ONE SPRINT. Removal is a separate cleanup task
# (out-of-scope for E70-S2 — see story Dev Notes). After the deprecation window
# expires, the entire file MAY be deleted; projects that have updated to the
# canonical adapter path continue to work without modification.
#
# Source vs exec
# --------------
# The functions are designed to be `source`d into a parent shell. Each shim
# calls the adapter `run.sh` as a subprocess (NOT `exec`) so that the parent
# shell remains alive and may continue with other commands. Exit code from the
# adapter is captured and returned by the function.

set -u

# Resolve the adapters root once (relative to this file's location).
# shellcheck disable=SC2034
_GAIA_LEGACY_ALIAS_DIR="${BASH_SOURCE[0]%/*}"
_GAIA_ADAPTERS_ROOT="${_GAIA_LEGACY_ALIAS_DIR}/../adapters"

# Internal helper: emit a single-line DEPRECATION warning to stderr and invoke
# the adapter run.sh.  Args after the tool name are forwarded verbatim.
_gaia_legacy_alias_dispatch() {
  local tool="$1"; shift
  local adapter_run="${_GAIA_ADAPTERS_ROOT}/${tool}/run.sh"
  printf 'DEPRECATION WARNING: legacy %s integration is deprecated. ' "$tool" >&2
  printf 'Use the canonical adapter at adapters/%s/run.sh ' "$tool" >&2
  printf '(full path: %s). ' "$adapter_run" >&2
  printf 'Alias removal is scheduled for the next sprint after E70-S2.\n' >&2
  if [ ! -x "$adapter_run" ]; then
    printf 'legacy-tool-aliases.sh: adapter run.sh missing or not executable: %s\n' "$adapter_run" >&2
    return 1
  fi
  "$adapter_run" "$@"
}

# Public shim functions — one per migrated tool.
run_semgrep_legacy()        { _gaia_legacy_alias_dispatch semgrep "$@"; }
run_gitleaks_legacy()       { _gaia_legacy_alias_dispatch gitleaks "$@"; }
run_radon_legacy()          { _gaia_legacy_alias_dispatch radon "$@"; }
run_gocyclo_legacy()        { _gaia_legacy_alias_dispatch gocyclo "$@"; }
run_eslint_sonarjs_legacy() { _gaia_legacy_alias_dispatch eslint-plugin-sonarjs "$@"; }
