#!/usr/bin/env bats
# run-with-retry.bats — TDD tests for run-with-retry.sh (E113-S6)
#
# Public functions covered (NFR-052): is_flaky_test, run_with_retry,
# parse_args, main.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  fake_bin="$TEST_TMP/bin"
  mkdir -p "$fake_bin"

  # Stub: always passes
  cat > "$fake_bin/always-pass" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$fake_bin/always-pass"

  # Stub: always fails
  cat > "$fake_bin/always-fail" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$fake_bin/always-fail"

  # Stub: fails N times then passes (counter via COUNTER_FILE env)
  cat > "$fake_bin/fail-then-pass" <<'STUB'
#!/usr/bin/env bash
count=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$COUNTER_FILE"
if [ "$count" -le "${FAIL_COUNT:-2}" ]; then exit 1; fi
exit 0
STUB
  chmod +x "$fake_bin/fail-then-pass"

  # Flaky list file
  cat > "$TEST_TMP/flaky-list.txt" <<'EOF'
flaky-x
flaky-y
test-flaky-z
EOF

  export COUNTER_FILE="$TEST_TMP/counter"
  echo "0" > "$COUNTER_FILE"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# NFR-052: source the script and verify every public function resolves
# ---------------------------------------------------------------------------

@test "NFR-052: source script — is_flaky_test is callable" {
  source "$SCRIPTS_DIR/run-with-retry.sh"
  type is_flaky_test
}

@test "NFR-052: source script — run_with_retry is callable" {
  source "$SCRIPTS_DIR/run-with-retry.sh"
  type run_with_retry
}

@test "NFR-052: source script — parse_args is callable" {
  source "$SCRIPTS_DIR/run-with-retry.sh"
  type parse_args
}

@test "NFR-052: source script — main is callable" {
  source "$SCRIPTS_DIR/run-with-retry.sh"
  type main
}

@test "NFR-052: main-guard — sourcing does not run main" {
  run bash -c 'source "'"$SCRIPTS_DIR/run-with-retry.sh"'" && echo "source-ok"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"source-ok"* ]]
}

# ---------------------------------------------------------------------------
# AC2: flaky test retries — fails then passes
# ---------------------------------------------------------------------------

@test "AC2: flaky test fails once then passes — exit 0" {
  export FAIL_COUNT=1
  echo "0" > "$COUNTER_FILE"
  run "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t1" --retry-limit 3 --is-flaky \
    -- "$fake_bin/fail-then-pass"
  [ "$status" -eq 0 ]
}

@test "AC2: flaky test fails twice then passes with retry-limit 3 — exit 0" {
  export FAIL_COUNT=2
  echo "0" > "$COUNTER_FILE"
  run "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t1" --retry-limit 3 --is-flaky \
    -- "$fake_bin/fail-then-pass"
  [ "$status" -eq 0 ]
}

@test "AC2: flaky test always-fail with retry-limit 2 → nonzero + ESCALATED" {
  run --separate-stderr "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t1" --retry-limit 2 --is-flaky \
    -- "$fake_bin/always-fail"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"ESCALATED_FLAKY_FAILURE"* ]]
}

# ---------------------------------------------------------------------------
# AC5: escalation blocks the pipeline
# ---------------------------------------------------------------------------

@test "AC5: always-fail flaky escalation → nonzero exit (blocks)" {
  run --separate-stderr "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t-critical" --retry-limit 1 --is-flaky \
    -- "$fake_bin/always-fail"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"ESCALATED_FLAKY_FAILURE"* ]]
  [[ "$stderr" == *"t-critical"* ]]
}

@test "AC5: non-flaky failure — immediate passthrough, no retry, no ESCALATED" {
  run --separate-stderr "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t2" --retry-limit 3 \
    -- "$fake_bin/always-fail"
  [ "$status" -ne 0 ]
  # Unconditional: ESCALATED_FLAKY_FAILURE must never appear for non-flaky tests
  [[ "$stderr" != *"ESCALATED_FLAKY_FAILURE"* ]]
}

@test "AC5: non-flaky failure does not retry (counter stays at 1)" {
  echo "0" > "$COUNTER_FILE"
  export FAIL_COUNT=999
  run "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t2" --retry-limit 3 \
    -- "$fake_bin/fail-then-pass"
  [ "$status" -ne 0 ]
  # Only 1 attempt should have been made
  local actual_count
  actual_count=$(cat "$COUNTER_FILE")
  [ "$actual_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Retry-limit boundary cases
# ---------------------------------------------------------------------------

@test "retry-limit=0 + flaky + failing → one attempt, nonzero" {
  run --separate-stderr "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t3" --retry-limit 0 --is-flaky \
    -- "$fake_bin/always-fail"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"ESCALATED_FLAKY_FAILURE"* ]]
}

@test "retry-limit=3 + flaky + fail-twice-then-pass → exit 0" {
  export FAIL_COUNT=2
  echo "0" > "$COUNTER_FILE"
  run "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t4" --retry-limit 3 --is-flaky \
    -- "$fake_bin/fail-then-pass"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Passing test — no retries needed
# ---------------------------------------------------------------------------

@test "passing test — immediate exit 0, no retry" {
  run "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t5" --retry-limit 3 --is-flaky \
    -- "$fake_bin/always-pass"
  [ "$status" -eq 0 ]
}

@test "passing non-flaky test — immediate exit 0" {
  run "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "t6" --retry-limit 3 \
    -- "$fake_bin/always-pass"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# is_flaky_test unit tests
# ---------------------------------------------------------------------------

@test "is_flaky_test: id in flaky list → 1" {
  source "$SCRIPTS_DIR/run-with-retry.sh"
  run is_flaky_test "flaky-x" "$TEST_TMP/flaky-list.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "is_flaky_test: id not in flaky list → 0" {
  source "$SCRIPTS_DIR/run-with-retry.sh"
  run is_flaky_test "not-flaky" "$TEST_TMP/flaky-list.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "is_flaky_test: empty flaky list file → 0" {
  source "$SCRIPTS_DIR/run-with-retry.sh"
  run is_flaky_test "anything" ""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# --flaky-list-file integration
# ---------------------------------------------------------------------------

@test "flaky-list-file: id found in list → retries on failure" {
  export FAIL_COUNT=1
  echo "0" > "$COUNTER_FILE"
  run "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "flaky-x" --retry-limit 2 \
    --flaky-list-file "$TEST_TMP/flaky-list.txt" \
    -- "$fake_bin/fail-then-pass"
  [ "$status" -eq 0 ]
}

@test "flaky-list-file: id NOT in list → no retry on failure" {
  echo "0" > "$COUNTER_FILE"
  export FAIL_COUNT=999
  run "$SCRIPTS_DIR/run-with-retry.sh" \
    --test-id "not-in-list" --retry-limit 2 \
    --flaky-list-file "$TEST_TMP/flaky-list.txt" \
    -- "$fake_bin/fail-then-pass"
  [ "$status" -ne 0 ]
  local actual_count
  actual_count=$(cat "$COUNTER_FILE")
  [ "$actual_count" -eq 1 ]
}
