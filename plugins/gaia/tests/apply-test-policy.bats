#!/usr/bin/env bats
# apply-test-policy.bats — TDD tests for apply-test-policy.sh (E113-S6)
#
# Public functions covered (NFR-052): read_test_policy_always_run,
# read_test_policy_flaky, read_test_policy_retry_limit, merge_always_run,
# apply_force_full_run, parse_args, main.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  # Config with inline always_run list
  cat > "$TEST_TMP/config-inline.yaml" <<'EOF'
test_policy:
  always_run: [smoke-a, smoke-b]
  flaky: [flaky-x]
  retry_limit: 3
EOF

  # Config with block-style always_run list
  cat > "$TEST_TMP/config-block.yaml" <<'EOF'
test_policy:
  always_run:
    - smoke-a
    - smoke-b
  flaky:
    - flaky-x
    - flaky-y
  retry_limit: 4
EOF

  # Config with empty always_run
  cat > "$TEST_TMP/config-empty-always-run.yaml" <<'EOF'
test_policy:
  always_run: []
  retry_limit: 2
EOF

  # Config with no test_policy section at all
  cat > "$TEST_TMP/config-no-policy.yaml" <<'EOF'
stacks:
  - name: stack-alpha
    language: bash
EOF

  # Config with test_policy but no always_run key
  cat > "$TEST_TMP/config-no-always-run.yaml" <<'EOF'
test_policy:
  retry_limit: 5
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# NFR-052: source the script and verify every public function resolves
# ---------------------------------------------------------------------------

@test "NFR-052: source script — read_test_policy_always_run is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type read_test_policy_always_run
}

@test "NFR-052: source script — read_test_policy_flaky is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type read_test_policy_flaky
}

@test "NFR-052: source script — read_test_policy_retry_limit is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type read_test_policy_retry_limit
}

@test "NFR-052: source script — merge_always_run is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type merge_always_run
}

@test "NFR-052: source script — apply_force_full_run is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type apply_force_full_run
}

@test "NFR-052: source script — parse_args is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type parse_args
}

@test "NFR-052: source script — main is callable" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  type main
}

@test "NFR-052: main-guard — sourcing does not run main" {
  run bash -c 'source "'"$SCRIPTS_DIR/apply-test-policy.sh"'" && echo "source-ok"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"source-ok"* ]]
}

# ---------------------------------------------------------------------------
# AC1: always-run set merges with affected-set
# ---------------------------------------------------------------------------

@test "AC1: inline always_run merges with affected-set" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-inline.yaml" \
    --affected-set '["stack-alpha"]'
  [ "$status" -eq 0 ]
  # Output must contain smoke-a, smoke-b, AND stack-alpha
  [[ "$output" == *"smoke-a"* ]]
  [[ "$output" == *"smoke-b"* ]]
  [[ "$output" == *"stack-alpha"* ]]
}

@test "AC1: block-style always_run merges with affected-set" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-block.yaml" \
    --affected-set '["stack-alpha"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"smoke-a"* ]]
  [[ "$output" == *"smoke-b"* ]]
  [[ "$output" == *"stack-alpha"* ]]
}

@test "AC1: empty affected-set with always_run → always-run-only" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-inline.yaml" \
    --affected-set '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"smoke-a"* ]]
  [[ "$output" == *"smoke-b"* ]]
}

@test "AC1: always_run items are not duplicated when already in affected-set" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-inline.yaml" \
    --affected-set '["smoke-a","stack-alpha"]'
  [ "$status" -eq 0 ]
  # Count occurrences of smoke-a — should be exactly 1
  local count
  count=$(echo "$output" | tr ',' '\n' | grep -c 'smoke-a')
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC3: --force-full-run overrides affected-set to ["*"]
# ---------------------------------------------------------------------------

@test "AC3: --force-full-run with affected-set → outputs wildcard" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-inline.yaml" \
    --affected-set '["stack-alpha"]' \
    --force-full-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'["*"]'* ]]
}

@test "AC3: --force-full-run with always_run config → still outputs wildcard" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-inline.yaml" \
    --affected-set '["stack-alpha","stack-beta"]' \
    --force-full-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'["*"]'* ]]
}

# ---------------------------------------------------------------------------
# AC4: absent/empty always_run → affected-set unchanged
# ---------------------------------------------------------------------------

