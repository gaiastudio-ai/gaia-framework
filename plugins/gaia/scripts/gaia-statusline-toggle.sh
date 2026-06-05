#!/usr/bin/env bash
# gaia-statusline-toggle.sh — toggle the GAIA Claude Code statusline on/off.
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
#   AC5  enable + disable round-trip preserves byte-identity.
#   AC6  atomic write via sibling-tempfile + mv -f. Never /tmp/.
#   AC7  enable fails when runtime ~/.claude/gaia-statusline/statusline.sh
#        is missing or non-executable; settings.json unmodified; the error
#        names install-statusline.sh.
#   AC8  malformed JSON in settings.json → exit non-zero, file unmodified.
#   AC9  consent-gated self-heal: before the AC2 idempotency check, compare
#        the installed runtime version (~/.claude/gaia-statusline/.installed-version
#        marker) to the cached plugin.json version under the highest-semver dir of
#        ~/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia. When
#        the marker differs from the cached version AND stdout/stdin are
#        both TTYs AND GAIA_YOLO_FLAG != 1, surface a one-shot consent
#        prompt with default decline. On 'y' (case-insensitive), re-run
#        the cached install-statusline.sh and reset the update-check
#        cache (preserving git_dirty). On 'N' or non-TTY or
#        YOLO, no install runs (preserves hand-edit consent).
#        Marker-absent is a silent no-op.
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

# Source the colocated lib/ helpers. Resolved relative to this
# script's directory so the toggle works both from the in-tree plugin
# checkout AND from the substrate plugin cache.
_TOGGLE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/statusline-plugin-cache-dir.sh
. "$_TOGGLE_SCRIPT_DIR/lib/statusline-plugin-cache-dir.sh"
# shellcheck source=lib/statusline-cache-reset.sh
. "$_TOGGLE_SCRIPT_DIR/lib/statusline-cache-reset.sh"

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
# (~/.claude/) so the rename is atomic. Never /tmp/.
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

    # AC9 — Consent-gated self-heal.
    # Compare the installed .installed-version marker to the cached
    # plugin.json version. When they differ AND we are interactive AND
    # YOLO is not active, prompt the user to re-install. On 'y' (case-
    # insensitive), re-run the cached install-statusline.sh AND reset the
    # update-check cache (preserving git_dirty). On any other answer, on
    # non-TTY, or with YOLO active, take no action — the existing AC3
    # hot-path WARN segment continues to fire on stale runtimes
    # (consent contract preserved).
    #
    # Marker absent → silent no-op.
    _marker_file="$HOME/.claude/gaia-statusline/.installed-version"
    if [ -r "$_marker_file" ]; then
      _installed_version="$(head -n1 "$_marker_file" 2>/dev/null | tr -d '[:space:]' || printf '')"
      _cached_plugin_json="$(_statusline_resolve_cached_plugin_json)"
      _cached_install_sh="$(_statusline_resolve_cached_install_script)"
      _cached_version=""
      if [ -n "$_cached_plugin_json" ]; then
        _cached_version="$(jq -r '.version // ""' "$_cached_plugin_json" 2>/dev/null || printf '')"
      fi
      # Both endpoints resolved AND they disagree → consider prompting.
      if [ -n "$_installed_version" ] && [ -n "$_cached_version" ] \
         && [ "$_installed_version" != "$_cached_version" ] \
         && [ -n "$_cached_install_sh" ]; then
        # Stricter TTY gate: BOTH stdin AND stdout must be a terminal.
        # bats (the test harness) attaches neither by default, so this
        # gate keeps the statusline bats test intact.
        if [ -t 0 ] && [ -t 1 ] && [ "${GAIA_YOLO_FLAG:-0}" != "1" ]; then
          printf 'gaia-statusline-enable: installed runtime is %s, cached plugin is %s. Re-install runtime? [y/N] ' \
            "$_installed_version" "$_cached_version"
          # Read a single line from stdin. IFS= preserves leading/trailing
          # whitespace; -r treats backslashes literally.
          _answer=""
          IFS= read -r _answer || _answer=""
          case "$_answer" in
            y|Y|yes|YES|Yes)
              # Run the cached installer in a subshell so a non-zero exit
              # does not abort the toggle. install-statusline.sh is
              # idempotent (cmp-only-if-different copies); re-running
              # touches at most five script files + the marker + the
              # cache reset.
              if bash "$_cached_install_sh" >/dev/null 2>&1; then
                printf 'gaia-statusline-enable: refreshed runtime from cached %s (was stale).\n' "$_cached_version"
              else
                printf 'gaia-statusline-enable: WARNING — refresh attempted but install-statusline.sh exited non-zero; runtime may be partially updated\n' >&2
              fi
              # Defense in depth: even if install-statusline.sh's own
              # cache reset call failed for any reason, we reset here.
              _statusline_cache_reset
              ;;
            *)
              # 'N', empty, or any non-affirmative answer → no install,
              # no cache mutation. Existing AC3 hot-path WARN keeps
              # firing on the next render so the signal is not lost.
              :
              ;;
          esac
        fi
      fi
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
