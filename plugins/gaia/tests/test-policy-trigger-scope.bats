#!/usr/bin/env bats
# test-policy-trigger-scope.bats — behavioral tests for per-trigger scope
# narrowing, wildcard override safety, and scope/threshold orthogonality.
#
# Public functions covered: read_trigger_scope, apply_trigger_scope.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  # Minimal valid base config (for schema validation tests in this file)
  BASE_REQUIRED='
project_root: /tmp/test-project
project_path: /tmp/test-project/src
memory_path: /tmp/test-project/.gaia/memory
checkpoint_path: /tmp/test-project/.gaia/checkpoints
installed_path: /tmp/test-project/.gaia/installed
framework_version: "1.197.0"
date: "2026-06-17"
'

  # Config with per-trigger scope rules for pr trigger
  cat > "$TEST_TMP/config-trigger-pr.yaml" <<'YAML'
stacks:
  - name: stack-a
    language: bash
    paths: ["src/a"]
  - name: stack-b
    language: python
    paths: ["src/b"]
test_policy:
  always_run: [smoke-a]
  triggers:
    pr:
      include_stacks:
        - stack-a
YAML

  # Config with exclude_stacks on pr trigger
  cat > "$TEST_TMP/config-trigger-pr-exclude.yaml" <<'YAML'
stacks:
  - name: stack-a
    language: bash
    paths: ["src/a"]
  - name: stack-b
    language: python
    paths: ["src/b"]
test_policy:
  triggers:
    pr:
      exclude_stacks:
        - stack-b
YAML

  # Config with empty include_stacks
  cat > "$TEST_TMP/config-trigger-empty-include.yaml" <<'YAML'
stacks:
  - name: stack-a
    language: bash
    paths: ["src/a"]
test_policy:
  triggers:
    pr:
      include_stacks: []
YAML

  # Config with no triggers section (only always_run)
  cat > "$TEST_TMP/config-no-triggers.yaml" <<'YAML'
test_policy:
  always_run: [smoke-a]
YAML

  # Config with no test_policy at all
  cat > "$TEST_TMP/config-plain.yaml" <<'YAML'
stacks:
  - name: stack-a
    language: bash
    paths: ["src/a"]
YAML

  # Config with severity + gates (for orthogonality test)
  cat > "$TEST_TMP/config-with-severity.yaml" <<'YAML'
stacks:
  - name: stack-a
    language: bash
    paths: ["src/a"]
test_policy:
  always_run: [smoke-a]
severity:
  Critical: BLOCKED
  High: REQUEST_CHANGES
gates:
  code-review:
    severity:
      Critical: BLOCKED
YAML

  # Same config with different severity (for orthogonality assertion)
  cat > "$TEST_TMP/config-with-severity-alt.yaml" <<'YAML'
stacks:
  - name: stack-a
    language: bash
    paths: ["src/a"]
test_policy:
  always_run: [smoke-a]
severity:
  Critical: APPROVE
  High: APPROVE
gates:
  code-review:
    severity:
      Critical: APPROVE
YAML
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Test 11: test_policy and gates/severity coexist in schema validation
# ---------------------------------------------------------------------------

@test "test_policy and gates/severity coexist in schema validation" {
  # Write a full config with both sections
  local cfg="$TEST_TMP/config-coexist.yaml"
  printf '%s\n' "$BASE_REQUIRED" > "$cfg"
  cat >> "$cfg" <<'YAML'
stacks:
  - name: stack-a
    language: bash
    paths: ["src/a"]
test_policy:
  triggers:
    pr:
      include_stacks:
        - stack-a
severity:
  Critical: BLOCKED
  High: REQUEST_CHANGES
gates:
  code-review:
    severity:
      Critical: BLOCKED
YAML
  run "$SCRIPTS_DIR/validate-project-config.sh" "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# Test 12: severity changes do not alter scope output
# ---------------------------------------------------------------------------

@test "severity changes do not alter scope output" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-with-severity.yaml" \
    --affected-set '["stack-a"]'
  [ "$status" -eq 0 ]
  local out1="$output"

  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-with-severity-alt.yaml" \
    --affected-set '["stack-a"]'
  [ "$status" -eq 0 ]
  local out2="$output"

  # Byte-identical output despite different severity values
  [ "$out1" = "$out2" ]
}

