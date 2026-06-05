#!/usr/bin/env bash
# statusline-plugin-cache-dir.sh — shared helper for resolving the highest-
# semver plugin cache directory.
#
#
# Provides two functions:
#
#   _statusline_plugin_cache_dir
#       Print the canonical plugin cache base dir:
#         $HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia
#       This is the single source of truth — `statusline-update-check.sh`
#       hardcodes the same path. If the slug ever changes again (e.g. a
#       future rename) this is the one helper to edit.
#
#   _statusline_resolve_cached_version
#       Print the highest-semver subdirectory name under the cache dir
#       (e.g. "1.183.0"). Empty string when the cache dir is absent or
#       contains no semver-named subdirectories. Sorts via `sort -V` so
#       "1.182.10" > "1.182.9" (correct semver, not lexicographic).
#
#   _statusline_resolve_cached_plugin_json
#       Print the path to the cached version's .claude-plugin/plugin.json
#       (e.g. "$HOME/.claude/plugins/cache/.../gaia/1.183.0/.claude-plugin/plugin.json").
#       Empty string when the cache dir or plugin.json is unreadable.
#
# Designed to be sourced by gaia-statusline-toggle.sh and any future
# consumer (statusline-update-check.sh could migrate to this helper in a
# follow-up to remove the duplicated literal; both paths agree today).
#
# POSIX discipline: bash 3.2 compatible. No `local -n`, no associative
# arrays, no `set -u` (callers may not have it on).

_statusline_plugin_cache_dir() {
  printf '%s\n' "$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia"
}

_statusline_resolve_cached_version() {
  local dir
  dir="$(_statusline_plugin_cache_dir)"
  [ -d "$dir" ] || return 0
  ls "$dir" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1
}

_statusline_resolve_cached_plugin_json() {
  local dir ver
  dir="$(_statusline_plugin_cache_dir)"
  ver="$(_statusline_resolve_cached_version)"
  [ -n "$ver" ] || return 0
  local pj="$dir/$ver/.claude-plugin/plugin.json"
  [ -r "$pj" ] || return 0
  printf '%s\n' "$pj"
}

_statusline_resolve_cached_install_script() {
  local dir ver
  dir="$(_statusline_plugin_cache_dir)"
  ver="$(_statusline_resolve_cached_version)"
  [ -n "$ver" ] || return 0
  local sh="$dir/$ver/scripts/install-statusline.sh"
  [ -r "$sh" ] || return 0
  printf '%s\n' "$sh"
}
