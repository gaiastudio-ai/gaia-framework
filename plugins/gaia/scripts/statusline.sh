#!/usr/bin/env bash
# statusline.sh — GAIA Claude Code statusline runtime.
#
# Runtime contract (https://code.claude.com/docs/en/statusline):
#   stdin: JSON with model.{id,display_name}, workspace.current_dir, etc.
#   stdout: a single line of statusline text, ANSI-allowed.
#   exit:  0 on success. NEVER nonzero. NEVER emit to stderr.
#
# Hot-path budget:
#   p95 wall < 100ms, ceiling < 300ms.
#
# Subprocess inventory:
#   ALLOWED (every external command this script can launch, by purpose):
#     stdin + JSON:          cat, jq
#     context snapshot:      mkdir, mv, rm
#     paths + names:         dirname, basename
#     git-state cache key:   cksum, awk
#     plugin version scan:   ls, grep, sort, tail
#     self-heal:             cmp, cp, chmod, mkdir
#     model name:            sed
#     branch probe:          git symbolic-ref
#     release cache age:     date
#     width:                 tput (only when COLUMNS is unset)
#     sprint yaml fallback:  grep, head, sed
#     background refresh:    the installed update-check helper (detached)
#   A valid sprint progress cache costs one jq call and skips the yaml chain.
#   FORBIDDEN: any network primitive (structurally enforced by the static
#              no-network check)
#
# File reads:
#   - ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json                     (version, active plugin)
#     Falls back to $PROJECT_PATH/gaia-framework/plugins/gaia/.claude-plugin/plugin.json (in-tree dev)
#   - $HOME/.claude/gaia-statusline/cache/latest-release.json             (silent on miss)
#   - $PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json                (rich theme, cache-first read)
#   - $PROJECT_ROOT/.gaia/state/sprint-status.yaml                         (rich theme, yaml fallback only)
#     Falls back to $PROJECT_PATH/docs/implementation-artifacts/sprint-status.yaml  (legacy read-compat)
#
# Snapshot root resolution (context-window snapshot):
#   The snapshot is written to <snapshot_root>/.gaia/memory/, where
#   snapshot_root is resolved independently of PROJECT_ROOT/PROJECT_PATH:
#     1. Explicit PROJECT_ROOT env
#     2. Explicit CLAUDE_PROJECT_ROOT env
#     3. workspace.project_dir from stdin JSON (the session's launch dir)
#     4. Computed PROJECT_ROOT (the current-dir / fallback chain)
#   This prevents stray .gaia/memory/ trees when the session's CWD moves.
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

# Capture whether PROJECT_ROOT / CLAUDE_PROJECT_ROOT were explicitly set
# BEFORE the fallback chain below overwrites them. Used by snapshot-root
# resolution to distinguish "explicitly set" from "fell through to
# PROJECT_PATH".
_SL_EXPLICIT_ROOT="${PROJECT_ROOT:-}"
_SL_EXPLICIT_CLAUDE_ROOT="${CLAUDE_PROJECT_ROOT:-}"

# Canonical state-tree root for .gaia/ access.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH}}}"

# Snapshot root: where the context-window snapshot is written. Resolved
# separately from PROJECT_ROOT so that a session whose CWD moves into a
# subdirectory does not create stray .gaia/memory/ trees there.
# Precedence: explicit PROJECT_ROOT env > CLAUDE_PROJECT_ROOT env >
# workspace.project_dir (the session's launch directory) > computed
# PROJECT_ROOT (which may track current_dir).
# ---- Persist the context-window snapshot for dev-step token telemetry -------
# statusline.sh is the ONLY component the Claude Code substrate hands the
# `.context_window.current_usage` object to (via hook stdin). The dev-step
# observability layer needs that cumulative token snapshot at step boundaries,
# but emit-step-boundary.sh has no access to the hook stdin. We bridge the two
# by persisting the latest snapshot to a small reusable file that
# emit-step-boundary.sh reads when no explicit --tokens payload is supplied.
#
# Privacy: we project the object through the SAME four-field numeric allowlist
# the consumer enforces (input_tokens, output_tokens, cache_creation_input_tokens,
# cache_read_input_tokens) and persist ONLY when every retained value is numeric.
# Any non-numeric value or non-allowlisted key is dropped here too, so neither
# arbitrary value text nor key-name text can ever reach the persisted file.
# Best-effort: a null/absent current_usage or any jq failure leaves the prior
# file untouched and never disrupts the statusline render.
#
# The same jq call that projects the snapshot also reads workspace.project_dir
# (output on the second line), so no extra subprocess is needed for the
# snapshot-root resolution.
if command -v jq >/dev/null 2>&1; then
  # Single jq call: line 1 = snapshot JSON (or empty), line 2 = project_dir.
  # Append a sentinel 'X' so command substitution does not strip trailing
  # newlines when project_dir is empty (the second line would be blank).
  _CW_COMBINED="$(printf '%s' "$INPUT" | jq -r '
    (.context_window.current_usage
     | if type == "object" then
         with_entries(select(.key as $k | ["input_tokens","output_tokens","cache_creation_input_tokens","cache_read_input_tokens"] | index($k)))
         | if (length > 0) and ([.[] | type == "number"] | all) then tojson else "" end
       else "" end),
    (.workspace.project_dir // "")
  ' 2>/dev/null; printf 'X')"
  _CW_COMBINED="${_CW_COMBINED%X}"
  # Split the two-line output using bash builtins only (no head/sed subprocess).
  _CW_SNAPSHOT="${_CW_COMBINED%%
*}"
  _SL_PROJECT_DIR="${_CW_COMBINED#*
}"
  # Strip trailing newline from project_dir if present.
  _SL_PROJECT_DIR="${_SL_PROJECT_DIR%
}"

  # Resolve the snapshot root now that project_dir is known.
  if [ -n "$_SL_EXPLICIT_ROOT" ]; then
    _SNAPSHOT_ROOT="$_SL_EXPLICIT_ROOT"
  elif [ -n "$_SL_EXPLICIT_CLAUDE_ROOT" ]; then
    _SNAPSHOT_ROOT="$_SL_EXPLICIT_CLAUDE_ROOT"
  elif [ -n "$_SL_PROJECT_DIR" ]; then
    _SNAPSHOT_ROOT="$_SL_PROJECT_DIR"
  else
    _SNAPSHOT_ROOT="$PROJECT_ROOT"
  fi

  if [ -n "$_CW_SNAPSHOT" ] && [ -d "$_SNAPSHOT_ROOT/.gaia" ]; then
    _CW_DIR="$_SNAPSHOT_ROOT/.gaia/memory"
    if mkdir -p "$_CW_DIR" 2>/dev/null; then
      # Atomic-ish write: tmpfile + mv so a concurrent reader never sees a
      # half-written file.
      _CW_TMP="$_CW_DIR/.context-window-snapshot.json.tmp.$$"
      if printf '%s\n' "$_CW_SNAPSHOT" > "$_CW_TMP" 2>/dev/null; then
        mv -f "$_CW_TMP" "$_CW_DIR/.context-window-snapshot.json" 2>/dev/null \
          || rm -f "$_CW_TMP" 2>/dev/null || true
      fi
    fi
  fi
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
# shellcheck source=/dev/null
[ -r "$LIB_DIR/statusline-project-cache-key.sh" ] && . "$LIB_DIR/statusline-project-cache-key.sh"

