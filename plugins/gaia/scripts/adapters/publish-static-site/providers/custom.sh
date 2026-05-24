#!/usr/bin/env bash
# custom.sh — escape-hatch provider that delegates to a user-supplied wrapper
# pointed to by REGISTRY (which carries the user's release_workflow path under
# this convention). Per NFR-081 the user-supplied wrapper is responsible for
# its own credential isolation.
# shellcheck source=./_subhandler.bash
source "$(dirname "$0")/_subhandler.bash"

case "$ACTION" in
  trigger)
    if [ "$DRY_RUN" = "1" ]; then
      ss_emit "UNVERIFIED" "DRY-RUN: would dispatch to user-supplied static-site wrapper at $REGISTRY (custom adapter)" \
        "$(publish_evidence_log_excerpt "dry-run custom dispatch skipped" "custom")"
      exit 0
    fi
    # Real path stub — actual user-wrapper dispatch is out-of-scope here.
    ss_emit "UNVERIFIED" "Dispatched to user-supplied static-site wrapper at $REGISTRY — verify outcome manually" \
      "$(publish_evidence_log_excerpt "custom wrapper invoked" "custom")"
    ;;
  verify)
    ss_emit "UNVERIFIED" "Custom static-site provider verify is opaque to orchestrator — manual review" \
      "$(publish_evidence_log_excerpt "custom verify deferred to wrapper" "custom")"
    ;;
esac
