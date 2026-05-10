#!/usr/bin/env bats
# sprint-status-dashboard-auto-close-banner.bats — E81-S3
#
# Tests `sprint-status-dashboard.sh` banner rendering for the auto-close
# condition. Verifies AC2 (banner present when detection fires, suppressed
# otherwise) and AC3 (banner code path does not mutate sprint-status.yaml).
#
# Refs: AC2, AC3, AC4, TC-SAC-1, TC-SAC-2, feedback_sprint_boundary_yaml_write.md

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DASHBOARD="$REPO_ROOT/plugins/gaia/scripts/sprint-status-dashboard.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/sprint-status"

  TEST_TMP="$BATS_TEST_TMPDIR/ssdacb-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

load_fixture() {
  local name="$1"
  cp "$FIXTURE_DIR/$name" "$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml"
  export SPRINT_STATUS_YAML="$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml"
}

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

@test "banner renders when all stories done and sprint active" {
  load_fixture "all-done-active.yaml"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  # Canonical banner markers
  [[ "$output" =~ AUTO-CLOSE ]] || [[ "$output" =~ auto-close ]]
  [[ "$output" =~ sprint-N ]]
  [[ "$output" =~ 3/3 ]] || [[ "$output" =~ "3 of 3" ]]
  [[ "$output" =~ 2026-05-14 ]]
  # Remediation hint MUST reference yq -i (per AC2)
  [[ "$output" =~ "yq -i" ]]
}

@test "banner suppressed when partial done" {
  load_fixture "partial-done-active.yaml"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ AUTO-CLOSE ]]
  ! [[ "$output" =~ auto-close ]]
}

@test "banner suppressed when sprint already closed" {
  load_fixture "all-done-closed.yaml"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ AUTO-CLOSE ]]
  ! [[ "$output" =~ auto-close ]]
}

@test "dashboard does NOT mutate sprint-status.yaml (all-done-active)" {
  load_fixture "all-done-active.yaml"
  before=$(snapshot)
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  after=$(snapshot)
  [ "$before" = "$after" ]
}

@test "dashboard does NOT mutate sprint-status.yaml (partial-done-active)" {
  load_fixture "partial-done-active.yaml"
  before=$(snapshot)
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  after=$(snapshot)
  [ "$before" = "$after" ]
}

@test "banner placement is above the Stories header (below metadata block)" {
  load_fixture "all-done-active.yaml"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  # Find line numbers of key markers; banner must appear before "Story" header row
  banner_line=$(printf '%s\n' "$output" | grep -nE 'AUTO-CLOSE|auto-close' | head -1 | cut -d: -f1)
  stories_header_line=$(printf '%s\n' "$output" | grep -nE '^  Story ' | head -1 | cut -d: -f1)
  [ -n "$banner_line" ]
  [ -n "$stories_header_line" ]
  [ "$banner_line" -lt "$stories_header_line" ]
}
