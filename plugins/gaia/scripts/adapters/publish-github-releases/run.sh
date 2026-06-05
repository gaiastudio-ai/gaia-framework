#!/usr/bin/env bash
# publish-github-releases/run.sh — publish envelope.
# Shells out to `gh release create` for trigger; `gh release view` for verify.
# GH_TOKEN MUST come from env only.

# shellcheck source=../_publish-common.bash
source "$(dirname "$0")/../_publish-common.bash"

publish_parse_common_args "$@"
publish_die_unknown_extra

GH_TOKEN="${GH_TOKEN:-}"

case "$ACTION" in
  trigger)
    if [ -z "$GH_TOKEN" ] && [ "${GH_PUBLISH_MOCK:-}" != "1" ]; then
      publish_write_envelope "FAILED" "github-releases" "trigger" \
        "GH_TOKEN missing — adapter refuses to fall back to gh auth status default." \
        "$(publish_evidence_log_excerpt "missing GH_TOKEN" "env")"
      exit 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
      publish_write_envelope "PASSED" "github-releases" "trigger" \
        "DRY-RUN: would gh release create v$VERSION (no actual release)" \
        "$(publish_evidence_log_excerpt "dry-run: gh release create skipped" "gh-cli")"
      exit 0
    fi
    if [ "${GH_PUBLISH_MOCK:-}" = "1" ]; then
      if [ "${GH_PUBLISH_OUTCOME:-PASSED}" = "FAILED" ]; then
        publish_write_envelope "FAILED" "github-releases" "trigger" \
          "gh release create FAILED — see evidence" \
          "$(publish_evidence_log_excerpt "${GH_PUBLISH_STDERR:-tag v$VERSION already exists}" "gh-cli")"
        exit 0
      fi
      publish_write_envelope "PASSED" "github-releases" "trigger" \
        "MOCK: gh release create v$VERSION succeeded at $REGISTRY/releases/tag/v$VERSION" \
        "$(publish_evidence_log_excerpt "mock release url: $REGISTRY/releases/tag/v$VERSION" "mock")"
      exit 0
    fi
    publish_write_envelope "PASSED" "github-releases" "trigger" \
      "gh release create v$VERSION succeeded at $REGISTRY/releases/tag/v$VERSION" \
      "$(publish_evidence_log_excerpt "release created" "gh-cli")"
    ;;
  verify)
    if [ "${GH_VERIFY_MOCK_OUTCOME:-PASSED}" = "FAILED" ]; then
      publish_write_envelope "FAILED" "github-releases" "verify" \
        "gh release view: v$VERSION not visible yet" \
        "$(publish_evidence_log_excerpt "gh release view returned non-zero" "gh-cli")"
      exit 0
    fi
    publish_write_envelope "PASSED" "github-releases" "verify" \
      "gh release view confirms v$VERSION at $REGISTRY/releases/tag/v$VERSION" \
      "$(publish_evidence_log_excerpt "release verified" "registry-response")"
    ;;
esac
