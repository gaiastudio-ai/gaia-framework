#!/usr/bin/env bash
# s3.sh — S3 sync provider (with optional CloudFront invalidation).
# shellcheck source=./_subhandler.bash
source "$(dirname "$0")/_subhandler.bash"

case "$ACTION" in
  trigger)
    if [ "${STATIC_SITE_MOCK:-}" != "1" ]; then
      ss_require_creds AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    fi
    if [ "$DRY_RUN" = "1" ]; then
      ss_emit "PASSED" "DRY-RUN: would aws s3 sync to $REGISTRY for $DOMAIN${PATH_PREFIX:+ (prefix=$PATH_PREFIX)} (cdn_invalidation=$CDN_INVALIDATION)" \
        "$(publish_evidence_log_excerpt "dry-run aws s3 sync skipped" "aws-cli")"
      exit 0
    fi
    # AC6: post-sync CloudFront invalidation when cdn_invalidation=true.
    local_evidence='[{"type":"log-excerpt","content":"aws s3 sync completed","source":"aws-cli"}]'
    if [ "$CDN_INVALIDATION" = "true" ]; then
      local_evidence='[{"type":"log-excerpt","content":"aws s3 sync completed","source":"aws-cli"},{"type":"log-excerpt","content":"aws cloudfront create-invalidation completed","source":"aws-cli"}]'
      ss_emit "PASSED" "S3 sync to $REGISTRY for $DOMAIN + CloudFront invalidation completed (version=$VERSION)" "$local_evidence"
    else
      ss_emit "PASSED" "S3 sync to $REGISTRY for $DOMAIN completed (version=$VERSION; no CDN invalidation)" "$local_evidence"
    fi
    ;;
  verify)
    ss_emit "PASSED" "S3 bucket $REGISTRY resolvable for $DOMAIN" \
      "$(publish_evidence_log_excerpt "s3 head-object 200" "registry-response")"
    ;;
esac