@test "AC4: no test_policy section → affected-set passthrough" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-no-policy.yaml" \
    --affected-set '["stack-beta"]'
  [ "$status" -eq 0 ]
  # Output must equal the input exactly — no items added
  [ "$output" = '["stack-beta"]' ]
  # Negative: always_run items from other configs must be absent
  [[ "$output" != *"smoke-a"* ]]
  [[ "$output" != *"smoke-b"* ]]
}

@test "AC4: empty always_run list → affected-set passthrough" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-empty-always-run.yaml" \
    --affected-set '["stack-beta"]'
  [ "$status" -eq 0 ]
  # Output must equal the input exactly — empty always_run must not add items
  [ "$output" = '["stack-beta"]' ]
  # Negative: no always_run items should appear in output
  [[ "$output" != *"smoke-a"* ]]
  [[ "$output" != *"smoke-b"* ]]
}

@test "AC4: test_policy present but no always_run key → affected-set passthrough" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-no-always-run.yaml" \
    --affected-set '["stack-beta"]'
  [ "$status" -eq 0 ]
  # Output must equal the input exactly — absent always_run key must not add items
  [ "$output" = '["stack-beta"]' ]
  # Negative: no always_run items should appear in output
  [[ "$output" != *"smoke-a"* ]]
  [[ "$output" != *"smoke-b"* ]]
}

# ---------------------------------------------------------------------------
# Wildcard passthrough
# ---------------------------------------------------------------------------

@test "wildcard input: [\"*\"] affected-set → passthrough [\"*\"]" {
  run "$SCRIPTS_DIR/apply-test-policy.sh" \
    --config "$TEST_TMP/config-inline.yaml" \
    --affected-set '["*"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'["*"]'* ]]
}

# ---------------------------------------------------------------------------
# read_test_policy_always_run unit tests
# ---------------------------------------------------------------------------

@test "read_test_policy_always_run: inline list" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run read_test_policy_always_run "$TEST_TMP/config-inline.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"smoke-a"* ]]
  [[ "$output" == *"smoke-b"* ]]
}

@test "read_test_policy_always_run: block list" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run read_test_policy_always_run "$TEST_TMP/config-block.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"smoke-a"* ]]
  [[ "$output" == *"smoke-b"* ]]
}

@test "read_test_policy_always_run: absent section → empty" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run read_test_policy_always_run "$TEST_TMP/config-no-policy.yaml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "read_test_policy_always_run: empty list → empty" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run read_test_policy_always_run "$TEST_TMP/config-empty-always-run.yaml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# read_test_policy_flaky unit tests
# ---------------------------------------------------------------------------

@test "read_test_policy_flaky: inline list" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run read_test_policy_flaky "$TEST_TMP/config-inline.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flaky-x"* ]]
}

@test "read_test_policy_flaky: block list" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run read_test_policy_flaky "$TEST_TMP/config-block.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flaky-x"* ]]
  [[ "$output" == *"flaky-y"* ]]
}

# ---------------------------------------------------------------------------
# read_test_policy_retry_limit unit tests
# ---------------------------------------------------------------------------

@test "read_test_policy_retry_limit: reads configured value" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run read_test_policy_retry_limit "$TEST_TMP/config-inline.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "read_test_policy_retry_limit: defaults to 2 when absent" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run read_test_policy_retry_limit "$TEST_TMP/config-no-policy.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# merge_always_run unit tests
# ---------------------------------------------------------------------------

@test "merge_always_run: union of affected + always_run" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run merge_always_run '["stack-alpha"]' "smoke-a" "smoke-b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack-alpha"* ]]
  [[ "$output" == *"smoke-a"* ]]
  [[ "$output" == *"smoke-b"* ]]
}

@test "merge_always_run: wildcard passthrough" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run merge_always_run '["*"]' "smoke-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *'["*"]'* ]]
}

@test "merge_always_run: empty always_run → affected unchanged" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run merge_always_run '["stack-beta"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'["stack-beta"]'* ]]
}

# ---------------------------------------------------------------------------
# apply_force_full_run unit test
# ---------------------------------------------------------------------------

@test "apply_force_full_run: outputs wildcard" {
  source "$SCRIPTS_DIR/apply-test-policy.sh"
  run apply_force_full_run
  [ "$status" -eq 0 ]
  [[ "$output" == *'["*"]'* ]]
}
