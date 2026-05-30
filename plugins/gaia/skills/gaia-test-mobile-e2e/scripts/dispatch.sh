#!/usr/bin/env bash
# gaia-test-mobile-e2e/dispatch.sh — E74-S10 / AC1, AC3, AC5, AC6.
#
# Resolves the configured device-farm adapter from project-config.yaml,
# checks the test_execution_bridge toggle, dispatches via the upstream
# dispatch-device-farm.sh helper, normalizes per-device output into the
# canonical AC3 schema (via normalize-results.py), and emits a composite
# verdict (via composite-verdict.sh + compose-output.py).
#
# Usage:
#   dispatch.sh --config <project-config.yaml> [--suite <path>] [--device <id>]
#
# Test/CI hook: GAIA_DEVICE_FARM_MOCK is honoured by the upstream dispatcher.
#
# Exit codes:
#   0 — dispatched (or short-circuited with SKIPPED) successfully
#   2 — missing/invalid config (no device_farm adapter)
#   3 — auth env var unset
#   4 — dispatcher timeout

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DISPATCH_DF="$PLUGIN_ROOT/scripts/dispatch-device-farm.sh"
COMPOSITE="$PLUGIN_ROOT/scripts/composite-verdict.sh"
NORMALIZE_PY="$SCRIPT_DIR/normalize-results.py"
COMPOSE_PY="$SCRIPT_DIR/compose-output.py"

CONFIG=""
SUITE=""
DEVICE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --suite)  SUITE="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
    *) printf 'dispatch.sh: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$CONFIG" ] || { printf 'dispatch.sh: --config required\n' >&2; exit 1; }
[ -f "$CONFIG" ] || { printf 'dispatch.sh: config not found: %s\n' "$CONFIG" >&2; exit 1; }

# DEVICE is currently parsed for forward-compat (see argument-hint in
# SKILL.md). Reference it here to keep shellcheck quiet without exporting it
# into the upstream dispatcher's environment.
: "${DEVICE:=}"

# yaml_get_nested — minimal nested-path reader for two-level keys, matching
# the awk style used by E74-S9 dispatch-device-farm.sh and avoiding a yq
# dependency (consistent with E74-S7 manifest tests).
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

# AF-2026-05-17-10: platforms-mobile gate. Defense-in-depth check — skip
# neutrally when no mobile platform is declared in platforms[]. Mirrors
# AF-2026-05-17-9 (compliance.ui_present guard on a11y family) for the
# mobile family. Reads the platforms[] block from the YAML directly via
# awk (parallel to yaml_get_nested but for the top-level list shape).
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
  printf '%s\n' '{"skill":"gaia-test-mobile-e2e","verdict":"SKIPPED","reason":"no_mobile_platform","diagnostic":"platforms[] does not contain ios or android. Mobile e2e tests are not applicable to this project. Declare a mobile platform via /gaia-config-platform add ios|android if mobile testing is required."}'
  exit 0
fi

# AC5 — bridge_enabled=false short-circuits with SKIPPED.
if [ "$BRIDGE_ENABLED" = "false" ]; then
  printf '%s\n' '{"skill":"gaia-test-mobile-e2e","verdict":"SKIPPED","reason":"bridge_disabled","diagnostic":"Test Execution Bridge is disabled. Run /gaia-bridge-enable to allow dispatch."}'
  exit 0
fi

# AC6 — missing adapter fails gracefully with verdict=ERROR.
if [ -z "$ADAPTER" ]; then
  # AF-2026-05-17-10: honest diagnostic. /gaia-config-device-target only edits
  # the device_targets section (per ADR-044) — NOT device_farm.adapter. No
  # /gaia-config-* skill currently edits this key, so the user must edit
  # .gaia/config/project-config.yaml directly.
  printf '%s\n' '{"skill":"gaia-test-mobile-e2e","verdict":"ERROR","reason":"no_device_farm_adapter","diagnostic":"No device-farm adapter configured. Set device_farm.adapter in .gaia/config/project-config.yaml to one of: firebase-test-lab | browserstack | sauce-labs. No section-scoped editor skill currently exists for this key (AF-2026-05-17-10) — edit the YAML directly. The Test Execution Bridge must also be enabled (/gaia-bridge-enable)."}'
  exit 2
fi

# Build a synthetic device-matrix path for the upstream dispatcher (it
# requires the flag; in mock mode the contents are not consulted).
TMP_MATRIX="$(mktemp)"
RAW_OUT="$(mktemp)"
COMPOSITE_TMP="$(mktemp)"
trap 'rm -f "$TMP_MATRIX" "$RAW_OUT" "$COMPOSITE_TMP"' EXIT
printf '%s\n' '{"devices":[]}' > "$TMP_MATRIX"

SUITE="${SUITE:-./tests/e2e}"

set +e
"$DISPATCH_DF" --adapter "$ADAPTER" --suite "$SUITE" --device-matrix "$TMP_MATRIX" >"$RAW_OUT" 2>&1
DF_EXIT=$?
set -e

if [ "$DF_EXIT" -eq 3 ]; then
  printf '%s\n' '{"skill":"gaia-test-mobile-e2e","verdict":"ERROR","reason":"auth_unset","diagnostic":"Device-farm auth env var is unset. Set the credential before dispatching."}'
  exit 3
fi

if [ "$DF_EXIT" -eq 4 ]; then
  printf '{"skill":"gaia-test-mobile-e2e","verdict":"TIMEOUT","reason":"dispatcher_timeout","adapter":"%s"}\n' "$ADAPTER"
  exit 4
fi

# Phase 4 — normalize upstream payload into AC3 canonical per-device schema.
NORMALIZED="$(python3 "$NORMALIZE_PY" "$RAW_OUT")"

# Phase 5 — composite verdict via shared helper.
printf '%s\n' "$NORMALIZED" > "$COMPOSITE_TMP"
COMPOSITE_OUT="$("$COMPOSITE" --results "$COMPOSITE_TMP")"

# Phase 6 — compose final skill output.
python3 "$COMPOSE_PY" "$ADAPTER" "$NORMALIZED" "$COMPOSITE_OUT"
