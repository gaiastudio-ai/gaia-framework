#!/usr/bin/env bash
# test_helper.bash — tests/lib/ helper (E79-S1)
#
# Mirrors the cluster-7 helper. Wraps the shared test helper conventions but
# overrides SCRIPTS_DIR / SKILLS_DIR / LIB_DIR to resolve correctly from a
# subdirectory two levels deep under tests/.
# Source the shared helper for litter guard, strict mode, and common utilities.
# shellcheck source=tests/test_helper.bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test_helper.bash"

# Override SCRIPTS_DIR for the subdirectory layout (the shared helper
# resolves relative to tests/, which is wrong for this subdirectory).
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"
export SCRIPTS_DIR

# Additional directories needed by lib/ tests.
SKILLS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../skills" && pwd)"
export SKILLS_DIR
LIB_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts/lib" && pwd)"
export LIB_DIR
