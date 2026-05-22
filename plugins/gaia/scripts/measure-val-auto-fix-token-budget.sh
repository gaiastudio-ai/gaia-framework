#!/usr/bin/env bash
# measure-val-auto-fix-token-budget.sh — E44-S9 NFR-VCP-2 verification harness.
#
# Computes the two NFR-VCP-2 ratios from a single-pass Val baseline cost and
# either (a) the per-iteration token_estimate values logged by E44-S2/E44-S8 in
# the checkpoint custom.val_loop_iterations array, or (b) explicit CLI flags
# (the E44-S2 AC-EC8 fallback path when instrumentation is unavailable).
#
# Bounds (per .gaia/artifacts/planning-artifacts/prd.md §NFR-VCP-2):
#   per_iteration_ratio = iteration_1_tokens / baseline_tokens     ≤ 2.0
#   total_loop_ratio    = loop_total_tokens / baseline_tokens      ≤ 6.0
#
# Exits 0 when both bounds hold; non-zero with a FAIL message naming the
# violated bound otherwise.
#
# Usage:
#   measure-val-auto-fix-token-budget.sh \
#       --baseline <N> --iteration-1 <N> --loop-total <N>
#   measure-val-auto-fix-token-budget.sh \
#       --baseline <N> --checkpoint <path-to-checkpoint.json>
#
# When both --checkpoint and the explicit flags are supplied, the script
# prefers the checkpoint values if a populated token_estimate field is found,
# and silently falls back to the explicit flags otherwise (data_source line
# in stdout records which path was taken — AC5).

set -euo pipefail

_print_usage() {
  cat <<'USAGE'
Usage:
  measure-val-auto-fix-token-budget.sh --baseline <N> --iteration-1 <N> --loop-total <N>
  measure-val-auto-fix-token-budget.sh --baseline <N> --checkpoint <path>

NFR-VCP-2 token-budget verification harness for the Val auto-fix loop.

Required:
  --baseline <N>       Single-pass Val token cost on the representative artifact.

Either:
  --iteration-1 <N>    Tokens consumed by iteration 1 of the auto-fix loop.
  --loop-total <N>     Tokens consumed across all 3 iterations of the loop.

Or:
  --checkpoint <path>  Path to an E44-S8 checkpoint JSON; the harness reads
                       custom.val_loop_iterations[*].token_estimate when
                       populated. Falls back to --iteration-1/--loop-total
                       if the field is absent.

Other:
  --help               Show this message and exit 0.

Bounds (per docs/planning-artifacts/prd.md §NFR-VCP-2):
  per_iteration_ratio  ≤ 2.0
  total_loop_ratio     ≤ 6.0
USAGE
}

_die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

_is_positive_number() {
  # Accepts integers and decimals, rejects empty / non-numeric / zero / negative.
  case "${1:-}" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  awk -v v="$1" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'
}

_format_ratio() {
  # Print 1.5 not 1.50000, 5 not 5.0000, with no trailing zeros.
  awk -v v="$1" 'BEGIN {
    s = sprintf("%.4f", v)
    sub(/0+$/, "", s)
    sub(/\.$/, "", s)
    print s
  }'
}

_extract_token_estimates_from_checkpoint() {
  # Echoes one token_estimate per line; empty output if none populated.
  local ckpt="$1"
  python3 - "$ckpt" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    iters = (data.get("custom") or {}).get("val_loop_iterations") or []
    for it in iters:
        est = it.get("token_estimate")
        if isinstance(est, (int, float)) and est > 0:
            print(est)
except Exception:
    sys.exit(0)
PY
}

