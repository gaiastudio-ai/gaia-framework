#!/usr/bin/env bash
# pixel-diff.sh — pixel-level visual regression detection.
# Sourceable library with _main guard.
#
# Public functions:
#   detect_compare_tool   — print "compare" or "pixelmatch" or "" (empty)
#   mask_image <src> <dst> <region-spec>
#                         — copy src to dst with masked region; never mutates src
#   diff_single_breakpoint <baseline> <screenshot> <threshold>
#                         — compare two images; print "PASSED <pct>%" or "FAILED <pct>%"
#   run_pixel_diff <story-slug> <screenshot-dir> [--project-root <dir>] [--config <path>]
#                         — per-breakpoint diff orchestrator; print per-bp + composite verdict
#
# STRUCTURAL GUARANTEE (AC3): this script contains NO cp/mv of a screenshot
# to a baseline path. Baseline writes belong exclusively in approve-baseline.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ---------- Public functions ----------

detect_compare_tool() {
  if command -v compare >/dev/null 2>&1; then
    printf 'compare\n'
  elif command -v pixelmatch >/dev/null 2>&1; then
    printf 'pixelmatch\n'
  else
    printf '\n'
  fi
}

mask_image() {
  local src="${1:?usage: mask_image <src> <dst> <region-spec>}"
  local dst="${2:?usage: mask_image <src> <dst> <region-spec>}"
  local region_spec="${3:?usage: mask_image <src> <dst> <region-spec>}"

  # Parse region: x,y,w,h,label (label consumed to clear the field)
  local x y w h label
  IFS=',' read -r x y w h label <<< "$region_spec"
  : "${label:=}"  # consumed; used by caller for diagnostic output

  if ! command -v convert >/dev/null 2>&1; then
    printf 'mask_image: convert not available; masking skipped\n' >&2
    # Copy as-is so downstream can still compare (unmasked)
    if [ -f "$src" ] && [ "$src" != "$dst" ]; then
      cp "$src" "$dst"
    fi
    return 0
  fi

  # Copy, then draw a filled rectangle over the region on the COPY.
  # Never mutate the original.
  cp "$src" "$dst"
  local x2 y2
  x2=$(( x + w - 1 ))
  y2=$(( y + h - 1 ))
  convert "$dst" -fill black -draw "rectangle ${x},${y} ${x2},${y2}" "$dst"
}

diff_single_breakpoint() {
  local baseline="${1:?usage: diff_single_breakpoint <baseline> <screenshot> <threshold>}"
  local screenshot="${2:?usage: diff_single_breakpoint <baseline> <screenshot> <threshold>}"
  local threshold="${3:?usage: diff_single_breakpoint <baseline> <screenshot> <threshold>}"

  local tool
  tool="$(detect_compare_tool)"
  if [ -z "$tool" ]; then
    printf 'UNVERIFIED 0%% (no compare tool)\n'
    return 0
  fi

  # Get image dimensions for percentage calculation
  local total_pixels
  total_pixels="$(identify -format '%[fx:w*h]' "$baseline" 2>/dev/null || echo 100)"

  # Run compare -metric AE (absolute error = count of different pixels)
  local diff_pixels
  diff_pixels="$(compare -metric AE "$baseline" "$screenshot" /dev/null 2>&1 || true)"
  # compare writes the metric to stderr; capture it
  diff_pixels="$(echo "$diff_pixels" | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1)"
  diff_pixels="${diff_pixels:-0}"

  # Calculate percentage
  local pct
  if [ "$total_pixels" -gt 0 ] 2>/dev/null; then
    pct="$(awk "BEGIN { printf \"%.2f\", (${diff_pixels} / ${total_pixels}) * 100 }")"
  else
    pct="0.00"
  fi

  # Compare against threshold: at-threshold is PASSED, strictly above is FAILED
  local result
  result="$(awk "BEGIN { print (${pct} <= ${threshold}) ? \"PASSED\" : \"FAILED\" }")"

  printf '%s %s%%\n' "$result" "$pct"
}

