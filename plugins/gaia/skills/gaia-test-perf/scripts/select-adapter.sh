#!/usr/bin/env bash
# select-adapter.sh — resolve which perf adapter to use (E73-S2).
#
# Precedence (first-match-wins):
#   1. --adapter <name>      — CLI override (highest priority)
#   2. test_execution.perf.adapter from --config <project-config-yaml>
#   3. Default: k6
#
# Stdout: absolute path to the resolved adapter directory under
#         plugins/gaia/scripts/adapters/{name}/
# Exit codes:
#   0 — resolved successfully (adapter dir exists)
#   1 — caller error (bad flag) OR resolved adapter dir does not exist
#
# Usage:
#   select-adapter.sh [--adapter <name>] [--config <project-config-yaml>]
#   select-adapter.sh --help
#
# POSIX discipline: bash 3.2 / macOS-compatible, set -euo pipefail, LC_ALL=C.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-perf/select-adapter.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ADAPTERS_BASE="$PLUGIN_ROOT/scripts/adapters"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

ADAPTER_FLAG=""
CONFIG_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --adapter) ADAPTER_FLAG="$2"; shift 2 ;;
    --config)  CONFIG_PATH="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — resolve perf adapter (CLI > project-config > default).
Usage:
  select-adapter.sh [--adapter <name>] [--config <project-config-yaml>]
EOF
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# 1. CLI override.
if [ -n "$ADAPTER_FLAG" ]; then
  resolved="$ADAPTER_FLAG"
# 2. Project-config lookup.
elif [ -n "$CONFIG_PATH" ] && [ -r "$CONFIG_PATH" ]; then
  # Pure-bash YAML extraction for `test_execution.perf.adapter:` (no yq dep).
  resolved="$(awk '
    /^test_execution[[:space:]]*:/ { in_te=1; next }
    in_te && /^[^[:space:]]/ { in_te=0 }
    in_te && /^[[:space:]]+perf[[:space:]]*:/ { in_perf=1; next }
    in_perf && /^[[:space:]]{0,2}[^[:space:]]/ { in_perf=0 }
    in_perf && /^[[:space:]]+adapter[[:space:]]*:/ {
      sub(/^[[:space:]]+adapter[[:space:]]*:[[:space:]]*/, "")
      gsub(/[[:space:]]/, "")
      print
      exit
    }
  ' "$CONFIG_PATH")"
  if [ -z "$resolved" ]; then
    resolved="k6"
  fi
else
  resolved="k6"
fi

# Validate resolved adapter dir exists.
adapter_dir="$ADAPTERS_BASE/$resolved"
if [ ! -d "$adapter_dir" ]; then
  die "resolved adapter '$resolved' has no directory at $adapter_dir"
fi

printf '%s\n' "$adapter_dir"
exit 0
