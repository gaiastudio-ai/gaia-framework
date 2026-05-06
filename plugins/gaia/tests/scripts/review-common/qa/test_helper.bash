#!/usr/bin/env bash
# test_helper.bash — review-common/qa/ test helper.
#
# Resolves SCRIPTS_DIR for tests nested 4 levels deep
# (tests/scripts/review-common/qa/) so the canonical
# verdict-resolver.sh and review-common/ scripts are reachable.
#
# Refs: E67-S4, ADR-077.

set -euo pipefail
LC_ALL=C
export LC_ALL
export TZ=UTC

# tests/scripts/review-common/qa/ -> ../../../../scripts
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../../scripts" && pwd)"
export SCRIPTS_DIR

REVIEW_COMMON_DIR="${SCRIPTS_DIR}/review-common"
export REVIEW_COMMON_DIR

# QA test runner lives under review-common/.
QA_TEST_RUNNER="${REVIEW_COMMON_DIR}/qa-test-runner.sh"
export QA_TEST_RUNNER

VERDICT_RESOLVER="${SCRIPTS_DIR}/verdict-resolver.sh"
export VERDICT_RESOLVER

SCHEMAS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../../schemas" && pwd)"
export SCHEMAS_DIR

common_setup() {
  local slug
  slug="$(printf '%s' "${BATS_TEST_NAME:-unknown}" | tr -c '[:alnum:]' '_')"
  TEST_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-qa-${slug}-$$"
  mkdir -p "$TEST_TMP"
  export TEST_TMP
}

common_teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}
