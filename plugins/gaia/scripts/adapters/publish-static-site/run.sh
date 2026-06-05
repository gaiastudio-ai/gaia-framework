#!/usr/bin/env bash
# publish-static-site/run.sh — Outer case-dispatch to per-provider sub-handlers under providers/.

# shellcheck source=../_publish-common.bash
source "$(dirname "$0")/../_publish-common.bash"

# Custom arg parse — accepts --provider, --domain, --path-prefix, --cdn-invalidation.
ACTION=""; MANIFEST=""; VERSION=""; REGISTRY=""; OUTPUT=""; DRY_RUN=0
PROVIDER=""; DOMAIN=""; PATH_PREFIX=""; CDN_INVALIDATION="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --action)             ACTION="$2"; shift 2 ;;
    --manifest)           MANIFEST="$2"; shift 2 ;;
    --version)            VERSION="$2"; shift 2 ;;
    --registry)           REGISTRY="$2"; shift 2 ;;
    --output)             OUTPUT="$2"; shift 2 ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --provider)           PROVIDER="$2"; shift 2 ;;
    --domain)             DOMAIN="$2"; shift 2 ;;
    --path-prefix)        PATH_PREFIX="$2"; shift 2 ;;
    --cdn-invalidation)   CDN_INVALIDATION="$2"; shift 2 ;;
    *) printf 'publish-static-site: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$ACTION" in trigger|verify) ;; *) printf 'publish-static-site: --action must be trigger|verify\n' >&2; exit 2 ;; esac
[ -n "$OUTPUT" ] || { printf 'publish-static-site: --output required\n' >&2; exit 2; }
[ -n "$VERSION" ] || { printf 'publish-static-site: --version required\n' >&2; exit 2; }

# Closed-enum rejection.
case "$PROVIDER" in
  cloudflare-pages|s3|netlify|vercel|github-pages|custom) ;;
  *)
    printf "publish-static-site: unknown static-site provider '%s' — must be one of {cloudflare-pages, s3, netlify, vercel, github-pages, custom}\n" "$PROVIDER" >&2
    exit 2
    ;;
esac

# Dispatch to sub-handler. Export common state for sub-handler.
export ACTION MANIFEST VERSION REGISTRY OUTPUT DRY_RUN PROVIDER DOMAIN PATH_PREFIX CDN_INVALIDATION

SUBHANDLER="$(dirname "$0")/providers/${PROVIDER}.sh"
if [ ! -x "$SUBHANDLER" ]; then
  publish_write_envelope "FAILED" "static-site" "$ACTION" \
    "static-site provider sub-handler not found: $SUBHANDLER" \
    "$(publish_evidence_log_excerpt "sub-handler missing for provider=$PROVIDER" "fs")"
  exit 0
fi

exec "$SUBHANDLER"
