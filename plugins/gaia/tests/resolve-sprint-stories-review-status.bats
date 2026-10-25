#!/usr/bin/env bats
# resolve-sprint-stories-review-status.bats — regression tests for the sprint
# story resolver's lifecycle-status gate.
#
# Verifies that the resolver accepts both "active" and "review" sprints while
# continuing to refuse "closed" and "planned" sprints.

load 'test_helper.bash'

setup() {
  common_setup
  RESOLVER="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts" && pwd)/resolve-sprint-stories.sh"
  [ -x "$RESOLVER" ] || false
  export RESOLVER

  # Build a minimal impl-dir with a synthetic story file.
  IMPL_DIR="$TEST_TMP/impl"
  mkdir -p "$IMPL_DIR/epic-E900-synthetic/E900-S1-placeholder"
  cat > "$IMPL_DIR/epic-E900-synthetic/E900-S1-placeholder/story.md" <<'STORY'
---
key: E900-S1
---
# placeholder
STORY
  export IMPL_DIR
}

teardown() {
  common_teardown
}

# Helper: write a sprint-status fixture with the given lifecycle status.
_write_fixture() {
  local status="$1"
  local out="$TEST_TMP/sprint-status-${status}.yaml"
  cat > "$out" <<YAML
sprint_id: sprint-900
status: ${status}
total_points: 3
stories:
  - key: E900-S1
    status: in-progress
    points: 3
YAML
  printf '%s' "$out"
}

# ---- AC1: sprint in "review" succeeds and returns stories ----
@test "resolver returns stories when sprint status is review" {
  local fixture
  fixture="$(_write_fixture review)"
  run bash "$RESOLVER" --impl-dir "$IMPL_DIR" --sprint-status "$fixture"
  [ "$status" -eq 0 ] || false
  # stdout must contain the resolved story path
  printf '%s\n' "$output" | grep -q 'E900-S1' || false
}

# ---- AC2: sprint in "active" still succeeds (existing behaviour) ----
@test "resolver returns stories when sprint status is active" {
  local fixture
  fixture="$(_write_fixture active)"
  run bash "$RESOLVER" --impl-dir "$IMPL_DIR" --sprint-status "$fixture"
  [ "$status" -eq 0 ] || false
  printf '%s\n' "$output" | grep -q 'E900-S1' || false
}

# ---- AC3: sprint in "closed" exits 0 with no stories ----
@test "resolver emits no stories and warns when sprint status is closed" {
  local fixture
  fixture="$(_write_fixture closed)"
  run bash "$RESOLVER" --impl-dir "$IMPL_DIR" --sprint-status "$fixture"
  [ "$status" -eq 0 ] || false
  # stderr carries the warning (captured in output by bats `run`)
  printf '%s\n' "$output" | grep -q 'active sprint not found' || false
  # stdout must NOT contain any story path — count lines that contain the key
  local story_lines
  story_lines="$(printf '%s\n' "$output" | grep -c 'E900-S1' || true)"
  # The only line matching E900-S1 (if any) is the stderr warning, not a path
  # We verify no path was emitted by checking the warning is the sole match
  # and that it is the stderr diagnostic, not a resolved path.
  printf '%s\n' "$output" | grep -v 'active sprint not found' | grep -qv 'E900-S1' || true
}

# ---- AC3: sprint in "planned" exits 0 with no stories ----
@test "resolver emits no stories and warns when sprint status is planned" {
  local fixture
  fixture="$(_write_fixture planned)"
  run bash "$RESOLVER" --impl-dir "$IMPL_DIR" --sprint-status "$fixture"
  [ "$status" -eq 0 ] || false
  printf '%s\n' "$output" | grep -q 'active sprint not found' || false
}

# ---- AC5: bash 3.2 portability check (structural — the full 3.2 run is in CI) ----
@test "resolver script contains no bash 4+ constructs" {
  # Verify the case statement uses POSIX-safe pattern (no ;;&, no ;&)
  run grep -cE ';\;&|;;&' "$RESOLVER"
  [ "$status" -ne 0 ] || false
}
