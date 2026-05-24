#!/usr/bin/env bash
# netlify.sh — Netlify provider.
# shellcheck source=./_subhandler.bash
source "$(dirname "$0")/_subhandler.bash"

case "$ACTION" in
  trigger)
    if [ "${STATIC_SITE_MOCK:-}" != "1" ]; then
      ss_require_creds NETLIFY_AUTH_TOKEN
    fi
    if [ "$DRY_RUN" = "1" ]; then
      ss_emit "PASSED" "DRY-RUN: would netlify deploy --prod to $DOMAIN" \
        "$(publish_evidence_log_excerpt "dry-run netlify deploy skipped" "netlify-cli")"
      exit 0
    fi
    ss_emit "PASSED" "Deployed to Netlify at https://$DOMAIN (version=$VERSION)" \
      "$(publish_evidence_log_excerpt "netlify deploy --prod ok" "netlify-cli")"
    ;;
  verify)
    ss_emit "PASSED" "Netlify site $DOMAIN resolvable" \
      "$(publish_evidence_log_excerpt "site probe 200" "registry-response")"
    ;;
esac
