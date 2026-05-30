#!/usr/bin/env bash
# bridge-populate-test-execution.sh — AF-2026-05-30-2 / Test10 F-27 fix.
#
# When `/gaia-bridge-enable` flips bridge_enabled:true on a project, populate
# the `test_execution.tier_N.{command,placement,required,timeout_seconds}`
# block in project-config.yaml from the runners declared in
# `.gaia/config/test-environment.yaml`. Prior to this helper, bridge-enable
# only flipped the flag; the `test_execution` block stayed empty, so
# `qa-test-runner.sh` skipped (false-PASS in code reviews) per Test10 F-27.
#
# Idempotent: if `test_execution.tier_N.command` is ALREADY set in
# project-config.yaml, leaves it alone (the operator's explicit value wins).
# Only fills tiers that have NO command. Comments and formatting in
# project-config.yaml are preserved (regex-based insert, not yq round-trip).
#
# Usage:
#   bridge-populate-test-execution.sh
#       [--config <path>]       (default: .gaia/config/project-config.yaml)
#       [--manifest <path>]     (default: .gaia/config/test-environment.yaml)
#       [--dry-run]             print what would change but don't write
#
# Exit codes:
#   0 — populated or already up-to-date (idempotent)
#   1 — manifest absent (no runners to copy from); config left untouched
#   2 — malformed args / config / manifest

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$PWD}}}"
CONFIG="${PROJECT_ROOT}/.gaia/config/project-config.yaml"
MANIFEST="${PROJECT_ROOT}/.gaia/config/test-environment.yaml"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config)   CONFIG="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "bridge-populate-test-execution: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$CONFIG" ]; then
  echo "bridge-populate-test-execution: config not found: $CONFIG" >&2
  exit 2
fi
if [ ! -f "$MANIFEST" ]; then
  echo "bridge-populate-test-execution: manifest absent — nothing to populate from: $MANIFEST" >&2
  echo "  (run /gaia-bridge-enable on a project with a generated test-environment.yaml manifest)" >&2
  exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "bridge-populate-test-execution: yq required" >&2
  exit 2
fi

# Map runner.tier (integer) → tier_N block. Default placement guesses by name.
_placement_for_runner_name() {
  case "${1:-}" in
    unit)         echo "unit" ;;
    integration)  echo "integration" ;;
    e2e|end-to-end) echo "e2e" ;;
    *)            echo "unit" ;;
  esac
}

# Read all runners from the manifest as JSON for easy parsing.
RUNNERS_JSON=$(yq -o=json '.runners // []' "$MANIFEST" 2>/dev/null || printf '[]')
if [ "$RUNNERS_JSON" = "[]" ] || [ -z "$RUNNERS_JSON" ]; then
  echo "bridge-populate-test-execution: manifest has no runners — nothing to populate" >&2
  exit 1
fi

# For each runner, check if test_execution.tier_N.command is already set;
# if not, queue a write. We collect (tier, command, placement) tuples first
# then apply via a single yq pass to preserve formatting.

WROTE_ANY=0
RUNNERS_COUNT=$(printf '%s' "$RUNNERS_JSON" | jq 'length')

for i in $(seq 0 $((RUNNERS_COUNT - 1))); do
  name=$(printf '%s' "$RUNNERS_JSON" | jq -r ".[$i].name // empty")
  tier=$(printf '%s' "$RUNNERS_JSON" | jq -r ".[$i].tier // empty")
  cmd=$(printf '%s' "$RUNNERS_JSON" | jq -r ".[$i].command // empty")
  timeout_s=$(printf '%s' "$RUNNERS_JSON" | jq -r ".[$i].timeout_seconds // 300")

  if [ -z "$tier" ] || [ -z "$cmd" ]; then
    echo "  skip: runner '$name' has no tier or command" >&2
    continue
  fi

  tier_key="tier_${tier}"

  # If test_execution.tier_N.command is already non-empty, respect the
  # operator's explicit value (idempotent / overwrite-safe).
  existing_cmd=$(yq -r ".test_execution.${tier_key}.command // \"\"" "$CONFIG" 2>/dev/null || echo "")
  if [ -n "$existing_cmd" ] && [ "$existing_cmd" != "null" ]; then
    echo "  keep: test_execution.${tier_key}.command already set ('$existing_cmd')" >&2
    continue
  fi

  placement=$(_placement_for_runner_name "$name")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  would write: test_execution.${tier_key} = { placement: $placement, command: '$cmd', required: true, timeout_seconds: $timeout_s }"
    WROTE_ANY=1
    continue
  fi

  # In-place write via yq. yq round-trips YAML preserving most comments but
  # may rewrite list/map ordering — acceptable for this auto-populate path
  # since the operator can always hand-edit afterwards.
  yq -i ".test_execution.${tier_key}.placement = \"${placement}\" |
         .test_execution.${tier_key}.command = \"${cmd}\" |
         .test_execution.${tier_key}.required = true |
         .test_execution.${tier_key}.timeout_seconds = ${timeout_s}" "$CONFIG"
  echo "  wrote: test_execution.${tier_key} (from runner '$name')" >&2
  WROTE_ANY=1
done

if [ "$WROTE_ANY" -eq 0 ]; then
  echo "bridge-populate-test-execution: nothing to populate (all tiers already set or no eligible runners)" >&2
fi
exit 0
