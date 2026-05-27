#!/usr/bin/env bash
# statusline.sh — GAIA Claude Code statusline runtime.
#
# Story: E82-S1.
#
# Runtime contract (https://code.claude.com/docs/en/statusline):
#   stdin: JSON with model.{id,display_name}, workspace.current_dir, etc.
#   stdout: a single line of statusline text, ANSI-allowed.
#   exit:  0 on success. NEVER nonzero. NEVER emit to stderr.
#
# Hot-path budget (D7):
#   p95 wall < 100ms, ceiling < 300ms.
#
# Subprocess inventory (TC-STATUSLINE-2, NFR-STATUSLINE-2):
#   ALLOWED: jq, git symbolic-ref, cat, tput
#   FORBIDDEN: any network primitive (structurally enforced by TC-9)
#
# File reads:
#   - ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json                     (D5: version, active plugin)
#     Falls back to $PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin/plugin.json (in-tree dev)
#   - $HOME/.claude/gaia-statusline/cache/latest-release.json             (silent on miss)
#   - $PROJECT_PATH/.gaia/artifacts/implementation-artifacts/sprint-status.yaml      (rich theme only, D11)
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -uo pipefail
LC_ALL=C
export LC_ALL

# Resolve project path. Prefer explicit env override (used by tests); fall
# back to the workspace.current_dir from stdin JSON; final fallback is CWD.
INPUT="$(cat)"
PROJECT_PATH="${PROJECT_PATH:-}"
if [ -z "$PROJECT_PATH" ]; then
  PROJECT_PATH="$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // ""' 2>/dev/null)"
fi
if [ -z "$PROJECT_PATH" ]; then
  PROJECT_PATH="$PWD"
fi

# Locate this script's directory so we can source the lib helpers when the
# runtime is run in-tree (tests). When installed under ~/.claude, the lib
# helpers live alongside under ./lib/.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SELF_DIR/lib" ]; then
  LIB_DIR="$SELF_DIR/lib"
else
  LIB_DIR="$SELF_DIR/../scripts/lib"
fi

# shellcheck source=/dev/null
[ -r "$LIB_DIR/statusline-glyphs.sh" ] && . "$LIB_DIR/statusline-glyphs.sh"
# shellcheck source=/dev/null
[ -r "$LIB_DIR/statusline-colors.sh" ] && . "$LIB_DIR/statusline-colors.sh"

# Defaults if the lib helpers are absent (graceful degrade).
: "${GLYPH_BRAND:=*}"
: "${GLYPH_BRANCH:=@}"
: "${GLYPH_DOT:=-}"
: "${COLOR_BRAND:=}"
: "${COLOR_MUTED:=}"
: "${COLOR_BOLD:=}"
: "${COLOR_RESET:=}"

# ---- Read GAIA version from plugin.json -----------------------------------
# Three-tier resolution:
#   Tier 1 (production): scan ~/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/
#     for the highest semver directory and read its plugin.json. This is the
#     canonical install location — Claude Code itself loads the latest cached
#     version on /reload-plugins, so the statusline matching it is correct.
#   Tier 2 (dev/test): in-tree repo plugin.json under PROJECT_PATH.
#   Tier 3 (last-resort): the literal "dev" — surfaces a vdev release link
#     and signals a misconfigured environment.
#
# CLAUDE_PLUGIN_ROOT is intentionally NOT consulted here. It is a per-skill
# envvar Claude Code sets only inside Skill() dispatches; the statusLine
# command runs outside that context, so the env var is always empty and a
# plugin.json lookup keyed on it always misses (the original "GAIA dev" bug).
PLUGIN_CACHE_DIR="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia"
PLUGIN_JSON=""
GAIA_VERSION=""

# Tier 1: cache scan for the highest semver subdirectory.
if [ -d "$PLUGIN_CACHE_DIR" ]; then
  GAIA_VERSION_CACHED="$(ls "$PLUGIN_CACHE_DIR" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
  if [ -n "$GAIA_VERSION_CACHED" ] && [ -r "$PLUGIN_CACHE_DIR/$GAIA_VERSION_CACHED/.claude-plugin/plugin.json" ]; then
    PLUGIN_JSON="$PLUGIN_CACHE_DIR/$GAIA_VERSION_CACHED/.claude-plugin/plugin.json"
  fi
