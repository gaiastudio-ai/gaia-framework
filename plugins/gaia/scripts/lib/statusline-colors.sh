#!/usr/bin/env bash
# statusline-colors.sh — color tokens for the GAIA Claude Code statusline.
#
# Story: E82-S1 — Statusline runtime + glyph helper + color helper + install script.
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
