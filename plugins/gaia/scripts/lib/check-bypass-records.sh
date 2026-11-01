#!/usr/bin/env bash
# check-bypass-records.sh — scan sprint audit for review gate bypass records.
#
# Reports every recorded bypass use (story, head, non-PASS rows) and warns
# when the bypass variable is present in the session environment.
#
# Usage:
#   check-bypass-records.sh [--project-root DIR]
#
# Exit codes:
#   0  always (diagnostic, not a gate)
#
# Output:
#   One line per bypass record and one warning per env-variable presence,
#   or nothing when no records exist and no variable is set.

set -euo pipefail
LC_ALL=C
export LC_ALL

_cbr_root="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}"

while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) _cbr_root="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

# Resolve the project root from common env vars.
if [ -z "$_cbr_root" ]; then
  _cbr_root="$PWD"
  _cbr_walk="$PWD"
  while [ "$_cbr_walk" != "/" ]; do
    if [ -d "$_cbr_walk/.gaia/state" ]; then
      _cbr_root="$_cbr_walk"
      break
    fi
    _cbr_walk="$(dirname "$_cbr_walk")"
  done
fi

_cbr_audit_dir="$_cbr_root/.gaia/state/sprint-audit"
_cbr_found=0

# --- Scan bypass records ---------------------------------------------------
if [ -d "$_cbr_audit_dir" ]; then
  # review_gate_bypass records (from merge.sh operator bypass)
  for _cbr_file in "$_cbr_audit_dir"/review_gate_bypass*.yaml; do
    [ -f "$_cbr_file" ] || continue
    _cbr_found=1
    _cbr_story=""
    _cbr_head=""
    _cbr_rows=""
    while IFS= read -r _cbr_line; do
      case "$_cbr_line" in
        story:*) _cbr_story="${_cbr_line#story: }" ;;
        head:*)  _cbr_head="${_cbr_line#head: }" ;;
        *\"*FAILED*|*\"*UNVERIFIED*|*\"*PENDING*)
          _cbr_rows="${_cbr_rows:+${_cbr_rows}, }${_cbr_line}" ;;
      esac
    done < "$_cbr_file"
    printf 'WARNING: review gate bypass recorded — story=%s head=%s non_pass_rows=[%s]\n' \
      "$_cbr_story" "$_cbr_head" "$_cbr_rows"
  done

  # bypass_attempt_blocked records (from pre-tool guard)
  for _cbr_file in "$_cbr_audit_dir"/bypass_attempt_blocked*.yaml; do
    [ -f "$_cbr_file" ] || continue
    _cbr_found=1
    _cbr_var=""
    _cbr_tool=""
    _cbr_ts=""
    while IFS= read -r _cbr_line; do
      case "$_cbr_line" in
        variable:*)  _cbr_var="${_cbr_line#variable: }" ;;
        tool:*)      _cbr_tool="${_cbr_line#tool: }" ;;
        timestamp:*) _cbr_ts="${_cbr_line#timestamp: }" ;;
      esac
    done < "$_cbr_file"
    printf 'WARNING: bypass attempt blocked — variable=%s tool=%s timestamp=%s\n' \
      "$_cbr_var" "$_cbr_tool" "$_cbr_ts"
  done
fi

# --- Check session environment for the bypass variable --------------------
if [ -n "${GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE:-}" ]; then
  _cbr_found=1
  printf 'WARNING: GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE is set in the current session environment — value=%s\n' \
    "${GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE}"
fi

if [ "$_cbr_found" -eq 0 ]; then
  printf 'No review gate bypass records found in the sprint audit.\n'
fi
