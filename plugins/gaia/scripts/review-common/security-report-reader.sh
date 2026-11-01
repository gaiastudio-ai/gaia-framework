#!/usr/bin/env bash
# security-report-reader.sh — read-only helper that extracts critical security
# findings from the findings register and reports the security gate state.
#
# Used by the fix-cycle cap orchestration to decide whether accept-override
# is blocked. Fails closed on parse/read errors (exit 1 with actionable msg).
#
# Usage:
#   security-report-reader.sh --story <key>
#
# Output (one JSON object per line for each critical security finding):
#   {"id":"RF-n","owasp":"cat","impact":"text","disposition":"open","signed_off":false}
#
# Also prints a gate-state line:
#   security_gate_state <assessed|unassessed|no_round>
#
# Exit codes:
#   0  success (findings listed, or none exist; gate state reported)
#   1  error — register unreadable or malformed (fail closed)

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="security-report-reader.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
SCRIPTS_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." >/dev/null && pwd)"

_sr_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_sr_die() { local rc="$1"; shift; _sr_err "$*"; exit "$rc"; }

_sr_require_tool() {
  command -v "$1" >/dev/null 2>&1 || _sr_die 1 "$1 is required but not on PATH"
}

_sr_require_tool yq
_sr_require_tool jq

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

key=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --story) [ "$#" -ge 2 ] || _sr_die 1 "--story requires a value"; key="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: %s --story <key>\n' "$SCRIPT_NAME"
      exit 0
      ;;
    *) _sr_die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$key" ] || _sr_die 1 "--story is required"

# ---------------------------------------------------------------------------
# Resolve the findings register
# ---------------------------------------------------------------------------

reg_path="$("$SCRIPTS_DIR/resolve-review-report-path.sh" --key "$key" --type findings-register 2>/dev/null)" || \
  _sr_die 1 "cannot resolve findings register for: $key (fail closed)"

if [ ! -f "$reg_path" ]; then
  # No register — no findings, gate state unknown.
  printf 'security_gate_state no_round\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate register is parseable (fail closed on errors)
# ---------------------------------------------------------------------------

if ! yq '.' "$reg_path" >/dev/null 2>&1; then
  _sr_die 1 "register is malformed: $reg_path (fail closed)"
fi

entries_type="$(yq '.entries | type' "$reg_path" 2>/dev/null)" || \
  _sr_die 1 "cannot read entries from register: $reg_path (fail closed)"

if [ "$entries_type" != "!!seq" ]; then
  _sr_die 1 "register entries is not a sequence: $reg_path (fail closed)"
fi

# ---------------------------------------------------------------------------
# Report security gate state from the latest round
# ---------------------------------------------------------------------------

rounds_len="$(yq '.rounds | length // 0' "$reg_path" 2>/dev/null)" || rounds_len="0"
if [ "$rounds_len" = "0" ] || [ "$rounds_len" = "null" ]; then
  printf 'security_gate_state no_round\n'
else
  # Check the latest round's security gate for a completed report.
  sec_report="$(yq '.rounds[-1].selected_gates[] | select(.gate == "security-review") | .report_path // ""' "$reg_path" 2>/dev/null)" || sec_report=""
  sec_in_round="$(yq '[.rounds[-1].selected_gates[] | select(.gate == "security-review")] | length' "$reg_path" 2>/dev/null)" || sec_in_round="0"

  if [ "$sec_in_round" = "0" ] || [ "$sec_in_round" = "null" ]; then
    # Security gate not selected — check carried gates.
    sec_carried="$(yq '[.rounds[-1].carried_gates[] | select(.gate == "security-review" and .report_path != "" and .report_path != null)] | length' "$reg_path" 2>/dev/null)" || sec_carried="0"
    if [ "$sec_carried" != "0" ] && [ "$sec_carried" != "null" ]; then
      printf 'security_gate_state assessed\n'
    else
      printf 'security_gate_state unassessed\n'
    fi
  elif [ -n "$sec_report" ] && [ "$sec_report" != "null" ]; then
    printf 'security_gate_state assessed\n'
  else
    printf 'security_gate_state unassessed\n'
  fi
