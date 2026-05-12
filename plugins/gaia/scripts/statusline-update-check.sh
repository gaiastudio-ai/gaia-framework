#!/usr/bin/env bash
# statusline-update-check.sh — GAIA Claude Code statusline background update
# fetcher.
#
# Story: E82-S2.
#
# Role
# ----
# OFF the hot path. The Claude Code statusline `refreshInterval` mechanism
# (1h default, configured by install-statusline.sh) drives invocation. The
# runtime statusline.sh NEVER falls through to a synchronous fetch — that
# would breach NFR-STATUSLINE-1.
#
# Cache contract (ADR-091)
# ------------------------
#   ~/.claude/gaia-statusline/cache/latest-release.json
#   {
#     "checked_at_iso": "2026-05-09T12:34:56Z",
#     "latest_tag":     "1.2.3",            # leading 'v' stripped
#     "current_tag":    "1.0.0",            # leading 'v' stripped
#     "update_available": false             # boolean
#   }
#
# Failure-mode philosophy (TC-STATUSLINE-10 / FR-441 / FR-442)
# ------------------------------------------------------------
# Every failure is silent: exit 0, cache untouched, NOTHING on stderr. The
# user perception of "no update indicator" must be indistinguishable from
# "actively up to date" and "fetch failed."
#
# Atomic write (NFR-STATUSLINE-3)
# -------------------------------
# Sibling-tempfile + `mv -f` on the same filesystem as the cache target.
# Crossing filesystems via the system temp dir would break rename atomicity.
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -u
LC_ALL=C
export LC_ALL

# Convert any unexpected non-zero exit into a silent exit 0 so the contract
# "every failure path returns 0 with cache untouched" holds even if a future
# refactor adds a new failure mode we did not anticipate.
trap 'exit 0' ERR

# Sweep any orphaned sibling tempfile if we are killed mid-write (SIGINT,
# SIGTERM). Using a sentinel variable so the trap is a no-op until SIBLING
# is set further down.
SIBLING=""
_cleanup() {
  if [ -n "${SIBLING:-}" ] && [ -e "$SIBLING" ]; then
    rm -f "$SIBLING" 2>/dev/null || true
  fi
}
trap _cleanup EXIT INT TERM

# ---- Constants -------------------------------------------------------------
TTL_SECONDS=1800           # 30min fetch TTL — sprint-43 update from 24h.
                           # ~48 unauth GitHub API calls/day per machine —
                           # safely under the 60/hr public rate limit even
                           # when combined with other gh CLI usage. New
                           # releases now surface within 30min instead of 24h.
HTTP_TIMEOUT=5             # curl --max-time, gh wrapper enforces its own.

CACHE_DIR="${HOME}/.claude/gaia-statusline/cache"
CACHE_FILE="${CACHE_DIR}/latest-release.json"

# Resolve plugin.json via the same three-tier scheme statusline.sh uses
# (sprint-43 update). CLAUDE_PLUGIN_ROOT is intentionally NOT consulted —
# it's a per-skill envvar Claude Code never sets when this fetcher is run
# from a hook or refresh cycle. The original CLAUDE_PLUGIN_ROOT-keyed
# fallback to $PROJECT_PATH/gaia-public/... double-stacked when cwd was
# already inside gaia-public/ (e.g. agent operating in that subdir).
PROJECT_PATH="${PROJECT_PATH:-$PWD}"
PLUGIN_CACHE_DIR="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia"
PLUGIN_JSON=""

# Tier 1: scan plugin cache for highest semver subdirectory.
if [ -d "$PLUGIN_CACHE_DIR" ]; then
  _CACHED="$(ls "$PLUGIN_CACHE_DIR" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
  if [ -n "$_CACHED" ] && [ -r "$PLUGIN_CACHE_DIR/$_CACHED/.claude-plugin/plugin.json" ]; then
    PLUGIN_JSON="$PLUGIN_CACHE_DIR/$_CACHED/.claude-plugin/plugin.json"
  fi
fi

# Tier 2: in-tree repo at PROJECT_PATH/gaia-public/... AND at
# PROJECT_PATH/plugins/... — the second form catches cwd that's already
# inside the gaia-public subtree (the doubled-gaia-public bug from the
# original code).
if [ -z "$PLUGIN_JSON" ] && [ -r "$PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin/plugin.json" ]; then
  PLUGIN_JSON="$PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin/plugin.json"
fi
if [ -z "$PLUGIN_JSON" ] && [ -r "$PROJECT_PATH/plugins/gaia/.claude-plugin/plugin.json" ]; then
  PLUGIN_JSON="$PROJECT_PATH/plugins/gaia/.claude-plugin/plugin.json"
fi

# ---- Read current version from plugin.json --------------------------------
# AC4: plugin.json missing or unparseable -> exit 0 silently, cache untouched.
if [ ! -r "$PLUGIN_JSON" ]; then
  exit 0
fi
CURRENT_TAG="$(jq -r '.version // ""' "$PLUGIN_JSON" 2>/dev/null || printf '')"
if [ -z "$CURRENT_TAG" ]; then
  exit 0
fi
# Strip leading 'v' if present (canonical form is bare semver).
CURRENT_TAG="${CURRENT_TAG#v}"

# ---- TTL guard (AC5) ------------------------------------------------------
# If the cache is fresher than 24h, exit 0 without touching it.
_now_epoch() { date -u +%s; }