fi

# Tier 2: in-tree repo for dev/test runs.
if [ -z "$PLUGIN_JSON" ] && [ -r "$PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin/plugin.json" ]; then
  PLUGIN_JSON="$PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin/plugin.json"
fi

# Read the version from whichever tier resolved.
if [ -n "$PLUGIN_JSON" ] && [ -r "$PLUGIN_JSON" ]; then
  GAIA_VERSION="$(jq -r '.version // ""' "$PLUGIN_JSON" 2>/dev/null)"
fi

# Tier 3: last-resort literal.
[ -n "$GAIA_VERSION" ] || GAIA_VERSION="dev"

# ---- Read model from stdin -------------------------------------------------
MODEL_NAME="$(printf '%s' "$INPUT" | jq -r '.model.display_name // .model.id // "claude"' 2>/dev/null)"
[ -n "$MODEL_NAME" ] || MODEL_NAME="claude"

# ---- Project name ----------------------------------------------------------
PROJECT_NAME="$(basename "$PROJECT_PATH" 2>/dev/null || printf 'project')"

# ---- Branch — env override, else cache active_branch, else local probe ----
# The active_branch field is written by statusline-git-dirty-check.sh on every
# PreToolUse — it reflects the repo of the file/dir the agent just touched,
# NOT the terminal's pinned workspace.current_dir. Cache wins so the branch
# tracks the agent's work across cd's inside Bash tool calls.
BRANCH=""
if [ -n "${GAIA_STATUSLINE_BRANCH_OVERRIDE:-}" ]; then
  BRANCH="$GAIA_STATUSLINE_BRANCH_OVERRIDE"
else
  # Cache read happens further down (line ~134) but we need active_branch
  # before the assembly block. Do a tiny early read here; the main cache
  # block re-reads from the same file shortly so no extra round-trip risk.
  _CACHE_EARLY="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  if [ -r "$_CACHE_EARLY" ]; then
    BRANCH="$(jq -r '.active_branch // ""' "$_CACHE_EARLY" 2>/dev/null || printf '')"
    # jq prints the literal "null" when the field is JSON null — normalise.
    [ "$BRANCH" = "null" ] && BRANCH=""
  fi
  # Fall back to the legacy git -C $PROJECT_PATH probe so first-run sessions
  # (no cache yet) still show a branch when cwd IS a git work tree.
  if [ -z "$BRANCH" ]; then
    BRANCH="$(git -C "$PROJECT_PATH" symbolic-ref --short HEAD 2>/dev/null || printf '')"
  fi
fi

# ---- Cache (silent on miss) — owned by E82-S2, read here ------------------
# Cache schema (ADR-091, written by statusline-update-check.sh):
#   { checked_at_iso, latest_tag, current_tag, update_available }
#
# 7-day stale-fence (E82-S2 / TC-STATUSLINE-7 / AT-4): when the cache has
# not been refreshed in > 7 days, every update signal (glyph + bold + ASCII
# prefix) is suppressed regardless of `update_available`. The fence belongs
# to the reader because the writer's TTL (24h) is for fetch frequency; the
# reader's fence (7d) is the trust window. Two timeouts, two concerns.
CACHE_FILE="$HOME/.claude/gaia-statusline/cache/latest-release.json"
LATEST_VERSION=""
UPDATE_AVAILABLE_RAW=""
INSTALLED_VERSION_STALE_RAW="false"
GIT_DIRTY_RAW="false"
CACHE_FRESH=0
CACHE_TS=""
AGE=0
if [ -r "$CACHE_FILE" ]; then
  CACHE_JSON="$(cat "$CACHE_FILE" 2>/dev/null || printf '')"
  if [ -n "$CACHE_JSON" ]; then
    LATEST_VERSION="$(printf '%s' "$CACHE_JSON" | jq -r '.latest_tag // ""' 2>/dev/null)"
    UPDATE_AVAILABLE_RAW="$(printf '%s' "$CACHE_JSON" | jq -r '.update_available // false' 2>/dev/null)"
    INSTALLED_VERSION_STALE_RAW="$(printf '%s' "$CACHE_JSON" | jq -r '.installed_version_stale // false' 2>/dev/null)"
    GIT_DIRTY_RAW="$(printf '%s' "$CACHE_JSON" | jq -r '.git_dirty // false' 2>/dev/null)"
    CACHE_TS="$(printf '%s' "$CACHE_JSON" | jq -r '.checked_at_iso // ""' 2>/dev/null)"
    if [ -n "$CACHE_TS" ]; then
      # Portable ISO-8601 -> epoch (try BSD then GNU date).
      CACHE_EPOCH="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$CACHE_TS" +%s 2>/dev/null \
        || date -u -d "$CACHE_TS" +%s 2>/dev/null \
        || printf '')"
      if [ -n "$CACHE_EPOCH" ]; then
        NOW_EPOCH="$(date -u +%s)"
        AGE=$(( NOW_EPOCH - CACHE_EPOCH ))
        # 604800 sec = 7 days. Negative ages (clock skew) treated as fresh.
        if [ "$AGE" -lt 604800 ]; then
          CACHE_FRESH=1
        fi
      fi
    fi
  fi