# ---------------------------------------------------------------------------
# Test 13: wildcard input with pr trigger narrowing outputs wildcard
# ---------------------------------------------------------------------------

@test "wildcard affected-set with --trigger pr outputs wildcard (safety override)" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-trigger-pr.yaml" \
    --affected-set '["*"]' \
    --trigger pr
  [ "$status" -eq 0 ]
  [[ "$output" == *'["*"]'* ]]
}

# ---------------------------------------------------------------------------
# Test 14: pr trigger include_stacks narrows affected-set
# ---------------------------------------------------------------------------

@test "pr trigger include_stacks narrows affected-set to included stacks" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-trigger-pr.yaml" \
    --affected-set '["stack-a","stack-b"]' \
    --trigger pr
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack-a"* ]]
  # Negative: stack-b must NOT appear (it is not in include_stacks)
  [[ "$output" != *"stack-b"* ]]
}

# ---------------------------------------------------------------------------
# Test 15: pr trigger exclude_stacks narrows affected-set
# ---------------------------------------------------------------------------

@test "pr trigger exclude_stacks removes excluded stacks from affected-set" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-trigger-pr-exclude.yaml" \
    --affected-set '["stack-a","stack-b"]' \
    --trigger pr
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack-a"* ]]
  # Negative: stack-b must NOT appear (it is excluded)
  [[ "$output" != *"stack-b"* ]]
}

# ---------------------------------------------------------------------------
# Test 16: absent trigger flag produces unmodified output
# ---------------------------------------------------------------------------

@test "absent --trigger flag with no test_policy produces unmodified output" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-plain.yaml" \
    --affected-set '["stack-a","stack-b"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["stack-a","stack-b"]' ]
}

# ---------------------------------------------------------------------------
# Test 17: absent trigger config for given trigger produces unmodified output
# ---------------------------------------------------------------------------

@test "absent trigger config for --trigger pr produces unmodified output" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-no-triggers.yaml" \
    --affected-set '["stack-a","stack-b"]' \
    --trigger pr
  [ "$status" -eq 0 ]
  # always_run smoke-a merges in, but no scope narrowing
  [[ "$output" == *"stack-a"* ]]
  [[ "$output" == *"stack-b"* ]]
  [[ "$output" == *"smoke-a"* ]]
}

# ---------------------------------------------------------------------------
# Test 18: empty include_stacks means no filtering (passthrough)
# ---------------------------------------------------------------------------

@test "empty include_stacks means no filtering (passthrough)" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-trigger-empty-include.yaml" \
    --affected-set '["stack-a","stack-b"]' \
    --trigger pr
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack-a"* ]]
  [[ "$output" == *"stack-b"* ]]
}

# ---------------------------------------------------------------------------
# Test 19: public-fn coverage — read_trigger_scope is callable after source
# ---------------------------------------------------------------------------

@test "public-fn coverage: source script — read_trigger_scope is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type read_trigger_scope
}

# ---------------------------------------------------------------------------
# Test 20: public-fn coverage — apply_trigger_scope is callable after source
# ---------------------------------------------------------------------------

@test "public-fn coverage: source script — apply_trigger_scope is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type apply_trigger_scope
}

# ---------------------------------------------------------------------------
# Test 21: public-fn coverage — main-guard still holds after new functions added
# ---------------------------------------------------------------------------

@test "public-fn coverage: main-guard — sourcing does not run main" {
  run bash -c 'source "'"$SCRIPTS_DIR/apply-test-policy.sh"'" && echo "source-ok"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"source-ok"* ]]
}
