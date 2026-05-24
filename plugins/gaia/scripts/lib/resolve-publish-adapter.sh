#!/usr/bin/env bash
# resolve-publish-adapter.sh — resolve a publish adapter directory path.
#
# Per ADR-113 §clause (e) + ADR-020 precedence + SR-81 + SR-82:
#   1. Custom adapters at <project-root>/.gaia/custom/adapters/publish-<adapter_name>/
#      SHADOW built-in adapters at <plugin-root>/scripts/adapters/publish-<channel>/.
#   2. SR-81: adapter_name MUST match ^[a-z0-9-]{1,64}$ (no slashes, no traversal).
#   3. SR-82: --strict-builtin refuses custom shadow on sensitive channels.
#   4. When a custom shadow exists, emit canonical WARN to stderr.
#
# Usage:
#   resolve-publish-adapter.sh --adapter <name> [--strict-builtin]
#     [--project-root <path>] [--plugin-root <path>]
#     [--strict-sensitive <comma-list>]
#
# Exit codes:
#   0 — resolved; absolute path emitted on stdout
#   1 — adapter not found (built-in or custom)
#   2 — usage error (missing arg, invalid adapter_name, path-traversal)
#   3 — --strict-builtin HALT (shadow refused for sensitive channel)

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="$(basename "$0")"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

# Default sensitive channels per SR-82 (story AC6 5-channel list).
# `marketplace` covers the broader marketplace family including claude-marketplace;
# operators can pin a project-specific list via publish.strict_builtin_channels in
# project-config.yaml (--strict-sensitive flag forwards that override).
DEFAULT_SENSITIVE="npm,pypi,app-store-connect,play-console,marketplace"

ADAPTER=""
STRICT_BUILTIN=0
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
SENSITIVE="$DEFAULT_SENSITIVE"

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter)            ADAPTER="$2"; shift 2 ;;
    --strict-builtin)     STRICT_BUILTIN=1; shift ;;
    --project-root)       PROJECT_ROOT="$2"; shift 2 ;;
    --plugin-root)        PLUGIN_ROOT="$2"; shift 2 ;;
    --strict-sensitive)   SENSITIVE="$2"; shift 2 ;;
    *) err "unknown flag: $1"; exit 2 ;;
  esac
done

[ -n "$ADAPTER" ] || { err "usage: $prog --adapter <name> [--strict-builtin]"; exit 2; }

# SR-81: regex validation. Also enforced schema-side via adapter_name pattern.
if ! printf '%s' "$ADAPTER" | grep -Eq '^[a-z0-9-]{1,64}$'; then
  err "HALT: adapter_name '$ADAPTER' violates SR-81 regex ^[a-z0-9-]{1,64}\$"
  exit 2
fi

# Resolve plugin-root if not set: walk up from this script's directory.
if [ -z "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

CUSTOM_DIR="$PROJECT_ROOT/.gaia/custom/adapters/publish-$ADAPTER"
BUILTIN_DIR="$PLUGIN_ROOT/scripts/adapters/publish-$ADAPTER"

custom_exists=0
builtin_exists=0
[ -d "$CUSTOM_DIR" ] && [ -x "$CUSTOM_DIR/run.sh" ] && custom_exists=1
[ -d "$BUILTIN_DIR" ] && [ -x "$BUILTIN_DIR/run.sh" ] && builtin_exists=1

# Helper: is channel in the sensitive list?
_is_sensitive() {
  local c="$1"
  local IFS=,
  for s in $SENSITIVE; do
    [ "$s" = "$c" ] && return 0
  done
  return 1
}

if [ "$custom_exists" = "1" ]; then
  # Post-resolution containment via physical-path resolution (SR-81 mitigates
  # T-DCH-3). MUST use `pwd -P` (or realpath when available) — the default
  # `cd && pwd` returns the LOGICAL path (Bash `pwd -L` default) which a
  # symlink under .gaia/custom/adapters/ pointing outside the tree would
  # successfully spoof, bypassing the containment check.
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$CUSTOM_DIR" 2>/dev/null)"
    custom_root="$(realpath "$PROJECT_ROOT/.gaia/custom/adapters" 2>/dev/null)"
  else
    resolved="$(cd "$CUSTOM_DIR" 2>/dev/null && pwd -P)"
    custom_root="$(cd "$PROJECT_ROOT/.gaia/custom/adapters" 2>/dev/null && pwd -P)"
  fi
  case "$resolved" in
    "$custom_root"/*) ;;
    *)
      err "HALT: custom adapter resolves outside .gaia/custom/adapters/"
      exit 2
      ;;
  esac

  # SR-82 strict-builtin gate (when shadow + sensitive).
  if [ "$builtin_exists" = "1" ] && [ "$STRICT_BUILTIN" = "1" ] && _is_sensitive "$ADAPTER"; then
    err "HALT: --strict-builtin refuses custom shadow for sensitive channel"
    exit 3
  fi

  # SR-82 shadow warning (only when shadow exists).
  if [ "$builtin_exists" = "1" ]; then
    err "WARN: custom adapter at .gaia/custom/adapters/publish-$ADAPTER/ shadows built-in adapter"
  fi

  printf '%s\n' "$resolved"
  exit 0
fi

if [ "$builtin_exists" = "1" ]; then
  printf '%s\n' "$BUILTIN_DIR"
  exit 0
fi

err "adapter not found (built-in or custom): $ADAPTER"
exit 1
