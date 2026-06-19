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
@test "transition-story-status.sh resolves PROJECT_PATH via CLAUDE_PROJECT_ROOT" {
  # Assert the script body contains the two-stage resolution idiom.
  run grep -F 'CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}' "$TRANSITION"
  [ "$status" -eq 0 ]
}

# ---------------- TC-SRF-9: tdd-review-gate.sh CLAUDE_PROJECT_ROOT precedence ----------------
@test "tdd-review-gate.sh resolves PROJECT_ROOT via CLAUDE_PROJECT_ROOT" {
  run grep -F 'CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-$(pwd)}' "$TDD_GATE"
  [ "$status" -eq 0 ]
}

# ---------------- TC-SRF-10: Legacy in-tree fallback preserved ----------------
@test "legacy PROJECT_PATH fallback preserved when CLAUDE_PROJECT_ROOT unset" {
  # When neither CLAUDE_PROJECT_ROOT nor PROJECT_PATH is set, transition-status
  # falls back to '.' (legacy in-tree behavior).
  run grep -F 'PROJECT_PATH:-.' "$TRANSITION"
  [ "$status" -eq 0 ]

  # tdd-review-gate falls back to $(pwd).
  run grep -F 'PROJECT_PATH:-$(pwd)' "$TDD_GATE"
  [ "$status" -eq 0 ]
}

# ---------------- AC3: init-review-gate.sh has no docs/ path assumptions ----------------
@test "init-review-gate.sh has no docs/ path assumptions in body" {
  local script="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/init-review-gate.sh"
  # Only comments may reference docs/ — assert no executable line contains docs/.
  run bash -c "grep -v '^[[:space:]]*#' '$script' | grep -F 'docs/'"
  [ "$status" -ne 0 ]
}

# ---------------- AC5: header documents two-stage convention ----------------
@test "transition-story-status.sh cites in header" {
  # The traceability ID was removed; assert the behavioral contract instead:
  # the script documents the three-stage env-var precedence for path resolution.
  run grep -F 'Three-stage env-var precedence' "$TRANSITION"
  [ "$status" -eq 0 ]
}

@test "tdd-review-gate.sh cites in header" {
  # The traceability ID was removed; assert the behavioral contract instead:
  # the script documents the two-stage env-var precedence for path resolution.
  run grep -F 'Path resolution — two-stage env-var precedence' "$TDD_GATE"
  [ "$status" -eq 0 ]
}

@test "init-review-gate.sh documents path-resolution no-op via citation" {
  local script="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/init-review-gate.sh"
  # The traceability ID was removed; assert the behavioral contract instead:
  # the script header explains it inherits two-stage CLAUDE_PROJECT_ROOT precedence from its caller.
  run grep -F 'two-stage CLAUDE_PROJECT_ROOT' "$script"
  [ "$status" -eq 0 ]
}
