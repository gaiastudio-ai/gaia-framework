#!/usr/bin/env bash
# _subhandler.bash — shared helper sourced by each provider sub-handler.
# Reads ACTION/MANIFEST/VERSION/REGISTRY/OUTPUT/DRY_RUN/PROVIDER/DOMAIN/PATH_PREFIX/CDN_INVALIDATION
# from the env (exported by run.sh).

set -euo pipefail
LC_ALL=C
export LC_ALL

# shellcheck source=../../_publish-common.bash
source "$(dirname "$0")/../../_publish-common.bash"

# Emit an ADR-037 envelope for static-site adapter.
# Args: verdict, summary, [evidence-json-array]
ss_emit() {
  local verdict="$1" summary="$2" evidence="${3:-[]}"
  jq -n \
    --arg v "$verdict" \
    --arg ch "static-site" \
    --arg act "$ACTION" \
    --arg sum "$summary" \
    --arg prov "$PROVIDER" \
    --argjson ev "$evidence" \
    '{verdict:$v, evidence:$ev, summary:$sum, adapter_metadata:{adapter_name:"publish-static-site", adapter_version:"1.0.0", channel:$ch, action:$act, provider:$prov}}' \
    > "$OUTPUT"
}

# Check credential env vars; FAIL if missing (NFR-081).
# Args: pass each required env var name as positional arg.
ss_require_creds() {
  local missing=""
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing="$missing$var "
    fi
  done
  if [ -n "$missing" ]; then
    ss_emit "FAILED" \
      "static-site/$PROVIDER: credential(s) missing per NFR-081: ${missing% }" \
      "$(publish_evidence_log_excerpt "missing env: ${missing% }" "env")"
    exit 0
  fi
}
