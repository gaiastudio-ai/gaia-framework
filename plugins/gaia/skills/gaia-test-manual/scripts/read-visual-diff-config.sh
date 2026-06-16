#!/usr/bin/env bash
# read-visual-diff-config.sh — read visual_diff configuration from
# project-config.yaml. Sourceable library with _main guard.
#
# Public functions:
#   read_threshold <config-path>    — print threshold_percent (default 0.1)
#   read_breakpoints <config-path>  — print breakpoints, one per line (default 1440)
#   read_mask_regions <config-path> — print mask regions as x,y,w,h,label lines
#
# Requires: yq (or python3 + pyyaml fallback for basic YAML parsing).

set -euo pipefail

# ---------- Internal helpers ----------

_yq_read() {
  local config="$1" expr="$2"
  if command -v yq >/dev/null 2>&1; then
    yq -r "$expr" "$config" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import yaml, sys
with open('$config') as f:
    cfg = yaml.safe_load(f) or {}
keys = '$expr'.strip('.').split('.')
val = cfg
for k in keys:
    if isinstance(val, dict):
        val = val.get(k)
    else:
        val = None
        break
if val is None:
    print('null')
else:
    print(val)
" 2>/dev/null || echo "null"
  else
    echo "null"
  fi
}

# ---------- Public functions ----------

read_threshold() {
  local config="${1:?usage: read_threshold <config-path>}"
  local val
  val="$(_yq_read "$config" '.visual_diff.threshold_percent')"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '0.1\n'
  else
    printf '%s\n' "$val"
  fi
}

read_breakpoints() {
  local config="${1:?usage: read_breakpoints <config-path>}"
  local raw
  if command -v yq >/dev/null 2>&1; then
    raw="$(yq -r '.visual_diff.breakpoints[]' "$config" 2>/dev/null || true)"
  elif command -v python3 >/dev/null 2>&1; then
    raw="$(python3 -c "
import yaml, sys
with open('$config') as f:
    cfg = yaml.safe_load(f) or {}
vd = cfg.get('visual_diff') or {}
bps = vd.get('breakpoints') or []
for bp in bps:
    print(bp)
" 2>/dev/null || true)"
  fi

  if [ -z "$raw" ]; then
    printf '1440\n'
  else
    printf '%s\n' "$raw"
  fi
}

read_mask_regions() {
  local config="${1:?usage: read_mask_regions <config-path>}"
  if command -v yq >/dev/null 2>&1; then
    # Guard: only emit lines when mask_regions is a non-null sequence
    local count
    count="$(yq '.visual_diff.mask_regions | length' "$config" 2>/dev/null || echo 0)"
    if [ "$count" -gt 0 ] 2>/dev/null; then
      yq -r '.visual_diff.mask_regions[] | "\(.x),\(.y),\(.w),\(.h),\(.label)"' \
        "$config" 2>/dev/null || true
    fi
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import yaml, sys
with open('$config') as f:
    cfg = yaml.safe_load(f) or {}
vd = cfg.get('visual_diff') or {}
regions = vd.get('mask_regions') or []
for r in regions:
    print('{},{},{},{},{}'.format(r.get('x',0), r.get('y',0), r.get('w',0), r.get('h',0), r.get('label','')))
" 2>/dev/null || true
  fi
}

# ---------- _main guard ----------

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-}" in
    threshold)    shift; read_threshold "$@" ;;
    breakpoints)  shift; read_breakpoints "$@" ;;
    mask_regions) shift; read_mask_regions "$@" ;;
    *)
      printf 'usage: %s {threshold|breakpoints|mask_regions} <config-path>\n' \
        "$(basename "$0")" >&2
      exit 1
      ;;
  esac
fi