# Per-project git-state cache file, keyed by this session's workspace root
# (PROJECT_PATH == workspace.current_dir). Concurrent sessions in different
# repos each read their OWN active_branch / git_dirty — fixes the cross-project
# branch leak. Version-check fields stay in the shared latest-release.json.
_GAIA_CACHE_DIR="$HOME/.claude/gaia-statusline/cache"
if command -v _statusline_git_state_cache_file >/dev/null 2>&1; then
  GIT_STATE_CACHE_FILE="$(_statusline_git_state_cache_file "$_GAIA_CACHE_DIR" "$PROJECT_PATH")"
else
  _GAIA_CK="$(printf '%s' "$PROJECT_PATH" | cksum 2>/dev/null | awk '{print $1}')"
  [ -n "$_GAIA_CK" ] || _GAIA_CK="global"
  GIT_STATE_CACHE_FILE="${_GAIA_CACHE_DIR}/git-state-${_GAIA_CK}.json"
fi

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
#   Tier 1 (production): scan ~/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/
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
PLUGIN_CACHE_DIR="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia"
PLUGIN_JSON=""
GAIA_VERSION=""

# Tier 1: cache scan for the highest semver subdirectory.
if [ -d "$PLUGIN_CACHE_DIR" ]; then
  GAIA_VERSION_CACHED="$(ls "$PLUGIN_CACHE_DIR" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
  if [ -n "$GAIA_VERSION_CACHED" ] && [ -r "$PLUGIN_CACHE_DIR/$GAIA_VERSION_CACHED/.claude-plugin/plugin.json" ]; then
    PLUGIN_JSON="$PLUGIN_CACHE_DIR/$GAIA_VERSION_CACHED/.claude-plugin/plugin.json"
  fi
fi

# Tier 2: in-tree repo for dev/test runs. The in-tree product source can live
# under a gaia-public/ dir (the published-source checkout — the canonical
# layout), a gaia-framework/ dir (legacy), or directly at the project root.
# All three are probed so an in-tree/dev run resolves regardless of which
# checkout dir name the workspace uses.
if [ -z "$PLUGIN_JSON" ] && [ -r "$PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin/plugin.json" ]; then
  PLUGIN_JSON="$PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin/plugin.json"
fi
if [ -z "$PLUGIN_JSON" ] && [ -r "$PROJECT_PATH/gaia-framework/plugins/gaia/.claude-plugin/plugin.json" ]; then
  PLUGIN_JSON="$PROJECT_PATH/gaia-framework/plugins/gaia/.claude-plugin/plugin.json"
fi
if [ -z "$PLUGIN_JSON" ] && [ -r "$PROJECT_PATH/plugins/gaia/.claude-plugin/plugin.json" ]; then
  PLUGIN_JSON="$PROJECT_PATH/plugins/gaia/.claude-plugin/plugin.json"
fi

# Read the version from whichever tier resolved.
if [ -n "$PLUGIN_JSON" ] && [ -r "$PLUGIN_JSON" ]; then
  GAIA_VERSION="$(jq -r '.version // ""' "$PLUGIN_JSON" 2>/dev/null)"
fi

# Tier 3: last-resort literal.
[ -n "$GAIA_VERSION" ] || GAIA_VERSION="dev"

