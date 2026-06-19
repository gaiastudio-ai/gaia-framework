#!/usr/bin/env bats
# plugin-ci-hardware-tag-skip.bats — E91-S1 hardware-dependent tag skip tests.
#
# Covers TC-SRF-1, TC-SRF-2, TC-SRF-3:
#   TC-SRF-1: plugin-ci.yml sets BATS_FILTER_TAGS to '!hardware-dependent'
#   TC-SRF-2: run-with-coverage.sh respects BATS_FILTER_TAGS env var
#   TC-SRF-3: drift-detection-ci-suppression.bats carries the file_tag

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CI_YAML="$PLUGIN_DIR/../../.github/workflows/plugin-ci.yml"
  RUN_WITH_COVERAGE="$PLUGIN_DIR/tests/run-with-coverage.sh"
  export PLUGIN_DIR CI_YAML RUN_WITH_COVERAGE
}

teardown() {
  common_teardown
}

# ---------------- TC-SRF-1: plugin-ci.yml sets BATS_FILTER_TAGS ----------------
@test "plugin-ci.yml sets BATS_FILTER_TAGS='!hardware-dependent' in bats-tests job" {
  [ -f "$CI_YAML" ]
  grep -qF "BATS_FILTER_TAGS:" "$CI_YAML"
  grep -qF "'!hardware-dependent'" "$CI_YAML"
}

# ---------------- TC-SRF-1b: plugin-ci.yml documents the hardware-tag-skip convention ----------------
@test "plugin-ci.yml bats-tests job documents the hardware-tag-skip convention" {
  [ -f "$CI_YAML" ]
  # The bats-tests job default-skips @hardware-dependent tests in CI; the
  # convention is documented in the job comment and enforced by the env var.
  grep -qF "hardware-dependent" "$CI_YAML"
  grep -qF "BATS_FILTER_TAGS" "$CI_YAML"
}

# ---------------- TC-SRF-2: run-with-coverage.sh honors BATS_FILTER_TAGS ----------------
@test "run-with-coverage.sh forwards BATS_FILTER_TAGS env to bats" {
  [ -f "$RUN_WITH_COVERAGE" ]
  grep -qF "BATS_FILTER_TAGS" "$RUN_WITH_COVERAGE"
  grep -qF -- "--filter-tags" "$RUN_WITH_COVERAGE"
}

# ---------------- TC-SRF-3: drift-detection-ci-suppression.bats has file_tag ----------------
@test "drift-detection-ci-suppression.bats carries 'bats file_tags=hardware-dependent'" {
  local target="$PLUGIN_DIR/tests/drift-detection-ci-suppression.bats"
  [ -f "$target" ]
  grep -qF "bats file_tags=hardware-dependent" "$target"
}

# ---------------- TC-SRF-4: documentation discoverability ----------------
@test "tests README documents the @hardware-dependent convention" {
  local readme="$PLUGIN_DIR/tests/README.md"
  if [ -f "$readme" ]; then
    grep -qF "hardware-dependent" "$readme"
  else
    skip "tests/README.md not yet present (created in this story)"
  fi
}