fi

# ---- Update fetcher background refresh (sprint-43: hot-path TTL gate) -----
# Original E82-S2 assumed `refreshInterval` triggered the fetcher itself —
# it doesn't. `refreshInterval` only re-runs statusline.sh (this renderer).
# Result: statusline-update-check.sh was never invoked, so the
# latest_tag / update_available fields were never populated, so the [update]
# indicator never fired.
#
# Fix: from this renderer, if the cache is missing the update-check fields
# OR is older than the writer's TTL (24h), fork the fetcher in the
# background so the next render picks up fresh data without ever blocking
# the current render. The fetcher itself has a 5s HTTP timeout and is
# silent-on-failure.
_FETCHER="$HOME/.claude/gaia-statusline/statusline-update-check.sh"
if [ -x "$_FETCHER" ]; then
  _NEED_FETCH=0
  if [ -z "${CACHE_TS:-}" ]; then
    _NEED_FETCH=1
  elif [ -n "${CACHE_EPOCH:-}" ]; then
    # 1800 sec = 30min — matches the writer's TTL_SECONDS (sprint-43
    # update from 24h so new GitHub releases surface within 30min).
    if [ "${AGE:-0}" -ge 1800 ]; then
      _NEED_FETCH=1
    fi
  fi
  if [ "$_NEED_FETCH" = "1" ]; then
    # Background fork with stdio detached so the render never waits on the
    # network probe. setsid would be ideal but is not portable; nohup-style
    # detachment via `</dev/null >/dev/null 2>&1 &` is bash-3.2 safe.
    ( "$_FETCHER" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
fi

# ---- Theme resolution (sprint-43: rich is the default) --------------------
# Historically rich was opt-in via `GAIA_STATUSLINE_THEME=rich`. Most users
# never set the env var (the statusLine command in settings.json is just
# a path with no env), so context-bar / rate-limits / sprint chunks were
# silently gated off. Flipping the default to "rich" surfaces them by
# default; users who want the minimal pre-43 layout set
# `GAIA_STATUSLINE_THEME=minimal` (any non-empty value other than "rich"
# also suppresses the rich-only chunks).
_GAIA_THEME="${GAIA_STATUSLINE_THEME:-rich}"
if [ "$_GAIA_THEME" = "rich" ]; then
  GAIA_RICH=1
else
  GAIA_RICH=0
fi

# ---- Rich-theme sprint status read (D11, TC-6) -----------------------------
# Walks UP from PROJECT_PATH looking for .gaia/artifacts/implementation-artifacts/
# sprint-status.yaml. This handles the common layout where the terminal cwd
# is inside a subproject (e.g., $PROJECT_ROOT/gaia-public/) but the sprint
# artifacts live at the project root. Capped at 5 levels to bound stat-call
# cost.
SPRINT_ID=""
if [ "$GAIA_RICH" = "1" ]; then
  SPRINT_FILE=""
  _SEARCH_DIR="$PROJECT_PATH"
  _DEPTH=0
  while [ "$_DEPTH" -lt 5 ]; do
    # E96-S8 smoke-test follow-up: prefer .gaia/state/sprint-status.yaml
    # (post-migration canonical per ADR-111) over legacy docs/.
    _GAIA_CANDIDATE="$_SEARCH_DIR/.gaia/state/sprint-status.yaml"
    if [ -r "$_GAIA_CANDIDATE" ]; then
      SPRINT_FILE="$_GAIA_CANDIDATE"
      break
    fi
    _CANDIDATE="$_SEARCH_DIR/docs/implementation-artifacts/sprint-status.yaml"
    if [ -r "$_CANDIDATE" ]; then
      SPRINT_FILE="$_CANDIDATE"
      break
    fi
    # Move up one level. Stop if we've reached the filesystem root.
    _PARENT="$(dirname "$_SEARCH_DIR" 2>/dev/null || printf '/')"
    if [ "$_PARENT" = "$_SEARCH_DIR" ]; then
      break
    fi
    _SEARCH_DIR="$_PARENT"
    _DEPTH=$((_DEPTH + 1))
  done
  if [ -n "$SPRINT_FILE" ] && [ -r "$SPRINT_FILE" ]; then
    # Tiny grep — direct read (NOT routed through dashboard script per D11).
    SPRINT_ID="$(grep -E '^sprint_id:' "$SPRINT_FILE" 2>/dev/null | head -1 | sed 's/^sprint_id:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' || printf '')"
    # Suppress closed sprints — once /gaia-sprint-close stamps `status: closed`
    # the sprint_id refers to historical state until /gaia-sprint-plan rolls
    # the next sprint forward. Showing a closed sprint id is misleading.
    SPRINT_STATUS="$(grep -E '^status:' "$SPRINT_FILE" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' || printf '')"
    if [ "$SPRINT_STATUS" = "closed" ]; then
      SPRINT_ID=""
    fi
  fi
fi

# ---- Width detection (FR-433) ---------------------------------------------
COLS="${COLUMNS:-0}"
if [ "$COLS" = "0" ] || [ -z "$COLS" ]; then
  COLS="$(tput cols 2>/dev/null || printf '80')"
fi
case "$COLS" in
  ''|*[!0-9]*) COLS=80 ;;
