#!/usr/bin/env bash
# install-statusline.sh — install the GAIA Claude Code statusline.
#
# Story: E82-S1.
#
# Behaviour:
#   1. Copy the runtime + helpers into ~/.claude/gaia-statusline/.
#   2. Atomically merge `statusLine.command` and `statusLine.refreshInterval`
#      into ~/.claude/settings.json (sibling-tempfile + mv on the SAME
#      filesystem — never /tmp/, per NFR-STATUSLINE-3).
#   3. Lazily create ~/.claude/gaia-statusline/cache/ (E82-S2 owns the
#      schema and writes; this story just creates the directory).
#
# Idempotency (TC-STATUSLINE-11): re-running the script with the same
# inputs produces a byte-identical filesystem state. Achieved by:
#   - cp only when source != dest (mtime-agnostic compare via cmp -s).
#   - jq merge that emits a stable canonical JSON (sorted keys + 2-space
#     indent) so the resulting settings.json is byte-deterministic.
#
# settings.json key preservation (TC-STATUSLINE-12): we use `jq * .` deep
# merge so unrelated top-level keys are preserved by-value.
#
# Plugin-upgrade-stable (TC-STATUSLINE-16): the per-user runtime under
# ~/.claude is updated ONLY when this script is re-run. A fresh plugin
# version on disk does NOT touch the installed runtime.
#
# POSIX discipline: bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

# Resolve plugin source dir = directory of this script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_RUNTIME="$SCRIPT_DIR/statusline.sh"
SRC_GLYPHS="$SCRIPT_DIR/lib/statusline-glyphs.sh"
SRC_COLORS="$SCRIPT_DIR/lib/statusline-colors.sh"
SRC_FETCHER="$SCRIPT_DIR/statusline-update-check.sh"
SRC_DIRTY_FETCHER="$SCRIPT_DIR/statusline-git-dirty-check.sh"

for f in "$SRC_RUNTIME" "$SRC_GLYPHS" "$SRC_COLORS" "$SRC_FETCHER" "$SRC_DIRTY_FETCHER"; do
  if [ ! -r "$f" ]; then
    printf 'install-statusline.sh: missing source file: %s\n' "$f" >&2
    exit 1
  fi
done

# Destination layout under $HOME/.claude.
DEST_BASE="$HOME/.claude/gaia-statusline"
DEST_LIB="$DEST_BASE/lib"
DEST_CACHE="$DEST_BASE/cache"
DEST_RUNTIME="$DEST_BASE/statusline.sh"
DEST_GLYPHS="$DEST_LIB/statusline-glyphs.sh"
DEST_COLORS="$DEST_LIB/statusline-colors.sh"
DEST_FETCHER="$DEST_BASE/statusline-update-check.sh"
DEST_DIRTY_FETCHER="$DEST_BASE/statusline-git-dirty-check.sh"

mkdir -p "$DEST_BASE" "$DEST_LIB" "$DEST_CACHE"

# Idempotent copy: only write if content differs.
_copy_if_different() {
  src="$1"; dst="$2"
  if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
    return 0
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
}

_copy_if_different "$SRC_RUNTIME" "$DEST_RUNTIME"
_copy_if_different "$SRC_GLYPHS"  "$DEST_GLYPHS"
_copy_if_different "$SRC_COLORS"  "$DEST_COLORS"
_copy_if_different "$SRC_FETCHER" "$DEST_FETCHER"
_copy_if_different "$SRC_DIRTY_FETCHER" "$DEST_DIRTY_FETCHER"

# ---- settings.json atomic merge -------------------------------------------
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"

# Build the new statusLine fragment.
# refreshInterval: 10000ms (10s) — sprint-43 update from 3600000ms (1h). The
# 1h cadence made context_window / rate_limits / git_dirty chunks reflect
# stale data between renders. 10s is ~5ms CPU per render — negligible.
STATUSLINE_FRAGMENT="$(jq -n \
  --arg cmd "$DEST_RUNTIME" \
  --argjson refresh 10000 \
  '{statusLine: {type: "command", command: $cmd, refreshInterval: $refresh}}')"

