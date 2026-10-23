#!/usr/bin/env bash
# test_helper.bash — Cluster 7 test helper (E61-S2)
#
# Mirrors the cluster-1 helper. Wraps the shared test helper but overrides
# SCRIPTS_DIR to point to the correct scripts/ directory (two levels up
# from cluster-7/). The shared helper resolves SCRIPTS_DIR via
# $BATS_TEST_DIRNAME/../scripts, which works for tests at the root tests/
# level but not for subdirectories.


# Resolve SCRIPTS_DIR before loading the shared helper so the cd in the
# shared helper doesn't fail.
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"
export SCRIPTS_DIR

# Source the shared helper for litter guard, strict mode, and common utilities.
# shellcheck source=tests/test_helper.bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test_helper.bash"

# Resolve SKILLS_DIR — used by SKILL.md prose-anchor tests.
SKILLS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../skills" && pwd)"
export SKILLS_DIR


