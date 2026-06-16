#!/usr/bin/env bash
# manual-test-flakiness.sh — compute verdict-flip rate for manual tests
#
# Reads .gaia/state/manual-test-verdicts.tsv and computes per-story +
# aggregate flip rate (verdict transitions / total runs).
#
# Usage:
#   manual-test-flakiness.sh --story <key>       Per-story flip rate
#   manual-test-flakiness.sh --check-promotion    Exit 0 iff aggregate
#                                                 flip rate < threshold
#                                                 across 3 consecutive
#                                                 closed sprints.
#
# Exit codes:
#   0 — stable (flip rate below threshold)
#   1 — unstable (flip rate above threshold, or insufficient data)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="manual-test-flakiness.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# Defaults
THRESHOLD="${MANUAL_TEST_FLIP_THRESHOLD:-10}"

# Resolve verdicts TSV path
resolve_verdicts_path() {
  if [ -n "${MANUAL_TEST_VERDICTS_TSV:-}" ]; then
    printf '%s' "$MANUAL_TEST_VERDICTS_TSV"
  else
    local root="${PROJECT_PATH:-.}"
    printf '%s' "$root/.gaia/state/manual-test-verdicts.tsv"
  fi
}

# Compute flip rate for a single story.
# Args: $1=story_key
# Output: flip rate as integer percentage (0-100)
compute_story_flip_rate() {
  local story_key="$1"
  local tsv_path
  tsv_path="$(resolve_verdicts_path)"

  if [ ! -f "$tsv_path" ] || [ ! -s "$tsv_path" ]; then
    printf '0'
    return 0
  fi

  local verdicts=()
  local sk _run_id verdict _ts
  while IFS=$'\t' read -r sk _run_id verdict _ts; do
    if [ "$sk" = "$story_key" ]; then
      verdicts+=("$verdict")
    fi
  done < "$tsv_path"

  local count="${#verdicts[@]}"
  if [ "$count" -le 1 ]; then
    printf '0'
    return 0
  fi

  local flips=0
  local i
  for ((i=1; i<count; i++)); do
    if [ "${verdicts[$i]}" != "${verdicts[$((i-1))]}" ]; then
      flips=$((flips + 1))
    fi
  done

  # Flip rate = flips / (count - 1) * 100, but the spec says
  # "50% one flip (PASSED then FAILED)" => flips / count * 100
  # i.e. 1 flip / 2 runs = 50%
  local rate=$(( (flips * 100) / count ))
  printf '%d' "$rate"
}

# Compute aggregate flip rate across all stories.
# Groups rows by story key so cross-story boundaries are never counted as flips.
# Output: aggregate flip rate as integer percentage
compute_aggregate_flip_rate() {
  local tsv_path
  tsv_path="$(resolve_verdicts_path)"

  if [ ! -f "$tsv_path" ] || [ ! -s "$tsv_path" ]; then
    printf '0'
    return 0
  fi

  # Collect distinct story keys (preserve chronological first-appearance order)
  local story_keys=()
  local seen_keys=""
  local sk _run_id _verdict _ts
  while IFS=$'\t' read -r sk _run_id _verdict _ts; do
    case "$seen_keys" in
      *"|${sk}|"*) ;;  # already seen
      *)
        story_keys+=("$sk")
        seen_keys="${seen_keys}|${sk}|"
        ;;
    esac
  done < "$tsv_path"

  local total_runs=0
  local total_flips=0
  local key

  for key in "${story_keys[@]}"; do
    # Filter this story's rows in chronological order, count flips
    local prev="" verdict
    while IFS=$'\t' read -r sk _run_id verdict _ts; do
      if [ "$sk" = "$key" ]; then
        total_runs=$((total_runs + 1))
        if [ -n "$prev" ] && [ "$verdict" != "$prev" ]; then
          total_flips=$((total_flips + 1))
        fi
        prev="$verdict"
      fi
    done < "$tsv_path"
  done

  if [ "$total_runs" -eq 0 ]; then
    printf '0'
    return 0
  fi

  local rate=$(( (total_flips * 100) / total_runs ))
  printf '%d' "$rate"
}

# Count closed sprints from sprint-archive
count_closed_sprints() {
  local archive_dir="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_PATH:-.}/docs/implementation-artifacts}/sprint-archive"
  if [ ! -d "$archive_dir" ]; then
    printf '0'
    return 0
  fi
  local count
  count=$(find "$archive_dir" -maxdepth 1 -name 'sprint-*-closed-*.yaml' -type f 2>/dev/null | wc -l | tr -d ' ')
  printf '%d' "$count"
}

# ---------- Main (only when executed, not sourced) ----------

_main() {
  MODE=""
  STORY_KEY=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        [ $# -ge 2 ] || die "--story requires an argument"
        STORY_KEY="$2"; shift 2 ;;
      --check-promotion)
        MODE="check-promotion"; shift ;;
      --threshold)
        [ $# -ge 2 ] || die "--threshold requires an argument"
        THRESHOLD="$2"; shift 2 ;;
      *)
        die "unknown flag: $1" ;;
    esac
  done

  if [ -n "$STORY_KEY" ] && [ "$MODE" != "check-promotion" ]; then
    rate="$(compute_story_flip_rate "$STORY_KEY")"
    printf 'flip_rate=%d%%\n' "$rate"
    exit 0
  fi

  if [ "$MODE" = "check-promotion" ]; then
    # Require 3 consecutive closed sprints
    closed="$(count_closed_sprints)"
    if [ "$closed" -lt 3 ]; then
      log "only $closed closed sprint(s) found (need 3); promotion not ready"
      exit 1
    fi

    # Check verdicts file
    tsv_path="$(resolve_verdicts_path)"
    if [ ! -f "$tsv_path" ] || [ ! -s "$tsv_path" ]; then
      log "no verdict data; promotion not ready"
      exit 1
    fi

    rate="$(compute_aggregate_flip_rate)"
    if [ "$rate" -ge "$THRESHOLD" ]; then
      log "aggregate flip rate ${rate}% >= threshold ${THRESHOLD}%; promotion not ready"
      exit 1
    fi

    log "aggregate flip rate ${rate}% < threshold ${THRESHOLD}%; promotion ready"
    exit 0
  fi

  die "usage: $SCRIPT_NAME --story <key> | --check-promotion"
}

# Guard: only run _main when executed directly, not when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _main "$@"
fi
