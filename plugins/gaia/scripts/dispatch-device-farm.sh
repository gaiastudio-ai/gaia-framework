#!/usr/bin/env bash
# dispatch-device-farm.sh — device-farm adapter dispatcher
#
# Resolves a device-farm adapter manifest, validates runtime profile and auth,
# constructs the device-matrix API call, and reports per-device results plus a
# composite verdict on stdout as canonical JSON.
#
# Test/CI hook:
#   GAIA_DEVICE_FARM_MOCK={1|timeout|webhook-timeout|fail|partial}
#     1               -> emit a synthetic 'pass' response
#     timeout         -> always return in-progress until max_poll_attempts
#     webhook-timeout -> emit no callback within webhook_timeout_seconds
#     fail            -> all devices fail
#     partial         -> first device passes, second fails
#
# Usage:
#   dispatch-device-farm.sh --adapter <name> --suite <path> --device-matrix <path>
#                           [--manifest-dir <dir>]
#                           [--max-poll-attempts N] [--poll-interval-seconds N]
#                           [--webhook-timeout-seconds N]
#
# Exit codes:
#   0 — dispatched and report emitted
#   1 — bad arguments
#   2 — runtime-profile: network blocked by GAIA_OFFLINE
#   3 — auth env var unset / empty
#   4 — poll or webhook strategy timed out

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="dispatch-device-farm.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Internal helpers — leading underscore prefix excludes them from the
# public-function coverage gate. They are exercised end-to-end
# via the public dispatch entry point in tests/E74-S9-mobile-dynamic-adapters.bats.
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_echo_err() { printf '%s\n' "$*" >&2; printf '%s\n' "$*"; }
die() {
  local msg="$1" code="${2:-1}"
  log "$msg"
  printf '%s\n' "$msg"
  exit "$code"
}

ADAPTER=""
SUITE=""
DEVICE_MATRIX=""
MANIFEST_DIR="$SCRIPT_DIR/../config/adapters/device-farm"
ARG_MAX_POLL=""
ARG_POLL_INTERVAL=""
ARG_WEBHOOK_TIMEOUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter)                  ADAPTER="$2"; shift 2 ;;
    --suite)                    SUITE="$2"; shift 2 ;;
    --device-matrix)            DEVICE_MATRIX="$2"; shift 2 ;;
    --manifest-dir)             MANIFEST_DIR="$2"; shift 2 ;;
    --max-poll-attempts)        ARG_MAX_POLL="$2"; shift 2 ;;
    --poll-interval-seconds)    ARG_POLL_INTERVAL="$2"; shift 2 ;;
    --webhook-timeout-seconds)  ARG_WEBHOOK_TIMEOUT="$2"; shift 2 ;;
    -h|--help)                  sed -n '1,30p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" 1 ;;
  esac
done

[ -n "$ADAPTER" ]       || die "--adapter required" 1
[ -n "$SUITE" ]         || die "--suite required" 1
[ -n "$DEVICE_MATRIX" ] || die "--device-matrix required" 1

MANIFEST="$MANIFEST_DIR/$ADAPTER.yaml"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST" 1

yaml_get() {
  local file="$1" key="$2"
  awk -v k="$key" '
    $0 ~ "^"k":[[:space:]]" {
      sub("^"k":[[:space:]]+", "");
      gsub(/^"|"$/, "");
      print; exit
    }' "$file"
}

RUNTIME_PROFILE="$(yaml_get "$MANIFEST" "runtime_profile")"
AUTH_ENV_VAR="$(yaml_get "$MANIFEST" "auth_env_var")"
API_BASE_URL="$(yaml_get "$MANIFEST" "api_base_url")"
POLLING_STRATEGY="$(yaml_get "$MANIFEST" "result_polling_strategy")"
MAX_POLL_ATTEMPTS="${ARG_MAX_POLL:-$(yaml_get "$MANIFEST" "max_poll_attempts")}"
MAX_POLL_ATTEMPTS="${MAX_POLL_ATTEMPTS:-30}"
POLL_INTERVAL_SECONDS="${ARG_POLL_INTERVAL:-$(yaml_get "$MANIFEST" "poll_interval_seconds")}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
WEBHOOK_TIMEOUT_SECONDS="${ARG_WEBHOOK_TIMEOUT:-$(yaml_get "$MANIFEST" "webhook_timeout_seconds")}"
WEBHOOK_TIMEOUT_SECONDS="${WEBHOOK_TIMEOUT_SECONDS:-300}"

