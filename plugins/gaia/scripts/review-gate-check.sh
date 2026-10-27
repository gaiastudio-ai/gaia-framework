#!/usr/bin/env bash
# review-gate-check.sh — commit-bound composite Review Gate checker
#
# Reads the Review Gate table from a story file and checks whether every
# canonical row is PASSED and bound to the current head SHA. Returns a
# composite verdict:
#
#   COMPLETE — all 6 rows PASSED, all bound to --bind-head, CI green
#   PENDING  — at least one row is stale (reviewed on an older SHA) or
#              UNVERIFIED, and no row is FAILED
#   BLOCKED  — at least one row is FAILED
#
# Usage:
#   review-gate-check.sh --bind-head <sha> --ci-sha <sha> --story <file>
#   review-gate-check.sh --help
#
# Flags:
#   --bind-head <sha>  The commit SHA that all reviews must be bound to.
#                      Must be a real hex SHA (not "none"), normalized to
#                      full length.
#   --ci-sha <sha>     The SHA of the CI run. Must match --bind-head for
#                      COMPLETE, or "none" ONLY when no CI is configured
#                      (no promotion chain in project config).
#   --story <file>     Path to the story markdown file.
#
# Exit codes:
#   0 — COMPLETE
#   1 — BLOCKED or error
#   2 — PENDING
#
# Read-only: this script never writes to the story file.
# POSIX discipline: bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="review-gate-check.sh"

_RGC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source the dual-shape table parser.
# shellcheck source=lib/review-gate-table.sh
. "${_RGC_DIR}/lib/review-gate-table.sh"

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  review-gate-check.sh --bind-head <sha> --ci-sha <sha> --story <file>
  review-gate-check.sh --help

Composite Review Gate check with commit binding.

Flags:
  --bind-head <sha>  The commit SHA that all reviews must be bound to.
                     Must be a real hex SHA, not "none".
  --ci-sha <sha>     CI run SHA; must match --bind-head, or "none" only
                     when no CI is configured.
  --story <file>     Path to the story markdown file.

Exit codes:
  0 — COMPLETE (all rows PASSED and bound to head, CI matches)
  1 — BLOCKED (any row FAILED) or error
  2 — PENDING (any row stale/UNVERIFIED, no FAILED)
USAGE
}

# Canonical gate names.
CANONICAL_GATES=(
  "Code Review"
  "QA Tests"
  "Security Review"
  "Test Automation"
  "Test Review"
  "Performance Review"
)