esac

# ---- OSC-8 hyperlink wrapping (allowlist iTerm.app/Kitty/WezTerm) ---------
# Wrap brand chunk in OSC-8 only when TERM_PROGRAM is in the allowlist.
TP="${TERM_PROGRAM:-}"
case "$TP" in
  iTerm.app|Kitty|WezTerm)
    OSC8_OPEN=$'\033]8;;https://github.com/gaiastudio-ai/gaia-public/releases/tag/v'"$GAIA_VERSION"$'\033\\'
    OSC8_CLOSE=$'\033]8;;\033\\'
    ;;
  *)
    OSC8_OPEN=""
    OSC8_CLOSE=""
    ;;
esac

# ---- Compose segments ------------------------------------------------------
# Brand: ◆ GAIA <version>
BRAND_TEXT="${GLYPH_BRAND} GAIA ${GAIA_VERSION}"
BRAND_CHUNK="${OSC8_OPEN}${COLOR_BRAND}${COLOR_BOLD}${BRAND_TEXT}${COLOR_RESET}${OSC8_CLOSE}"

# Update indicator (D10: glyph + bold + colour + ASCII prefix in ASCII theme).
# Suppressed when (a) cache absent or unparseable, (b) cached latest_tag is
# missing, (c) cached latest_tag equals the live installed GAIA_VERSION
# (sprint-43: recompute on every render so the indicator clears immediately
# after the user runs /plugin marketplace update, without waiting for the
# fetcher's 24h TTL to expire), or (d) the 7-day stale-fence has tripped
# — see E82-S2 / TC-STATUSLINE-7 / AT-4 above.
UPDATE_CHUNK=""
if [ "$CACHE_FRESH" -eq 1 ] && [ -n "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "$GAIA_VERSION" ]; then
  if [ "${GAIA_STATUSLINE_ASCII:-0}" = "1" ]; then
    UPDATE_CHUNK="[update] ${GLYPH_UPDATE:-^}"
  else
    UPDATE_CHUNK="${COLOR_UPDATE:-}${GLYPH_UPDATE:-^}${COLOR_RESET}"
  fi
fi

# ---- Staleness WARN segment (E82-S6 / ADR-094 Component 4) ----------------
# Renders ONCE per UTC day. Gated by per-day marker file. Suppressed when
# `installed_version_stale` is not literally "true" or when the per-day
# marker already exists. Touching the marker is the only new write on the
# hot path — bounded to one open(O_CREAT) per first-render-per-day.
STALE_CHUNK=""
if [ "$INSTALLED_VERSION_STALE_RAW" = "true" ]; then
  STALE_DAY_KEY="$(date -u +%Y-%m-%d)"
  STALE_MARKER="$HOME/.claude/gaia-statusline/cache/staleness-warning-shown.${STALE_DAY_KEY}"
  if [ ! -e "$STALE_MARKER" ]; then
    # Touch the marker first so concurrent renders don't double-emit.
    : > "$STALE_MARKER" 2>/dev/null || true
    if [ "${GAIA_STATUSLINE_ASCII:-0}" = "1" ]; then
      STALE_CHUNK="[stale: rerun install-statusline]"
    else
      STALE_CHUNK="${COLOR_UPDATE:-}[stale: rerun install-statusline]${COLOR_RESET}"
    fi
  fi
fi

MODEL_CHUNK="${COLOR_MUTED}${MODEL_NAME}${COLOR_RESET}"
PROJECT_CHUNK="${PROJECT_NAME}"
# Branch and dirty marker are separate chunks so they can be placed in
# distinct boxes on line 2 (per the sprint-43 layout request). The dirty
# marker is still gated on BRANCH being non-empty — a detached HEAD with
# no branch context renders nothing for both chunks.
BRANCH_CHUNK=""
DIRTY_CHUNK=""
if [ -n "$BRANCH" ]; then
  BRANCH_CHUNK="${GLYPH_BRANCH} ${BRANCH}"
  if [ "$GIT_DIRTY_RAW" = "true" ]; then
    if [ "${GAIA_STATUSLINE_ASCII:-0}" = "1" ]; then
      DIRTY_CHUNK="${COLOR_DIRTY:-}*${COLOR_RESET}"
    else
      DIRTY_CHUNK="${COLOR_DIRTY:-}${GLYPH_DIRTY:-*}${COLOR_RESET}"
    fi
  fi
fi
SPRINT_CHUNK=""
if [ -n "$SPRINT_ID" ]; then
  SPRINT_CHUNK="${COLOR_MUTED}${SPRINT_ID}${COLOR_RESET}"
fi

# ---- Rate-limits chunk (E82-S10 / FR-451) ---------------------------------
# Rich-theme-only. Reads `.rate_limits.five_hour.used_percentage` and
# `.rate_limits.seven_day.used_percentage` from stdin. Renders as
# `RL: <5h>%/<7d>%` colored by the MAX of the two (band: <50 OK, 50..<80
# WARN, >=80 DIRTY). Defensive: when only one window is present, render
# only that window. When both absent or theme != rich, chunk is empty.
RLIMIT_CHUNK=""
if [ "$GAIA_RICH" = "1" ]; then
  _RL_5H="$(printf '%s' "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // "null"' 2>/dev/null || printf 'null')"
  _RL_7D="$(printf '%s' "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // "null"' 2>/dev/null || printf 'null')"
  _RL_HAS_5H=0
  _RL_HAS_7D=0
  [ "$_RL_5H" != "null" ] && _RL_HAS_5H=1
  [ "$_RL_7D" != "null" ] && _RL_HAS_7D=1
  if [ "$_RL_HAS_5H" -eq 1 ] || [ "$_RL_HAS_7D" -eq 1 ]; then
    # Clamp + integer-cast each present value.
    if [ "$_RL_HAS_5H" -eq 1 ]; then
      case "$_RL_5H" in ''|*[!0-9]*) _RL_5H=0 ;; esac
      [ "$_RL_5H" -gt 100 ] && _RL_5H=100
      [ "$_RL_5H" -lt 0 ] && _RL_5H=0
    fi
    if [ "$_RL_HAS_7D" -eq 1 ]; then
      case "$_RL_7D" in ''|*[!0-9]*) _RL_7D=0 ;; esac
      [ "$_RL_7D" -gt 100 ] && _RL_7D=100
      [ "$_RL_7D" -lt 0 ] && _RL_7D=0
    fi
    # Compute the dominant percentage for color band.
    _RL_MAX=0
    if [ "$_RL_HAS_5H" -eq 1 ] && [ "$_RL_5H" -gt "$_RL_MAX" ]; then _RL_MAX="$_RL_5H"; fi
    if [ "$_RL_HAS_7D" -eq 1 ] && [ "$_RL_7D" -gt "$_RL_MAX" ]; then _RL_MAX="$_RL_7D"; fi
    # Color band.
    if [ "$_RL_MAX" -lt 50 ]; then
      _RL_COLOR="${COLOR_OK:-}"
    elif [ "$_RL_MAX" -lt 80 ]; then
      _RL_COLOR="${COLOR_WARN:-}"
    else
      _RL_COLOR="${COLOR_DIRTY:-}"
    fi
    # Build the body. Single-window vs both-windows.
    if [ "$_RL_HAS_5H" -eq 1 ] && [ "$_RL_HAS_7D" -eq 1 ]; then
      _RL_BODY="RL: ${_RL_5H}%/${_RL_7D}%"
    elif [ "$_RL_HAS_5H" -eq 1 ]; then
      _RL_BODY="RL: ${_RL_5H}%"
    else
      _RL_BODY="RL: ${_RL_7D}%"
    fi
    RLIMIT_CHUNK="${_RL_COLOR}${_RL_BODY}${COLOR_RESET}"
  fi
