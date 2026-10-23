#!/usr/bin/env bash
# test_helper.bash — review-common/action/ test helper.
#
# Resolves SCRIPTS_DIR for tests nested 4 levels deep
# (tests/scripts/review-common/action/) so the canonical
# verdict-resolver.sh and review-common/ scripts are reachable.
#
# Refs: E67-S3, ADR-077.


# tests/scripts/review-common/action/ -> tests/ -> ../../../../scripts
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../../scripts" && pwd)"
export SCRIPTS_DIR

# Source the shared helper for litter guard, strict mode, and common utilities.
# shellcheck source=tests/test_helper.bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/test_helper.bash"

# Action scripts live under review-common/action/.
ACTION_DIR="${SCRIPTS_DIR}/review-common/action"
export ACTION_DIR