# ---- Self-heal the installed runtime against the active plugin
# The statusline RUNTIME is a standalone copy under ~/.claude/gaia-statusline/
# (installed once by install-statusline.sh). `/plugin marketplace update` only
# refreshes the plugin CACHE — it never touches the installed runtime — so the
# runtime silently froze at whatever version the user first installed and NONE
# of the shipped fixes appeared after an update. The pre-existing staleness
# detector also stayed silent for installs with no `.installed-version` marker.
#
# Fix: when this script is running AS the installed runtime AND a newer (or
# simply different) runtime exists in the resolved plugin cache, re-copy the
# runtime + helpers in place and (re)write the marker. This makes every user
# self-heal on the next render after a `/plugin` update — no manual re-install.
#
# Guards: best-effort (never breaks the render), only fires from the installed
# location (so dev/in-tree runs are untouched), and only copies a file when it
# actually differs (`cmp -s`). The copied runtime takes effect on the NEXT
# render; this render finishes with the current (about-to-be-replaced) code.
_GAIA_INSTALL_DIR="$HOME/.claude/gaia-statusline"
_GAIA_SELF="${BASH_SOURCE[0]:-$0}"
case "$_GAIA_SELF" in
  "$_GAIA_INSTALL_DIR"/*)
    # We ARE the installed runtime. Is there a newer cache runtime to pull in?
    if [ -n "${GAIA_VERSION_CACHED:-}" ]; then
      _GAIA_CACHE_SCRIPTS="$PLUGIN_CACHE_DIR/$GAIA_VERSION_CACHED/scripts"
      if [ -d "$_GAIA_CACHE_SCRIPTS" ] && [ -f "$_GAIA_CACHE_SCRIPTS/statusline.sh" ]; then
        # Only act when the runtime actually differs (cheap cmp, no churn).
        if ! cmp -s "$_GAIA_CACHE_SCRIPTS/statusline.sh" "$_GAIA_INSTALL_DIR/statusline.sh" 2>/dev/null; then
          mkdir -p "$_GAIA_INSTALL_DIR/lib" 2>/dev/null || true
          # Mirror exactly what install-statusline.sh copies.
          for _gp in \
            "statusline.sh:$_GAIA_INSTALL_DIR/statusline.sh" \
            "lib/statusline-glyphs.sh:$_GAIA_INSTALL_DIR/lib/statusline-glyphs.sh" \
            "lib/statusline-colors.sh:$_GAIA_INSTALL_DIR/lib/statusline-colors.sh" \
            "lib/statusline-project-cache-key.sh:$_GAIA_INSTALL_DIR/lib/statusline-project-cache-key.sh" \
            "lib/session-binding.sh:$_GAIA_INSTALL_DIR/lib/session-binding.sh" \
            "statusline-update-check.sh:$_GAIA_INSTALL_DIR/statusline-update-check.sh" \
            "statusline-git-dirty-check.sh:$_GAIA_INSTALL_DIR/statusline-git-dirty-check.sh"; do
            _gp_src="$_GAIA_CACHE_SCRIPTS/${_gp%%:*}"
            _gp_dst="${_gp#*:}"
            if [ -f "$_gp_src" ] && ! cmp -s "$_gp_src" "$_gp_dst" 2>/dev/null; then
              cp "$_gp_src" "$_gp_dst" 2>/dev/null && chmod +x "$_gp_dst" 2>/dev/null || true
            fi
          done
          # Stamp the marker so the staleness detector + future self-heals agree.
          printf '%s' "$GAIA_VERSION" > "$_GAIA_INSTALL_DIR/.installed-version" 2>/dev/null || true
        fi
      fi
    fi
    ;;
esac

# ---- Read model from stdin -------------------------------------------------
MODEL_NAME="$(printf '%s' "$INPUT" | jq -r '.model.display_name // .model.id // "claude"' 2>/dev/null)"
[ -n "$MODEL_NAME" ] || MODEL_NAME="claude"
# Strip a trailing context-window parenthetical from the display name so the
# statusline shows just the model (e.g. "Opus 4.7 (1M context)" -> "Opus 4.7").
# Only drops a final "( ... )" group whose contents mention context / a token
# window (1M / 200K / "context") — other parentheticals are left intact.
case "$MODEL_NAME" in
  *\(*context*\)|*\(*[0-9][MmKk]\))
    MODEL_NAME="$(printf '%s' "$MODEL_NAME" | sed -E 's/[[:space:]]*\([^)]*([Cc]ontext|[0-9]+[MmKk])[^)]*\)[[:space:]]*$//')"
    ;;
esac
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
  # Read active_branch from the PER-PROJECT git-state cache (keyed by this
  # session's workspace root), not the shared latest-release.json — otherwise a
  # concurrent session in another repo would leak its branch into this one.
  if [ -r "$GIT_STATE_CACHE_FILE" ]; then
    BRANCH="$(jq -r '.active_branch // ""' "$GIT_STATE_CACHE_FILE" 2>/dev/null || printf '')"
    # jq prints the literal "null" when the field is JSON null — normalise.
    [ "$BRANCH" = "null" ] && BRANCH=""
  fi
  # Fall back to the legacy git -C $PROJECT_PATH probe so first-run sessions
  # (no cache yet) still show a branch when cwd IS a git work tree.
  if [ -z "$BRANCH" ]; then
    BRANCH="$(git -C "$PROJECT_PATH" symbolic-ref --short HEAD 2>/dev/null || printf '')"
  fi
fi

# ---- Cache (silent on miss) ------------------------------------------------
# Cache schema (written by statusline-update-check.sh):
#   { checked_at_iso, latest_tag, current_tag, update_available }
#
# 7-day stale-fence: when the cache has
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
# Git-state fields (git_dirty + per-class line counts) come from the
# PER-PROJECT cache, written by statusline-git-dirty-check.sh keyed to this
# session's workspace root — never the shared latest-release.json. Defaults to
# 0/false on miss (e.g. before the first PreToolUse fires this session).
GIT_STAGED_ADDED=0
GIT_STAGED_REMOVED=0
GIT_UNSTAGED_ADDED=0
GIT_UNSTAGED_REMOVED=0
if [ -r "$GIT_STATE_CACHE_FILE" ]; then
  GIT_STATE_JSON="$(cat "$GIT_STATE_CACHE_FILE" 2>/dev/null || printf '')"
  if [ -n "$GIT_STATE_JSON" ]; then
    GIT_DIRTY_RAW="$(printf '%s' "$GIT_STATE_JSON" | jq -r '.git_dirty // false' 2>/dev/null)"
    # Per-class line-change counts (default 0 when absent).
    GIT_STAGED_ADDED="$(printf '%s' "$GIT_STATE_JSON" | jq -r '.staged_added // 0' 2>/dev/null)"
    GIT_STAGED_REMOVED="$(printf '%s' "$GIT_STATE_JSON" | jq -r '.staged_removed // 0' 2>/dev/null)"
    GIT_UNSTAGED_ADDED="$(printf '%s' "$GIT_STATE_JSON" | jq -r '.unstaged_added // 0' 2>/dev/null)"
    GIT_UNSTAGED_REMOVED="$(printf '%s' "$GIT_STATE_JSON" | jq -r '.unstaged_removed // 0' 2>/dev/null)"
  fi
fi

if [ -r "$CACHE_FILE" ]; then
  CACHE_JSON="$(cat "$CACHE_FILE" 2>/dev/null || printf '')"
  if [ -n "$CACHE_JSON" ]; then
    LATEST_VERSION="$(printf '%s' "$CACHE_JSON" | jq -r '.latest_tag // ""' 2>/dev/null)"
    UPDATE_AVAILABLE_RAW="$(printf '%s' "$CACHE_JSON" | jq -r '.update_available // false' 2>/dev/null)"
    INSTALLED_VERSION_STALE_RAW="$(printf '%s' "$CACHE_JSON" | jq -r '.installed_version_stale // false' 2>/dev/null)"
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

# ---- Update fetcher background refresh (hot-path TTL gate) ----------------
# The renderer originally assumed `refreshInterval` triggered the fetcher itself —
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
    # 1800 sec = 30min — matches the writer's TTL_SECONDS (updated
    # from 24h so new GitHub releases surface within 30min).
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

# ---- Theme resolution (rich is the default) --------------------------------
# Historically rich was opt-in via `GAIA_STATUSLINE_THEME=rich`. Most users
# never set the env var (the statusLine command in settings.json is just
# a path with no env), so context-bar / rate-limits / sprint chunks were
# silently gated off. Flipping the default to "rich" surfaces them by
# default; users who want the minimal layout set
# `GAIA_STATUSLINE_THEME=minimal` (any non-empty value other than "rich"
# also suppresses the rich-only chunks).
_GAIA_THEME="${GAIA_STATUSLINE_THEME:-rich}"
if [ "$_GAIA_THEME" = "rich" ]; then
  GAIA_RICH=1
else
  GAIA_RICH=0
fi

# ---- Rich-theme sprint status read ----------------------------------------
# Cache-first: reads .gaia/state/.sprint-progress-cache.json (one jq call) and
# falls back to sprint-status.yaml (grep chain) only when the cache is missing,
# unreadable, or carries invalid fields. Walks UP from PROJECT_ROOT (max 5
# levels) in one shared loop: at each level the cache is checked first, then
# the yaml. The loop stops at the first level that holds a yaml, so a cache
# that sits above that level is not used. No second loop, so the cache-absent
# subprocess count is unchanged. Only regular files are opened (a FIFO or a
# device at either path is ignored, so a read can never block the render).
SPRINT_ID=""
_SPRINT_PCT=""
_SPRINT_WARN=0
_SPRINT_CACHE_HIT=0

# _sl_clean_sprint_id VALUE — set _SL_CLEAN_ID to VALUE with terminal escape
# sequences and control bytes removed, or to "" when the result is not a plain
# sprint id. Pure bash (no subprocess, no subshell), bash 3.2 safe. The ASCII
# allowlist and the length cap are the security control; the stripping only
# recovers ids that carry a stray escape. Same rules as the cache read below.
_sl_clean_sprint_id() {
  local _v="$1" _re_csi _re_osc
  _re_csi=$'\033''\[[0-9;]*[A-Za-z]'
  _re_osc=$'\033'']'"[^"$'\007\033'"]*("$'\007'"|"$'\033''\\'")"
  while [[ $_v =~ $_re_csi ]]; do
    _v="${_v/"${BASH_REMATCH[0]}"/}"
  done
  while [[ $_v =~ $_re_osc ]]; do
    _v="${_v/"${BASH_REMATCH[0]}"/}"
  done
  _v="${_v//[$'\001'-$'\037']/}"
  _SL_CLEAN_ID=""
  case "$_v" in
    ''|*[!A-Za-z0-9-]*) return 0 ;;
  esac
  [ "${#_v}" -le 64 ] || return 0
  _SL_CLEAN_ID="$_v"
}
_SL_TAB=$'\t'

if [ "$GAIA_RICH" = "1" ]; then
  SPRINT_FILE=""
  _SPRINT_CACHE_FILE=""
  _SEARCH_DIR="$PROJECT_ROOT"
  _DEPTH=0
  while [ "$_DEPTH" -lt 5 ]; do
    # Check cache at this level (builtin tests, no subprocess).
    if [ -z "$_SPRINT_CACHE_FILE" ]; then
      _CACHE_CANDIDATE="$_SEARCH_DIR/.gaia/state/.sprint-progress-cache.json"
      if [ -f "$_CACHE_CANDIDATE" ] && [ -r "$_CACHE_CANDIDATE" ]; then
        _SPRINT_CACHE_FILE="$_CACHE_CANDIDATE"
      fi
    fi
    # Prefer .gaia/state/sprint-status.yaml (canonical location) over legacy docs/.
    _GAIA_CANDIDATE="$_SEARCH_DIR/.gaia/state/sprint-status.yaml"
    if [ -f "$_GAIA_CANDIDATE" ] && [ -r "$_GAIA_CANDIDATE" ]; then
      SPRINT_FILE="$_GAIA_CANDIDATE"
      break
    fi
    _CANDIDATE="$_SEARCH_DIR/docs/implementation-artifacts/sprint-status.yaml"
    if [ -f "$_CANDIDATE" ] && [ -r "$_CANDIDATE" ]; then
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

  # ---- Cache-first read: single jq invocation, SEG/NONE/FALLBACK tokens ----
  # Precedence: (1) cache readable + sprint null or closed -> no segment, no
  # yaml fallback; (2) cache readable + valid fields -> full segment from cache;
  # (3) anything else -> yaml fallback. Only an explicit `"sprint": null` in a
  # cache object means "no active sprint"; a document that is not an object or
  # has no `sprint` key at all (`{}`, `null`) counts as missing fields and
  # falls back, so an active sprint is never hidden by a foreign file. The
  # percentage is emitted in canonical integer form (50.0, -0 and 1E+2 render
  # as 50, 0 and 100), and the id is capped at 64 characters.
  if [ -n "$_SPRINT_CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
    _SPRINT_JQ_OUT="$(jq -r '
      if type != "object" then "FALLBACK"
      elif (has("sprint") | not) then "FALLBACK"
      elif .sprint == null then "NONE"
      elif (.sprint | type) != "object" then "FALLBACK"
      elif (.sprint.status // "") == "closed" then "NONE"
      else
        (.sprint.id // null) as $id |
        (.totals.progress_pct // null) as $pct |
        (.action_needed // null) as $an |
        if $id == null or $pct == null or $an == null then "FALLBACK"
        elif ($id | type) != "string" then "FALLBACK"
        elif ($pct | type) != "number" then "FALLBACK"
        elif ($pct != ($pct | floor)) then "FALLBACK"
        elif ($pct < 0 or $pct > 100) then "FALLBACK"
        elif ($an | type) != "array" then "FALLBACK"
        else
          ($id | gsub("\u001b\\[[0-9;]*[A-Za-z]"; "")
               | gsub("\u001b\\][^\u0007\u001b]*(\u0007|\u001b\\\\)"; "")
               | gsub("[\u0000-\u001f]"; "")) as $clean_id |
          if ($clean_id | test("^[A-Za-z0-9-]+$")) and (($clean_id | length) <= 64) then
            "SEG\t\($clean_id)\t\((($pct | floor) + 0) | tostring)\t\($an | length)"
          else "FALLBACK"
          end
        end
      end
    ' "$_SPRINT_CACHE_FILE" 2>/dev/null)" || _SPRINT_JQ_OUT="FALLBACK"

    case "$_SPRINT_JQ_OUT" in
      NONE)
        # Precedence 1: sprint null or closed — no segment, no yaml fallback.
        _SPRINT_CACHE_HIT=1
        SPRINT_ID=""
        ;;
      SEG"$_SL_TAB"*)
        # Precedence 2: valid cache — split the tab-delimited line with
        # parameter expansion (no here-string temp file, no subprocess).
        _S_REST="${_SPRINT_JQ_OUT#SEG"$_SL_TAB"}"
        _S_ID="${_S_REST%%"$_SL_TAB"*}"
        _S_REST="${_S_REST#*"$_SL_TAB"}"
        _S_PCT="${_S_REST%%"$_SL_TAB"*}"
        _S_WARN_N="${_S_REST#*"$_SL_TAB"}"
        # Re-check every field in the shell: one id, a 0-100 integer, a count.
        # Anything else (for example a second JSON document) falls back.
        _S_OK=1
        case "$_S_ID" in ''|*[!A-Za-z0-9-]*) _S_OK=0 ;; esac
        case "$_S_PCT" in ''|*[!0-9]*) _S_OK=0 ;; esac
        case "$_S_WARN_N" in ''|*[!0-9]*) _S_OK=0 ;; esac
        if [ "$_S_OK" = "1" ] && [ "${#_S_ID}" -le 64 ] && [ "${#_S_PCT}" -le 3 ] \
          && [ "$_S_PCT" -le 100 ] && [ "${#_S_WARN_N}" -le 9 ]; then
          _SPRINT_CACHE_HIT=1
          SPRINT_ID="$_S_ID"
          _SPRINT_PCT="$_S_PCT"
          [ "$_S_WARN_N" -gt 0 ] && _SPRINT_WARN=1
        fi
        ;;
      *)
        # Precedence 3: fallback — let the yaml extraction below run.
        ;;
    esac
  fi

  # Yaml extraction — runs only when the cache did not provide the answer.
  # The yaml id goes through the same escape stripping and ASCII allowlist as
  # the cache id; an id that fails them shows no sprint segment.
  if [ "$_SPRINT_CACHE_HIT" != "1" ] && [ -n "$SPRINT_FILE" ] && [ -f "$SPRINT_FILE" ] && [ -r "$SPRINT_FILE" ]; then
    SPRINT_ID="$(grep -E '^sprint_id:' "$SPRINT_FILE" 2>/dev/null | head -1 | sed 's/^sprint_id:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' || printf '')"
    _sl_clean_sprint_id "$SPRINT_ID"
    SPRINT_ID="$_SL_CLEAN_ID"
    # Suppress closed sprints — once /gaia-sprint-close stamps `status: closed`
    # the sprint_id refers to historical state until /gaia-sprint-plan rolls
    # the next sprint forward. Showing a closed sprint id is misleading.
    SPRINT_STATUS="$(grep -E '^status:' "$SPRINT_FILE" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' || printf '')"
    if [ "$SPRINT_STATUS" = "closed" ]; then
      SPRINT_ID=""
    fi
  fi

  # ---- Concurrent mode: bound-sprint resolution and +N indicator ----
  # When per-sprint cache files exist, resolve this session's bound sprint
  # via the session-binding helper. The +N indicator shows how many other
  # non-closed sprints are tracked alongside the bound one.
  _SL_PLUS_N=""
  _SL_CLOSED_LABEL=""
  _SL_STATE_DIR=""
  # Extract directory with parameter expansion (no subprocess).
  if [ -n "$_SPRINT_CACHE_FILE" ]; then
    _SL_STATE_DIR="${_SPRINT_CACHE_FILE%/*}"
  elif [ -n "$SPRINT_FILE" ]; then
    _SL_STATE_DIR="${SPRINT_FILE%/*}"
  fi

  if [ -n "$_SL_STATE_DIR" ] && [ -d "$_SL_STATE_DIR" ]; then
    # Check if per-sprint cache files exist (a proxy for concurrent mode).
    _SL_HAS_PER_SPRINT=0
    for _slpc in "$_SL_STATE_DIR"/.sprint-progress-cache-*.json; do
      [ -f "$_slpc" ] || continue
      _SL_HAS_PER_SPRINT=1
      break
    done

    if [ "$_SL_HAS_PER_SPRINT" = "1" ]; then
      # Extract session ID from stdin JSON.
      _SL_SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || _SL_SESSION_ID=""

      # Resolve bound sprint via the session-binding helper.
      _SL_BINDING_SH=""
      if [ -n "${_GAIA_INSTALL_DIR:-}" ] && [ -f "$_GAIA_INSTALL_DIR/lib/session-binding.sh" ]; then
        _SL_BINDING_SH="$_GAIA_INSTALL_DIR/lib/session-binding.sh"
      fi
      # Fallback: the plugin scripts dir (when running from source, not installed).
      if [ -z "$_SL_BINDING_SH" ]; then
        _SL_SELF_SCRIPTS=""
        case "${BASH_SOURCE[0]:-$0}" in
          */*) _SL_SELF_SCRIPTS="${BASH_SOURCE[0]%/*}" ;;
          *)   _SL_SELF_SCRIPTS="." ;;
        esac
        if [ -f "$_SL_SELF_SCRIPTS/lib/session-binding.sh" ]; then
          _SL_BINDING_SH="$_SL_SELF_SCRIPTS/lib/session-binding.sh"
        fi
      fi

      if [ -z "$_SL_BINDING_SH" ]; then
        # Helper missing: degrade to single-sprint rendering with stderr warning.
        printf 'statusline: session-binding helper not found, falling back to single-sprint\n' >&2
      elif [ -n "$_SL_SESSION_ID" ]; then
        _SL_BOUND_ID=""
        _SL_BIND_EXIT=1
        set +e
        _SL_BOUND_ID="$("$_SL_BINDING_SH" read --session-id "$_SL_SESSION_ID" --project-root "$PROJECT_ROOT" 2>/dev/null)"
        _SL_BIND_EXIT=$?
        set -e

        case "$_SL_BIND_EXIT" in
          0)
            # Bound: use the per-sprint cache for this sprint.
            _sl_clean_sprint_id "$_SL_BOUND_ID"
            _SL_BOUND_ID="$_SL_CLEAN_ID"
            if [ -n "$_SL_BOUND_ID" ]; then
              _SL_PER_CACHE="$_SL_STATE_DIR/.sprint-progress-cache-${_SL_BOUND_ID}.json"
              if [ -f "$_SL_PER_CACHE" ] && [ -r "$_SL_PER_CACHE" ] && command -v jq >/dev/null 2>&1; then
                _SL_PER_OUT="$(jq -r '
                  if type != "object" then "FALLBACK"
                  elif (has("sprint") | not) then "FALLBACK"
                  elif .sprint == null then "NONE"
                  elif (.sprint | type) != "object" then "FALLBACK"
                  elif (.sprint.status // "") == "closed" then "NONE"
                  else
                    (.sprint.id // null) as $id |
                    (.totals.progress_pct // null) as $pct |
                    (.action_needed // null) as $an |
                    if $id == null or $pct == null or $an == null then "FALLBACK"
                    elif ($id | type) != "string" then "FALLBACK"
                    elif ($pct | type) != "number" then "FALLBACK"
                    elif ($pct != ($pct | floor)) then "FALLBACK"
                    elif ($pct < 0 or $pct > 100) then "FALLBACK"
                    elif ($an | type) != "array" then "FALLBACK"
                    else
                      ($id | gsub("\u001b\\[[0-9;]*[A-Za-z]"; "")
                           | gsub("\u001b\\][^\u0007\u001b]*(\u0007|\u001b\\\\)"; "")
                           | gsub("[\u0000-\u001f]"; "")) as $clean_id |
                      if ($clean_id | test("^[A-Za-z0-9-]+$")) and (($clean_id | length) <= 64) then
                        "SEG\t\($clean_id)\t\((($pct | floor) + 0) | tostring)\t\($an | length)"
                      else "FALLBACK"
                      end
                    end
                  end
                ' "$_SL_PER_CACHE" 2>/dev/null)" || _SL_PER_OUT="FALLBACK"
                case "$_SL_PER_OUT" in
                  SEG"$_SL_TAB"*)
                    _S_REST="${_SL_PER_OUT#SEG"$_SL_TAB"}"
                    _S_ID="${_S_REST%%"$_SL_TAB"*}"
                    _S_REST="${_S_REST#*"$_SL_TAB"}"
                    _S_PCT="${_S_REST%%"$_SL_TAB"*}"
                    _S_WARN_N="${_S_REST#*"$_SL_TAB"}"
                    _S_OK=1
                    case "$_S_ID" in ''|*[!A-Za-z0-9-]*) _S_OK=0 ;; esac
                    case "$_S_PCT" in ''|*[!0-9]*) _S_OK=0 ;; esac
                    case "$_S_WARN_N" in ''|*[!0-9]*) _S_OK=0 ;; esac
                    if [ "$_S_OK" = "1" ] && [ "${#_S_ID}" -le 64 ] && [ "${#_S_PCT}" -le 3 ] \
                      && [ "$_S_PCT" -le 100 ] && [ "${#_S_WARN_N}" -le 9 ]; then
                      _SPRINT_CACHE_HIT=1
                      SPRINT_ID="$_S_ID"
                      _SPRINT_PCT="$_S_PCT"
                      [ "$_S_WARN_N" -gt 0 ] && _SPRINT_WARN=1
                    fi
                    ;;
                esac
              fi

              # Count per-sprint cache files for other non-closed sprints (+N).
              _SL_OTHER_N=0
              for _slpc in "$_SL_STATE_DIR"/.sprint-progress-cache-*.json; do
                [ -f "$_slpc" ] || continue
                _slpc_base="${_slpc##*/}"
                _slpc_sid="${_slpc_base#.sprint-progress-cache-}"
                _slpc_sid="${_slpc_sid%.json}"
                # Skip the bound sprint itself.
                [ "$_slpc_sid" = "$_SL_BOUND_ID" ] && continue
                # Skip any cache whose recorded status is closed (defense in depth).
                if command -v jq >/dev/null 2>&1; then
                  _slpc_status="$(jq -r '.sprint.status // ""' "$_slpc" 2>/dev/null)" || _slpc_status=""
                  [ "$_slpc_status" = "closed" ] && continue
                fi
                _SL_OTHER_N=$((_SL_OTHER_N + 1))
              done
              if [ "$_SL_OTHER_N" -gt 0 ]; then
                _SL_PLUS_N="+${_SL_OTHER_N}"
              fi
            fi
            ;;
          2)
            # Bound sprint closed: render read-only labelled "closed", no +N.
            _sl_clean_sprint_id "$_SL_BOUND_ID"
            _SL_BOUND_ID="$_SL_CLEAN_ID"
            if [ -n "$_SL_BOUND_ID" ]; then
              SPRINT_ID="$_SL_BOUND_ID"
              _SPRINT_PCT=""
              _SPRINT_WARN=0
              _SPRINT_CACHE_HIT=1
              _SL_CLOSED_LABEL=" closed"
            fi
            ;;
          3)
            # Invalid binding: single-sprint fallback with stderr warning.
            printf 'statusline: invalid session binding, falling back to single-sprint\n' >&2
            ;;
          *)
            # exit 1 (unbound) or other: single-sprint rendering (no +N).
            ;;
        esac
      fi
    fi
  fi