fi

# ---- Context-window progress bar (E82-S9 / FR-450, redesigned) -------------
# Renders a 10-char gradient bar from stdin's `.context_window.used_percentage`
# (0-100), inline percentage, and grey size hint (200K / 1M).
#
# Original E82-S9 used a single solid color band per AC2/AC3/AC4. This
# redesign (sprint-43 issue-3 follow-up) replaces it with per-cell gradient
# fill (green -> yellow -> red across the 10 cells) and appends:
#
#   <gradient-bar> <pct%-colored-by-dominant-band> <[size]-grey>
#
# Two distinct null-vs-zero paths preserved:
#   - `.context_window.current_usage` is null    -> empty chunk (smart-hide)
#   - `current_usage` non-null AND `used_percentage` = 0 -> all-empty bar +
#     "0%" + size hint ("we know it's empty")
#
# Filled / empty glyphs: `#`/`-` in ASCII theme, `█`/`░` UTF-8.
CONTEXTBAR_CHUNK=""
# Claude Code (>= 2.1.x) sends `context_window.current_usage` as an OBJECT
# (input_tokens, output_tokens, cache_*_tokens) — NOT a scalar token count.
# Gating on .used_percentage (a scalar 0..100) instead avoids treating that
# object as an integer in shell arithmetic, which would crash the chunk
# silently. Schema discovered via stdin trace 2026-05-12.
_CTX_PCT="$(printf '%s' "$INPUT" | jq -r '.context_window.used_percentage // "null"' 2>/dev/null || printf 'null')"
if [ "$_CTX_PCT" != "null" ]; then
  case "$_CTX_PCT" in
    ''|*[!0-9]*) _CTX_PCT=0 ;;
  esac
  if [ "$_CTX_PCT" -gt 100 ]; then _CTX_PCT=100; fi
  if [ "$_CTX_PCT" -lt 0 ]; then _CTX_PCT=0; fi
  _CTX_FILLED=$(( _CTX_PCT / 10 ))
  _CTX_EMPTY=$(( 10 - _CTX_FILLED ))
  if [ "${GAIA_STATUSLINE_ASCII:-0}" = "1" ]; then
    _CTX_FILLED_GLYPH="#"
    _CTX_EMPTY_GLYPH="-"
  else
    _CTX_FILLED_GLYPH="${GLYPH_BAR_FILLED:-█}"
    _CTX_EMPTY_GLYPH="${GLYPH_BAR_EMPTY:-░}"
  fi
  # Per-cell TRUE gradient fill: each filled cell is colored by its own
  # position along the green -> amber -> red gradient (cell i represents the
  # ~i*10..(i+1)*10% band; we color it at its midpoint i*10+5 so the 10 cells
  # sweep smoothly from green at the left to red at the right). Replaces the
  # former 3-discrete-band scheme (green 0-4 / yellow 5-7 / red 8-9) per the
  # gradient requirement. `gradient_color` handles truecolor / nearest-256 /
  # NO_COLOR emission internally.
  _FILLED_STR=""
  i=0
  while [ "$i" -lt "$_CTX_FILLED" ]; do
    _CELL_PCT=$(( i * 10 + 5 ))
    # Fork-free: gradient_color writes into _CELL_COLOR via printf -v.
    gradient_color "$_CELL_PCT" _CELL_COLOR
    _FILLED_STR="${_FILLED_STR}${_CELL_COLOR}${_CTX_FILLED_GLYPH}${COLOR_RESET}"
    i=$((i + 1))
  done
  _EMPTY_STR=""
  i=0
  while [ "$i" -lt "$_CTX_EMPTY" ]; do
    _EMPTY_STR="${_EMPTY_STR}${_CTX_EMPTY_GLYPH}"
    i=$((i + 1))
  done
  # Inline percentage colored by the SAME green -> amber -> red gradient,
  # evaluated at the actual percentage (so the number's hue matches the
  # right-most filled cell's neighbourhood). True gradient, not a 3-band step.
  # Fork-free out-var form.
  gradient_color "$_CTX_PCT" _PCT_COLOR
  _PCT_TEXT="${_PCT_COLOR}${_CTX_PCT}%${COLOR_RESET}"
  # Size hint: Claude Code sends `context_window.context_window_size` as an
  # integer (e.g. 1000000 for 1M, 200000 for 200K). Round to the stock label.
  _CTX_SIZE="$(printf '%s' "$INPUT" | jq -r '.context_window.context_window_size // 0' 2>/dev/null || printf '0')"
  case "$_CTX_SIZE" in
    ''|*[!0-9]*) _CTX_SIZE=0 ;;
  esac
  if [ "$_CTX_SIZE" -gt 500000 ]; then
    _SIZE_HINT="1M"
  elif [ "$_CTX_SIZE" -gt 0 ]; then
    _SIZE_HINT="200K"
  else
    _SIZE_HINT=""
  fi
  if [ -n "$_SIZE_HINT" ]; then
    _SIZE_TEXT=" ${COLOR_MUTED}[${_SIZE_HINT}]${COLOR_RESET}"
  else
    _SIZE_TEXT=""
  fi
  CONTEXTBAR_CHUNK="${_FILLED_STR}${_EMPTY_STR} ${_PCT_TEXT}${_SIZE_TEXT}"
