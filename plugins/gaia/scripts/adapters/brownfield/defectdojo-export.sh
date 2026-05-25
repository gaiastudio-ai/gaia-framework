#!/usr/bin/env bash
# adapters/brownfield/defectdojo-export.sh — E104-S4 opt-in DefectDojo export.
#
# POSTs the merged SARIF (E104-S4 sarif-merge.sh output) to a configured
# DefectDojo instance — ONLY when explicitly enabled. DefectDojo requires a
# Django + PostgreSQL + Celery + Redis stack, so it is too heavy as a default
# brownfield dependency and is gated opt-in (AC4).
#
# Usage: defectdojo-export.sh <merged-sarif-path>
#
# Contract:
#   - Disabled by default (GAIA_BROWNFIELD_DEFECTDOJO_ENABLED != true) -> INFO
#     skip, exit 0, ZERO network calls, no token requirement.
#   - Enabled but missing api_url/api_token/engagement_id -> WARN + skip (no
#     failure) rather than abort Phase 7.
#   - Fire-and-forget: no synchronous wait on DefectDojo response beyond the
#     POST; success on 2xx. Idempotent via engagement_id + scan_type.
#
# Config (resolved by /gaia-brownfield, exported as env):
#   GAIA_BROWNFIELD_DEFECTDOJO_ENABLED        bool (default false)
#   GAIA_BROWNFIELD_DEFECTDOJO_API_URL        DefectDojo import endpoint
#   GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN      API token (env-var ref, never literal)
#   GAIA_BROWNFIELD_DEFECTDOJO_ENGAGEMENT_ID  engagement id for dedup idempotency

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/defectdojo-export.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }

MERGED_SARIF="${1:-}"

ENABLED="${GAIA_BROWNFIELD_DEFECTDOJO_ENABLED:-false}"
if [ "$ENABLED" != "true" ]; then
  log_info "DefectDojo export skipped (disabled by default — opt-in via brownfield.defectdojo_enabled); no network calls"
  exit 0
fi

API_URL="${GAIA_BROWNFIELD_DEFECTDOJO_API_URL:-}"
API_TOKEN="${GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN:-}"
ENGAGEMENT_ID="${GAIA_BROWNFIELD_DEFECTDOJO_ENGAGEMENT_ID:-}"

if [ -z "$API_URL" ] || [ -z "$API_TOKEN" ] || [ -z "$ENGAGEMENT_ID" ]; then
  log_warn "DefectDojo enabled but missing config (api_url/api_token/engagement_id); skipping export (no failure)"
  exit 0
fi

if [ -z "$MERGED_SARIF" ] || [ ! -f "$MERGED_SARIF" ]; then
  log_warn "merged SARIF not found at '$MERGED_SARIF'; skipping DefectDojo export"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  log_warn "curl not found on PATH; skipping DefectDojo export (graceful degrade)"
  exit 0
fi

# Fire-and-forget POST. DefectDojo's reimport-scan API dedups via
# engagement_id + scan_type, so repeated runs are idempotent.
log_info "exporting merged SARIF to DefectDojo (engagement_id=$ENGAGEMENT_ID)"
if curl -sS -X POST "$API_URL" \
     -H "Authorization: Token $API_TOKEN" \
     -F "scan_type=SARIF" \
     -F "engagement=$ENGAGEMENT_ID" \
     -F "file=@$MERGED_SARIF" >/dev/null 2>&1; then
  log_info "DefectDojo export POST completed"
else
  log_warn "DefectDojo export POST failed (fire-and-forget — Phase 7 continues)"
fi

exit 0
