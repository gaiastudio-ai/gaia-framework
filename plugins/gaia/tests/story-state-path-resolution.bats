#!/usr/bin/env bats
# story-state-path-resolution.bats — E91-S3 two-stage path resolution.
#
# Covers TC-SRF-8..10:
#   TC-SRF-8: transition-story-status.sh honors CLAUDE_PROJECT_ROOT precedence.
#   TC-SRF-9: tdd-review-gate.sh resolves PROJECT_ROOT via CLAUDE_PROJECT_ROOT.
#   TC-SRF-10: Legacy in-tree mode preserved when CLAUDE_PROJECT_ROOT unset.

load 'test_helper.bash'

setup() {
  common_setup
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"
  TDD_GATE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/tdd-review-gate.sh"
  export TRANSITION TDD_GATE
}

teardown() {
  common_teardown
}

# ---------------- TC-SRF-8: transition-story-status.sh CLAUDE_PROJECT_ROOT precedence ----------------
@test "TC-SRF-8: transition-story-status.sh resolves PROJECT_PATH via CLAUDE_PROJECT_ROOT" {
  # Assert the script body contains the two-stage resolution idiom.
  run grep -F 'CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}' "$TRANSITION"
  [ "$status" -eq 0 ]
}

# ---------------- TC-SRF-9: tdd-review-gate.sh CLAUDE_PROJECT_ROOT precedence ----------------
@test "TC-SRF-9: tdd-review-gate.sh resolves PROJECT_ROOT via CLAUDE_PROJECT_ROOT" {
  run grep -F 'CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-$(pwd)}' "$TDD_GATE"
  [ "$status" -eq 0 ]
}

# ---------------- TC-SRF-10: Legacy in-tree fallback preserved ----------------
@test "TC-SRF-10: legacy PROJECT_PATH fallback preserved when CLAUDE_PROJECT_ROOT unset" {
  # When neither CLAUDE_PROJECT_ROOT nor PROJECT_PATH is set, transition-status
  # falls back to '.' (legacy in-tree behavior).
  run grep -F 'PROJECT_PATH:-.' "$TRANSITION"
  [ "$status" -eq 0 ]

  # tdd-review-gate falls back to $(pwd).
  run grep -F 'PROJECT_PATH:-$(pwd)' "$TDD_GATE"
  [ "$status" -eq 0 ]
}

# ---------------- AC3: init-review-gate.sh has no docs/ path assumptions ----------------
@test "AC3: init-review-gate.sh has no docs/ path assumptions in body" {
  local script="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/init-review-gate.sh"
  # Only comments may reference docs/ — assert no executable line contains docs/.
  run bash -c "grep -v '^[[:space:]]*#' '$script' | grep -F 'docs/'"
  [ "$status" -ne 0 ]
}

# ---------------- AC5: header documents two-stage convention ----------------
@test "AC5: transition-story-status.sh cites E91-S3 in header" {
  run grep -F 'E91-S3' "$TRANSITION"
  [ "$status" -eq 0 ]
}

@test "AC5: tdd-review-gate.sh cites E91-S3 in header" {
  run grep -F 'E91-S3' "$TDD_GATE"
  [ "$status" -eq 0 ]
}

@test "AC5: init-review-gate.sh documents path-resolution no-op via E91-S3 citation" {
  local script="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/init-review-gate.sh"
  run grep -F 'E91-S3' "$script"
  [ "$status" -eq 0 ]
}
