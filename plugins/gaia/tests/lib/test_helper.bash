#!/usr/bin/env bash
# test_helper.bash — tests/lib/ helper (E79-S1)
#
# Mirrors the cluster-7 helper. Wraps the shared test helper conventions but
# overrides SCRIPTS_DIR / SKILLS_DIR / LIB_DIR to resolve correctly from a
# subdirectory two levels deep under tests/.

set -euo pipefail
LC_ALL=C
export LC_ALL
export TZ=UTC

SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"
export SCRIPTS_DIR

SKILLS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../skills" && pwd)"
export SKILLS_DIR

LIB_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts/lib" && pwd)"
export LIB_DIR

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
