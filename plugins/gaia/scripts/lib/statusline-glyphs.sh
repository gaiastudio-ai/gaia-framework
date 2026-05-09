#!/usr/bin/env bash
# statusline-glyphs.sh — canonical glyph palette for the GAIA Claude Code statusline.
#
# Story: E82-S1 — Statusline runtime + glyph helper + color helper + install script.
#
# This file is sourced by ~/.claude/gaia-statusline/statusline.sh after the
# install script copies it to ~/.claude/gaia-statusline/lib/. It exports
# variables, never executes side effects.
#
# Canonical palette (single-codepoint UTF-8 by default):
#   GLYPH_BRAND   = ◆   diamond, GAIA brand mark
#   GLYPH_BRANCH  = ⎇   git-branch
#   GLYPH_SPARK   = *   activity / pulse (kept ASCII for terminal robustness)
#   GLYPH_CLOCK   = ◷   timer / age
#   GLYPH_UPDATE  = ↑   update available (D10 — paired with bold + colour + ASCII prefix)
#   GLYPH_CHEVRON = ▸   segment chevron
#   GLYPH_DOT     = ·   middle dot, separator
#
# Env-flag gates (exclusive, ASCII wins):
#   GAIA_STATUSLINE_ASCII=1     → swap each glyph for an ASCII fallback.
#   GAIA_STATUSLINE_NERDFONT=1  → swap to Nerdfont icons (only honoured when
#                                  ASCII is NOT set).
#
# POSIX discipline: bash 3.2 compatible. No mapfile, no ${var,,}, no
# associative arrays.

# Default UTF-8 palette.
GLYPH_BRAND="◆"
GLYPH_BRANCH="⎇"
GLYPH_SPARK="*"
GLYPH_CLOCK="◷"
GLYPH_UPDATE="↑"
GLYPH_CHEVRON="▸"
GLYPH_DOT="·"

# ASCII fallback table (gated on GAIA_STATUSLINE_ASCII=1, AT-3).
# Each fallback is a printable 7-bit ASCII string of <= 2 chars.
if [ "${GAIA_STATUSLINE_ASCII:-0}" = "1" ]; then
  GLYPH_BRAND="*"
  GLYPH_BRANCH="@"
  GLYPH_SPARK="*"
  GLYPH_CLOCK="t"
  GLYPH_UPDATE="^"
  GLYPH_CHEVRON=">"
  GLYPH_DOT="-"
elif [ "${GAIA_STATUSLINE_NERDFONT:-0}" = "1" ]; then
  # Nerdfont upgrade map — codepoints in the Nerd Font private-use range.
  # Users opt-in explicitly via GAIA_STATUSLINE_NERDFONT=1.
  GLYPH_BRAND=$''   # nf-fa-diamond
  GLYPH_BRANCH=$''  # nf-pl-branch
  GLYPH_SPARK=$''   # nf-fa-star
  GLYPH_CLOCK=$''   # nf-fa-clock
  GLYPH_UPDATE=$''  # nf-fa-arrow_up
  GLYPH_CHEVRON=$'' # nf-fa-chevron_right
  GLYPH_DOT=$''     # nf-md-circle_small
fi

export GLYPH_BRAND GLYPH_BRANCH GLYPH_SPARK GLYPH_CLOCK GLYPH_UPDATE GLYPH_CHEVRON GLYPH_DOT