fi

# ---------------------------------------------------------------------------
# Extract critical security findings
# ---------------------------------------------------------------------------

crit_count="$(yq '[.entries[] | select(.severity == "critical" and (.gate_ratings[] | .gate == "security-review"))] | length' "$reg_path" 2>/dev/null)" || \
  _sr_die 1 "cannot count critical findings: $reg_path (fail closed)"

if [ "$crit_count" = "0" ] || [ "$crit_count" = "null" ]; then
  exit 0
fi

# For each critical finding, output one JSON line (safe for multi-line values).
idx=0
while [ "$idx" -lt "$crit_count" ]; do
  f_id="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].id // \"unknown\"" "$reg_path" 2>/dev/null)" || f_id="unknown"
  f_disp="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].disposition // \"open\"" "$reg_path" 2>/dev/null)" || f_disp="open"

  # OWASP category: from gate_ratings first, then sign_off, else "unknown".
  f_owasp="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].gate_ratings[] | select(.gate == \"security-review\") | .owasp_category // \"\"" "$reg_path" 2>/dev/null)" || f_owasp=""
  if [ -z "$f_owasp" ] || [ "$f_owasp" = "null" ]; then
    f_owasp="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].sign_off.owasp_category // \"\"" "$reg_path" 2>/dev/null)" || f_owasp=""
  fi
  [ -n "$f_owasp" ] && [ "$f_owasp" != "null" ] || f_owasp="unknown"

  # Impact: from entry.impact first, then sign_off.impact, else "unknown".
  f_impact="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].impact // \"\"" "$reg_path" 2>/dev/null)" || f_impact=""
  if [ -z "$f_impact" ] || [ "$f_impact" = "null" ]; then
    f_impact="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].sign_off.impact // \"\"" "$reg_path" 2>/dev/null)" || f_impact=""
  fi
  [ -n "$f_impact" ] && [ "$f_impact" != "null" ] || f_impact="unknown"

  # Sign-off: complete only if ALL six fields are present.
  f_signed="false"
  so_user="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].sign_off.risk_accepted_by // \"\"" "$reg_path" 2>/dev/null)" || so_user=""
  so_owasp="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].sign_off.owasp_category // \"\"" "$reg_path" 2>/dev/null)" || so_owasp=""
  so_impact="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].sign_off.impact // \"\"" "$reg_path" 2>/dev/null)" || so_impact=""
  so_fid="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].sign_off.finding_id // \"\"" "$reg_path" 2>/dev/null)" || so_fid=""
  so_round="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].sign_off.round // \"\"" "$reg_path" 2>/dev/null)" || so_round=""
  so_ts="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].sign_off.timestamp // \"\"" "$reg_path" 2>/dev/null)" || so_ts=""

  if [ -n "$so_user" ] && [ "$so_user" != "null" ] && \
     [ -n "$so_owasp" ] && [ "$so_owasp" != "null" ] && \
     [ -n "$so_impact" ] && [ "$so_impact" != "null" ] && \
     [ -n "$so_fid" ] && [ "$so_fid" != "null" ] && \
     [ -n "$so_round" ] && [ "$so_round" != "null" ] && \
     [ -n "$so_ts" ] && [ "$so_ts" != "null" ]; then
    f_signed="true"
  fi

  jq -n --arg id "$f_id" --arg owasp "$f_owasp" --arg impact "$f_impact" \
    --arg disp "$f_disp" --argjson signed "$f_signed" \
    '{id: $id, owasp: $owasp, impact: $impact, disposition: $disp, signed_off: $signed}' || \
    _sr_die 1 "jq output failed for finding $f_id"

  idx=$((idx + 1))
done

exit 0