main() {
  local baseline="" iteration_1="" loop_total="" checkpoint=""

  if [ "$#" -eq 0 ]; then
    printf 'error: missing required arguments — provide --baseline plus either --iteration-1/--loop-total or --checkpoint.\n' >&2
    _print_usage >&2
    exit 2
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)         _print_usage; exit 0 ;;
      --baseline)        baseline="${2:-}"; shift 2 ;;
      --iteration-1)     iteration_1="${2:-}"; shift 2 ;;
      --loop-total)      loop_total="${2:-}"; shift 2 ;;
      --checkpoint)      checkpoint="${2:-}"; shift 2 ;;
      *) _die "unknown argument: $1" ;;
    esac
  done

  # Validate baseline.
  if [ -z "$baseline" ]; then
    _die "--baseline is required (single-pass Val token cost)."
  fi
  if ! _is_positive_number "$baseline"; then
    if [ "$baseline" = "0" ]; then
      _die "--baseline must be > 0 to avoid division by zero."
    fi
    _die "--baseline must be a positive numeric value (got: $baseline)."
  fi

  # Resolve data source — checkpoint preferred when populated, else CLI flags.
  local data_source="external"
  local source_note=""

  if [ -n "$checkpoint" ]; then
    if [ ! -f "$checkpoint" ]; then
      _die "checkpoint file not found: $checkpoint"
    fi
    local estimates
    estimates="$(_extract_token_estimates_from_checkpoint "$checkpoint")"
    if [ -n "$estimates" ]; then
      # Preferred path — use checkpoint token_estimate values.
      data_source="checkpoint"
      source_note="(read from $checkpoint)"
      iteration_1="$(printf '%s\n' "$estimates" | head -n 1)"
      loop_total="$(printf '%s\n' "$estimates" | awk '{ s += $1 } END { print s }')"
    fi
  fi

  # When the checkpoint path did not yield values, the explicit CLI flags must
  # be present — this is the AC-EC8 / AC5 fallback recorded in the methodology.
  if [ -z "$iteration_1" ] || [ -z "$loop_total" ]; then
    _die "missing iteration values — supply --iteration-1 and --loop-total or a --checkpoint with populated token_estimate fields."
  fi
  if ! _is_positive_number "$iteration_1"; then
    _die "--iteration-1 must be a positive numeric value (got: $iteration_1)."
  fi
  if ! _is_positive_number "$loop_total"; then
    _die "--loop-total must be a positive numeric value (got: $loop_total)."
  fi

  # Compute ratios.
  local per_iteration_ratio total_loop_ratio
  per_iteration_ratio="$(awk -v a="$iteration_1" -v b="$baseline" 'BEGIN { printf "%.6f", a/b }')"
  total_loop_ratio="$(awk -v a="$loop_total" -v b="$baseline" 'BEGIN { printf "%.6f", a/b }')"

  local per_iteration_pretty total_loop_pretty
  per_iteration_pretty="$(_format_ratio "$per_iteration_ratio")"
  total_loop_pretty="$(_format_ratio "$total_loop_ratio")"

  # Bound checks (inclusive — exactly 2.0 / 6.0 PASS).
  local per_iteration_pass total_loop_pass
  per_iteration_pass="$(awk -v r="$per_iteration_ratio" 'BEGIN { exit (r <= 2.0) ? 0 : 1 }' && echo 1 || echo 0)"
  total_loop_pass="$(awk -v r="$total_loop_ratio" 'BEGIN { exit (r <= 6.0) ? 0 : 1 }' && echo 1 || echo 0)"

  local measurement_date
  measurement_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Emit machine-readable verdict.
  printf 'NFR-VCP-2 Val Auto-Fix Loop Token Budget — Measurement Report\n'
  printf 'data_source: %s %s\n' "$data_source" "$source_note"
  printf 'baseline_tokens: %s\n' "$baseline"
  printf 'iteration_1_tokens: %s\n' "$iteration_1"
  printf 'loop_total_tokens: %s\n' "$loop_total"
  printf 'per_iteration_ratio: %s (bound ≤ 2.0)\n' "$per_iteration_pretty"
  printf 'total_loop_ratio: %s (bound ≤ 6.0)\n' "$total_loop_pretty"
  printf 'measurement_date: %s\n' "$measurement_date"

  if [ "$per_iteration_pass" -eq 1 ] && [ "$total_loop_pass" -eq 1 ]; then
    printf 'verdict: PASS\n'
    exit 0
  fi

  printf 'verdict: FAIL\n'
  if [ "$per_iteration_pass" -ne 1 ]; then
    printf 'violation: per-iteration bound exceeded (measured %s > 2.0)\n' "$per_iteration_pretty"
  fi
  if [ "$total_loop_pass" -ne 1 ]; then
    printf 'violation: total loop bound exceeded (measured %s > 6.0)\n' "$total_loop_pretty"
  fi
  exit 1
}

main "$@"
