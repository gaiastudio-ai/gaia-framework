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
#   - $PROJECT_PATH/docs/implementation-artifacts/sprint-status.yaml      (rich theme only, D11)
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

# ---- Read GAIA version from plugin.json (D5) -------------------------------
# Prefer the actively-loaded plugin (Claude Code injects CLAUDE_PLUGIN_ROOT
# pointing at e.g. ~/.claude/plugins/cache/.../gaia/<version>/). Fall back to
# the in-tree repo for dev/test runs where CLAUDE_PLUGIN_ROOT is unset.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -r "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" ]; then
  PLUGIN_JSON="${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json"
else
  PLUGIN_JSON="$PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin/plugin.json"
fi
GAIA_VERSION=""
if [ -r "$PLUGIN_JSON" ]; then
  GAIA_VERSION="$(jq -r '.version // ""' "$PLUGIN_JSON" 2>/dev/null)"
fi
[ -n "$GAIA_VERSION" ] || GAIA_VERSION="dev"

# ---- Read model from stdin -------------------------------------------------
MODEL_NAME="$(printf '%s' "$INPUT" | jq -r '.model.display_name // .model.id // "claude"' 2>/dev/null)"
[ -n "$MODEL_NAME" ] || MODEL_NAME="claude"

# ---- Project name ----------------------------------------------------------
PROJECT_NAME="$(basename "$PROJECT_PATH" 2>/dev/null || printf 'project')"

# ---- Branch — env override for testability, else git symbolic-ref ----------
BRANCH=""
if [ -n "${GAIA_STATUSLINE_BRANCH_OVERRIDE:-}" ]; then
  BRANCH="$GAIA_STATUSLINE_BRANCH_OVERRIDE"
else
  BRANCH="$(git -C "$PROJECT_PATH" symbolic-ref --short HEAD 2>/dev/null || printf '')"
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

# ---- Rich-theme sprint status read (D11, TC-6) -----------------------------
SPRINT_ID=""
if [ "${GAIA_STATUSLINE_THEME:-}" = "rich" ]; then
  SPRINT_FILE="$PROJECT_PATH/docs/implementation-artifacts/sprint-status.yaml"
  if [ -r "$SPRINT_FILE" ]; then
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
# Suppressed when (a) cache absent or unparseable, (b) `update_available` is
# not the literal "true", or (c) the 7-day stale-fence has tripped — see
# E82-S2 / TC-STATUSLINE-7 / AT-4 above.
UPDATE_CHUNK=""
if [ "$CACHE_FRESH" -eq 1 ] && [ "$UPDATE_AVAILABLE_RAW" = "true" ] && [ -n "$LATEST_VERSION" ]; then
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
BRANCH_CHUNK=""
if [ -n "$BRANCH" ]; then
  # E82-S8 / AC3: append dirty glyph when git_dirty=true. AC4: BRANCH-empty
  # already suppresses the entire chunk via smart-hiding (FR-447), so no
  # marker leaks to a detached-HEAD render.
  DIRTY_SUFFIX=""
  if [ "$GIT_DIRTY_RAW" = "true" ]; then
    if [ "${GAIA_STATUSLINE_ASCII:-0}" = "1" ]; then
      DIRTY_SUFFIX="*"
    else
      DIRTY_SUFFIX="${GLYPH_DIRTY:-*}"
    fi
  fi
  BRANCH_CHUNK="${GLYPH_BRANCH} ${BRANCH}${DIRTY_SUFFIX}"
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
if [ "${GAIA_STATUSLINE_THEME:-}" = "rich" ]; then
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

# ---- Context-window progress bar (E82-S9 / FR-450) -------------------------
# Renders a 10-char band from stdin's `.context_window.used_percentage`
# (0-100). Two distinct null-vs-zero paths per AC6/AC7:
#   - `.context_window.current_usage` is null    -> empty chunk (pre-API or
#     post-/compact). Smart-hiding (FR-447) suppresses the separator.
#   - `current_usage` non-null AND `used_percentage` = 0 -> visible
#     10-glyph all-empty bar ("we know it's empty").
# Color bands: <50 OK, 50..<80 WARN, >=80 DIRTY.
# Filled / empty glyphs use `#` / `-` in ASCII theme (AC5), `█` / `░` UTF-8.
CONTEXTBAR_CHUNK=""
_CTX_CURRENT="$(printf '%s' "$INPUT" | jq -r '.context_window.current_usage // "null"' 2>/dev/null || printf 'null')"
if [ "$_CTX_CURRENT" != "null" ]; then
  _CTX_PCT="$(printf '%s' "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null || printf '0')"
  # Clamp to [0, 100] and integer-cast via shell arithmetic.
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
  # Color band per AC2/AC3/AC4.
  if [ "$_CTX_PCT" -lt 50 ]; then
    _CTX_COLOR="${COLOR_OK:-}"
  elif [ "$_CTX_PCT" -lt 80 ]; then
    _CTX_COLOR="${COLOR_WARN:-}"
  else
    _CTX_COLOR="${COLOR_DIRTY:-}"
  fi
  # Build filled run + empty run. Use string repetition via printf %*s.
  _FILLED_STR=""
  i=0
  while [ "$i" -lt "$_CTX_FILLED" ]; do
    _FILLED_STR="${_FILLED_STR}${_CTX_FILLED_GLYPH}"
    i=$((i + 1))
  done
  _EMPTY_STR=""
  i=0
  while [ "$i" -lt "$_CTX_EMPTY" ]; do
    _EMPTY_STR="${_EMPTY_STR}${_CTX_EMPTY_GLYPH}"
    i=$((i + 1))
  done
  CONTEXTBAR_CHUNK="${_CTX_COLOR}${_FILLED_STR}${COLOR_RESET}${_EMPTY_STR}"
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
elif [ "$COLS" -lt 100 ]; then
  # E82-S10: rate-limits requires more width — first to drop in the wide tier.
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=1; KEEP_SPRINT=1; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=0
else
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=1; KEEP_SPRINT=1; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=1
fi

# Assemble.
OUT="$BRAND_CHUNK"
[ -n "$UPDATE_CHUNK" ] && OUT="$OUT $UPDATE_CHUNK"
[ -n "$STALE_CHUNK" ] && OUT="$OUT $STALE_CHUNK"
if [ "$KEEP_MODEL" -eq 1 ] && [ -n "$MODEL_CHUNK" ]; then
  OUT="$OUT$SEP$MODEL_CHUNK"
fi
if [ "$KEEP_PROJECT" -eq 1 ] && [ -n "$PROJECT_CHUNK" ]; then
  OUT="$OUT$SEP$PROJECT_CHUNK"
fi
if [ "$KEEP_BRANCH" -eq 1 ] && [ -n "$BRANCH_CHUNK" ]; then
  OUT="$OUT$SEP$BRANCH_CHUNK"
fi
if [ "$KEEP_CONTEXTBAR" -eq 1 ] && [ -n "$CONTEXTBAR_CHUNK" ]; then
  OUT="$OUT$SEP$CONTEXTBAR_CHUNK"
fi
if [ "$KEEP_RLIMIT" -eq 1 ] && [ -n "$RLIMIT_CHUNK" ]; then
  OUT="$OUT$SEP$RLIMIT_CHUNK"
fi
if [ "$KEEP_SPRINT" -eq 1 ] && [ -n "$SPRINT_CHUNK" ]; then
  OUT="$OUT$SEP$SPRINT_CHUNK"
fi

printf '%s\n' "$OUT"
exit 0
