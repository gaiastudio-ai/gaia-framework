#!/usr/bin/env bash
# health-check.sh — /gaia-deploy Pattern A post-deploy health-check.
#
# Default behavior (mode=poll): polls a target URL until HTTP 2xx or timeout.
# Skip behavior  (mode=skip):  bypasses the poll loop entirely and records an
#                              audit-trail evidence entry. Required for projects
#                              without a reachable health-check endpoint
#                              (e.g., marketplace-published plugins).
#
# Modes:
#   poll (default) — existing behavior; --url is required.
#   skip           — emit `{status: "skipped", mode: "skip", reason: "configured skip"}`
#                    to evidence and exit 0. --url is NOT required.
#
# Test seam: GAIA_DEPLOY_HEALTH_FAKE_RC overrides the curl call entirely:
#   0 → first poll succeeds; 1 → never succeeds (timeout path).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/health-check.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

URL=""
TIMEOUT="60"
OUTPUT_DIR=""
MODE="poll"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — post-deploy health-check.
Usage: $SCRIPT_NAME [--mode <poll|skip>] [--url <url>] [--timeout <secs>] --output-dir <dir>

Modes:
  poll (default) — poll <url> until HTTP 2xx or timeout
  skip           — bypass the poll loop and record an audit-trail evidence entry
EOF
      exit 0 ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

# --- Mode validation -------------------------------------------------------
case "$MODE" in
  poll|skip) ;;
  *)
    log "invalid health_check.mode: '$MODE' — valid options: poll, skip"
    log "  remediation: set health_check.mode in project-config.yaml to 'poll' (default) or 'skip'"
    exit 2
    ;;
esac

if [ -z "$OUTPUT_DIR" ]; then
  log "usage: [--mode <poll|skip>] [--url <url>] [--timeout <secs>] --output-dir <dir>"
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/health-check.json"

# --- Skip-mode short-circuit -----------------------------------------------
if [ "$MODE" = "skip" ]; then
  jq -n \
    '{status: "skipped", mode: "skip", reason: "configured skip"}' \
    > "$RESULT_FILE"
  log "health-check: SKIPPED (mode=skip, reason=configured skip)"
  exit 0
fi

# --- Poll mode requires --url (preserves prior contract) -----------------
if [ -z "$URL" ]; then
  log "usage: --url <url> [--timeout <secs>] --output-dir <dir> (required when --mode poll)"
  exit 2
fi

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
