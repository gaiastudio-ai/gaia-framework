#!/usr/bin/env bash
# test_helper.bash — review-common/action/ test helper.
#
# Resolves SCRIPTS_DIR for tests nested 4 levels deep
# (tests/scripts/review-common/action/) so the canonical
# verdict-resolver.sh and review-common/ scripts are reachable.
#
# Refs: E67-S3, ADR-077.

set -euo pipefail
LC_ALL=C
export LC_ALL
export TZ=UTC

# tests/scripts/review-common/action/ -> tests/ -> ../../../../scripts
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../../scripts" && pwd)"
export SCRIPTS_DIR

# Action scripts live under review-common/action/.
ACTION_DIR="${SCRIPTS_DIR}/review-common/action"
export ACTION_DIR

common_setup() {
  local slug
  slug="$(printf '%s' "${BATS_TEST_NAME:-unknown}" | tr -c '[:alnum:]' '_')"
  TEST_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-${slug}-$$"
  mkdir -p "$TEST_TMP"
  export TEST_TMP
}

common_teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}