# Check whether CI is configured by reading the promotion chain from config.
_has_ci_configured() {
  local config_file="${PROJECT_CONFIG:-}"
  if [ -z "$config_file" ]; then
    local root="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"
    config_file="$root/.gaia/config/project-config.yaml"
  fi
  if [ ! -f "$config_file" ]; then
    return 1
  fi
  # Check for ci_cd.promotion_chain with at least one entry.
  if grep -q 'promotion_chain:' "$config_file" 2>/dev/null; then
    if awk '
      /^ci_cd:/ { in_ci = 1; next }
      in_ci && /^[^ ]/ { in_ci = 0 }
      in_ci && /promotion_chain:/ { in_pc = 1; next }
      in_pc && /^[^ ]/ && !/^    / { in_pc = 0 }
      in_pc && /- id:/ { found = 1; exit }
      END { exit (found ? 0 : 1) }
    ' "$config_file" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

main() {
  local bind_head="" ci_sha="" story_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --bind-head) [ $# -ge 2 ] || die "--bind-head requires a value"; bind_head="$2"; shift 2 ;;
      --ci-sha)    [ $# -ge 2 ] || die "--ci-sha requires a value";    ci_sha="$2";    shift 2 ;;
      --story)     [ $# -ge 2 ] || die "--story requires a value";     story_file="$2"; shift 2 ;;
      --help|-h)   usage; exit 0 ;;
      *)           die "unknown flag: $1" ;;
    esac
  done

  [ -n "$bind_head" ] || die "--bind-head is required"
  [ -n "$ci_sha" ]    || die "--ci-sha is required"
  [ -n "$story_file" ] || die "--story is required"

  # Validate --bind-head BEFORE file check: must be a real hex SHA, not "none".
  case "$bind_head" in
    -*)  die "--bind-head starts with '-' — potential argument injection" ;;
    none) die "--bind-head must be a real commit SHA, not 'none'" ;;
  esac
  if ! printf '%s' "$bind_head" | grep -qE '^[0-9a-fA-F]{4,40}$'; then
    die "--bind-head must be a hex SHA (4-40 hex chars), got '$bind_head'"
  fi

  # Validate --ci-sha: "none" only allowed in no-CI mode.
  if [ "$ci_sha" = "none" ]; then
    if _has_ci_configured; then
      die "--ci-sha none is not accepted when CI is configured (promotion chain present); pass the CI run SHA"
    fi
  else
    case "$ci_sha" in
      -*) die "--ci-sha starts with '-' — potential argument injection" ;;
    esac
    if ! printf '%s' "$ci_sha" | grep -qE '^[0-9a-fA-F]{4,40}$'; then
      die "--ci-sha must be a hex SHA or 'none', got '$ci_sha'"
    fi
  fi

  [ -f "$story_file" ] || die "story file not found: $story_file"

  # Parse the table.
  local rows_tsv
  rows_tsv="$(parse_review_gate_table "$story_file")" \
    || die "failed to parse Review Gate table in $story_file"

  # Build parallel arrays from parsed rows.
  local -a gates=() statuses=() shas=()
  local gate status _report sha
  while IFS=$'\t' read -r gate status _report sha; do
    [ -z "$gate" ] && continue
    gates+=("$gate")
    statuses+=("$status")
    shas+=("$sha")
  done <<< "$rows_tsv"

  # Verify all 6 canonical gates are present.
  local cg found i
  for cg in "${CANONICAL_GATES[@]}"; do
    found=0
    i=0
    while [ "$i" -lt "${#gates[@]}" ]; do
      if [ "${gates[$i]}" = "$cg" ]; then
        found=1
        break
      fi
      i=$((i + 1))
    done
    if [ "$found" -eq 0 ]; then
      die "missing canonical gate row: $cg"
    fi
  done

  # Read carry-forward sidecar if it exists (audit trail for carried rows).
  local story_dir
  story_dir="$(dirname "$story_file")"
  local sidecar="${story_dir}/review-gate-carry.jsonl"
  local has_sidecar=0
  # Build a newline-separated list of "row\tto_sha" from the sidecar.
  local sidecar_entries=""
  if [ -f "$sidecar" ]; then
    has_sidecar=1
    # Parse each JSONL line (portable: no jq dependency — use awk).
    sidecar_entries="$(awk '
      {
        row = ""; to = ""
        if (match($0, /"row":"[^"]*"/)) {
          row = substr($0, RSTART + 7, RLENGTH - 8)
        }
        if (match($0, /"to_sha":"[^"]*"/)) {
          to = substr($0, RSTART + 10, RLENGTH - 11)
        }
        if (row != "" && to != "") printf "%s\t%s\n", row, to
      }
    ' "$sidecar" 2>/dev/null)" || sidecar_entries=""
  fi

  # Helper: check if a carry-forward sidecar record exists for (row, to_sha).
  _has_carry_record() {
    local check_row="$1" check_sha="$2"
    [ -n "$sidecar_entries" ] || return 1
    printf '%s\n' "$sidecar_entries" | while IFS=$'\t' read -r sr st; do
      if [ "$sr" = "$check_row" ] && [ "$st" = "$check_sha" ]; then
        return 0
      fi
    done
    return 1
  }

  # Classify each row.
  local has_failed=0 has_pending=0
  local pending_list="" blocked_list=""
  i=0
  while [ "$i" -lt "${#gates[@]}" ]; do
    local g="${gates[$i]}"
    local s="${statuses[$i]}"
    local row_sha="${shas[$i]}"

    # Check if this is a canonical gate.
    local is_canonical=0
    for cg in "${CANONICAL_GATES[@]}"; do
      if [ "$g" = "$cg" ]; then is_canonical=1; break; fi
    done
    if [ "$is_canonical" -eq 0 ]; then
      i=$((i + 1))
      continue
    fi

    if [ "$s" = "FAILED" ]; then
      has_failed=1
      blocked_list="${blocked_list}  - ${g}\n"
    elif [ "$s" = "UNVERIFIED" ] || [ "$s" = "NOT STARTED" ]; then
      has_pending=1
      pending_list="${pending_list}  - ${g} (unverified)\n"
    elif [ "$s" = "PASSED" ]; then
      # Check SHA binding.
      if [ "$row_sha" = "absent" ] || [ -z "$row_sha" ]; then
        has_pending=1
        pending_list="${pending_list}  - ${g} (no SHA — stale)\n"
      elif [ "$row_sha" != "$bind_head" ]; then
        # Row SHA doesn't match bind-head. Check for carry-forward.
        if [ "$has_sidecar" -eq 1 ] && _has_carry_record "$g" "$bind_head"; then
          : # Carried to bind-head via sidecar — bound.
        else
          has_pending=1
          pending_list="${pending_list}  - ${g} (reviewed on ${row_sha}, head is ${bind_head} — stale)\n"
        fi
      fi
      # If SHA matches bind-head, the row is directly bound — no sidecar needed.
    else
      has_pending=1
      pending_list="${pending_list}  - ${g} (unknown verdict: ${s})\n"
    fi
    i=$((i + 1))
  done

  # CI SHA check: "none" is only valid when no CI is configured (checked above).
  # When ci_sha is "none" AND no CI is configured, it's acceptable (no CI binding).
  # When ci_sha is a real SHA, it must match bind_head.
  if [ "$ci_sha" != "none" ] && [ "$ci_sha" != "$bind_head" ]; then
    has_pending=1
    pending_list="${pending_list}  - CI SHA mismatch (ci=${ci_sha}, head=${bind_head})\n"
  fi

  # Emit verdict.
  if [ "$has_failed" -eq 1 ]; then
    printf 'Review Gate: BLOCKED\n'
    printf 'Blocking gates:\n'
    printf '%b' "$blocked_list"
    exit 1
  elif [ "$has_pending" -eq 1 ]; then
    printf 'Review Gate: PENDING\n'
    printf 'Pending gates:\n'
    printf '%b' "$pending_list"
    exit 2
  else
    printf 'Review Gate: COMPLETE\n'
    exit 0
  fi
}

main "$@"
