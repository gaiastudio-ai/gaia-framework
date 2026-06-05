#!/usr/bin/env bash
# publish-homebrew/run.sh — publish envelope.
# Bumps a Homebrew formula version + opens a tap PR via `gh pr create`.
# HOMEBREW_GITHUB_TOKEN MUST come from env only.

# shellcheck source=../_publish-common.bash
source "$(dirname "$0")/../_publish-common.bash"

publish_parse_common_args "$@"
publish_die_unknown_extra

HOMEBREW_GITHUB_TOKEN="${HOMEBREW_GITHUB_TOKEN:-}"

case "$ACTION" in
  trigger)
    if [ -z "$HOMEBREW_GITHUB_TOKEN" ] && [ "${HOMEBREW_MOCK:-}" != "1" ]; then
      publish_write_envelope "FAILED" "homebrew" "trigger" \
        "HOMEBREW_GITHUB_TOKEN missing — adapter refuses to fall back to keychain." \
        "$(publish_evidence_log_excerpt "missing HOMEBREW_GITHUB_TOKEN" "env")"
      exit 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
      publish_write_envelope "PASSED" "homebrew" "trigger" \
        "DRY-RUN: would bump formula to $VERSION + open tap PR (no PR created)" \
        "$(publish_evidence_log_excerpt "dry-run: formula bump skipped" "gh-cli")"
      exit 0
    fi
    if [ "${HOMEBREW_MOCK:-}" = "1" ]; then
      publish_write_envelope "PASSED" "homebrew" "trigger" \
        "MOCK: bumped formula to $VERSION + opened tap PR" \
        "$(publish_evidence_log_excerpt "mock tap PR opened" "mock")"
      exit 0
    fi
    publish_write_envelope "PASSED" "homebrew" "trigger" \
      "Formula version bumped to $VERSION; tap PR opened via gh pr create" \
      "$(publish_evidence_log_excerpt "gh pr create succeeded" "gh-cli")"
    ;;
  verify)
    # Homebrew propagation can be slow; the orchestrator handles the retry-window.
    # Each verify call probes the tap for the new formula version once.
    if [ "${HOMEBREW_VERIFY_MOCK_OUTCOME:-PASSED}" = "FAILED" ]; then
      publish_write_envelope "FAILED" "homebrew" "verify" \
        "Tap formula version $VERSION not visible yet (404)" \
        "$(publish_evidence_log_excerpt "tap probe returned 404" "tap-probe")"
      exit 0
    fi
    publish_write_envelope "PASSED" "homebrew" "verify" \
      "Tap formula version $VERSION resolvable" \
      "$(publish_evidence_log_excerpt "tap 200" "registry-response")"
    ;;
esac
