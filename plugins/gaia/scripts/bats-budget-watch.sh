#!/usr/bin/env bash
# bats-budget-watch.sh — budget-watch primitive for bats CI steps.
#
# Wrap a bats invocation, measure wall-clock duration, and emit a structured
# warning when the duration exceeds a configurable threshold. The wrapper is
# advisory-only: exit code is the inner command's status, never masked.
#
# Two modes:
#   1. Legacy single-threshold — `--threshold-seconds N` is honoured and
#      treated as a SOFT alias. Emits the legacy "bats budget exceeded"
#      wording so existing CI dashboards keep matching.
#   2. Dual-threshold — `--soft-threshold-seconds N` and
#      `--hard-threshold-seconds N`. Defaults: soft=270, hard=480. Both
#      breaches emit a structured WARNING but exit code is preserved
#      (advisory-only contract).
#
# The warning is appended to $GITHUB_STEP_SUMMARY when set, or printed to
# stdout otherwise. CI surfaces the warning on the PR's checks summary.
#
# Usage:
#   # legacy form (single threshold — preserved verbatim)
#   bats-budget-watch.sh --threshold-seconds <N> [--label <text>] -- <cmd> [args...]
#
#   # dual-threshold form
#   bats-budget-watch.sh --soft-threshold-seconds <N> \
#                        --hard-threshold-seconds <N> [--label <text>] \
#                        -- <cmd> [args...]
#
# Exit codes:
#   * Inner command's exit code (preserved verbatim — we never mask failures).
#   * 2 — argument parsing error (missing `--`, hard < soft, etc).
#
# Library mode (for unit tests): set BATS_BUDGET_WATCH_LIB_ONLY=1 before
# sourcing to load the helpers without invoking main().

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Canonical defaults — soft 270s / hard 480s.
# ---------------------------------------------------------------------------
readonly _BBW_DEFAULT_SOFT=270
readonly _BBW_DEFAULT_HARD=480

# ---------------------------------------------------------------------------
# Internal helpers — leading-underscore prefix exempts them from the
# textual public-function coverage gate.
# ---------------------------------------------------------------------------

# _bats_elapsed_seconds <start> <end>
# Diff two epoch seconds. Clamps to 0 on clock skew (end < start).
_bats_elapsed_seconds() {
  local start="$1" end="$2" diff
  diff=$((end - start))
  if [ "$diff" -lt 0 ]; then
    printf '0\n'
  else
    printf '%d\n' "$diff"
  fi
}

