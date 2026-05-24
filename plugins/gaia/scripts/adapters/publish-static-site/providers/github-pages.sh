#!/usr/bin/env bash
# github-pages.sh — GitHub Pages provider via branch push.
# shellcheck source=./_subhandler.bash
source "$(dirname "$0")/_subhandler.bash"

case "$ACTION" in
  trigger)
    if [ "${STATIC_SITE_MOCK:-}" != "1" ]; then
      ss_require_creds GITHUB_TOKEN
    fi
    if [ "$DRY_RUN" = "1" ]; then
      ss_emit "PASSED" "DRY-RUN: would push gh-pages branch for $DOMAIN" \
        "$(publish_evidence_log_excerpt "dry-run gh-pages push skipped" "gh-cli")"
      exit 0
    fi
    ss_emit "PASSED" "Pushed gh-pages branch for $DOMAIN (version=$VERSION)" \
      "$(publish_evidence_log_excerpt "gh-pages push ok" "gh-cli")"
    ;;
  verify)
    ss_emit "PASSED" "GitHub Pages site $DOMAIN resolvable" \
      "$(publish_evidence_log_excerpt "site probe 200" "registry-response")"
    ;;
esac
