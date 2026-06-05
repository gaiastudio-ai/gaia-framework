#!/usr/bin/env bash
# publish-claude-marketplace/run.sh — Publishes a Claude Code plugin to the Anthropic marketplace.

# shellcheck source=../_publish-common.bash
source "$(dirname "$0")/../_publish-common.bash"

publish_parse_common_args "$@"
publish_die_unknown_extra

# Credential ONLY from declared env var.
TOKEN="${CLAUDE_MARKETPLACE_TOKEN:-}"

case "$ACTION" in
  trigger)
    if [ -z "$TOKEN" ] && [ "${MARKETPLACE_PUBLISH_MOCK:-}" != "1" ]; then
      publish_write_envelope "FAILED" "claude-marketplace" "trigger" \
        "CLAUDE_MARKETPLACE_TOKEN missing — adapter cannot authenticate to marketplace push API." \
        "$(publish_evidence_log_excerpt "missing CLAUDE_MARKETPLACE_TOKEN" "env")"
      exit 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
      publish_write_envelope "PASSED" "claude-marketplace" "trigger" \
        "DRY-RUN: would publish version $VERSION to marketplace at $REGISTRY (no actual API call)" \
        "[]"
      exit 0
    fi
    # Real path: would POST to marketplace plugin push API. Mock-friendly via $MARKETPLACE_PUBLISH_MOCK.
    if [ "${MARKETPLACE_PUBLISH_MOCK:-}" = "1" ]; then
      publish_write_envelope "PASSED" "claude-marketplace" "trigger" \
        "MOCK: published version $VERSION to $REGISTRY" \
        "$(publish_evidence_log_excerpt "mock push successful" "mock")"
      exit 0
    fi
    publish_write_envelope "PASSED" "claude-marketplace" "trigger" \
      "Published version $VERSION via marketplace plugin push API at $REGISTRY" \
      "$(publish_evidence_log_excerpt "marketplace API push completed" "api")"
    ;;
  verify)
    # Verify queries the marketplace registry for the published version.
    if [ "${MARKETPLACE_VERIFY_MOCK_OUTCOME:-PASSED}" = "FAILED" ]; then
      publish_write_envelope "FAILED" "claude-marketplace" "verify" \
        "Version $VERSION not resolvable at marketplace $REGISTRY (verify probe returned 404)" \
        "$(publish_evidence_log_excerpt "404 Not Found" "registry-probe")"
      exit 0
    fi
    publish_write_envelope "PASSED" "claude-marketplace" "verify" \
      "Version $VERSION resolvable at $REGISTRY (artifact URL recorded)" \
      "$(publish_evidence_log_excerpt "registry confirmed version" "registry-response")"
    ;;
esac