fi

# ---- Width detection ------------------------------------------------------
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
    OSC8_OPEN=$'\033]8;;https://github.com/gaiastudio-ai/gaia-framework/releases/tag/v'"$GAIA_VERSION"$'\033\\'
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

# Update indicator (glyph + bold + colour + ASCII prefix in ASCII theme).
# Suppressed when (a) cache absent or unparseable, (b) cached latest_tag is
# missing, (c) the cached latest_tag is NOT strictly newer than the live
# installed GAIA_VERSION, or (d) the 7-day stale-fence has tripped (see above).
#
# The gate compares with a strict semver "latest > installed"
# test, NOT a bare `latest != installed`. After the user runs /plugin update, the
# installed version becomes >= the cached latest_tag; a `!=` check still fired
# (installed now DIFFERS from the stale cached latest) so the arrow lingered until
# the 24h fetcher TTL refreshed the cache. The strict-greater test clears the
# arrow on the very next render once installed catches up to (or passes) the
# cached latest — and a downgrade likewise shows no false "update".
#
# _semver_gt <a> <b> — return 0 (true) iff a is strictly greater than b under
# `sort -V`. Non-numeric/dev versions: any non-strict-semver value is treated as
# "not greater" so a "dev" install never shows a spurious update arrow.
_semver_gt() {
  _sg_a="$1"; _sg_b="$2"
  # Equal -> not greater. (Also the fast path for the common "already current".)
  [ "$_sg_a" = "$_sg_b" ] && return 1
  # A non-numeric installed version (e.g. "dev") must never show an update
  # arrow — treat it as already-current so a dev/in-tree run stays quiet.
  case "$_sg_b" in ''|*[!0-9.]*) return 1 ;; esac
  # Likewise a non-numeric latest_tag is not a real, comparable release.
  case "$_sg_a" in ''|*[!0-9.]*) return 1 ;; esac
  # a is greater iff it sorts LAST under version-sort and differs from b.
  _sg_hi="$(printf '%s\n%s\n' "$_sg_a" "$_sg_b" | sort -V | tail -1)"
  [ "$_sg_hi" = "$_sg_a" ]
}
UPDATE_CHUNK=""
if [ "$CACHE_FRESH" -eq 1 ] && [ -n "$LATEST_VERSION" ] && _semver_gt "$LATEST_VERSION" "$GAIA_VERSION"; then
  if [ "${GAIA_STATUSLINE_ASCII:-0}" = "1" ]; then
    UPDATE_CHUNK="[update] ${GLYPH_UPDATE:-^}"
  else
    UPDATE_CHUNK="${COLOR_UPDATE:-}${GLYPH_UPDATE:-^}${COLOR_RESET}"
  fi
