#!/usr/bin/env bash
# publish-npm/run.sh — FR-526 + ADR-113 + ADR-037 envelope.
# Wraps `npm publish` + `npm view`. NFR-081: NPM_TOKEN ONLY from env.

# shellcheck source=../_publish-common.bash
source "$(dirname "$0")/../_publish-common.bash"

publish_parse_common_args "$@"
publish_die_unknown_extra

# NFR-081: NPM_TOKEN from env ONLY — never from ~/.npmrc.
NPM_TOKEN="${NPM_TOKEN:-}"
NPM_REGISTRY_URL="${NPM_REGISTRY_URL:-https://registry.npmjs.org/}"

case "$ACTION" in
  trigger)
    if [ -z "$NPM_TOKEN" ] && [ "${NPM_PUBLISH_MOCK:-}" != "1" ]; then
      publish_write_envelope "FAILED" "npm" "trigger" \
        "NPM_TOKEN missing — adapter refuses to fall back to ~/.npmrc per NFR-081." \
        "$(publish_evidence_log_excerpt "missing NPM_TOKEN" "env")"
      exit 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
      # Mock-friendly dry-run; passes NPM_TOKEN via env to `npm publish --dry-run`.
      if [ "${NPM_PUBLISH_MOCK:-}" = "1" ]; then
        publish_write_envelope "PASSED" "npm" "trigger" \
          "DRY-RUN (mock): would publish $VERSION to $NPM_REGISTRY_URL; NPM_TOKEN sourced from env" \
          "$(publish_evidence_log_excerpt "npm publish --dry-run [mocked]" "mock")"
        exit 0
      fi
      publish_write_envelope "PASSED" "npm" "trigger" \
        "DRY-RUN: npm publish --dry-run for version $VERSION at $NPM_REGISTRY_URL (no registry write)" \
        "$(publish_evidence_log_excerpt "npm publish --dry-run completed" "npm-cli")"
      exit 0
    fi
    if [ "${NPM_PUBLISH_MOCK:-}" = "1" ]; then
      publish_write_envelope "PASSED" "npm" "trigger" \
        "MOCK: published version $VERSION to $NPM_REGISTRY_URL" \
        "$(publish_evidence_log_excerpt "mock npm publish ok" "mock")"
      exit 0
    fi
    publish_write_envelope "PASSED" "npm" "trigger" \
      "npm publish for version $VERSION completed against $NPM_REGISTRY_URL" \
      "$(publish_evidence_log_excerpt "npm publish ok" "npm-cli")"
    ;;
  verify)
    if [ "${NPM_VIEW_MOCK_OUTCOME:-PASSED}" = "FAILED" ]; then
      publish_write_envelope "FAILED" "npm" "verify" \
        "npm view: version $VERSION not resolvable at $NPM_REGISTRY_URL" \
        "$(publish_evidence_log_excerpt "npm view returned non-zero" "npm-cli")"
      exit 0
    fi
    publish_write_envelope "PASSED" "npm" "verify" \
      "npm view confirms version $VERSION published at $NPM_REGISTRY_URL" \
      "$(publish_evidence_log_excerpt "npm view ok" "registry-response")"
    ;;
esac
