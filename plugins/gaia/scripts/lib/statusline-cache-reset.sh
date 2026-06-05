#!/usr/bin/env bash
# statusline-cache-reset.sh — surgical reset of update-check-owned keys in
# ~/.claude/gaia-statusline/cache/latest-release.json, preserving the
# git_dirty field (shared-schema contract).
#
# The cache file is shared across three writers:
#   - statusline-update-check.sh        (owns: checked_at_iso, latest_tag,
#                                                current_tag, update_available,
#                                                installed_version_stale)
#   - statusline-git-dirty-check.sh     (owns: git_dirty)
#   - install-statusline.sh             (this reset — defense in depth)
#   - gaia-statusline-toggle.sh --enable (consent-triggered reset)
#
# This helper deletes only the keys owned by the update-check fetcher so
# the next render recomputes them against the freshly-installed runtime.
# The git_dirty field is preserved by value because its writer
# (PreToolUse hook, every tool call) cycles on a faster cadence than the
# update-check (24h TTL); clobbering git_dirty would force a stale state
# until the next PreToolUse fire.
#
# Atomic write via sibling-tempfile + mv on the SAME filesystem as the
# target cache file. Never /tmp/.
#
# Idempotent:
#   - Cache file absent → no-op, exit 0 (no error, no file created).
#   - All five reader-fields already absent → write is byte-identical, no
#     mtime bump.
#
# Usage:
#   _statusline_cache_reset
#       Reset the canonical cache file at
#       ~/.claude/gaia-statusline/cache/latest-release.json.
#
# POSIX discipline: bash 3.2 compatible.

_statusline_cache_reset() {
  local cache="${HOME}/.claude/gaia-statusline/cache/latest-release.json"

  # Cache absent → nothing to reset, success.
  [ -e "$cache" ] || return 0

  # Malformed JSON → leave it alone; the cache writer will recompute on
  # next run. Reset is best-effort; do not propagate failure to callers
  # whose primary work (install / toggle) succeeded.
  command -v jq >/dev/null 2>&1 || return 0
  jq '.' "$cache" >/dev/null 2>&1 || return 0

  local pruned sibling
  pruned="$(jq 'del(.checked_at_iso, .latest_tag, .current_tag, .update_available, .installed_version_stale)' "$cache")"

  # Byte-identical short-circuit. cmp -s reads both files; pruned is a
  # string so we materialize it in a sibling to compare.
  sibling="$(mktemp "${cache}.XXXXXX")"
  printf '%s\n' "$pruned" > "$sibling"
  if cmp -s "$sibling" "$cache"; then
    rm -f "$sibling"
    return 0
  fi
  mv -f "$sibling" "$cache"
  return 0
}