fi

# ---- Staleness WARN segment ------------------------------------------------
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
# distinct boxes on line 2 (per the two-line layout design). The dirty
# marker is still gated on BRANCH being non-empty — a detached HEAD with
# no branch context renders nothing for both chunks.
BRANCH_CHUNK=""
DIRTY_CHUNK=""
if [ -n "$BRANCH" ]; then
  BRANCH_CHUNK="${GLYPH_BRANCH} ${BRANCH}"
  if [ "$GIT_DIRTY_RAW" = "true" ]; then
    # Render per-class line-change counts instead of a bare
    # dirty glyph — "S +30 -4  U +12 -3" (S=staged, U=unstaged; +added green,
    # -removed red; muted labels). Both sides always shown when dirty, incl.
    # "+0 -0" for an untracked-only tree (git counts no line diff for those).
    # Integer-cast each count defensively (cache could be stale/garbage).
    for _v in GIT_STAGED_ADDED GIT_STAGED_REMOVED GIT_UNSTAGED_ADDED GIT_UNSTAGED_REMOVED; do
      eval "_cv=\${$_v:-0}"
      case "$_cv" in ''|*[!0-9]*) eval "$_v=0" ;; esac
    done
    _DIRTY_S="${COLOR_MUTED}S${COLOR_RESET} ${COLOR_OK}+${GIT_STAGED_ADDED:-0}${COLOR_RESET} ${COLOR_DIRTY}-${GIT_STAGED_REMOVED:-0}${COLOR_RESET}"
    _DIRTY_U="${COLOR_MUTED}U${COLOR_RESET} ${COLOR_OK}+${GIT_UNSTAGED_ADDED:-0}${COLOR_RESET} ${COLOR_DIRTY}-${GIT_UNSTAGED_REMOVED:-0}${COLOR_RESET}"
    DIRTY_CHUNK="${_DIRTY_S}  ${_DIRTY_U}"
  fi
