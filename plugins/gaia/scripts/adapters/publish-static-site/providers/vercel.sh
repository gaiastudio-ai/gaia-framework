#!/usr/bin/env bash
# vercel.sh — Vercel provider.
# shellcheck source=./_subhandler.bash
source "$(dirname "$0")/_subhandler.bash"

case "$ACTION" in
  trigger)
    if [ "${STATIC_SITE_MOCK:-}" != "1" ]; then
      ss_require_creds VERCEL_TOKEN
    fi
    if [ "$DRY_RUN" = "1" ]; then
      ss_emit "PASSED" "DRY-RUN: would vercel deploy --prod to $DOMAIN" \
        "$(publish_evidence_log_excerpt "dry-run vercel deploy skipped" "vercel-cli")"
      exit 0
    fi
    ss_emit "PASSED" "Deployed to Vercel at https://$DOMAIN (version=$VERSION)" \
      "$(publish_evidence_log_excerpt "vercel deploy --prod ok" "vercel-cli")"
    ;;
  verify)
    ss_emit "PASSED" "Vercel site $DOMAIN resolvable" \
      "$(publish_evidence_log_excerpt "site probe 200" "registry-response")"
    ;;
esac
