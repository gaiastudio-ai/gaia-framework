#!/usr/bin/env bash
# test_helper.bash — review-common/qa/ test helper.
#
# Resolves SCRIPTS_DIR for tests nested 4 levels deep
# (tests/scripts/review-common/qa/) so the canonical
# verdict-resolver.sh and review-common/ scripts are reachable.

# Source the shared helper for litter guard, strict mode, and common utilities.
# shellcheck source=tests/test_helper.bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/test_helper.bash"

# Override SCRIPTS_DIR for the deeply nested layout.
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../../scripts" && pwd)"
export SCRIPTS_DIR

REVIEW_COMMON_DIR="${SCRIPTS_DIR}/review-common"
export REVIEW_COMMON_DIR

QA_TEST_RUNNER="${REVIEW_COMMON_DIR}/qa-test-runner.sh"
export QA_TEST_RUNNER

VERDICT_RESOLVER="${SCRIPTS_DIR}/verdict-resolver.sh"
export VERDICT_RESOLVER

SCHEMAS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../../schemas" && pwd)"
export SCHEMAS_DIR
