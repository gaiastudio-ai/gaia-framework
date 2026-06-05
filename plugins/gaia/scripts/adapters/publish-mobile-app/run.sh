#!/usr/bin/env bash
# publish-mobile-app/run.sh — deploy adapter envelope.
# Bounded STUB: emits verdict: UNVERIFIED with next_step: human-review-required.
# App Store Connect + Play Console credential flows are deferred to a follow-up cascade.
# verify_retry_window_seconds: null in adapter-manifest (documented sentinel).

# shellcheck source=../_publish-common.bash
source "$(dirname "$0")/../_publish-common.bash"

publish_parse_common_args "$@"

# Accept platform / store_id / review_required as per the adapter contract.
PLATFORM=""; STORE_ID=""; REVIEW_REQUIRED="true"
i=0
while [ "$i" -lt "${#EXTRA_ARGS[@]}" ]; do
  case "${EXTRA_ARGS[$i]:-}" in
    --platform)        PLATFORM="${EXTRA_ARGS[$((i+1))]:-}"; i=$((i+2)) ;;
    --store-id)        STORE_ID="${EXTRA_ARGS[$((i+1))]:-}"; i=$((i+2)) ;;
    --review-required) REVIEW_REQUIRED="${EXTRA_ARGS[$((i+1))]:-true}"; i=$((i+2)) ;;
    *)                 printf 'publish-mobile-app: unknown flag: %s\n' "${EXTRA_ARGS[$i]:-}" >&2; exit 2 ;;
  esac
done

SUMMARY="STUB: human review required. platform=${PLATFORM:-unspecified} store_id=${STORE_ID:-unspecified} review_required=$REVIEW_REQUIRED. Submit version $VERSION to the appropriate app store console manually. Follow-up cascade will wire automated App Store Connect / Play Console publishes."
EVIDENCE='[{"type":"log-excerpt","content":"adapter returned UNVERIFIED (STUB)","source":"stub","next_step":"human-review-required"}]'

case "$ACTION" in
  trigger|verify)
    jq -n \
      --arg v "UNVERIFIED" \
      --arg ch "mobile-app" \
      --arg act "$ACTION" \
      --arg sum "$SUMMARY" \
      --argjson ev "$EVIDENCE" \
      --arg ns "human-review-required" \
      '{verdict:$v, evidence:$ev, summary:$sum, adapter_metadata:{adapter_name:"publish-mobile-app", adapter_version:"1.0.0", channel:$ch, action:$act}, next_step:$ns}' \
      > "$OUTPUT"
    ;;
esac