_iso_to_epoch() {
  # Portable ISO-8601 -> epoch. macOS BSD date and GNU date take different
  # flags; try both. Returns "" on failure (caller treats as "stale").
  ts="$1"
  # macOS / BSD: -j -f
  if e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)"; then
    printf '%s' "$e"; return 0
  fi
  # GNU: -d
  if e="$(date -u -d "$ts" +%s 2>/dev/null)"; then
    printf '%s' "$e"; return 0
  fi
  printf ''
}

if [ -r "$CACHE_FILE" ]; then
  prev_iso="$(jq -r '.checked_at_iso // ""' "$CACHE_FILE" 2>/dev/null || printf '')"
  if [ -n "$prev_iso" ]; then
    prev_epoch="$(_iso_to_epoch "$prev_iso")"
    if [ -n "$prev_epoch" ]; then
      now_epoch="$(_now_epoch)"
      delta=$(( now_epoch - prev_epoch ))
      if [ "$delta" -lt "$TTL_SECONDS" ] && [ "$delta" -ge 0 ]; then
        exit 0
      fi
    fi
  fi
fi

# ---- Fetch latest tag from GitHub Releases --------------------------------
# Prefer `gh api` (already a GAIA prereq). Fall back to unauthenticated curl.
# Both are wrapped to swallow failures.
LATEST_RAW=""
if command -v gh >/dev/null 2>&1; then
  LATEST_RAW="$(gh api repos/gaiastudio-ai/gaia-public/releases/latest 2>/dev/null || printf '')"
fi
if [ -z "$LATEST_RAW" ] && command -v curl >/dev/null 2>&1; then
  LATEST_RAW="$(curl -sSL --max-time "$HTTP_TIMEOUT" \
    https://api.github.com/repos/gaiastudio-ai/gaia-public/releases/latest 2>/dev/null || printf '')"
fi

# AC1, AC2: empty response -> exit 0 silently, cache untouched.
if [ -z "$LATEST_RAW" ]; then
  exit 0
fi

# AC3: parse JSON -> on failure, exit 0 silently.
LATEST_TAG="$(printf '%s' "$LATEST_RAW" | jq -r '.tag_name // ""' 2>/dev/null || printf '')"
if [ -z "$LATEST_TAG" ]; then
  exit 0
fi
LATEST_TAG="${LATEST_TAG#v}"

# ---- Tag comparison (AC6, AC7) -------------------------------------------
# Shell-only semver comparison via `sort -V`. When tags are equal, no update.
# When LATEST > CURRENT, update_available=true.
UPDATE_AVAILABLE="false"
if [ "$LATEST_TAG" != "$CURRENT_TAG" ]; then
  larger="$(printf '%s\n%s\n' "$CURRENT_TAG" "$LATEST_TAG" | sort -V | tail -1 2>/dev/null || printf '')"
  if [ "$larger" = "$LATEST_TAG" ] && [ -n "$larger" ]; then
    UPDATE_AVAILABLE="true"
  fi
fi

# ---- Atomic write (AC8, AC10 / NFR-STATUSLINE-3) -------------------------
# Sibling tempfile in the cache dir + mv -f. Cross-filesystem renames are
# not atomic, so we keep the temp file beside its target.
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

CHECKED_AT_ISO="$(date -u +%FT%TZ)"

# ---- installed_version_stale computation (E82-S6 / ADR-094 Component 3) --
# Rule: stale=true IFF marker file exists AND its trimmed content !=
# `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`.
# Missing marker => false. Missing CLAUDE_PLUGIN_ROOT => false.
INSTALLED_VERSION_STALE="false"
MARKER_FILE="$HOME/.claude/gaia-statusline/.installed-version"
if [ -r "$MARKER_FILE" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] \
   && [ -r "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" ]; then
  MARKER_VERSION="$(head -1 "$MARKER_FILE" 2>/dev/null | tr -d '[:space:]')"
  ACTIVE_VERSION="$(jq -r '.version // ""' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$MARKER_VERSION" ] && [ -n "$ACTIVE_VERSION" ] \
     && [ "$MARKER_VERSION" != "$ACTIVE_VERSION" ]; then
    INSTALLED_VERSION_STALE="true"
  fi
fi

SIBLING="$(mktemp "${CACHE_FILE}.XXXXXX" 2>/dev/null || printf '')"
if [ -z "$SIBLING" ]; then
  exit 0
fi

# Read-modify-write (ADR-091 amendment, E82-S8): the cache file is shared
# with statusline-git-dirty-check.sh. A naive `jq -n` overwrite would
# clobber its owned `git_dirty` field on every 1h refresh. Read existing
# cache, merge only our owned fields, atomic-write.
if [ -r "$CACHE_FILE" ]; then
  EXISTING_CACHE="$(jq '.' "$CACHE_FILE" 2>/dev/null || printf '{}')"
else
  EXISTING_CACHE="{}"
fi

# Build the canonical schema. `--argjson` for booleans (so jq emits a real
# JSON boolean, not a string).
if printf '%s' "$EXISTING_CACHE" | jq \
  --arg ts "$CHECKED_AT_ISO" \
  --arg lt "$LATEST_TAG" \
  --arg ct "$CURRENT_TAG" \
  --argjson ua "$UPDATE_AVAILABLE" \
  --argjson ivs "$INSTALLED_VERSION_STALE" \
  '. + {checked_at_iso:$ts, latest_tag:$lt, current_tag:$ct, update_available:$ua, installed_version_stale:$ivs}' \
  > "$SIBLING" 2>/dev/null; then
  # mv -f within the same directory == atomic rename on the same filesystem.
  mv -f "$SIBLING" "$CACHE_FILE" 2>/dev/null || rm -f "$SIBLING" 2>/dev/null
else
  rm -f "$SIBLING" 2>/dev/null
fi

exit 0