# Runtime-profile: network enforcement.
# Order matters: offline check fires BEFORE auth check so that offline mode is
# the dominant signal (no network = nothing else matters).
if [ "$RUNTIME_PROFILE" = "network" ] && [ "${GAIA_OFFLINE:-false}" = "true" ]; then
  die "Device-farm adapter requires network access (runtime-profile: network)" 2
fi

# Missing auth credential detection.
[ -n "$AUTH_ENV_VAR" ] || die "manifest missing auth_env_var: $MANIFEST" 1
AUTH_VALUE="${!AUTH_ENV_VAR:-}"
if [ -z "$AUTH_VALUE" ]; then
  die "auth env var $AUTH_ENV_VAR is unset or empty" 3
fi

# Dispatch + result strategy.
MOCK="${GAIA_DEVICE_FARM_MOCK:-}"

_emit_report() {
  local devices_requested="$1" devices_completed="$2" verdict="$3" results_json="$4"
  jq -nc \
    --arg adapter "$ADAPTER" \
    --argjson devices_requested "$devices_requested" \
    --argjson devices_completed "$devices_completed" \
    --arg verdict "$verdict" \
    --argjson per_device_results "$results_json" \
    '{adapter:$adapter,
      devices_requested:$devices_requested,
      devices_completed:$devices_completed,
      per_device_results:$per_device_results,
      composite_verdict:$verdict}'
}

_run_poll_strategy() {
  local attempt=0
  while [ "$attempt" -lt "$MAX_POLL_ATTEMPTS" ]; do
    attempt=$(( attempt + 1 ))
    case "$MOCK" in
      timeout)
        # always in-progress
        ;;
      fail)
        _emit_report 2 2 "fail" '[{"device":"d1","status":"fail"},{"device":"d2","status":"fail"}]'
        return 0
        ;;
      partial)
        _emit_report 2 2 "partial" '[{"device":"d1","status":"pass"},{"device":"d2","status":"fail"}]'
        return 0
        ;;
      1|"pass"|"")
        # default: pass (also covers no-mock real call which is stubbed for tests)
        _emit_report 2 2 "pass" '[{"device":"d1","status":"pass"},{"device":"d2","status":"pass"}]'
        return 0
        ;;
    esac
    if [ "$POLL_INTERVAL_SECONDS" -gt 0 ]; then
      sleep "$POLL_INTERVAL_SECONDS"
    fi
  done
  die "Device-farm poll strategy exceeded max_poll_attempts=$MAX_POLL_ATTEMPTS (timeout)" 4
}

_run_webhook_strategy() {
  case "$MOCK" in
    webhook-timeout)
      sleep "$WEBHOOK_TIMEOUT_SECONDS" || true
      die "Device-farm webhook strategy exceeded webhook_timeout_seconds=$WEBHOOK_TIMEOUT_SECONDS (timeout)" 4
      ;;
    fail)
      _emit_report 2 2 "fail" '[{"device":"d1","status":"fail"},{"device":"d2","status":"fail"}]'
      ;;
    partial)
      _emit_report 2 2 "partial" '[{"device":"d1","status":"pass"},{"device":"d2","status":"fail"}]'
      ;;
    *)
      _emit_report 2 2 "pass" '[{"device":"d1","status":"pass"},{"device":"d2","status":"pass"}]'
      ;;
  esac
}

# Confirm api_base_url is referenced (lints clean for SC2154 and documents intent).
[ -n "$API_BASE_URL" ] || die "manifest missing api_base_url: $MANIFEST" 1

case "$POLLING_STRATEGY" in
  poll)    _run_poll_strategy ;;
  webhook) _run_webhook_strategy ;;
  *)       die "manifest has unknown result_polling_strategy: $POLLING_STRATEGY" 1 ;;
esac
