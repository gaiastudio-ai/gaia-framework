#!/usr/bin/env bats
# bats-shard-retry.bats — tests for the shard-level retry logic in
# .github/scripts/bats-shard-retry.sh.
#
# Covers three scenarios:
#   1. pass-on-retry: a test file fails first, passes on retry
#   2. fail-twice: a test file fails both times, shard fails
#   3. nothing-failed: all files pass on first attempt, no retry
# Plus a signal-kill guard: exit >= 128 is never retried.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RETRY_SCRIPT="$REPO_ROOT/.github/scripts/bats-shard-retry.sh"
  SUMMARY_FILE="$TEST_TMP/summary.md"
  : > "$SUMMARY_FILE"
}
teardown() { common_teardown; }

# _clean_bats_env — run a command with all BATS_* env vars stripped so a
# nested bats invocation does not inherit the outer runner's test-selection
# state (BATS_TEST_NAME, BATS_TEST_NUMBER, etc.). Without this, CI's outer
# bats sets these vars and the inner bats tries to find a test function by
# that name in the fixture file, fails, and exits non-zero.
_clean_bats_env() {
  env -u BATS_TEST_NAME -u BATS_TEST_NUMBER -u BATS_SUITE_TEST_NUMBER \
      -u BATS_TEST_DESCRIPTION -u BATS_TEST_FILENAME \
      -u BATS_TEST_DIRNAME -u BATS_TEST_NAMES \
      -u BATS_TEST_PATTERN -u BATS_TEST_TMPDIR \
      -u BATS_RUN_TMPDIR -u BATS_FILE_TMPDIR \
      -u BATS_SUITE_TMPDIR -u BATS_TEST_RETRIES \
      -u BATS_TEST_COMPLETED -u BATS_TEST_SKIPPED \
      -u BATS_ERROR_STATUS -u BATS_ERROR_STACK_TRACE \
      "$@"
}

@test "retry script exists and is executable" {
  [ -f "$RETRY_SCRIPT" ]
  [ -x "$RETRY_SCRIPT" ]
}

@test "pass-on-retry: file fails first then passes on retry" {
  # Create a bats file that fails on first run, passes on second.
  # Uses a marker file to track attempts.
  local marker="$TEST_TMP/attempt-marker"
  cat > "$TEST_TMP/flaky.bats" <<EOF
#!/usr/bin/env bats
@test "flaky test" {
  if [ ! -f "$marker" ]; then
    touch "$marker"
    false
  fi
  true
}
EOF

  run _clean_bats_env bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" -- "$TEST_TMP/flaky.bats"
  [ "$status" -eq 0 ]
  # Summary should mention the retry
  grep -qi "retry" "$SUMMARY_FILE"
}

@test "fail-twice: file fails on both attempts" {
  cat > "$TEST_TMP/always-fail.bats" <<'EOF'
#!/usr/bin/env bats
@test "always fails" {
  false
}
EOF

  run _clean_bats_env bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" -- "$TEST_TMP/always-fail.bats"
  [ "$status" -ne 0 ]
  # Summary should indicate the retry happened and failed
  grep -qi "retry" "$SUMMARY_FILE"
}

@test "nothing-failed: all tests pass on first attempt" {
  cat > "$TEST_TMP/passing.bats" <<'EOF'
#!/usr/bin/env bats
@test "always passes" {
  true
}
EOF

  run _clean_bats_env bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" -- "$TEST_TMP/passing.bats"
  [ "$status" -eq 0 ]
  # Summary should NOT mention any retry
  ! grep -qi "retrying" "$SUMMARY_FILE"
}

@test "signal-kill exit codes are never retried" {
  # The retry script should not retry when bats exits >= 128.
  # We simulate this by replacing bats with a wrapper that exits 130.
  cat > "$TEST_TMP/passing.bats" <<'EOF'
#!/usr/bin/env bats
@test "always passes" {
  true
}
EOF
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/bats" <<'WRAPPER'
#!/usr/bin/env bash
exit 130
WRAPPER
  chmod +x "$TEST_TMP/bin/bats"

  run _clean_bats_env env PATH="$TEST_TMP/bin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" -- "$TEST_TMP/passing.bats"
  [ "$status" -eq 130 ]
  # Should NOT have retried — no retry message in summary
  ! grep -qi "retrying" "$SUMMARY_FILE"
}
