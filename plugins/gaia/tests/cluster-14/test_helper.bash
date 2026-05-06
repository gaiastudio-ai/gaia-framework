#!/usr/bin/env bash
# test_helper.bash — Cluster 14 test helper (E71-S2)
#
# Resolves SCRIPTS_DIR before loading the shared helper so tests under
# the cluster-14/ subdirectory can locate plugins/gaia/scripts/.

set -euo pipefail
LC_ALL=C
export LC_ALL
export TZ=UTC

SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"
export SCRIPTS_DIR

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
