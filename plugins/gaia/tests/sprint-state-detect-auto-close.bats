#!/usr/bin/env bats
# sprint-state-detect-auto-close.bats — E81-S3
#
# NFR-052 public-function coverage anchor: cmd_detect_auto_close
#
# Tests `sprint-state.sh detect-auto-close` against three canonical fixtures
# under tests/fixtures/sprint-status/:
#   - all-done-active.yaml      → JSON payload emitted on stdout
#   - partial-done-active.yaml  → empty stdout (some stories still open)
#   - all-done-closed.yaml      → empty stdout (sprint already closed)
#
# Also verifies AC3: detect-auto-close MUST NEVER mutate sprint-status.yaml.
# Each test snapshots mtime + sha256 before and after invocation.
#
# Refs: AC1, AC3, TC-SAC-1, TC-SAC-2, feedback_sprint_boundary_yaml_write.md

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/sprint-state.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/sprint-status"

  TEST_TMP="$BATS_TEST_TMPDIR/sdac-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# Copy a fixture into the test tmpdir and export SPRINT_STATUS_YAML to point at it.
load_fixture() {
  local name="$1"
  cp "$FIXTURE_DIR/$name" "$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml"
  export SPRINT_STATUS_YAML="$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml"
}

# Snapshot mtime + sha256 of the fixture yaml.
snapshot() {
  local f="$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    shasum -a 256 "$f" | awk '{print $1}'
  fi
  if stat -f '%m' "$f" >/dev/null 2>&1; then
    stat -f '%m' "$f"
  else
    stat -c '%Y' "$f"
  fi
}

@test "detect-auto-close emits JSON when all stories done and sprint active" {
  load_fixture "all-done-active.yaml"
  run "$SCRIPT" detect-auto-close
  [ "$status" -eq 0 ]
  # Single line JSON with the four canonical keys
  [[ "$output" =~ \"sprint_id\":\"sprint-N\" ]]
  [[ "$output" =~ \"done\":3 ]]
  [[ "$output" =~ \"total\":3 ]]
  [[ "$output" =~ \"status\":\"active\" ]]
  [[ "$output" =~ \"end_date\":\"2026-05-14\" ]]
  # Output is exactly one line
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$line_count" -eq 1 ]
}

@test "detect-auto-close emits empty stdout when partial done" {
  load_fixture "partial-done-active.yaml"
  run "$SCRIPT" detect-auto-close
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect-auto-close emits empty stdout when sprint already closed" {
  load_fixture "all-done-closed.yaml"
  run "$SCRIPT" detect-auto-close
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect-auto-close does NOT mutate sprint-status.yaml (all-done-active)" {
  load_fixture "all-done-active.yaml"
  before=$(snapshot)
  run "$SCRIPT" detect-auto-close
  [ "$status" -eq 0 ]
  after=$(snapshot)
  [ "$before" = "$after" ]
}

@test "detect-auto-close does NOT mutate sprint-status.yaml (partial-done-active)" {
  load_fixture "partial-done-active.yaml"
  before=$(snapshot)
  run "$SCRIPT" detect-auto-close
  [ "$status" -eq 0 ]
  after=$(snapshot)
  [ "$before" = "$after" ]
}

@test "detect-auto-close output is valid JSON parseable by jq when present" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not installed"
  fi
  load_fixture "all-done-active.yaml"
  run "$SCRIPT" detect-auto-close
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.sprint_id == "sprint-N"' >/dev/null
  echo "$output" | jq -e '.done == 3' >/dev/null
  echo "$output" | jq -e '.total == 3' >/dev/null
  echo "$output" | jq -e '.status == "active"' >/dev/null
  echo "$output" | jq -e '.end_date == "2026-05-14"' >/dev/null
}

@test "detect-auto-close is listed in --help output" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ detect-auto-close ]]
}
