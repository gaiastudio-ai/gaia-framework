#!/usr/bin/env bash
# test_helper.bash — Cluster 14 test helper.
#
# Sources the shared test_helper.bash for strict mode, litter guard, and
# common utilities, then overrides SCRIPTS_DIR for the subdirectory layout.

# shellcheck source=tests/test_helper.bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test_helper.bash"

# Override SCRIPTS_DIR for the subdirectory layout (the shared helper
# resolves relative to tests/, which is wrong for this subdirectory).
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"
export SCRIPTS_DIR