fi

SEP=" | "

# ---- Width-ladder right-to-left segment drop (FR-433, TC-4) ----------------
# Order from most-droppable (last) to most-essential (first):
#   1. sprint  (rich-only; least-essential)
#   2. branch  (drop BEFORE project at <50 cols)
#   3. project
#   4. model
#   5. brand   (always present)
#
# Boundaries:
#   >= 80 cols: all segments
#   60..79   : drop sprint
#   50..59   : drop sprint + branch
#   40..49   : drop sprint + branch + project (project drop AFTER branch — branch first per TC-4)
#   32..39   : drop sprint + branch + project + model (just brand + ascii update if any)
#   < 32     : brand only

if [ "$COLS" -lt 32 ]; then
  KEEP_BRAND=1; KEEP_MODEL=0; KEEP_PROJECT=0; KEEP_BRANCH=0; KEEP_SPRINT=0; KEEP_CONTEXTBAR=0; KEEP_RLIMIT=0
elif [ "$COLS" -lt 40 ]; then
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=0; KEEP_BRANCH=0; KEEP_SPRINT=0; KEEP_CONTEXTBAR=0; KEEP_RLIMIT=0
elif [ "$COLS" -lt 50 ]; then
  # E82-S9 / AC10: at <50 cols, the bar survives but the branch is dropped.
  # E82-S10 / AC8: rate-limits drops FIRST (least essential).
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=0; KEEP_SPRINT=0; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=0
elif [ "$COLS" -lt 60 ]; then
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=1; KEEP_SPRINT=0; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=0
elif [ "$COLS" -lt 80 ]; then
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=1; KEEP_SPRINT=0; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=0
else
  # sprint-43 update: rate-limits kept from 80 cols up (was 100). Most users
  # run terminals 80-120 wide; the 100-col gate dropped RL on common widths.
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=1; KEEP_SPRINT=1; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=1
fi

