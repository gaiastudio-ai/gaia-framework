#!/usr/bin/env bats
# gaia-paths.bats — unit tests for plugins/gaia/scripts/lib/gaia-paths.sh
# Covers AC1, AC2, AC10 of E96-S1 (ADR-111). Maps to TC-GLM-10.
#
# Scenarios:
#   1. Default constants resolve to .gaia/* paths
#   2. GAIA_*_PATH env-var override under project root accepted
#   3. GAIA_*_PATH env-var override OUTSIDE project root rejected (non-zero)
#   4. Shell-metacharacter override rejected with explicit error
#   5. Sourcing the library twice does not double-export (idempotent guard)

load 'test_helper.bash'

setup() {
  common_setup
  LIB="$SCRIPTS_DIR/lib/gaia-paths.sh"
  # Fixture project root. Canonicalize to resolve macOS /tmp -> /private/tmp
  # so assertions compare apples-to-apples with the script's pwd -P output.
  mkdir -p "$TEST_TMP/proj"
  PROJECT_ROOT="$( cd "$TEST_TMP/proj" && pwd -P )"
  export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
  cd "$PROJECT_ROOT"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT \
        GAIA_CONFIG_PATH GAIA_ARTIFACTS_PATH GAIA_STATE_PATH \
        GAIA_MEMORY_PATH GAIA_CUSTOM_PATH \
        _GAIA_PATHS_LOADED \
        GAIA_CONFIG_DIR GAIA_ARTIFACTS_DIR GAIA_STATE_DIR \
        GAIA_MEMORY_DIR GAIA_CUSTOM_DIR 2>/dev/null || true
  common_teardown
}

@test "gaia-paths.sh: file exists at canonical path" {
  [ -f "$LIB" ]
}

@test "gaia-paths.sh: default constants resolve to .gaia/* (AC1)" {
  run bash -c "source '$LIB' && echo CONFIG=\$GAIA_CONFIG_DIR && echo ARTIFACTS=\$GAIA_ARTIFACTS_DIR && echo STATE=\$GAIA_STATE_DIR && echo MEMORY=\$GAIA_MEMORY_DIR && echo CUSTOM=\$GAIA_CUSTOM_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIG=$PROJECT_ROOT/.gaia/config"* ]]
  [[ "$output" == *"ARTIFACTS=$PROJECT_ROOT/.gaia/artifacts"* ]]
  [[ "$output" == *"STATE=$PROJECT_ROOT/.gaia/state"* ]]
  [[ "$output" == *"MEMORY=$PROJECT_ROOT/.gaia/memory"* ]]
  [[ "$output" == *"CUSTOM=$PROJECT_ROOT/.gaia/custom"* ]]
}

@test "gaia-paths.sh: GAIA_CONFIG_PATH override under project root accepted (AC2)" {
  mkdir -p "$PROJECT_ROOT/alt-config"
  run bash -c "export GAIA_CONFIG_PATH='$PROJECT_ROOT/alt-config'; source '$LIB' && echo CONFIG=\$GAIA_CONFIG_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIG=$PROJECT_ROOT/alt-config"* ]]
}

@test "gaia-paths.sh: GAIA_CONFIG_PATH override OUTSIDE project root rejected (AC2)" {
  run bash -c "export GAIA_CONFIG_PATH='/etc'; source '$LIB' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside project root"* ]] || [[ "$output" == *"CRITICAL"* ]]
}

@test "gaia-paths.sh: shell-metacharacter in override rejected (AC2, SR-75)" {
  run bash -c "export GAIA_MEMORY_PATH='./x;rm -rf /'; source '$LIB' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shell-metacharacter rejected"* ]]
  [[ "$output" == *"GAIA_MEMORY_PATH"* ]]
}

@test "gaia-paths.sh: backtick metacharacter rejected" {
  run bash -c "export GAIA_CONFIG_PATH='\`whoami\`'; source '$LIB' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shell-metacharacter rejected"* ]]
}

@test "gaia-paths.sh: dollar-paren metacharacter rejected" {
  run bash -c "export GAIA_STATE_PATH='\$(whoami)'; source '$LIB' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shell-metacharacter rejected"* ]]
}

@test "gaia-paths.sh: pipe metacharacter rejected" {
  run bash -c "export GAIA_ARTIFACTS_PATH='./a|b'; source '$LIB' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shell-metacharacter rejected"* ]]
}

@test "gaia-paths.sh: idempotent source guard (AC10e)" {
  run bash -c "source '$LIB'; FIRST=\$GAIA_CONFIG_DIR; export GAIA_CONFIG_PATH='/etc'; source '$LIB' 2>/dev/null; echo \"FIRST=\$FIRST SECOND=\$GAIA_CONFIG_DIR LOADED=\$_GAIA_PATHS_LOADED\""
  [ "$status" -eq 0 ]
  # After first source, _GAIA_PATHS_LOADED=1; second source must be no-op
  [[ "$output" == *"LOADED=1"* ]]
  # Second source must NOT re-evaluate the bad override
  [[ "$output" == *"SECOND=$PROJECT_ROOT/.gaia/config"* ]]
}

@test "gaia-paths.sh: missing CLAUDE_PROJECT_ROOT falls back to PWD" {
  unset CLAUDE_PROJECT_ROOT
  run bash -c "cd '$PROJECT_ROOT' && source '$LIB' && echo CONFIG=\$GAIA_CONFIG_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJECT_ROOT/.gaia/config"* ]]
}
