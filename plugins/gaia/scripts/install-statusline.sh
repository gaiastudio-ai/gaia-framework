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

for f in "$SRC_RUNTIME" "$SRC_GLYPHS" "$SRC_COLORS"; do
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

# ---- settings.json atomic merge -------------------------------------------
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"

# Build the new statusLine fragment.
STATUSLINE_FRAGMENT="$(jq -n \
  --arg cmd "$DEST_RUNTIME" \
  --argjson refresh 3600000 \
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

printf 'install-statusline.sh: installed runtime at %s\n' "$DEST_RUNTIME"
printf 'install-statusline.sh: settings.json updated at %s\n' "$SETTINGS"
exit 0
