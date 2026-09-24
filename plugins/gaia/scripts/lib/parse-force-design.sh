#!/usr/bin/env bash
# parse-force-design.sh — shared --force-design flag parser
#
# Sourced by setup.sh of every solutioning entry point. Parses
# --force-design, --reason, --entry-point, and --sprint-id from argv,
# exports the four FORCE_DESIGN_* env vars, and shifts consumed args.
#
# Binding rule for --reason: a --reason binds to the most recent
# preceding owning flag. --force-design claims ownership, so the
# immediately following --reason is consumed as FORCE_DESIGN_REASON.
# Any other flag (e.g. --bypass) releases ownership, so a subsequent
# --reason passes through in _PFD_REMAINING for the caller.
#
# Usage (in setup.sh, after variable declarations):
#   source "$PLUGIN_SCRIPTS_DIR/lib/parse-force-design.sh"
#   _parse_force_design "$@"; set -- "${_PFD_REMAINING[@]}"
#
# After the call, FORCE_DESIGN, FORCE_DESIGN_REASON,
# FORCE_DESIGN_ENTRY_POINT, and FORCE_DESIGN_SPRINT_ID are exported.
# Unconsumed args are in _PFD_REMAINING for the caller to process.

set -euo pipefail

# Guard against double-source.
if [ "${_PARSE_FORCE_DESIGN_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_PARSE_FORCE_DESIGN_LOADED=1

# Binding rule: --reason binds to the most recent preceding owning flag.
# --force-design claims ownership; any other flag (e.g. --bypass) releases
# it. An unowned --reason passes through in _PFD_REMAINING.
_parse_force_design() {
  FORCE_DESIGN=""
  FORCE_DESIGN_REASON=""
  FORCE_DESIGN_ENTRY_POINT=""
  FORCE_DESIGN_SPRINT_ID=""
  _PFD_REMAINING=()
  local _pfd_owns_reason=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --force-design)
        FORCE_DESIGN=1
        _pfd_owns_reason=1
        shift ;;
      --reason)
        [ $# -ge 2 ] || { printf 'parse-force-design: --reason requires a quoted text argument\n' >&2; return 2; }
        if [ "$_pfd_owns_reason" -eq 1 ]; then
          FORCE_DESIGN_REASON="$2"
          _pfd_owns_reason=0
        else
          _PFD_REMAINING+=("$1" "$2")
        fi
        shift 2 ;;
      --entry-point)
        [ $# -ge 2 ] || { printf 'parse-force-design: --entry-point requires a value\n' >&2; return 2; }
        FORCE_DESIGN_ENTRY_POINT="$2"; shift 2 ;;
      --sprint-id)
        [ $# -ge 2 ] || { printf 'parse-force-design: --sprint-id requires a value\n' >&2; return 2; }
        FORCE_DESIGN_SPRINT_ID="$2"; shift 2 ;;
      *)
        _pfd_owns_reason=0
        _PFD_REMAINING+=("$1"); shift ;;
    esac
  done

  export FORCE_DESIGN FORCE_DESIGN_REASON FORCE_DESIGN_ENTRY_POINT FORCE_DESIGN_SPRINT_ID
}
