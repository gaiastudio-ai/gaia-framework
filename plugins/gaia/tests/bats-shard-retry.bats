#!/usr/bin/env bats
# bats-shard-retry.bats — tests for the shard-level retry logic in
# .github/scripts/bats-shard-retry.sh.
#
# Tests use mock bats scripts instead of real nested bats invocations
# to avoid env-var conflicts between the outer and inner bats runtimes.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RETRY_SCRIPT="$REPO_ROOT/.github/scripts/bats-shard-retry.sh"
  SUMMARY_FILE="$TEST_TMP/summary.md"
  : > "$SUMMARY_FILE"

  # Create a mock bats directory. The retry script calls `bats` as a command;
  # we prepend a mock to PATH so the inner invocation uses our stub.
  mkdir -p "$TEST_TMP/mockbin"
}
teardown() { common_teardown; }

# _mock_bats_pass — creates a mock bats that always exits 0
_mock_bats_pass() {
  cat > "$TEST_TMP/mockbin/bats" <<'MOCK'
#!/usr/bin/env bash
# Mock bats: print TAP and exit 0
count=0
for f in "$@"; do
  case "$f" in *.bats) count=$((count + 1)) ;; esac
done
echo "1..$count"
i=0
for f in "$@"; do
  case "$f" in
    *.bats) i=$((i + 1)); echo "ok $i $(basename "$f")" ;;
  esac
done
exit 0
MOCK
  chmod +x "$TEST_TMP/mockbin/bats"
}

# _mock_bats_fail — creates a mock bats that fails on first call, passes on second
_mock_bats_fail_then_pass() {
  local marker="$TEST_TMP/bats-call-marker"
  cat > "$TEST_TMP/mockbin/bats" <<MOCK
#!/usr/bin/env bash
# Mock bats: fail on first call, pass on second
if [ ! -f "$marker" ]; then
  touch "$marker"
  echo "1..1"
  echo "not ok 1 flaky test"
  exit 1
fi
echo "1..1"
echo "ok 1 flaky test"
exit 0
MOCK
  chmod +x "$TEST_TMP/mockbin/bats"
}

# _mock_bats_always_fail — creates a mock bats that always fails
_mock_bats_always_fail() {
  cat > "$TEST_TMP/mockbin/bats" <<'MOCK'
#!/usr/bin/env bash
echo "1..1"
echo "not ok 1 always fails"
exit 1
MOCK
  chmod +x "$TEST_TMP/mockbin/bats"
}

# _mock_bats_signal — creates a mock bats that exits with a signal code
_mock_bats_signal() {
  local code="${1:-130}"
  cat > "$TEST_TMP/mockbin/bats" <<MOCK
#!/usr/bin/env bash
exit $code
MOCK
  chmod +x "$TEST_TMP/mockbin/bats"
}

@test "retry script exists and is executable" {
  [ -f "$RETRY_SCRIPT" ]
  [ -x "$RETRY_SCRIPT" ]
}

@test "pass-on-retry: test fails first then passes on retry" {
  _mock_bats_fail_then_pass
  cat > "$TEST_TMP/flaky.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" -- "$TEST_TMP/flaky.bats"
  [ "$status" -eq 0 ]
  grep -qi "retry" "$SUMMARY_FILE"
}

@test "fail-twice: test fails on both attempts" {
  _mock_bats_always_fail
  cat > "$TEST_TMP/always-fail.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" -- "$TEST_TMP/always-fail.bats"
  [ "$status" -ne 0 ]
  grep -qi "retry" "$SUMMARY_FILE"
}

@test "nothing-failed: all tests pass on first attempt" {
  _mock_bats_pass
  cat > "$TEST_TMP/passing.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" -- "$TEST_TMP/passing.bats"
  [ "$status" -eq 0 ]
  ! grep -qi "retrying" "$SUMMARY_FILE"
}

@test "signal-kill exit codes are never retried" {
  _mock_bats_signal 130
  cat > "$TEST_TMP/signal.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" -- "$TEST_TMP/signal.bats"
  [ "$status" -eq 130 ]
  ! grep -qi "retrying" "$SUMMARY_FILE"
}

# --- Promotion-path tests (BATS_RETRY_SCRIPT wiring in run-with-coverage.sh) ---

@test "BATS_RETRY_SCRIPT: run-with-coverage.sh uses the retry script when set" {
  # Verify that run-with-coverage.sh references BATS_RETRY_SCRIPT and
  # conditionally calls it instead of bare bats.
  local rwc="$REPO_ROOT/plugins/gaia/tests/run-with-coverage.sh"
  [ -f "$rwc" ]
  grep -q 'BATS_RETRY_SCRIPT' "$rwc"
  grep -q 'bats-shard-retry' "$rwc"
}

@test "promotion per-file retry: fail-then-pass via BATS_RETRY_SCRIPT" {
  _mock_bats_fail_then_pass
  : > "$SUMMARY_FILE"
  cat > "$TEST_TMP/flaky.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" \
    GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
    bash "$RETRY_SCRIPT" -- "$TEST_TMP/flaky.bats"
  [ "$status" -eq 0 ]
  grep -qi "retry" "$SUMMARY_FILE"
}

@test "promotion per-file retry: fail-twice via BATS_RETRY_SCRIPT" {
  _mock_bats_always_fail
  : > "$SUMMARY_FILE"
  cat > "$TEST_TMP/always-fail.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" \
    GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
    bash "$RETRY_SCRIPT" -- "$TEST_TMP/always-fail.bats"
  [ "$status" -ne 0 ]
  grep -qi "retry" "$SUMMARY_FILE"
}

@test "promotion per-file retry: none-fail via BATS_RETRY_SCRIPT" {
  _mock_bats_pass
  : > "$SUMMARY_FILE"
  cat > "$TEST_TMP/passing.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" \
    GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
    bash "$RETRY_SCRIPT" -- "$TEST_TMP/passing.bats"
  [ "$status" -eq 0 ]
  ! grep -qi "retrying" "$SUMMARY_FILE"
}