fi
SPRINT_CHUNK=""
if [ -n "$SPRINT_ID" ]; then
  if [ -n "${_SL_CLOSED_LABEL:-}" ]; then
    # Closed sprint: read-only labelled "closed", no percentage, no +N.
    _SP_TEXT="${SPRINT_ID}${_SL_CLOSED_LABEL}"
    SPRINT_CHUNK="${COLOR_MUTED}${_SP_TEXT}${COLOR_RESET}"
  elif [ -n "$_SPRINT_PCT" ]; then
    _SP_TEXT="${SPRINT_ID} ${_SPRINT_PCT}%"
    # Append +N indicator when other non-closed sprints exist.
    if [ -n "${_SL_PLUS_N:-}" ]; then
      _SP_TEXT="${_SP_TEXT} ${_SL_PLUS_N}"
    fi
    if [ "$_SPRINT_WARN" = "1" ]; then
      SPRINT_CHUNK="${COLOR_WARN:-}${GLYPH_WARN:-!} ${_SP_TEXT}${COLOR_RESET}"
    else
      SPRINT_CHUNK="${COLOR_MUTED}${_SP_TEXT}${COLOR_RESET}"
    fi
  else
    _SP_TEXT="$SPRINT_ID"
    if [ -n "${_SL_PLUS_N:-}" ]; then
      _SP_TEXT="${_SP_TEXT} ${_SL_PLUS_N}"
    fi
    if [ "$_SPRINT_WARN" = "1" ]; then
      SPRINT_CHUNK="${COLOR_WARN:-}${GLYPH_WARN:-!} ${_SP_TEXT}${COLOR_RESET}"
    else
      SPRINT_CHUNK="${COLOR_MUTED}${_SP_TEXT}${COLOR_RESET}"
    fi
  fi
