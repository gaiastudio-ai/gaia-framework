#!/usr/bin/env bash
# statusline-colors.sh — color tokens for the GAIA Claude Code statusline.
#
# Sourced by the runtime. Exports six SGR-tagged variables plus a RESET. Honours
# NO_COLOR (suppresses all SGR) and COLORTERM=truecolor (24-bit fg sequences).
#
# Tokens:
#   COLOR_BRAND  = #7B61FF (purple) — GAIA brand
#   COLOR_WARN   = yellow            — warnings, dirty git tree
#   COLOR_OK     = green             — success / fresh
#   COLOR_MUTED  = grey              — secondary / subdued text
#   COLOR_UPDATE = bold + UPDATE color — update-available signal (D10)
#   COLOR_DIRTY  = orange            — git-dirty marker
#
# Two emission modes:
#   - NO_COLOR set → all tokens become empty strings (passthrough output).
#   - COLORTERM=truecolor → 24-bit sequences (\033[38;2;R;G;Bm).
#   - default → 256-color SGR fallback (\033[38;5;Nm).
#
# POSIX discipline: bash 3.2 compatible.

ESC=$'\033'

if [ "${NO_COLOR:-}" != "" ] || [ "${GAIA_STATUSLINE_NO_COLOR:-0}" = "1" ]; then
  COLOR_BRAND=""
  COLOR_WARN=""
  COLOR_OK=""
  COLOR_MUTED=""
  COLOR_UPDATE=""
  COLOR_DIRTY=""
  COLOR_BOLD=""
  COLOR_RESET=""
elif [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
  # 24-bit truecolor.
  COLOR_BRAND="${ESC}[38;2;123;97;255m"   # #7B61FF
  COLOR_WARN="${ESC}[38;2;255;176;0m"     # amber
  COLOR_OK="${ESC}[38;2;46;204;113m"      # green
  COLOR_MUTED="${ESC}[38;2;128;128;128m"  # grey
  COLOR_UPDATE="${ESC}[1;38;2;255;176;0m" # bold + amber
  COLOR_DIRTY="${ESC}[38;2;255;120;0m"    # orange
  COLOR_BOLD="${ESC}[1m"
  COLOR_RESET="${ESC}[0m"
else
  # 256-color fallback.
  COLOR_BRAND="${ESC}[38;5;99m"
  COLOR_WARN="${ESC}[38;5;214m"
  COLOR_OK="${ESC}[38;5;42m"
  COLOR_MUTED="${ESC}[38;5;244m"
  COLOR_UPDATE="${ESC}[1;38;5;214m"
  COLOR_DIRTY="${ESC}[38;5;208m"
  COLOR_BOLD="${ESC}[1m"
  COLOR_RESET="${ESC}[0m"
fi

export COLOR_BRAND COLOR_WARN COLOR_OK COLOR_MUTED COLOR_UPDATE COLOR_DIRTY COLOR_BOLD COLOR_RESET

# ---------------------------------------------------------------------------
# gradient_color <pct> — emit an SGR foreground escape for a smooth
# green -> amber -> red gradient mapped to <pct> in 0..100.
#
# Two-segment linear interpolation in RGB:
#   0   -> green  (46, 204, 113)
#   50  -> amber  (255, 176, 0)
#   100 -> red    (231, 76, 60)
#
# Emission modes mirror the static tokens above:
#   - NO_COLOR / GAIA_STATUSLINE_NO_COLOR=1 -> empty string (passthrough).
#   - COLORTERM in {truecolor,24bit}        -> 24-bit \033[38;2;R;G;Bm.
#   - default                               -> nearest xterm-256 \033[38;5;Nm
#     (RGB snapped to the 6x6x6 color cube, the standard 16..231 mapping).
#
# gradient_color <pct> [out_var]
#   - With one arg: prints the SGR escape to stdout (tests + simple callers
#     use `$(gradient_color N)`).
#   - With a second arg: assigns the escape to the named variable via
#     `printf -v` (NO subshell fork) — the hot path in statusline.sh calls it
#     up to 11x per render (10 bar cells + the number), so the fork-free form
#     keeps render latency low. bash 3.2 compatible (`printf -v` is available).
# Integer arithmetic only; no bc/awk dependency.
gradient_color() {
  _gc_pct="${1:-0}"
  _gc_out="${2:-}"
  case "$_gc_pct" in ''|*[!0-9]*) _gc_pct=0 ;; esac
  [ "$_gc_pct" -gt 100 ] && _gc_pct=100
  [ "$_gc_pct" -lt 0 ] && _gc_pct=0

  # NO_COLOR: emit nothing (empty string to the out-var if one was given).
  if [ "${NO_COLOR:-}" != "" ] || [ "${GAIA_STATUSLINE_NO_COLOR:-0}" = "1" ]; then
    [ -n "$_gc_out" ] && printf -v "$_gc_out" '%s' ''
    return 0
  fi

  # Two-segment interpolation. Segment A: 0..50 green->amber. Segment B:
  # 50..100 amber->red. `t` is the 0..100 position within the segment so all
  # arithmetic stays integer (round-to-nearest via +50 before /100).
  if [ "$_gc_pct" -le 50 ]; then
    _gc_t=$(( _gc_pct * 2 ))                    # 0..100 across segment A
    _gc_r=$(( 46  + ( (255 - 46)  * _gc_t + 50) / 100 ))
    _gc_g=$(( 204 + ( (176 - 204) * _gc_t + 50) / 100 ))
    _gc_b=$(( 113 + ( (0   - 113) * _gc_t + 50) / 100 ))
  else
    _gc_t=$(( (_gc_pct - 50) * 2 ))             # 0..100 across segment B
    _gc_r=$(( 255 + ( (231 - 255) * _gc_t + 50) / 100 ))
    _gc_g=$(( 176 + ( (76  - 176) * _gc_t + 50) / 100 ))
    _gc_b=$(( 0   + ( (60  - 0)   * _gc_t + 50) / 100 ))
  fi

  if [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
    _gc_seq="${ESC}[38;2;${_gc_r};${_gc_g};${_gc_b}m"
  else
    # 256-color fallback: snap each channel to the 6-level cube (0,95,135,175,
    # 215,255 -> indices 0..5) and compute the 16..231 cube index.
    _gc_cube "$_gc_r"; _gc_idx_r="$_GC_CUBE"
    _gc_cube "$_gc_g"; _gc_idx_g="$_GC_CUBE"
    _gc_cube "$_gc_b"; _gc_idx_b="$_GC_CUBE"
    _gc_n=$(( 16 + 36 * _gc_idx_r + 6 * _gc_idx_g + _gc_idx_b ))
    _gc_seq="${ESC}[38;5;${_gc_n}m"
  fi

  if [ -n "$_gc_out" ]; then
    printf -v "$_gc_out" '%s' "$_gc_seq"
  else
    printf '%s' "$_gc_seq"
  fi
}

# _gc_cube <0..255> -> nearest 6x6x6-cube level index (0..5) in $_GC_CUBE (no
# fork). xterm cube levels are 0,95,135,175,215,255; midpoints 47,115,155,195,235.
_gc_cube() {
  _v="${1:-0}"
  if   [ "$_v" -lt 48  ]; then _GC_CUBE=0
  elif [ "$_v" -lt 115 ]; then _GC_CUBE=1
  elif [ "$_v" -lt 155 ]; then _GC_CUBE=2
  elif [ "$_v" -lt 195 ]; then _GC_CUBE=3
  elif [ "$_v" -lt 235 ]; then _GC_CUBE=4
  else _GC_CUBE=5
  fi
}
