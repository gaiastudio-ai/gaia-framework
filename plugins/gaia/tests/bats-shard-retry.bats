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

# _mock_bats_fail — creates a mock bats that fails on first call, passes on second.
# Writes JUnit XML on the first call so the retry script can identify which
# file failed.
_mock_bats_fail_then_pass() {
  local marker="$TEST_TMP/bats-call-marker"
  cat > "$TEST_TMP/mockbin/bats" <<MOCK
#!/usr/bin/env bash
# Find the output dir from -o / --output flag
_odir=""
_prev=""
for _a in "\$@"; do
  if [ "\$_prev" = "-o" ] || [ "\$_prev" = "--output" ]; then
    _odir="\$_a"; break
  fi
  _prev="\$_a"
done
if [ ! -f "$marker" ]; then
  touch "$marker"
  # Write JUnit XML so the retry script can identify failed files.
  if [ -n "\$_odir" ]; then
    mkdir -p "\$_odir"
    # Identify the .bats file(s) passed as arguments.
    for _f in "\$@"; do
      case "\$_f" in *.bats)
        cat > "\$_odir/report.xml" <<JXML
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="\$(basename "\$_f")" tests="1" failures="1" errors="0">
    <testcase name="flaky test">
      <failure>Expected true, got false</failure>
    </testcase>
  </testsuite>
</testsuites>
JXML
        break
        ;;
      esac
    done
  fi
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

# _mock_bats_always_fail — creates a mock bats that always fails. Writes
# JUnit XML so the retry script can identify failed files.
_mock_bats_always_fail() {
  cat > "$TEST_TMP/mockbin/bats" <<'MOCK'
#!/usr/bin/env bash
# Find the output dir from -o / --output flag
_odir=""
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "-o" ] || [ "$_prev" = "--output" ]; then
    _odir="$_a"; break
  fi
  _prev="$_a"
done
if [ -n "$_odir" ]; then
  mkdir -p "$_odir"
  for _f in "$@"; do
    case "$_f" in *.bats)
      cat > "$_odir/report.xml" <<JXML
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="$(basename "$_f")" tests="1" failures="1" errors="0">
    <testcase name="always fails">
      <failure>always fails</failure>
    </testcase>
  </testsuite>
</testsuites>
JXML
      break
      ;;
    esac
  done
fi
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
  local jdir="$TEST_TMP/junit-retry"
  mkdir -p "$jdir"
  cat > "$TEST_TMP/flaky.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" --junit-dir "$jdir" \
    -- --output "$jdir" "$TEST_TMP/flaky.bats"
  [ "$status" -eq 0 ]
  grep -qi "retry" "$SUMMARY_FILE"
}

@test "fail-twice: test fails on both attempts" {
  _mock_bats_always_fail
  local jdir="$TEST_TMP/junit-fail-twice"
  mkdir -p "$jdir"
  cat > "$TEST_TMP/always-fail.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" --junit-dir "$jdir" \
    -- --output "$jdir" "$TEST_TMP/always-fail.bats"
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

# --- JUnit-directed retry: only the failed file is retried ---

# _mock_bats_junit_one_fail — writes JUnit XML reporting flaky.bats as failed,
# then exits non-zero on first call and 0 on second.
_mock_bats_junit_one_fail() {
  local marker="$TEST_TMP/bats-junit-marker"
  cat > "$TEST_TMP/mockbin/bats" <<MOCK
#!/usr/bin/env bash
# Find the output dir from -o / --output flag
junit_dir=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-o" ] || [ "\$prev" = "--output" ]; then
    junit_dir="\$arg"; break
  fi
  prev="\$arg"
done
if [ ! -f "$marker" ]; then
  touch "$marker"
  # First call: write JUnit XML marking flaky.bats as failed
  if [ -n "\$junit_dir" ]; then
    mkdir -p "\$junit_dir"
    cat > "\$junit_dir/report.xml" <<'JXML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="pass.bats" tests="1" failures="0" errors="0">
    <testcase name="always passes" />
  </testsuite>
  <testsuite name="flaky.bats" tests="1" failures="1" errors="0">
    <testcase name="flaky test">
      <failure>Expected true, got false</failure>
    </testcase>
  </testsuite>
</testsuites>
JXML
  fi
  exit 1
fi
# Second call (retry): pass
exit 0
MOCK
  chmod +x "$TEST_TMP/mockbin/bats"
}

# _mock_bats_fail_no_junit — fails without writing any JUnit output.
_mock_bats_fail_no_junit() {
  cat > "$TEST_TMP/mockbin/bats" <<'MOCK'
#!/usr/bin/env bash
echo "1..1"
echo "not ok 1 some failure"
exit 1
MOCK
  chmod +x "$TEST_TMP/mockbin/bats"
}

@test "junit-directed retry: only the failed file is retried, not the passing file" {
  _mock_bats_junit_one_fail
  local jdir="$TEST_TMP/junit-out"
  mkdir -p "$jdir"
  cat > "$TEST_TMP/pass.bats" <<'EOF'
placeholder
EOF
  cat > "$TEST_TMP/flaky.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" --junit-dir "$jdir" \
    -- --output "$jdir" "$TEST_TMP/pass.bats" "$TEST_TMP/flaky.bats"
  [ "$status" -eq 0 ]
  # The summary should mention retrying 1 file (flaky.bats), not 2
  grep -q 'Retrying 1 failed file' "$SUMMARY_FILE"
  grep -q 'flaky.bats' "$SUMMARY_FILE"
  ! grep -q 'pass.bats' "$SUMMARY_FILE"
}

@test "no-report fallback: no retry attempted, original status returned" {
  _mock_bats_fail_no_junit
  cat > "$TEST_TMP/some.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" bash "$RETRY_SCRIPT" \
    --summary-file "$SUMMARY_FILE" \
    -- "$TEST_TMP/some.bats"
  [ "$status" -eq 1 ]
  # The script must NOT have retried — no "Retrying" in the summary
  ! grep -qi 'retrying' "$SUMMARY_FILE"
  # It should have logged the skip
  grep -q 'retry skipped' "$SUMMARY_FILE" || [[ "$output" == *"skipping retry"* ]]
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
  local jdir="$TEST_TMP/junit-promo-flaky"
  mkdir -p "$jdir"
  cat > "$TEST_TMP/flaky.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" \
    GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
    bash "$RETRY_SCRIPT" --junit-dir "$jdir" \
    -- --output "$jdir" "$TEST_TMP/flaky.bats"
  [ "$status" -eq 0 ]
  grep -qi "retry" "$SUMMARY_FILE"
}

@test "promotion per-file retry: fail-twice via BATS_RETRY_SCRIPT" {
  _mock_bats_always_fail
  : > "$SUMMARY_FILE"
  local jdir="$TEST_TMP/junit-promo-fail"
  mkdir -p "$jdir"
  cat > "$TEST_TMP/always-fail.bats" <<'EOF'
placeholder
EOF

  run env PATH="$TEST_TMP/mockbin:$PATH" \
    GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
    bash "$RETRY_SCRIPT" --junit-dir "$jdir" \
    -- --output "$jdir" "$TEST_TMP/always-fail.bats"
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

# --- Integration: real run-with-coverage.sh -> bats-shard-retry.sh hand-off ---
# These tests run the real scripts against a temp dir with real .bats files.
# They must run outside the outer bats env to avoid BATS_* var leaks, so each
# test builds a standalone driver script and invokes it via env -u.

_build_integration_driver() {
  # Args: $1=driver path, $2=tests dir, $3=summary path, $4=scripts dir
  # Strips BATS test-state vars but preserves BATS_ROOT (installation path)
  # so the nested bats can find its own libraries.
  local covdir
  covdir="$(mktemp -d)"
  cat > "$1" <<DRIVER
#!/usr/bin/env bash
set -euo pipefail
# Strip BATS test-state vars but keep installation vars.
while IFS='=' read -r name _; do
  case "\$name" in
    BATS_ROOT|BATS_LIB_PATH|BATS_LIBDIR) ;;
    BATS_*) unset "\$name" ;;
  esac
done < <(env)
export BATS_RETRY_SCRIPT="$4/bats-shard-retry.sh"
export TESTS_DIR_OVERRIDE="$2"
export SCRIPTS_DIR_OVERRIDE="$2"
export COVERAGE_DIR="$covdir"
export GITHUB_STEP_SUMMARY="$3"
export LC_ALL=C
exec bash "$REPO_ROOT/plugins/gaia/tests/run-with-coverage.sh"
DRIVER
  chmod +x "$1"
}