run_pixel_diff() {
  local story_slug="${1:?usage: run_pixel_diff <story-slug> <screenshot-dir> [options]}"
  local screenshot_dir="${2:?usage: run_pixel_diff <story-slug> <screenshot-dir> [options]}"
  shift 2

  local project_root="${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-${PROJECT_ROOT:-${PROJECT_PATH:-${PWD}}}}}"
  local config_path=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --project-root) project_root="$2"; shift 2 ;;
      --config)       config_path="$2"; shift 2 ;;
      *)              shift ;;
    esac
  done

  if [ -z "$config_path" ]; then
    config_path="${project_root}/.gaia/config/project-config.yaml"
  fi

  # Source the config reader
  # shellcheck source=read-visual-diff-config.sh
  source "$SCRIPT_DIR/read-visual-diff-config.sh"

  # Read configuration
  local threshold
  threshold="$(read_threshold "$config_path")"

  local breakpoints_raw
  breakpoints_raw="$(read_breakpoints "$config_path")"

  local mask_regions_raw
  mask_regions_raw="$(read_mask_regions "$config_path")"

  # Resolve baseline directory via the paths helper
  local resolver
  resolver="$(cd "$SCRIPT_DIR/../../../../scripts/lib" && pwd)/resolve-artifact-path.sh"

  local baseline_dir
  baseline_dir="$(bash "$resolver" design_baselines --slug "$story_slug" \
    --project-root "$project_root" 2>/dev/null || true)"

  # Check if baseline directory exists and is non-empty
  if [ -z "$baseline_dir" ] || [ ! -d "$baseline_dir" ] || \
     [ -z "$(ls -A "$baseline_dir" 2>/dev/null)" ]; then
    printf 'UNVERIFIED: no baselines found for %s' "$story_slug"
    if [ -n "$baseline_dir" ] && [ -d "$baseline_dir" ]; then
      printf ' (baseline directory empty: %s)' "$baseline_dir"
    fi
    printf '\n'
    return 0
  fi

  # Check for compare tool
  local tool
  tool="$(detect_compare_tool)"
  if [ -z "$tool" ]; then
    printf 'UNVERIFIED: no image comparison tool available\n' >&2
    printf 'UNVERIFIED: install ImageMagick (compare) or pixelmatch\n'
    return 0
  fi

  # Per-breakpoint diff
  local composite_verdict="PASSED"
  local has_real_result=0
  local bp
  while IFS= read -r bp; do
    [ -n "$bp" ] || continue
    local baseline_file="$baseline_dir/baseline-${bp}.png"
    local screenshot_file="$screenshot_dir/screenshot-${bp}.png"

    if [ ! -f "$baseline_file" ]; then
      printf '%s: UNVERIFIED (no baseline)\n' "$bp"
      continue
    fi

    if [ ! -f "$screenshot_file" ]; then
      printf '%s: UNVERIFIED (no screenshot)\n' "$bp"
      continue
    fi

    # Apply masking if configured
    local effective_baseline="$baseline_file"
    local effective_screenshot="$screenshot_file"
    if [ -n "$mask_regions_raw" ]; then
      local mask_tmp
      mask_tmp="$(mktemp -d)"
      effective_baseline="$mask_tmp/baseline-${bp}.png"
      effective_screenshot="$mask_tmp/screenshot-${bp}.png"
      cp "$baseline_file" "$effective_baseline"
      cp "$screenshot_file" "$effective_screenshot"

      while IFS= read -r region; do
        [ -n "$region" ] || continue
        mask_image "$effective_baseline" "$effective_baseline" "$region"
        mask_image "$effective_screenshot" "$effective_screenshot" "$region"
        local region_label
        region_label="$(echo "$region" | cut -d',' -f5)"
        printf '%s: masked: %s\n' "$bp" "$region_label"
      done <<< "$mask_regions_raw"
    fi

    # Run the diff
    local result
    result="$(diff_single_breakpoint "$effective_baseline" "$effective_screenshot" "$threshold")"

    local verdict
    verdict="$(echo "$result" | awk '{print $1}')"
    local pct
    pct="$(echo "$result" | awk '{print $2}')"

    printf '%s: %s %s (threshold: %s%%)\n' "$bp" "$verdict" "$pct" "$threshold"
    has_real_result=1

    if [ "$verdict" = "FAILED" ]; then
      composite_verdict="FAILED"
    fi

    # Clean up masked temp files
    if [ -n "$mask_regions_raw" ] && [ -d "${mask_tmp:-}" ]; then
      rm -rf "$mask_tmp"
    fi
  done <<< "$breakpoints_raw"

  if [ "$has_real_result" -eq 0 ]; then
    printf 'UNVERIFIED: no breakpoints had both baseline and screenshot\n'
    return 0
  fi

  printf '%s\n' "$composite_verdict"
}

# ---------- _main guard ----------

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-}" in
    detect)
      detect_compare_tool
      ;;
    diff)
      shift
      run_pixel_diff "$@"
      ;;
    *)
      printf 'usage: %s {detect|diff} [args...]\n' "$(basename "$0")" >&2
      exit 1
      ;;
  esac
fi