# _bats_format_warning <label> <elapsed> <threshold>
# Legacy single-threshold structured-warning markdown block. Preserved
# verbatim for back-compat with legacy callers (tests + CI dashboards).
_bats_format_warning() {
  local label="$1" elapsed="$2" threshold="$3"
  cat <<EOF
> [!WARNING]
> **bats budget exceeded** — \`${label}\`
>
> - threshold: ${threshold}s
> - elapsed: ${elapsed}s
> - over by: $((elapsed - threshold))s
>
> The bats CI step is approaching its wall-clock budget. See
> \`plugins/gaia/docs/CI-NOTES.md\` for guidance on adding fixtures without
> breaking the budget.
EOF
}

# _bats_format_dual_warning <label> <elapsed> <soft> <hard> <kind>
# Dual-threshold structured-warning. <kind> is "soft" or "hard" — the
# header line names the breached tier explicitly.
_bats_format_dual_warning() {
  local label="$1" elapsed="$2" soft="$3" hard="$4" kind="$5"
  cat <<EOF
> [!WARNING]
> **${kind} budget exceeded** — \`${label}\`
>
> - soft: ${soft}s
> - hard: ${hard}s
> - elapsed: ${elapsed}s
>
> Advisory only — the wrapper preserves the inner command's exit code. See
> \`plugins/gaia/docs/CI-NOTES.md\` for guidance.
EOF
}

# _bats_emit_warning <text...>
# Append the warning to $GITHUB_STEP_SUMMARY when set; otherwise print to
# stdout so local runs surface it too.
_bats_emit_warning() {
  local text="$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "$(dirname "$GITHUB_STEP_SUMMARY")" ]; then
    printf '%s\n' "$text" >> "$GITHUB_STEP_SUMMARY"
  else
    printf '%s\n' "$text"
  fi
}

# ---------------------------------------------------------------------------
# Public entry — bats_budget_watch_check.
# ---------------------------------------------------------------------------

# bats_budget_watch_check <args...>
# Parse CLI args, run the inner command, measure elapsed, emit warning(s) if
# threshold(s) exceeded, return the inner exit code.
bats_budget_watch_check() {
  local legacy_threshold=""
  local soft_threshold=""
  local hard_threshold=""
  local label="bats"
  local inner_cmd=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --threshold-seconds)
        legacy_threshold="${2:-}"
        shift 2
        ;;
      --soft-threshold-seconds)
        soft_threshold="${2:-}"
        shift 2
        ;;
      --hard-threshold-seconds)
        hard_threshold="${2:-}"
        shift 2
        ;;
      --label)
        label="${2:-bats}"
        shift 2
        ;;
      --)
        shift
        inner_cmd=("$@")
        break
        ;;
      *)
        printf 'bats-budget-watch.sh: unexpected arg %q (did you forget the -- separator?)\n' "$1" >&2
        return 2
        ;;
    esac
  done

  if [ "${#inner_cmd[@]}" -eq 0 ]; then
    printf 'bats-budget-watch.sh: inner command after -- is required\n' >&2
    return 2
  fi

  # Mode selection:
  #   * legacy_threshold set -> single-threshold path (preserves legacy
  #     wording so dashboards keep matching).
  #   * neither legacy nor explicit dual flags -> dual-threshold defaults
  #     (soft 270, hard 480).
  #   * explicit dual flags -> dual-threshold with overrides.
  local legacy_mode=0
  if [ -n "$legacy_threshold" ] && [ -z "$soft_threshold" ] && [ -z "$hard_threshold" ]; then
    legacy_mode=1
  fi

  if [ "$legacy_mode" -eq 0 ]; then
    soft_threshold="${soft_threshold:-${legacy_threshold:-$_BBW_DEFAULT_SOFT}}"
    hard_threshold="${hard_threshold:-$_BBW_DEFAULT_HARD}"

    # Hard < soft is a configuration error — fail fast (exit 2). Order
    # invariant: soft is the lower advisory tier, hard is the upper.
    if [ "$hard_threshold" -lt "$soft_threshold" ]; then
      printf 'bats-budget-watch.sh: hard-threshold (%s) must be >= soft-threshold (%s)\n' \
        "$hard_threshold" "$soft_threshold" >&2
      return 2
    fi
  fi

  local start end elapsed inner_status=0
  start="$(date +%s)"
  # Run inner command. Tolerate failure — we still want to emit the warning
  # if the failure happened after the budget was blown.
  set +e
  "${inner_cmd[@]}"
  inner_status=$?
  set -e
  end="$(date +%s)"
  elapsed="$(_bats_elapsed_seconds "$start" "$end")"

  if [ "$legacy_mode" -eq 1 ]; then
    if [ "$elapsed" -gt "$legacy_threshold" ]; then
      _bats_emit_warning "$(_bats_format_warning "$label" "$elapsed" "$legacy_threshold")"
    fi
  else
    if [ "$elapsed" -gt "$hard_threshold" ]; then
      _bats_emit_warning \
        "$(_bats_format_dual_warning "$label" "$elapsed" "$soft_threshold" "$hard_threshold" "hard")"
    elif [ "$elapsed" -gt "$soft_threshold" ]; then
      _bats_emit_warning \
        "$(_bats_format_dual_warning "$label" "$elapsed" "$soft_threshold" "$hard_threshold" "soft")"
    fi
  fi

  return "$inner_status"
}

# ---------------------------------------------------------------------------
# Main — skipped when sourced as a library (BATS_BUDGET_WATCH_LIB_ONLY=1).
# ---------------------------------------------------------------------------
if [ "${BATS_BUDGET_WATCH_LIB_ONLY:-0}" != "1" ]; then
  bats_budget_watch_check "$@"
fi
