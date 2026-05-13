#!/usr/bin/env bats
# config-hydration-allowlist-invariant.bats — bidirectional invariant tests for E85-S11.
#
# Story: E85-S11 — Reconciler/hydrator allowlist alignment + fail-closed contract.
# Source: AF-2026-05-13-2 sub-fix (d) bidirectional invariant.
# Test plan: §11.67.14 (TC-RV2-45, TC-RV2-46).
# Contract: ADR-098 (config-hydration.sh allowlist), AF-2026-05-13-2 sub-fix (a) + (d).
#
# Test scenarios:
#   TC-RV2-45 — Forward: every _CONFIG_HYDRATION_ALLOWLIST member is a declared schema property.
#   TC-RV2-46 — Reverse: every schema property is in allowlist, managed-elsewhere, or x-no-auto-hydration.

setup() {
  PLUGIN_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  HYDRATION="${PLUGIN_ROOT}/scripts/lib/config-hydration.sh"
  SCHEMA="${PLUGIN_ROOT}/schemas/project-config.schema.json"

  [ -f "$HYDRATION" ] || skip "config-hydration.sh not found at $HYDRATION"
  [ -f "$SCHEMA" ] || skip "project-config.schema.json not found at $SCHEMA"
}

# Extract the _CONFIG_HYDRATION_ALLOWLIST entries by sourcing the file in a subshell
# (the file refuses direct invocation but can be sourced — the dual-mode dispatch
# from E85-S11 T3a keeps the sourceable behavior intact).
_get_allowlist() {
  bash -c "source '$HYDRATION' 2>/dev/null; printf '%s\n' \"\${_CONFIG_HYDRATION_ALLOWLIST[@]}\""
}

_get_managed_elsewhere() {
  bash -c "source '$HYDRATION' 2>/dev/null; printf '%s\n' \"\${_CONFIG_HYDRATION_MANAGED_ELSEWHERE[@]:-}\""
}

_get_schema_props() {
  jq -r '.properties | keys[]' "$SCHEMA"
}

# Get schema properties flagged x-no-auto-hydration: true (optional escape hatch).
_get_x_no_auto() {
  jq -r '.properties | to_entries[] | select(.value["x-no-auto-hydration"] == true) | .key' "$SCHEMA"
}

@test "TC-RV2-45 — Forward invariant: every allowlist member is a declared schema property" {
  schema_props=$(_get_schema_props | sort -u)
  allowlist=$(_get_allowlist | sort -u)
  orphans=""
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if ! printf '%s\n' "$schema_props" | grep -Fxq "$entry"; then
      orphans="${orphans}${entry}\n"
    fi
  done <<< "$allowlist"
  if [ -n "$orphans" ]; then
    printf 'allowlist members not in schema (forward-invariant violation):\n%b' "$orphans" >&2
    return 1
  fi
}

@test "TC-RV2-46 — Reverse invariant: every schema property is allowlisted, managed-elsewhere, or x-no-auto-hydration" {
  schema_props=$(_get_schema_props | sort -u)
  allowlist=$(_get_allowlist | sort -u)
  managed=$(_get_managed_elsewhere | sort -u)
  optout=$(_get_x_no_auto | sort -u)

  orphans=""
  while IFS= read -r prop; do
    [ -z "$prop" ] && continue
    if printf '%s\n' "$allowlist" | grep -Fxq "$prop"; then continue; fi
    if printf '%s\n' "$managed" | grep -Fxq "$prop"; then continue; fi
    if printf '%s\n' "$optout" | grep -Fxq "$prop"; then continue; fi
    orphans="${orphans}${prop}\n"
  done <<< "$schema_props"

  if [ -n "$orphans" ]; then
    printf 'schema properties not classified in allowlist/managed-elsewhere/x-no-auto-hydration (reverse-invariant violation):\n%b' "$orphans" >&2
    return 1
  fi
}
