#!/usr/bin/env bats
# run-stack-tests.bats — TDD tests for run-stack-tests.sh
#
# Public functions covered (per the public-function coverage gate): parse_args, resolve_test_command,
# resolve_language_for_stack, main.

load 'test_helper.bash'

setup() {
  common_setup

  SCRIPT="$SCRIPTS_DIR/run-stack-tests.sh"

  # Minimal project config with two stacks of different languages.
  cat > "$TEST_TMP/project-config.yaml" <<'YAML'
stacks:
  - name: api
    language: typescript
    path: src/api
  - name: gaia-plugin
    language: bash
    paths:
      - "plugins/gaia/scripts/**"
      - "plugins/gaia/tests/**"
  - name: worker
    language: python
    path: src/worker
  - name: mobile
    language: kotlin
    path: src/mobile
YAML

  # Config with a per-stack test_cmd field (future-proof).
  cat > "$TEST_TMP/config-with-test-cmd.yaml" <<'YAML'
stacks:
  - name: custom-stack
    language: bash
    path: src/custom
    test_cmd: "make test-custom"
  - name: api
    language: typescript
    path: src/api
YAML
}

teardown() { common_teardown; }

# =========================================================================
# Public-function coverage gate: source the script and verify every public function resolves
# =========================================================================

@test "source script — parse_args is callable" {
  source "$SCRIPT"
  type parse_args
}

@test "source script — resolve_test_command is callable" {
  source "$SCRIPT"
  type resolve_test_command
}

@test "source script — resolve_language_for_stack is callable" {
  source "$SCRIPT"
  type resolve_language_for_stack
}

@test "source script — main is callable" {
  source "$SCRIPT"
  type main
}

@test "sourcing the script does not run main" {
  run bash -c 'source "'"$SCRIPT"'" && echo "sourced-ok"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"sourced-ok"* ]]
  # Should NOT contain test execution output or error messages
  [[ "$output" != *'HALT'* ]]
  [[ "$output" != *'unknown stack'* ]]
}

# =========================================================================
# Stack-to-command resolution: bash language falls back to bats suite
# =========================================================================

@test "bash stack resolves to bats test command" {
  source "$SCRIPT"
  local cmd
  cmd="$(resolve_test_command "gaia-plugin" "$TEST_TMP/project-config.yaml")"
  [[ "$cmd" == *"bats"* ]]
}

# =========================================================================
# Stack-to-command resolution: typescript falls back to npm test
# =========================================================================

@test "typescript stack resolves to npm test command" {
  source "$SCRIPT"
  local cmd
  cmd="$(resolve_test_command "api" "$TEST_TMP/project-config.yaml")"
  [[ "$cmd" == *"npm"* ]] || [[ "$cmd" == *"npx"* ]]
}

# =========================================================================
# Stack-to-command resolution: python falls back to pytest
# =========================================================================

@test "python stack resolves to pytest command" {
  source "$SCRIPT"
  local cmd
  cmd="$(resolve_test_command "worker" "$TEST_TMP/project-config.yaml")"
  [[ "$cmd" == *"pytest"* ]] || [[ "$cmd" == *"python"* ]]
}

# =========================================================================
# Per-stack test_cmd field takes precedence over language default
# =========================================================================

@test "per-stack test_cmd field overrides language default" {
  source "$SCRIPT"
  local cmd
  cmd="$(resolve_test_command "custom-stack" "$TEST_TMP/config-with-test-cmd.yaml")"
  [[ "$cmd" == "make test-custom" ]]
}

# =========================================================================
# Unknown stack exits non-zero with clear message
# =========================================================================

@test "unknown stack exits non-zero with clear error message" {
  run "$SCRIPT" --config "$TEST_TMP/project-config.yaml" "nonexistent-stack"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"nonexistent-stack"* ]]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"unknown"* ]] || [[ "$output" == *"no stack"* ]]
}

# =========================================================================
# Unsupported language exits non-zero with clear message
# =========================================================================

@test "unsupported language exits non-zero with clear message" {
  run "$SCRIPT" --config "$TEST_TMP/project-config.yaml" "mobile"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"kotlin"* ]] || [[ "$output" == *"unsupported"* ]] || [[ "$output" == *"no default"* ]]
}

# =========================================================================
# Missing stack argument exits non-zero
# =========================================================================

@test "missing stack argument exits non-zero" {
  run "$SCRIPT" --config "$TEST_TMP/project-config.yaml"
  [[ "$status" -ne 0 ]]
}