# Assemble two-line layout (sprint-43 issue-3):
#
#   Line 1: brand [update] [stale] | context-bar pct% [size] | model |
#           rate-limits | sprint
#   Line 2: branch | dirty | project
#
# Smart-hiding (FR-447) still applies: empty chunks are suppressed and the
# separator before them is dropped. Line 2 is also suppressed entirely when
# branch+dirty+project are all empty so a non-git terminal session renders
# only line 1.
#
# Width-ladder semantics preserved: KEEP_BRANCH / KEEP_PROJECT control
# whether line 2 chunks survive at narrow widths.

LINE1="$BRAND_CHUNK"
[ -n "$UPDATE_CHUNK" ] && LINE1="$LINE1 $UPDATE_CHUNK"
[ -n "$STALE_CHUNK" ] && LINE1="$LINE1 $STALE_CHUNK"
if [ "$KEEP_CONTEXTBAR" -eq 1 ] && [ -n "$CONTEXTBAR_CHUNK" ]; then
  LINE1="$LINE1$SEP$CONTEXTBAR_CHUNK"
fi
if [ "$KEEP_MODEL" -eq 1 ] && [ -n "$MODEL_CHUNK" ]; then
  LINE1="$LINE1$SEP$MODEL_CHUNK"
fi
if [ "$KEEP_RLIMIT" -eq 1 ] && [ -n "$RLIMIT_CHUNK" ]; then
  LINE1="$LINE1$SEP$RLIMIT_CHUNK"