@test "integration: run-with-coverage.sh + retry script passes with flaky file" {
  # Skip on CI: nested bats inside bats leaks env vars (BATS_ROOT, BATS_LIBDIR)
  # that break the inner bats installation lookup. The mocked tests above cover
  # the retry logic; this integration test runs locally only.
  [ "${CI:-}" = "true" ] && skip "nested-bats integration unreliable on CI runners"
  # Build a temp tests dir with one passing file and one flaky file.
  local tdir="$TEST_TMP/integration-pass"
  mkdir -p "$tdir"
  # Fixture test lines are built from a split token: a literal test keyword
  # at line start would be counted by this file's own bats preprocessor.
  local kw='@''test'
  printf '#!/usr/bin/env bats\n%s "always passes" { true; }\n' "$kw" > "$tdir/pass.bats"
  local marker="$TEST_TMP/flaky-marker"
  printf '#!/usr/bin/env bats\n%s "flaky" {\n  if [ ! -f "%s" ]; then\n    touch "%s"\n    false\n  fi\n  true\n}\n' \
    "$kw" "$marker" "$marker" > "$tdir/flaky.bats"
  # Dummy script dir so the coverage check (step 3) finds no scripts and
  # doesn't fail on an unrelated public-function assertion.
  mkdir -p "$tdir/scripts_stub"
  local summary="$TEST_TMP/integration-summary.md"
  : > "$summary"
  local driver="$TEST_TMP/integration-driver.sh"
  _build_integration_driver "$driver" "$tdir" "$summary" \
    "$REPO_ROOT/.github/scripts"

  run "$driver"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  # The flaky file should have been retried
  grep -qi "retrying.*flaky" "$summary" || grep -qi "flaky.bats" "$summary"
}

@test "integration: run-with-coverage.sh + retry script fails on double failure" {
  [ "${CI:-}" = "true" ] && skip "nested-bats integration unreliable on CI runners"
  local tdir="$TEST_TMP/integration-fail"
  mkdir -p "$tdir"
  local kw='@''test'
  printf '#!/usr/bin/env bats\n%s "always passes" { true; }\n' "$kw" > "$tdir/pass.bats"
  printf '#!/usr/bin/env bats\n%s "always fails" { false; }\n' "$kw" > "$tdir/always-fail.bats"
  mkdir -p "$tdir/scripts_stub"
  local summary="$TEST_TMP/integration-fail-summary.md"
  : > "$summary"
  local driver="$TEST_TMP/integration-fail-driver.sh"
  _build_integration_driver "$driver" "$tdir" "$summary" \
    "$REPO_ROOT/.github/scripts"

  run "$driver"
  [ "$status" -ne 0 ]
  # The always-fail file should have been retried and still failed
  grep -qi "retry" "$summary"
}