# Read existing settings (or {} if absent / unparseable).
if [ -r "$SETTINGS" ]; then
  EXISTING="$(jq '.' "$SETTINGS" 2>/dev/null || printf '{}')"
else
  EXISTING="{}"
fi

# Shallow merge at the top level: existing keys preserved by value (deep
# structure intact, no key reordering inside nested objects), and the
# statusLine block overlays. `+` is shallow merge — RHS wins only on the
# top-level statusLine key, leaving sibling keys (theme, model, hooks)
# byte-identical (TC-STATUSLINE-12).
MERGED="$(printf '%s\n%s\n' "$EXISTING" "$STATUSLINE_FRAGMENT" | jq -s '.[0] + .[1]')"

# E82-S8: register PreToolUse hook to invoke the git-dirty fetcher. The hook
# is appended to hooks.PreToolUse[] only when an entry referencing this
# specific command is not already present (idempotent). The match pattern
# is the dirty-fetcher path so re-running the install does not duplicate.
MERGED="$(printf '%s' "$MERGED" | jq \
  --arg cmd "$DEST_DIRTY_FETCHER" \
  '
    .hooks //= {} |
    .hooks.PreToolUse //= [] |
    if any(.hooks.PreToolUse[]?; .hooks[]?.command == $cmd)
    then .
    else .hooks.PreToolUse += [{matcher: "*", hooks: [{type: "command", command: $cmd}]}]
    end
  ')"

# Atomic write via SIBLING tempfile + mv — same filesystem so rename is
# atomic (NFR-STATUSLINE-3). NEVER /tmp/.
SIBLING="$(mktemp "${SETTINGS}.XXXXXX")"
printf '%s\n' "$MERGED" > "$SIBLING"
# Idempotent: if the new content matches existing, drop the sibling and
# do not bump mtime.
if [ -e "$SETTINGS" ] && cmp -s "$SIBLING" "$SETTINGS"; then
  rm -f "$SIBLING"
else
  mv -f "$SIBLING" "$SETTINGS"
fi

# ---- .installed-version marker (E82-S6 / ADR-094 Component 1) -------------
# Atomic sibling-tempfile + mv. Written as the LAST action so a successful
# install is the only thing that produces the marker. Source of truth for
# the plugin version: the in-tree .claude-plugin/plugin.json (the script's
# own plugin tree — three levels up from plugins/gaia/scripts/).
PLUGIN_JSON_SRC="$SCRIPT_DIR/../../.claude-plugin/plugin.json"
INSTALLED_VERSION=""
if [ -r "$PLUGIN_JSON_SRC" ]; then
  INSTALLED_VERSION="$(jq -r '.version // ""' "$PLUGIN_JSON_SRC" 2>/dev/null || printf '')"
fi
if [ -n "$INSTALLED_VERSION" ]; then
  MARKER="$DEST_BASE/.installed-version"
  MARKER_TMP="$(mktemp "${MARKER}.XXXXXX")"
  printf '%s\n' "$INSTALLED_VERSION" > "$MARKER_TMP"
  mv -f "$MARKER_TMP" "$MARKER"
fi

# ---- Cache reset (E82-S11 / FR-448 AC8 defense-in-depth) ------------------
# Surgically reset the update-check-owned keys (checked_at_iso, latest_tag,
# current_tag, update_available, installed_version_stale) in
# ~/.claude/gaia-statusline/cache/latest-release.json so the next render
# recomputes against the just-installed runtime instead of whatever values
# the prior install left behind. Preserves git_dirty (ADR-091). Idempotent:
# cache-absent is a no-op; all-fields-already-absent is a byte-identical
# write. Source from the colocated lib/ helper (same script tree).
. "$SCRIPT_DIR/lib/statusline-cache-reset.sh"
_statusline_cache_reset

printf 'install-statusline.sh: installed runtime at %s\n' "$DEST_RUNTIME"
printf 'install-statusline.sh: settings.json updated at %s\n' "$SETTINGS"
exit 0
