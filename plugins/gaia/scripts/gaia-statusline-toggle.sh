#!/usr/bin/env bash
# gaia-statusline-toggle.sh — toggle the GAIA Claude Code statusline on/off.
#
# Story: E82-S3.
#
# Modes:
#   --enable   Add the canonical statusLine block to ~/.claude/settings.json
#              pointing at ~/.claude/gaia-statusline/statusline.sh with
#              refreshInterval = 10000 (10s — sprint-43 update from 1h).
#   --disable  Remove the statusLine block from ~/.claude/settings.json.
#
# Contract (AC1..AC8):
#   AC1  enable on file w/o block → block added, unrelated keys preserved.
#   AC2  enable on already-canonical block → byte-identical no-op.
#   AC3  disable on file w/ block → block removed, unrelated keys preserved.
#   AC4  disable on file w/o block → byte-identical no-op.
#   AC5  enable + disable round-trip preserves byte-identity (TC-14).
#   AC6  atomic write via sibling-tempfile + mv -f. Never /tmp/.
#   AC7  enable fails when runtime ~/.claude/gaia-statusline/statusline.sh
#        is missing or non-executable; settings.json unmodified; the error
#        names install-statusline.sh.
#   AC8  malformed JSON in settings.json → exit non-zero, file unmodified.
#
# Pattern reference: gaia-framework/plugins/gaia/scripts/install-statusline.sh
# (atomic merge idiom) and the gaia-bridge-toggle precedent (semantic
# contract: thin enable/disable wrappers + idempotency + canonical no-op
# messages).
#
# POSIX discipline: bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SETTINGS="$HOME/.claude/settings.json"
RUNTIME="$HOME/.claude/gaia-statusline/statusline.sh"
REFRESH_MS=10000

usage() {
  cat <<USAGE >&2
Usage: gaia-statusline-toggle.sh --enable | --disable

Modes:
  --enable    Add canonical statusLine block to ~/.claude/settings.json.
  --disable   Remove statusLine block from ~/.claude/settings.json.
USAGE
  exit 2
}

if [ "${1:-}" = "" ]; then
  usage
fi

MODE="$1"
case "$MODE" in
  --enable|--disable) ;;
  *) usage ;;
esac

# Require jq.
if ! command -v jq >/dev/null 2>&1; then
  printf 'gaia-statusline-toggle: jq not found in PATH\n' >&2
  exit 1
fi

# Atomic write via SIBLING tempfile + mv -f. Same filesystem as the target
# (~/.claude/) so the rename is atomic per NFR-STATUSLINE-3. Never /tmp/.
_atomic_write() {
  local target="$1" content="$2" sibling
  mkdir -p "$(dirname "$target")"
  sibling="$(mktemp "${target}.XXXXXX")"
  printf '%s\n' "$content" > "$sibling"
  if [ -e "$target" ] && cmp -s "$sibling" "$target"; then
    rm -f "$sibling"
    return 1
  fi
  mv -f "$sibling" "$target"
  return 0
}

# Read settings.json contents. Treats missing file as "{}". On malformed
# JSON, prints an error and returns non-zero — the caller bails without
# touching the file.
_read_settings() {
  if [ ! -e "$SETTINGS" ]; then
    printf '{}'
    return 0
  fi
  if ! jq '.' "$SETTINGS" >/dev/null 2>&1; then
    printf 'gaia-statusline-toggle: malformed settings.json at %s\n' "$SETTINGS" >&2
    return 1
  fi
  jq '.' "$SETTINGS"
}

# Canonical statusLine fragment expected by /gaia-statusline-enable.
# Single source of truth — used both for the idempotency check and for
# the merge payload.
_canonical_fragment() {
  jq -nc \
    --arg cmd "$RUNTIME" \
    --argjson refresh "$REFRESH_MS" \
    '{type: "command", command: $cmd, refreshInterval: $refresh}'
}

case "$MODE" in
  --enable)
    # AC7 — pre-flight: runtime must exist and be executable.
    if [ ! -x "$RUNTIME" ]; then
      printf 'gaia-statusline-enable: runtime not installed at %s\n' "$RUNTIME" >&2
      printf 'gaia-statusline-enable: run install-statusline.sh first (gaia-framework/plugins/gaia/scripts/install-statusline.sh)\n' >&2
      exit 1
    fi

    # Read settings (or {} if absent). AC8 — exit non-zero on malformed.
    if ! existing="$(_read_settings)"; then
      exit 1
    fi

    expected_fragment="$(_canonical_fragment)"
    current_fragment="$(printf '%s' "$existing" | jq -c '.statusLine // null')"

    # AC2 — idempotency. If current == expected, emit no-op message and
    # exit without writing.
    if [ "$current_fragment" = "$expected_fragment" ]; then
      printf 'gaia-statusline-enable: no-op (already enabled)\n'
      exit 0
    fi

    # Compose the merged settings: add/overwrite the statusLine key.
    merged="$(printf '%s' "$existing" | jq -S \
      --arg cmd "$RUNTIME" \
      --argjson refresh "$REFRESH_MS" \
      '. + {statusLine: {type: "command", command: $cmd, refreshInterval: $refresh}}')"

    if _atomic_write "$SETTINGS" "$merged"; then
      printf 'gaia-statusline-enable: enabled (%s)\n' "$SETTINGS"
    else
      # Sibling matched target — nothing changed on disk.
      printf 'gaia-statusline-enable: no-op (already enabled)\n'
    fi
    ;;

  --disable)
    # AC4 — file absent → already disabled, no-op without creating the file.
    if [ ! -e "$SETTINGS" ]; then
      printf 'gaia-statusline-disable: no-op (already disabled)\n'
      exit 0
    fi

    # AC8 — malformed JSON → exit non-zero, do not touch the file.
    if ! existing="$(_read_settings)"; then
      exit 1
    fi

    current_fragment="$(printf '%s' "$existing" | jq -c '.statusLine // null')"

    # AC4 — idempotency. If no statusLine present, emit no-op and exit
    # without writing. Byte-identity is guaranteed by skipping the write.
    if [ "$current_fragment" = "null" ]; then
      printf 'gaia-statusline-disable: no-op (already disabled)\n'
      exit 0
    fi

    # Remove the statusLine key.
    pruned="$(printf '%s' "$existing" | jq -S 'del(.statusLine)')"

    if _atomic_write "$SETTINGS" "$pruned"; then
      printf 'gaia-statusline-disable: disabled (%s)\n' "$SETTINGS"
    else
      printf 'gaia-statusline-disable: no-op (already disabled)\n'
    fi
    ;;
esac

exit 0
