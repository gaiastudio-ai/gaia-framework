#!/usr/bin/env bats
# e38-s3-lint-dependencies.bats
#
# Integration tests for the lint-dependencies sub-operation added by E38-S3.
# Exercises the full CLI contract: sprint-state.sh lint-dependencies [opts]
#
# Covers: AC1, AC2, AC-EC1 through AC-EC13
# Test IDs: TC-SPQG-7 (clean + inversion), TC-SPQG-8 (wired into sprint-plan),
#           TC-SPQG-9 (override path — SKILL.md only, not exercised here)
#
# These tests invoke sprint-state.sh as a subprocess (not sourced) to
# validate the full CLI arg parsing and exit-code contract.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

SPRINT_STATE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/sprint-state.sh"

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
_make_story_file() {
  local dir="$1" key="$2" status="$3"
  local depends_on="${4:-}"
  local ac_text="${5:-}"
  local file="${dir}/${key}-story.md"
  cat > "$file" <<EOF
---
template: 'story'
key: ${key}
status: ${status}
depends_on: [${depends_on}]
---
> **Status:** ${status}

## Acceptance Criteria

${ac_text:-No AC text.}
EOF
}

_make_yaml() {
  local file="$1"; shift
  cat > "$file" <<HEADER
sprint_id: "sprint-99"
duration: "2 weeks"
stories:
HEADER
  while [ $# -ge 2 ]; do
    local k="$1" st="$2"; shift 2
    cat >> "$file" <<ENTRY
  - key: ${k}
    title: "Title for ${k}"
    status: "${st}"
    points: 3
ENTRY
  done
}

# ===========================================================================
# CLI contract: subcommand recognition
# ===========================================================================

@test "lint-dependencies: recognized as valid subcommand" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
duration: "2 weeks"
stories: []
EOF
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies
  # Should not fail with "unknown subcommand"
  [ "$status" -ne 1 ] || [[ ! "$output" =~ "unknown subcommand" ]]
}

@test "lint-dependencies: --format json produces valid JSON" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sprint_id"'
}

@test "lint-dependencies: --format text produces text output" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format text
  [ "$status" -eq 0 ]
}

@test "lint-dependencies: default format is json" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sprint_id"'
}

# ===========================================================================
# TC-SPQG-7: Clean sprint + inversions
# ===========================================================================

@test "clean sprint exits 0" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  _make_story_file "$dir" "E1-S3" "ready-for-dev"
  _make_story_file "$dir" "E1-S4" "ready-for-dev"
  _make_story_file "$dir" "E1-S5" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev" \
    "E1-S3" "ready-for-dev" \
    "E1-S4" "ready-for-dev" \
    "E1-S5" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status": "clean"'
  echo "$output" | grep -q '"stories_analyzed": 5'
}

@test "forward-reference inversion flagged" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  _make_story_file "$dir" "E1-S3" "ready-for-dev" '"E1-S5"'
  _make_story_file "$dir" "E1-S4" "ready-for-dev"
  _make_story_file "$dir" "E1-S5" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev" \
    "E1-S3" "ready-for-dev" \
    "E1-S4" "ready-for-dev" \
    "E1-S5" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format json
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '"dependent": "E1-S3"'
  echo "$output" | grep -q '"dependency": "E1-S5"'
  echo "$output" | grep -q '"confidence": "explicit"'
  echo "$output" | grep -q '"suggested_reorder"'
}

# ===========================================================================
# Edge cases (AC-EC1 through AC-EC13)
# ===========================================================================

@test "empty sprint reports 0 stories, clean, exit 0" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
duration: "2 weeks"
stories: []
EOF
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"stories_analyzed": 0'
  echo "$output" | grep -q '"status": "clean"'
}

@test "external dependency emits heuristic inversion" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" '"E2-S1"'
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format json
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '"confidence": "heuristic"'
  echo "$output" | grep -q "External dependency"
}

@test "circular A->B->A reports inversions, terminates" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" '"E1-S2"'
  _make_story_file "$dir" "E1-S2" "ready-for-dev" '"E1-S1"'
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format json
  # Should exit 2 (inversions detected) — at least one edge is forward
  [ "$status" -eq 2 ]
}

@test "malformed yaml exits 1" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  local yaml="$TEST_TMP/sprint-status.yaml"
  printf 'this is not valid yaml: [[[' > "$yaml"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies
  [ "$status" -eq 1 ]
}

@test "story file not found exits 1" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "not found"
}

@test "Unicode in AC text does not crash" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" "" \
    "Given the system uses 🚀 emoji and café résumé text with BOM ﻿"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev"
  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format json
  [ "$status" -eq 0 ]
}

@test "read-only guarantee — no writes to any file" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" '"E1-S2"'
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  local yaml="$TEST_TMP/sprint-status.yaml"
  _make_yaml "$yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev"

  # Snapshot checksums
  local before_yaml before_s1 before_s2
  before_yaml="$(shasum -a 256 "$yaml" | cut -d' ' -f1)"
  before_s1="$(shasum -a 256 "$dir/E1-S1-story.md" | cut -d' ' -f1)"
  before_s2="$(shasum -a 256 "$dir/E1-S2-story.md" | cut -d' ' -f1)"

  run env PROJECT_PATH="$TEST_TMP" \
      IMPLEMENTATION_ARTIFACTS="$dir" \
      SPRINT_STATUS_YAML="$yaml" \
      bash "$SPRINT_STATE_SH" lint-dependencies --format json

  local after_yaml after_s1 after_s2
  after_yaml="$(shasum -a 256 "$yaml" | cut -d' ' -f1)"
  after_s1="$(shasum -a 256 "$dir/E1-S1-story.md" | cut -d' ' -f1)"
  after_s2="$(shasum -a 256 "$dir/E1-S2-story.md" | cut -d' ' -f1)"
  [ "$before_yaml" = "$after_yaml" ]
  [ "$before_s1" = "$after_s1" ]
  [ "$before_s2" = "$after_s2" ]
}

# ===========================================================================
# --help should include lint-dependencies
# ===========================================================================

@test "help text mentions lint-dependencies" {
  run bash "$SPRINT_STATE_SH" --help
  echo "$output" | grep -q "lint-dependencies"
}
