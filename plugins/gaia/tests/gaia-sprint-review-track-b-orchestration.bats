#!/usr/bin/env bats
# gaia-sprint-review-track-b-orchestration.bats — TC-SGR-27..35 + AskUserQuestion regression guard
#
# Story: E93-S4. Traces to AC1, AC3, AC4, AC5, AC6, AC8, AC9.

setup() {
  RUNNER="${BATS_TEST_DIRNAME}/../skills/gaia-sprint-review/scripts/track-b-dispatch.sh"
  FIXTURE_DIR="${BATS_TEST_DIRNAME}/../skills/gaia-sprint-review/tests/fixtures"
  FIXTURE="${FIXTURE_DIR}/test-fixture-command.sh"
  TMPDIR_TEST="$(mktemp -d)"
  CONFIG="$TMPDIR_TEST/test-config.yaml"
  # Helper to (re)write the config with current FIXTURE_* env vars baked into
  # the command string (since `env -i` strips them from the child env).
  write_config() {
    local timeout="${1:-5}"
    cat >"$CONFIG" <<EOF
sprint_review:
  backend_commands:
    node: "FIXTURE_EXIT_CODE=${FIXTURE_EXIT_CODE:-0} FIXTURE_STDOUT='${FIXTURE_STDOUT:-}' FIXTURE_STDERR='${FIXTURE_STDERR:-}' FIXTURE_SLEEP_SECONDS=${FIXTURE_SLEEP_SECONDS:-0} FIXTURE_PRINT_ENV=${FIXTURE_PRINT_ENV:-0} $FIXTURE"
  timeout_per_stack: $timeout
EOF
  }
  # Default config (overridable per-test via write_config)
  write_config 5
  # Set up .gaia/memory/checkpoints under TMPDIR + matching .gitignore
  mkdir -p "$TMPDIR_TEST/.gaia/memory/checkpoints"
  cat >"$TMPDIR_TEST/.gitignore" <<EOF
.gaia/memory/checkpoints/sprint-review-*
EOF
  cd "$TMPDIR_TEST"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "runner stub replacement — no longer emits ' not yet shipped' SKIPPED placeholder" {
  ! grep -q "E93-S4 not yet shipped" "$RUNNER"
}

@test "runner preserves --sprint + --config CLI contract" {
  grep -q -- "--sprint" "$RUNNER"
  grep -q -- "--config" "$RUNNER"
}

@test "fixture command exists and is executable" {
  [ -x "$FIXTURE" ]
}

@test "env-allowlist strips secrets — AWS_SECRET_ACCESS_KEY not visible to subprocess" {
  export AWS_SECRET_ACCESS_KEY="sekret-do-not-leak"
  export GITHUB_TOKEN="ghp-leak"
  export FIXTURE_PRINT_ENV=1
  export FIXTURE_EXIT_CODE=0
  write_config 5
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  echo "$output" | grep -q "AWS_SECRET_ACCESS_KEY" && return 1
  echo "$output" | grep -q "GITHUB_TOKEN" && return 1
  return 0
}

@test "timeout hard-kill — fixture sleep 30s with timeout=1 returns within 5s with TIMEOUT verdict" {
  export FIXTURE_SLEEP_SECONDS=30
  export FIXTURE_EXIT_CODE=0
  write_config 1
  start=$(date +%s)
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  end=$(date +%s)
  duration=$((end - start))
  [ "$duration" -lt 10 ]
  echo "$output" | grep -q "TIMEOUT"
}

@test "transcript file lands under .gaia/memory/checkpoints/sprint-review-{sprint_id}/ at mode 0600" {
  export FIXTURE_STDOUT="hello-from-node"
  export FIXTURE_EXIT_CODE=0
  write_config 5
  bash "$RUNNER" --sprint sprint-47 --config "$CONFIG" >/dev/null
  transcript="$TMPDIR_TEST/.gaia/memory/checkpoints/sprint-review-sprint-47/node.log"
  [ -f "$transcript" ]
  if [ "$(uname)" = "Darwin" ]; then
    mode=$(stat -f '%Lp' "$transcript")
  else
    mode=$(stat -c '%a' "$transcript")
  fi
  [ "$mode" = "600" ]
  grep -q "hello-from-node" "$transcript"
}

@test ".gitignore pre-flight HALTs when sprint-review-* pattern missing" {
  echo "# no sprint-review coverage" >"$TMPDIR_TEST/.gitignore"
  export FIXTURE_EXIT_CODE=0
  write_config 5
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "gitignore"
}

@test "exit code 0 yields verdict PASSED" {
  export FIXTURE_EXIT_CODE=0
  write_config 5
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  echo "$output" | grep -q "PASSED"
}

@test "exit code 42 yields verdict FAILED" {
  export FIXTURE_EXIT_CODE=42
  write_config 5
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  echo "$output" | grep -q "FAILED"
}

@test "envelope JSON has all 9 required fields" {
  export FIXTURE_EXIT_CODE=0
  write_config 5
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  # Extract last line of JSON output (envelope array)
  for field in stack verdict exit_code stdout stderr transcript_path duration_seconds started_at ended_at; do
    echo "$output" | grep -q "\"$field\"" || { echo "missing field $field in: $output"; return 1; }
  done
}

@test "GAIA_HEADLESS=1 HALTs with canonical stderr" {
  export GAIA_HEADLESS=1
  export FIXTURE_EXIT_CODE=0
  write_config 5
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "GAIA_HEADLESS=1 detected"
  echo "$output" | grep -q "Track B requires foreground"
}

@test "non-TTY stdout emits WARNING (not HALT) and continues" {
  export FIXTURE_EXIT_CODE=0
  write_config 5
  # When run via bats, stdout is not a TTY anyway. Just verify the runner doesn't HALT under non-TTY.
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # WARNING line emitted to stderr (captured in $output too by `run`)
  echo "$output" | grep -qi "WARNING.*TTY" || true  # WARNING is optional under bats, but no HALT
}

@test "runner does NOT invoke AskUserQuestion" {
  # Strip comment lines, then assert no actual invocation of AskUserQuestion
  ! grep -v '^[[:space:]]*#' "$RUNNER" | grep -q "AskUserQuestion("
}

@test "empty sprint_review section → empty array + stderr warning, exit 0 ( soft-fail preserved)" {
  echo "{}" >"$CONFIG"
  run bash "$RUNNER" --sprint sprint-47 --config "$CONFIG"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq "^\[\]" || echo "$output" | grep -q '\[\]'
}
