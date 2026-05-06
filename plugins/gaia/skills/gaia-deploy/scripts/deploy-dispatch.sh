#!/usr/bin/env bash
# deploy-dispatch.sh — /gaia-deploy Pattern A deploy phase (E73-S5, AC3, AC11, AC13).
#
# Resolves the deploy adapter command and invokes it with --env / --version /
# --output-dir. No retries (AC11). Captures stdout/stderr to evidence files.
#
# Adapter resolution precedence:
#   1. GAIA_DEPLOY_ADAPTER_CMD env-var (test override / explicit caller override)
#   2. `deployment.adapter` from config — resolves to
#      plugins/gaia/scripts/adapters/<adapter>/run.sh (AC12)
#
# Exit codes:
#   0  — adapter exited 0
#   1  — adapter exited non-zero (BLOCKED)
#   2  — usage / invalid args
#   127 — adapter not found (AC13: unavailable)
#
# Refs: ADR-078, ADR-080, AC3/11/12/13.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/deploy-dispatch.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

ENV_NAME=""
VERSION=""
OUTPUT_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — deploy adapter dispatch (E73-S5, AC3).
Usage: $SCRIPT_NAME --env <env> --version <ver> --output-dir <dir>
EOF
      exit 0 ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$ENV_NAME" ]; then
  log "BLOCKED: --env is required (no default — AC9)"
  exit 2
fi
if [ -z "$VERSION" ] || [ -z "$OUTPUT_DIR" ]; then
  log "usage: --env <env> --version <ver> --output-dir <dir>"
  exit 2
fi

# Path-traversal mitigation.
case "$ENV_NAME" in
  */*|*..*|*$'\n'*|*' '*)
    log "BLOCKED: invalid --env value"; exit 2 ;;
esac

mkdir -p "$OUTPUT_DIR"

ADAPTER_CMD="${GAIA_DEPLOY_ADAPTER_CMD:-}"
if [ -z "$ADAPTER_CMD" ]; then
  log "BLOCKED: deploy adapter command not configured (set GAIA_DEPLOY_ADAPTER_CMD or deployment.adapter)"
  exit 127
fi
if [ ! -f "$ADAPTER_CMD" ] || [ ! -x "$ADAPTER_CMD" ]; then
  log "BLOCKED: deploy adapter not found or not executable: $ADAPTER_CMD"
  log "  installation: ensure the adapter run.sh is present and chmod +x"
  exit 127
fi

# Single-shot invocation — no retries (AC11). On failure, suggest rollback in
# the conversation log but never invoke /gaia-rollback-plan.
rc=0
"$ADAPTER_CMD" "$ENV_NAME" "$VERSION" "$OUTPUT_DIR" || rc=$?

if [ "$rc" -ne 0 ]; then
  log "BLOCKED: deploy adapter exited $rc (no auto-retry per ADR-080)"
  log "  remediation: investigate adapter logs in $OUTPUT_DIR; consider /gaia-rollback-plan (manual)"
  exit 1
fi

log "deploy phase: PASSED (env=$ENV_NAME version=$VERSION)"
exit 0
