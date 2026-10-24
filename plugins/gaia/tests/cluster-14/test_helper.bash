#!/usr/bin/env bash
# test_helper.bash — Cluster 14 test helper (E71-S2)
#
# Resolves SCRIPTS_DIR before loading the shared helper so tests under
# the cluster-14/ subdirectory can locate plugins/gaia/scripts/.
# Source the shared helper for litter guard, strict mode, and common utilities.
# shellcheck source=tests/test_helper.bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test_helper.bash"

# Override SCRIPTS_DIR for the subdirectory layout (the shared helper
# resolves relative to tests/, which is wrong for this subdirectory).
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"
export SCRIPTS_DIR
