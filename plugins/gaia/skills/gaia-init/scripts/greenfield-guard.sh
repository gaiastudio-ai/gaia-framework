#!/usr/bin/env bash
# greenfield-guard.sh — refuse to run /gaia-init when project-config.yaml exists.
# Story: E71-S1 (FR-RSV2-34, AC4). Deterministic per ADR-042 (Scripts-over-LLM).
#
# Usage:
#   greenfield-guard.sh [--path <project-root>]
#
# --path defaults to the current working directory.
#
# Exit codes:
#   0  No config/project-config.yaml at the target — safe to proceed.
#   1  Existing config/project-config.yaml — refuse and direct user to
#      /gaia-config-* (E71-S3) or /gaia-brownfield (E71-S2).
#   2  Usage error.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-init/greenfield-guard.sh"
target="."

while [ $# -gt 0 ]; do
  case "$1" in
    --path)
      [ $# -ge 2 ] || { printf '%s: --path requires a value\n' "$SCRIPT_NAME" >&2; exit 2; }
      target="$2"; shift 2 ;;
    --help|-h)
      sed -n '1,15p' "$0"; exit 0 ;;
    *)
      printf '%s: unexpected argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
done

cfg="$target/config/project-config.yaml"

if [ -e "$cfg" ]; then
  cat <<MSG >&2
$SCRIPT_NAME: $cfg already exists.

/gaia-init is greenfield-only and refuses to modify existing configurations.

Next steps:
  - To edit the existing config, run /gaia-config-show or /gaia-config-validate
    (see /gaia-config-* family — E71-S3).
  - To onboard an existing codebase, run /gaia-brownfield (E71-S2) instead.
MSG
  exit 1
fi

exit 0
