#!/usr/bin/env bash
# test_helper.bash — Cluster 1 test helper (E61-S1)
#
# Mirrors the cluster-9 helper. Wraps the shared test helper but overrides
# SCRIPTS_DIR to point to the correct scripts/ directory (two levels up
# from cluster-1/). The shared helper resolves SCRIPTS_DIR via
# $BATS_TEST_DIRNAME/../scripts, which works for tests at the root tests/
# level but not for subdirectories.


# Source the shared helper for litter guard, strict mode, and common utilities.
# shellcheck source=tests/test_helper.bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test_helper.bash"

# Override SCRIPTS_DIR for the subdirectory layout (the shared helper
# resolves relative to tests/, which is wrong for this subdirectory).
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"
export SCRIPTS_DIR
