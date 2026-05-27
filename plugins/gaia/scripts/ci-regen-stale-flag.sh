#!/usr/bin/env bash
# ci-regen-stale-flag.sh — config-stale flag lifecycle for /gaia-config-ci (E71-S4).
#
# Maintains the marker file `.gaia/memory/.config-stale`. Presence of the file
# means the project's CI workflow files are out of sync with the latest
# config-mutating /gaia-config-* edits. Absence means in-sync.
#
# Subcommands:
#   write   Create the flag file (idempotent).
#   check   Exit 0 + warn-on-stderr when present, exit 1 silent when absent.
#   clear   Remove the flag file (idempotent).
#
# Refs: AC9 (TS-09, TS-10, TS-11), FR-RSV2-37.

set -euo pipefail
LC_ALL=C
export LC_ALL

cmd="${1:-}"
shift || true

flag_path() {
  # AF-2026-05-27-3 (ADR-111): .gaia/memory is the only marker home; legacy
  # _memory fallback removed with the consolidation migration.
  printf '%s/.gaia/memory/.config-stale\n' "${PROJECT_ROOT:-$PWD}"
}

write_flag() {
  local p; p="$(flag_path)"
  mkdir -p "$(dirname "$p")"
  : > "$p"
}

check_flag() {
  local p; p="$(flag_path)"
  if [ -f "$p" ]; then
    echo "ci-regen-stale-flag.sh: project config has changed since last CI workflow regeneration. Run /gaia-config-ci --regenerate to refresh generated workflows." >&2
    exit 0
  fi
  exit 1
}

clear_flag() {
  local p; p="$(flag_path)"
  if [ -f "$p" ]; then
    rm -f "$p"
  fi
  exit 0
}

case "$cmd" in
  write) write_flag ;;
  check) check_flag ;;
  clear) clear_flag ;;
  ""|-h|--help)
    sed -n '1,20p' "$0"
    ;;
  *)
    echo "ci-regen-stale-flag.sh: unknown subcommand: $cmd" >&2
    exit 64
    ;;
esac