fi

# ---- Rate-limits chunk (redesigned per user req) ---------------------------
# Rich-theme-only. Reads `.rate_limits.{five_hour,seven_day}.{used_percentage,
# resets_at}` from stdin (resets_at = Unix epoch seconds; per the Claude Code
# statusline schema). Renders ONE gradient-colored segment PER PRESENT WINDOW:
#
#   5h:23% (2h13m)   7d:63% (4d2h)
#
# - Each segment's % is gradient-colored by its OWN value (green->amber->red),
#   reusing gradient_color() — no shared "max" band.
# - The parenthetical is the adaptive countdown until that window resets
#   (resets_at - now): <1h "47m", 1-24h "2h13m", >24h "4d2h", <=0 "now".
# - resets_at absent on a present window -> show just "5h:23%" (no parens).
# - A window entirely absent is omitted; rate_limits entirely absent ->
#   empty chunk (graceful, matches the prior behavior for non-Pro/Max).
#
# used_percentage may be a float (e.g. 23.5); truncate to int for both display
# and the gradient. _RL_NOW is captured once so both windows share a clock.

# _rl_reltime <resets_at_epoch> -> adaptive "Nh Nm" / "Nm" / "NdNh" / "now".
# Empty string when the epoch is missing/non-numeric. Uses _RL_NOW.
_rl_reltime() {
  _rt="$1"
  case "$_rt" in ''|null|*[!0-9]*) printf ''; return 0 ;; esac
  _delta=$(( _rt - _RL_NOW ))
  if [ "$_delta" -le 0 ]; then printf 'now'; return 0; fi
  _d=$(( _delta / 86400 ))
  _h=$(( (_delta % 86400) / 3600 ))
  _m=$(( (_delta % 3600) / 60 ))
  if [ "$_d" -gt 0 ]; then
    printf '%dd%dh' "$_d" "$_h"
  elif [ "$_h" -gt 0 ]; then
    printf '%dh%dm' "$_h" "$_m"
  else
    # under an hour — show whole minutes, minimum 1m so a >0 delta never shows 0m.
    [ "$_m" -lt 1 ] && _m=1
    printf '%dm' "$_m"
  fi
}

