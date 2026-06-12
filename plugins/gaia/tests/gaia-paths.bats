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
        GAIA_MEMORY_PATH GAIA_CUSTOM_PATH GAIA_KNOWLEDGE_PATH \
        _GAIA_PATHS_LOADED \
        GAIA_CONFIG_DIR GAIA_ARTIFACTS_DIR GAIA_STATE_DIR \
        GAIA_MEMORY_DIR GAIA_CUSTOM_DIR GAIA_KNOWLEDGE_DIR 2>/dev/null || true
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

# E96-S7 AC4: derived checkpoint-dir constant + backward-compat env-var aliases.

@test "gaia-paths.sh: exports GAIA_CHECKPOINT_DIR derived from GAIA_MEMORY_DIR (AC4)" {
  run bash -c "source '$LIB' && echo CKPT=\$GAIA_CHECKPOINT_DIR && echo MEM=\$GAIA_MEMORY_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CKPT=$PROJECT_ROOT/.gaia/memory/checkpoints"* ]]
  [[ "$output" == *"MEM=$PROJECT_ROOT/.gaia/memory"* ]]
}

@test "gaia-paths.sh: exports MEMORY_PATH alias for backward compat (AC4)" {
  run bash -c "source '$LIB' && echo MEMORY_PATH=\$MEMORY_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MEMORY_PATH=$PROJECT_ROOT/.gaia/memory"* ]]
}

@test "gaia-paths.sh: exports CHECKPOINT_PATH alias for backward compat (AC4)" {
  run bash -c "source '$LIB' && echo CHECKPOINT_PATH=\$CHECKPOINT_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECKPOINT_PATH=$PROJECT_ROOT/.gaia/memory/checkpoints"* ]]
}

@test "gaia-paths.sh: aliases honor GAIA_MEMORY_PATH env-var override (AC4)" {
  # Override GAIA_MEMORY_PATH; CHECKPOINT_PATH and MEMORY_PATH should follow.
  local alt="$PROJECT_ROOT/alt-mem"
  mkdir -p "$alt"
  run bash -c "GAIA_MEMORY_PATH='$alt' source '$LIB' && echo CKPT=\$CHECKPOINT_PATH && echo MEM=\$MEMORY_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CKPT=$alt/checkpoints"* ]]
  [[ "$output" == *"MEM=$alt"* ]]
  rm -rf "$alt"
}

# ---------------------------------------------------------------------------
# GAIA_KNOWLEDGE_DIR — the sixth canonical constant (brain knowledge layer).
# Mirrors the five existing override tests above.
# ---------------------------------------------------------------------------

@test "gaia-paths.sh: GAIA_KNOWLEDGE_DIR defaults to .gaia/knowledge" {
  run bash -c "source '$LIB' && echo KNOWLEDGE=\$GAIA_KNOWLEDGE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KNOWLEDGE=$PROJECT_ROOT/.gaia/knowledge"* ]]
}

@test "gaia-paths.sh: GAIA_KNOWLEDGE_PATH override under project root accepted" {
  mkdir -p "$PROJECT_ROOT/alt-knowledge"
  run bash -c "export GAIA_KNOWLEDGE_PATH='$PROJECT_ROOT/alt-knowledge'; source '$LIB' && echo KNOWLEDGE=\$GAIA_KNOWLEDGE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KNOWLEDGE=$PROJECT_ROOT/alt-knowledge"* ]]
}

@test "gaia-paths.sh: GAIA_KNOWLEDGE_PATH override OUTSIDE project root rejected" {
  run bash -c "export GAIA_KNOWLEDGE_PATH='/etc'; source '$LIB' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside project root"* ]] || [[ "$output" == *"CRITICAL"* ]]
}

@test "gaia-paths.sh: shell-metacharacter in GAIA_KNOWLEDGE_PATH rejected" {
  run bash -c "export GAIA_KNOWLEDGE_PATH='./k;rm -rf /'; source '$LIB' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shell-metacharacter rejected"* ]]
  [[ "$output" == *"GAIA_KNOWLEDGE_PATH"* ]]
}
