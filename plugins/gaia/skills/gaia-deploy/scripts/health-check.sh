#!/usr/bin/env bash
# health-check.sh — /gaia-deploy Pattern A post-deploy health-check (E73-S5, AC4).
#
# Polls a target URL until HTTP 2xx or timeout. Writes
# `health-check.json` to the output directory.
#
# Test seam: GAIA_DEPLOY_HEALTH_FAKE_RC overrides the curl call entirely:
#   0 → first poll succeeds; 1 → never succeeds (timeout path).
#
# Refs: ADR-080, AC4.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/health-check.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

URL=""
TIMEOUT="60"
OUTPUT_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — health-check poll (E73-S5, AC4).
Usage: $SCRIPT_NAME --url <url> --timeout <secs> --output-dir <dir>
EOF
      exit 0 ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$URL" ] || [ -z "$OUTPUT_DIR" ]; then
  log "usage: --url <url> [--timeout <secs>] --output-dir <dir>"
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/health-check.json"

start_epoch="$(date +%s)"
attempt=0
interval=2
max_interval=10
status="timeout"

# Poll loop with exponential backoff.
while :; do
  attempt=$((attempt + 1))
  now_epoch="$(date +%s)"
  elapsed=$((now_epoch - start_epoch))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    break
  fi

  rc=1
  if [ -n "${GAIA_DEPLOY_HEALTH_FAKE_RC:-}" ]; then
    rc="$GAIA_DEPLOY_HEALTH_FAKE_RC"
  else
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -o /dev/null --max-time "$interval" "$URL" >/dev/null 2>&1 && rc=0 || rc=$?
    else
      log "BLOCKED: curl not on PATH"
      rc=127
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    status="passed"
    break
  fi

  # Backoff with cap. Wait up to (TIMEOUT - elapsed) - never overshoot.
  remaining=$((TIMEOUT - elapsed))
  wait_secs="$interval"
  if [ "$wait_secs" -gt "$remaining" ]; then
    wait_secs="$remaining"
  fi
  if [ "$wait_secs" -gt 0 ]; then
    sleep "$wait_secs"
  fi
  interval=$((interval * 2))
  if [ "$interval" -gt "$max_interval" ]; then
    interval="$max_interval"
  fi
done

end_epoch="$(date +%s)"
duration=$((end_epoch - start_epoch))

# Write result JSON.
jq -n \
  --arg status "$status" \
  --arg url "$URL" \
  --argjson timeout "$TIMEOUT" \
  --argjson duration "$duration" \
  --argjson attempts "$attempt" \
  '{status: $status, url: $url, timeout_seconds: $timeout, duration_seconds: $duration, attempts: $attempts}' \
  > "$RESULT_FILE"

if [ "$status" = "passed" ]; then
  log "health-check: PASSED ($attempt attempts, ${duration}s)"
  exit 0
fi

log "BLOCKED: health-check timed out after ${duration}s ($attempt attempts)"
log "  remediation: verify the deployed service is up, increase deployment.health_check.timeout_seconds, or check ingress / DNS"
exit 1
