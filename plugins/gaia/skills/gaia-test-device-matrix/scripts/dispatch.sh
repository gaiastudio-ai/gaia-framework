#!/usr/bin/env bash
# gaia-test-device-matrix/dispatch.sh — E74-S10 / AC2, AC3, AC4, AC5, AC6.
#
# Expands device_targets into a cartesian product, dispatches via the upstream
# device-farm dispatcher, normalizes per-device results onto the expanded
# matrix axes, and emits a composite verdict.
#
# Usage: dispatch.sh --config <project-config.yaml> [--platform <ios|android|all>] [--filter <regex>]

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXPAND="$SCRIPT_DIR/expand-matrix.sh"
NORMALIZE_PY="$SCRIPT_DIR/normalize-results.py"
COMPOSE_PY="$SCRIPT_DIR/compose-output.py"
DISPATCH_DF="$PLUGIN_ROOT/scripts/dispatch-device-farm.sh"
COMPOSITE="$PLUGIN_ROOT/scripts/composite-verdict.sh"

CONFIG=""; PLATFORM=""; FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)   CONFIG="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --filter)   FILTER="$2"; shift 2 ;;
    -h|--help)  sed -n '1,15p' "$0"; exit 0 ;;
    *) printf 'dispatch.sh: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$CONFIG" ] || { printf 'dispatch.sh: --config required\n' >&2; exit 1; }
[ -f "$CONFIG" ] || { printf 'dispatch.sh: config not found: %s\n' "$CONFIG" >&2; exit 1; }

# PLATFORM and FILTER are currently parsed for forward-compat (see
# argument-hint in SKILL.md). Reference them here to keep shellcheck quiet
# without yet wiring them through to the dispatcher.
: "${PLATFORM:=}" "${FILTER:=}"

yaml_get_nested() {
  local file="$1" outer="$2" inner="$3"
  awk -v o="$outer" -v i="$inner" '
    BEGIN { in_block=0 }
    /^[^[:space:]#]/ {
      if ($0 ~ "^"o":") { in_block=1; next }
      else { in_block=0 }
    }
    in_block && $0 ~ "^[[:space:]]+"i":" {
      sub("^[[:space:]]+"i":[[:space:]]+", "");
      gsub(/^"|"$/, "");
      gsub(/[[:space:]]+$/, "");
      print; exit
    }' "$file"
}

ADAPTER="$(yaml_get_nested "$CONFIG" "device_farm" "adapter")"
BRIDGE_ENABLED="$(yaml_get_nested "$CONFIG" "test_execution_bridge" "bridge_enabled")"

# AF-2026-05-17-10: platforms-mobile gate. Defense-in-depth — skip
# neutrally when no mobile platform is declared. Mirrors AF-2026-05-17-9.
PLATFORMS_LIST=$(awk '
  /^platforms:[[:space:]]*$/ { flag=1; next }
  flag && /^[a-z][a-z_]*:/ { flag=0 }
  flag && /^[[:space:]]+-[[:space:]]+/ {
    sub(/^[[:space:]]+-[[:space:]]+/, "")
    gsub(/[[:space:]]+$/, "")
    gsub(/^"|"$/, "")
    print
  }
' "$CONFIG" | tr '\n' ',')
if ! printf '%s' "$PLATFORMS_LIST" | grep -qE '(^|,)(ios|android)(,|$)'; then
  printf '%s\n' '{"skill":"gaia-test-device-matrix","verdict":"SKIPPED","reason":"no_mobile_platform","diagnostic":"platforms[] does not contain ios or android. Device-matrix expansion is not applicable to this project. Declare a mobile platform via /gaia-config-platform add ios|android if mobile testing is required."}'
  exit 0
fi

if [ "$BRIDGE_ENABLED" = "false" ]; then
  printf '%s\n' '{"skill":"gaia-test-device-matrix","verdict":"SKIPPED","reason":"bridge_disabled","diagnostic":"Test Execution Bridge is disabled. Run /gaia-bridge-enable to allow dispatch."}'
  exit 0
fi

if [ -z "$ADAPTER" ]; then
  # AF-2026-05-17-10: honest diagnostic — see mobile-e2e dispatch.sh for rationale.
  printf '%s\n' '{"skill":"gaia-test-device-matrix","verdict":"ERROR","reason":"no_device_farm_adapter","diagnostic":"No device-farm adapter configured. Set device_farm.adapter in .gaia/config/project-config.yaml to one of: firebase-test-lab | browserstack | sauce-labs. No section-scoped editor skill currently exists for this key (AF-2026-05-17-10) — edit the YAML directly. The Test Execution Bridge must also be enabled (/gaia-bridge-enable)."}'
  exit 2
fi

# Phase 1 — expand the matrix.
EXPANDED="$("$EXPAND" --config "$CONFIG")"

# Phase 2 — dispatch via upstream helper.
TMP_MATRIX="$(mktemp)"
RAW_OUT="$(mktemp)"
COMPOSITE_TMP="$(mktemp)"
trap 'rm -f "$TMP_MATRIX" "$RAW_OUT" "$COMPOSITE_TMP"' EXIT
printf '%s\n' "$EXPANDED" > "$TMP_MATRIX"

set +e
"$DISPATCH_DF" --adapter "$ADAPTER" --suite "./tests/e2e" --device-matrix "$TMP_MATRIX" >"$RAW_OUT" 2>&1
DF_EXIT=$?
set -e

if [ "$DF_EXIT" -eq 3 ]; then
  printf '{"skill":"gaia-test-device-matrix","verdict":"ERROR","reason":"auth_unset","adapter":"%s"}\n' "$ADAPTER"
  exit 3
fi

# Phase 3 — normalize: project axes onto each upstream row (round-robin if
# upstream returned fewer rows than matrix entries; common in mock mode).
NORMALIZED="$(python3 "$NORMALIZE_PY" "$RAW_OUT" "$EXPANDED")"

# Phase 4 — composite verdict.
printf '%s\n' "$NORMALIZED" > "$COMPOSITE_TMP"
COMPOSITE_OUT="$("$COMPOSITE" --results "$COMPOSITE_TMP")"

# Phase 5 — compose final skill output.
python3 "$COMPOSE_PY" "$ADAPTER" "$NORMALIZED" "$COMPOSITE_OUT"
