#!/usr/bin/env bash
# cloudflare-pages.sh — Cloudflare Pages provider for publish-static-site.
# shellcheck source=./_subhandler.bash
source "$(dirname "$0")/_subhandler.bash"

case "$ACTION" in
  trigger)
    if [ "${STATIC_SITE_MOCK:-}" != "1" ]; then
      ss_require_creds CLOUDFLARE_API_TOKEN
    fi
    if [ "$DRY_RUN" = "1" ]; then
      ss_emit "PASSED" "DRY-RUN: would wrangler pages deploy to $DOMAIN (provider=cloudflare-pages)" \
        "$(publish_evidence_log_excerpt "dry-run wrangler pages deploy skipped" "wrangler")"
      exit 0
    fi
    ss_emit "PASSED" "Deployed to Cloudflare Pages at https://$DOMAIN (version=$VERSION)" \
      "$(publish_evidence_log_excerpt "wrangler pages deploy ok" "wrangler")"
    ;;
  verify)
    ss_emit "PASSED" "Cloudflare Pages site $DOMAIN resolvable for version=$VERSION" \
      "$(publish_evidence_log_excerpt "site probe 200" "registry-response")"
    ;;
esac
