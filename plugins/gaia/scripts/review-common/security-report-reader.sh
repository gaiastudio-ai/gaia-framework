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
    # Follow the full carry chain to find a completed security assessment.
    hop_run="$(yq '.rounds[-1].carried_gates[] | select(.gate == "security-review") | .from_run // ""' "$reg_path" 2>/dev/null)" || hop_run=""
    found_assessed=""
    hops=0
    while [ -n "$hop_run" ] && [ "$hop_run" != "null" ] && [ "$hops" -lt 10 ]; do
      export _SR_FROM_RUN="$hop_run"
      hop_report="$(yq '(.rounds[] | select(.run_id == strenv(_SR_FROM_RUN))).selected_gates[] | select(.gate == "security-review") | .report_path // ""' "$reg_path" 2>/dev/null)" || hop_report=""
      if [ -n "$hop_report" ] && [ "$hop_report" != "null" ]; then
        hop_outcome="$(yq '[.gate_runs[] | select(.run_id == strenv(_SR_FROM_RUN) and .gate == "security-review" and .outcome == "completed")] | length' "$reg_path" 2>/dev/null)" || hop_outcome="0"
        if [ "$hop_outcome" != "0" ] && [ "$hop_outcome" != "null" ]; then
          found_assessed=1
        fi
        unset _SR_FROM_RUN; break
      fi
      next_hop="$(yq '(.rounds[] | select(.run_id == strenv(_SR_FROM_RUN))).carried_gates[] | select(.gate == "security-review") | .from_run // ""' "$reg_path" 2>/dev/null)" || next_hop=""
      unset _SR_FROM_RUN
      hop_run="$next_hop"
      hops=$((hops + 1))
    done
    if [ -n "$found_assessed" ]; then
      printf 'security_gate_state assessed\n'
    else
      printf 'security_gate_state unassessed\n'
    fi
  elif [ -n "$sec_report" ] && [ "$sec_report" != "null" ]; then
    # Check gate_runs outcome — errored is not assessed.
    latest_rid="$(yq '.rounds[-1].run_id' "$reg_path" 2>/dev/null)" || latest_rid=""
    export _SR_RID="$latest_rid"
    sec_outcome="$(yq '[.gate_runs[] | select(.run_id == strenv(_SR_RID) and .gate == "security-review" and .outcome == "completed")] | length' "$reg_path" 2>/dev/null)" || sec_outcome="0"
    unset _SR_RID
    if [ "$sec_outcome" != "0" ] && [ "$sec_outcome" != "null" ]; then
      printf 'security_gate_state assessed\n'
    else
      printf 'security_gate_state unassessed\n'
    fi
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

  # OWASP category: from gate_ratings only (the reviewer's classification).
  # The sign-off category belongs to the approver and must not be shown
  # as the reviewer's classification — that would let an approver inject
  # a misleading category.
  f_owasp="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].gate_ratings[] | select(.gate == \"security-review\") | .owasp_category // \"\"" "$reg_path" 2>/dev/null)" || f_owasp=""
  [ -n "$f_owasp" ] && [ "$f_owasp" != "null" ] || f_owasp="unknown"

  # Impact: from entry.impact only (the reviewer's classification).
  # The sign-off impact belongs to the approver and must not be shown
  # as the reviewer's — that would let an approver inject misleading text.
  f_impact="$(yq "[.entries[] | select(.severity == \"critical\" and (.gate_ratings[] | .gate == \"security-review\"))] | .[$idx].impact // \"\"" "$reg_path" 2>/dev/null)" || f_impact=""
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
