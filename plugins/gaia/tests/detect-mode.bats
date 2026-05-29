#!/usr/bin/env bats
# detect-mode.bats — coverage for skills/gaia-dev-story/scripts/detect-mode.sh
#
# Story: E57-S5 — story-parse.sh (P0-1) + detect-mode.sh (P0-2)
# Traces: TC-DSS-03 (mode tree)
# ACs: AC3, AC4, AC5

load 'test_helper.bash'

setup() {
  common_setup
  DETECT_MODE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/detect-mode.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts
  export PROJECT_PATH="$TEST_TMP"
}

teardown() { common_teardown; }

# Write a story with a given status and an optional FAILED review row
_write_story_with_gate() {
  local key="$1" status="$2" gate_failed="${3:-no}"
  local code_review="UNVERIFIED"
  if [ "$gate_failed" = "yes" ]; then
    code_review="FAILED"
  fi
  cat > "docs/implementation-artifacts/${key}-test.md" <<EOF
---
template: 'story'
key: "$key"
epic: "E10"
status: $status
risk: "low"
depends_on: []
---

# Story

## Acceptance Criteria
- [ ] AC1

## Tasks / Subtasks
- [ ] T1

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $code_review | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
EOF
}

# ---------------------------------------------------------------------------
# AC3 / TC-DSS-03 — FRESH branch
# ---------------------------------------------------------------------------

@test "detect-mode: status=ready-for-dev returns FRESH" {
  _write_story_with_gate "E10-S1" "ready-for-dev"
  run "$DETECT_MODE" "docs/implementation-artifacts/E10-S1-test.md"
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
}

# ---------------------------------------------------------------------------
# AC4 / TC-DSS-03 — REWORK branch
# ---------------------------------------------------------------------------

@test "detect-mode: status=in-progress + FAILED review returns REWORK" {
  _write_story_with_gate "E10-S2" "in-progress" "yes"
  run "$DETECT_MODE" "docs/implementation-artifacts/E10-S2-test.md"
  [ "$status" -eq 0 ]
  [ "$output" = "REWORK" ]
}

# ---------------------------------------------------------------------------
# AC5 / TC-DSS-03 — RESUME branches
# ---------------------------------------------------------------------------

@test "detect-mode: status=in-progress without FAILED returns RESUME" {
  _write_story_with_gate "E10-S3" "in-progress"
  run "$DETECT_MODE" "docs/implementation-artifacts/E10-S3-test.md"
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME" ]
}

@test "detect-mode: status=review returns RESUME" {
  _write_story_with_gate "E10-S4" "review"
  run "$DETECT_MODE" "docs/implementation-artifacts/E10-S4-test.md"
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME" ]
}

@test "detect-mode: status=done returns RESUME" {
  _write_story_with_gate "E10-S5" "done"
  run "$DETECT_MODE" "docs/implementation-artifacts/E10-S5-test.md"
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME" ]
}

@test "detect-mode: status=backlog returns FRESH (Test08 F-14)" {
  # AF-2026-05-29-1 / Test08 F-14: backlog is a canonically-FRESH state — no
  # implementation, no checkpoint, no commits. The prior RESUME classification
  # (fallthrough to the `*)` catchall) steered /gaia-dev-story Step 1 into the
  # resume-an-in-flight-implementation branch for a never-started story.
  _write_story_with_gate "E10-S6" "backlog"
  run "$DETECT_MODE" "docs/implementation-artifacts/E10-S6-test.md"
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

@test "detect-mode: missing arg shows usage" {
  run "$DETECT_MODE"
  [ "$status" -ne 0 ]
}

@test "detect-mode: missing file errors out" {
  run "$DETECT_MODE" "docs/implementation-artifacts/E99-S99-nonexistent.md"
  [ "$status" -ne 0 ]
}