# _rl_segment <label> <pct> <resets_at> -> gradient-colored "label:PCT% (reset)".
# Assigns the rendered segment to _RL_SEG (no fork). Empty when pct is null.
_rl_segment() {
  _seg_label="$1"; _seg_pct="$2"; _seg_reset="$3"
  _RL_SEG=""
  [ "$_seg_pct" = "null" ] && return 0
  # Truncate a possible float (23.5 -> 23) then clamp 0..100.
  _seg_pct="${_seg_pct%%.*}"
  case "$_seg_pct" in ''|*[!0-9]*) _seg_pct=0 ;; esac
  [ "$_seg_pct" -gt 100 ] && _seg_pct=100
  [ "$_seg_pct" -lt 0 ] && _seg_pct=0
  # gradient_color assigns _seg_color via `printf -v` (out-var form, no fork).
  # Pre-declare so static analysis sees the assignment (SC2154).
  _seg_color=""
  gradient_color "$_seg_pct" _seg_color
  _seg_rel="$(_rl_reltime "$_seg_reset")"
  if [ -n "$_seg_rel" ]; then
    _RL_SEG="${_seg_color}${_seg_label}:${_seg_pct}% (${_seg_rel})${COLOR_RESET}"
  else
    _RL_SEG="${_seg_color}${_seg_label}:${_seg_pct}%${COLOR_RESET}"
  fi
}

RLIMIT_CHUNK=""
if [ "$GAIA_RICH" = "1" ]; then
  _RL_5H="$(printf '%s' "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // "null"' 2>/dev/null || printf 'null')"
  _RL_5H_RESET="$(printf '%s' "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // "null"' 2>/dev/null || printf 'null')"
  _RL_7D="$(printf '%s' "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // "null"' 2>/dev/null || printf 'null')"
  _RL_7D_RESET="$(printf '%s' "$INPUT" | jq -r '.rate_limits.seven_day.resets_at // "null"' 2>/dev/null || printf 'null')"
  if [ "$_RL_5H" != "null" ] || [ "$_RL_7D" != "null" ]; then
    _RL_NOW="$(date +%s 2>/dev/null || printf '0')"
    case "$_RL_NOW" in ''|*[!0-9]*) _RL_NOW=0 ;; esac
    _rl_segment "5h" "$_RL_5H" "$_RL_5H_RESET"; _RL_SEG_5H="$_RL_SEG"
    _rl_segment "7d" "$_RL_7D" "$_RL_7D_RESET"; _RL_SEG_7D="$_RL_SEG"
    # Join present segments with a single space (both -> "5h:.. 7d:..").
    if [ -n "$_RL_SEG_5H" ] && [ -n "$_RL_SEG_7D" ]; then
      RLIMIT_CHUNK="${_RL_SEG_5H} ${_RL_SEG_7D}"
    else
      RLIMIT_CHUNK="${_RL_SEG_5H}${_RL_SEG_7D}"
    fi
  fi
fi

# ---- Context-window progress bar ------------------------------------------
# Renders a 10-char gradient bar from stdin's `.context_window.used_percentage`
# (0-100), inline percentage, and grey size hint (200K / 1M).
#
# An earlier version used a single solid color band. This
# redesign replaces it with per-cell gradient
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

# ---- Width-ladder right-to-left segment drop --------------------------------
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
#   40..49   : drop sprint + branch + project (project drop AFTER branch)
#   32..39   : drop sprint + branch + project + model (just brand + ascii update if any)
#   < 32     : brand only

if [ "$COLS" -lt 32 ]; then
  KEEP_BRAND=1; KEEP_MODEL=0; KEEP_PROJECT=0; KEEP_BRANCH=0; KEEP_SPRINT=0; KEEP_CONTEXTBAR=0; KEEP_RLIMIT=0
elif [ "$COLS" -lt 40 ]; then
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=0; KEEP_BRANCH=0; KEEP_SPRINT=0; KEEP_CONTEXTBAR=0; KEEP_RLIMIT=0
elif [ "$COLS" -lt 50 ]; then
  # At <50 cols, the context bar survives but the branch is dropped.
  # Rate-limits drops first (least essential).
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=0; KEEP_SPRINT=0; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=0
elif [ "$COLS" -lt 60 ]; then
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=1; KEEP_SPRINT=0; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=0
elif [ "$COLS" -lt 80 ]; then
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=1; KEEP_SPRINT=0; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=0
else
  # Rate-limits kept from 80 cols up (was 100). Most users
  # run terminals 80-120 wide; the 100-col gate dropped RL on common widths.
  KEEP_BRAND=1; KEEP_MODEL=1; KEEP_PROJECT=1; KEEP_BRANCH=1; KEEP_SPRINT=1; KEEP_CONTEXTBAR=1; KEEP_RLIMIT=1
fi

# Assemble two-line layout:
#
#   Line 1: brand [update] [stale] | context-bar pct% [size] | model |
#           rate-limits | sprint
#   Line 2: branch | dirty | project
#
# Smart-hiding still applies: empty chunks are suppressed and the
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
