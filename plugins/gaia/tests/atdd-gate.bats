#!/usr/bin/env bats
# atdd-gate.bats — coverage for skills/gaia-dev-story/scripts/atdd-gate.sh
#
# Story: E55-S8 — Auto-reviews YOLO-only + helper scripts + bats coverage
#
# The atdd-gate script ships with E55-S5 (already landed). This file is
# the bats coverage E55-S8 owns. We exercise the full risk matrix:
#   - medium / low / unset risk: pass unconditionally
#   - high risk + epic-glob ATDD file present: pass
#   - high risk + story-glob ATDD file present: pass
#   - high risk + no ATDD file: HALT (exit 1) with expected-glob message
#   - invalid story_key shape: usage error (exit 2)
#   - missing story file: usage error (exit 2)

load 'test_helper.bash'

setup() {
  common_setup
  ATDD_GATE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/atdd-gate.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts docs/test-artifacts
  export PROJECT_PATH="$TEST_TMP"
}

teardown() { common_teardown; }

_write_story() {
  local key="$1" risk="$2"
  cat > "docs/implementation-artifacts/${key}-test.md" <<EOF
---
key: "$key"
risk: "$risk"
status: in-progress
---

# Story: Test
EOF
}

# ---------------------------------------------------------------------------
# Non-high risk
# ---------------------------------------------------------------------------

@test "atdd-gate: medium risk passes with no ATDD file" {
  _write_story "E10-S1" "medium"
  run "$ATDD_GATE" "E10-S1"
  [ "$status" -eq 0 ]
}

@test "atdd-gate: low risk passes with no ATDD file" {
  _write_story "E10-S2" "low"
  run "$ATDD_GATE" "E10-S2"
  [ "$status" -eq 0 ]
}

@test "atdd-gate: unset risk passes with no ATDD file" {
  cat > "docs/implementation-artifacts/E10-S3-test.md" <<'EOF'
---
key: "E10-S3"
status: in-progress
---

# Story: Test
EOF
  run "$ATDD_GATE" "E10-S3"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# High risk — present (epic glob)
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk passes when atdd-{epic}*.md is present" {
  _write_story "E20-S5" "high"
  : > "docs/test-artifacts/atdd-E20-coverage.md"
  run "$ATDD_GATE" "E20-S5"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# High risk — present (story glob)
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk passes when atdd-{story}*.md is present" {
  _write_story "E20-S6" "high"
  : > "docs/test-artifacts/atdd-E20-S6-scenarios.md"
  run "$ATDD_GATE" "E20-S6"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# High risk — present at the canonical NESTED per-story home (issue #1108)
# /gaia-atdd writes test-artifacts/epic-{slug}/{key}-{slug}/atdd.md via the
# resolver; the gate must accept it, not only the legacy flat globs.
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk passes when nested per-story atdd.md is present (issue #1108)" {
  _write_story "E20-S7" "high"
  # The resolver's nested home for a story with no per-story dir is
  # test-artifacts/epic-{EPIC}/{KEY}/atdd.md (stories/ level dropped per
  # AF-2026-06-01-1). Create it where /gaia-atdd would write.
  mkdir -p "docs/test-artifacts/epic-E20/E20-S7"
  : > "docs/test-artifacts/epic-E20/E20-S7/atdd.md"
  # No flat atdd-E20-S7*.md exists — only the nested file.
  run "$ATDD_GATE" "E20-S7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "epic-E20/E20-S7/atdd.md"
}

@test "atdd-gate: high risk passes when nested atdd.md under stories/ legacy level is present (issue #1108)" {
  _write_story "E20-S8" "high"
  # Legacy nested form with the stories/ middle level (read-compat fallback).
  mkdir -p "docs/test-artifacts/epic-E20/stories/E20-S8"
  : > "docs/test-artifacts/epic-E20/stories/E20-S8/atdd.md"
  run "$ATDD_GATE" "E20-S8"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# High risk — missing -> HALT
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk with no ATDD file HALTs (exit 1) and names globs" {
  _write_story "E30-S1" "high"
  run "$ATDD_GATE" "E30-S1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"atdd-E30"* ]]
  [[ "$output" == *"atdd-E30-S1"* ]]
}

# ---------------------------------------------------------------------------
# Usage errors — exit 2
# ---------------------------------------------------------------------------

@test "atdd-gate: invalid story_key shape -> usage error (exit 2)" {
  run "$ATDD_GATE" "not-a-story"
  [ "$status" -eq 2 ]
}

@test "atdd-gate: missing story file -> usage error (exit 2)" {
  run "$ATDD_GATE" "E99-S99"
  [ "$status" -eq 2 ]
}

@test "atdd-gate: no args -> usage error (exit 2)" {
  run "$ATDD_GATE"
  [ "$status" -eq 2 ]
}