fi
if [ "$KEEP_SPRINT" -eq 1 ] && [ -n "$SPRINT_CHUNK" ]; then
  LINE1="$LINE1$SEP$SPRINT_CHUNK"
fi

# Line 2: branch | dirty | project — only emitted when at least one chunk
# is present, to avoid a bare blank second line on terminals not in a repo.
LINE2=""
LINE2_HAS_CHUNK=0
if [ "$KEEP_BRANCH" -eq 1 ] && [ -n "$BRANCH_CHUNK" ]; then
  LINE2="$BRANCH_CHUNK"
  LINE2_HAS_CHUNK=1
fi
if [ "$KEEP_BRANCH" -eq 1 ] && [ -n "$DIRTY_CHUNK" ]; then
  if [ "$LINE2_HAS_CHUNK" -eq 1 ]; then
    LINE2="$LINE2$SEP$DIRTY_CHUNK"
  else
    LINE2="$DIRTY_CHUNK"
    LINE2_HAS_CHUNK=1
  fi
fi
if [ "$KEEP_PROJECT" -eq 1 ] && [ -n "$PROJECT_CHUNK" ]; then
  if [ "$LINE2_HAS_CHUNK" -eq 1 ]; then
    LINE2="$LINE2$SEP$PROJECT_CHUNK"
  else
    LINE2="$PROJECT_CHUNK"
    LINE2_HAS_CHUNK=1
  fi
fi

printf '%s\n' "$LINE1"
if [ "$LINE2_HAS_CHUNK" -eq 1 ]; then
  printf '%s\n' "$LINE2"
fi
exit 0
