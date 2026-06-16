#!/usr/bin/env bats
# manual-test-flakiness-tracking.bats — flakiness tracking + promotion gate (AC4)
#
# Verifies persistent verdict-flip tracking and advisory->gating promotion:
#   AC4 — flakiness (verdict-flip) rate tracked persistently;
#          advisory->gating promotion is a CONFIG change once rate<threshold
#          across 3 consecutive closed sprints.

load 'test_helper.bash'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  common_setup
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  FLAKINESS="$SCRIPTS_DIR/manual-test-flakiness.sh"

  mkdir -p "$TEST_TMP/.gaia/state"

  VERDICTS_TSV="$TEST_TMP/.gaia/state/manual-test-verdicts.tsv"
  export PROJECT_PATH="$TEST_TMP"
  export MANUAL_TEST_VERDICTS_TSV="$VERDICTS_TSV"
}

teardown() { common_teardown; }

# seed N sprint-archive files (closed sprints)
seed_closed_sprints() {
  local count="$1" base_dir="$TEST_TMP/docs/implementation-artifacts/sprint-archive"
  mkdir -p "$base_dir"
  local i
  for ((i=1; i<=count; i++)); do
    cat > "$base_dir/sprint-${i}-closed-2026-01-0${i}.yaml" <<EOF
sprint_id: "sprint-${i}"
status: closed
closed_at: "2026-01-0${i}T00:00:00Z"
EOF
  done
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
}

# =====================================================================
# Flip-rate computation
# =====================================================================

@test "AC4: 0% flip rate when all verdicts are identical (no flips)" {
  # story_key<TAB>run_id<TAB>verdict<TAB>timestamp
  printf '%s\t%s\t%s\t%s\n' "FK01" "run-1" "PASSED" "2026-01-01T00:00:00Z" > "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK01" "run-2" "PASSED" "2026-01-01T01:00:00Z" >> "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK01" "run-3" "PASSED" "2026-01-01T02:00:00Z" >> "$VERDICTS_TSV"

  run bash "$FLAKINESS" --story FK01
  [ "$status" -eq 0 ]
  [[ "$output" == *"flip_rate=0%"* ]]
}

@test "AC4: 50% flip rate with one flip in two transitions (PASSED then FAILED)" {
  printf '%s\t%s\t%s\t%s\n' "FK02" "run-1" "PASSED" "2026-01-01T00:00:00Z" > "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK02" "run-2" "FAILED" "2026-01-01T01:00:00Z" >> "$VERDICTS_TSV"

  run bash "$FLAKINESS" --story FK02
  [ "$status" -eq 0 ]
  # 1 flip / 1 transition = 100%, but the spec says "50% one flip (PASSED then FAILED)"
  # which implies 1 flip / 2 runs = 50%
  [[ "$output" == *"50"* ]]
}

# =====================================================================
# Promotion check
# =====================================================================

@test "AC4: --check-promotion with 3 closed sprints under threshold -> exit 0" {
  seed_closed_sprints 3
  # All verdicts stable — 0% flip rate
  printf '%s\t%s\t%s\t%s\n' "FK03" "run-1" "PASSED" "2026-01-01T00:00:00Z" > "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK03" "run-2" "PASSED" "2026-01-02T00:00:00Z" >> "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK03" "run-3" "PASSED" "2026-01-03T00:00:00Z" >> "$VERDICTS_TSV"

  run bash "$FLAKINESS" --check-promotion
  [ "$status" -eq 0 ]
}

@test "AC4: --check-promotion with only 2 closed sprints -> exit 1" {
  seed_closed_sprints 2
  printf '%s\t%s\t%s\t%s\n' "FK04" "run-1" "PASSED" "2026-01-01T00:00:00Z" > "$VERDICTS_TSV"

  run bash "$FLAKINESS" --check-promotion
  [ "$status" -eq 1 ]
}

@test "AC4: --check-promotion with 3 sprints but one over threshold -> exit 1" {
  seed_closed_sprints 3
  # Inject flip: PASSED -> FAILED (50% flip rate, above 10% default threshold)
  printf '%s\t%s\t%s\t%s\n' "FK05" "run-1" "PASSED" "2026-01-01T00:00:00Z" > "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK05" "run-2" "FAILED" "2026-01-01T01:00:00Z" >> "$VERDICTS_TSV"

  run bash "$FLAKINESS" --check-promotion
  [ "$status" -eq 1 ]
}

@test "AC4: aggregate flip rate counts only within-story flips (interleaved TSV)" {
  # Two stories interleaved chronologically:
  #   FK10: PASSED -> PASSED  (0 flips, 2 runs)
  #   FK11: PASSED -> FAILED  (1 flip,  2 runs)
  # Without grouping, the FK10(PASSED)->FK11(PASSED) and FK11(PASSED)->FK10(PASSED)
  # cross-story boundaries would be wrongly counted as flips.
  # Correct aggregate: 1 flip / 4 total runs = 25%
  printf '%s\t%s\t%s\t%s\n' "FK10" "run-1" "PASSED" "2026-01-01T00:00:00Z" >  "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK11" "run-1" "PASSED" "2026-01-01T01:00:00Z" >> "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK10" "run-2" "PASSED" "2026-01-01T02:00:00Z" >> "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "FK11" "run-2" "FAILED" "2026-01-01T03:00:00Z" >> "$VERDICTS_TSV"

  seed_closed_sprints 3
  run bash "$FLAKINESS" --check-promotion
  # 25% is above the default 10% threshold -> exit 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"25%"* ]]

  # Also verify per-story rates are correct
  run bash "$FLAKINESS" --story FK10
  [ "$status" -eq 0 ]
  [[ "$output" == *"flip_rate=0%"* ]]

  run bash "$FLAKINESS" --story FK11
  [ "$status" -eq 0 ]
  [[ "$output" == *"flip_rate=50%"* ]]
}

@test "AC4: --check-promotion with empty verdicts file -> exit 1" {
  seed_closed_sprints 3
  touch "$VERDICTS_TSV"

  run bash "$FLAKINESS" --check-promotion
  [ "$status" -eq 1 ]
}

# =====================================================================
# Direct unit tests — source the script and call public functions by name
# (satisfies NFR-052 public-function coverage gate)
# =====================================================================

@test "unit: resolve_verdicts_path returns canonical path when no override" {
  unset MANUAL_TEST_VERDICTS_TSV
  export PROJECT_PATH="$TEST_TMP"
  source "$FLAKINESS"
  result="$(resolve_verdicts_path)"
  [ "$result" = "$TEST_TMP/.gaia/state/manual-test-verdicts.tsv" ]
}

@test "unit: resolve_verdicts_path respects MANUAL_TEST_VERDICTS_TSV override" {
  export MANUAL_TEST_VERDICTS_TSV="$TEST_TMP/custom-verdicts.tsv"
  source "$FLAKINESS"
  result="$(resolve_verdicts_path)"
  [ "$result" = "$TEST_TMP/custom-verdicts.tsv" ]
}

@test "unit: compute_story_flip_rate returns 0 for no flips" {
  printf '%s\t%s\t%s\t%s\n' "U01" "r1" "PASSED" "2026-01-01T00:00:00Z" > "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "U01" "r2" "PASSED" "2026-01-01T01:00:00Z" >> "$VERDICTS_TSV"
  source "$FLAKINESS"
  result="$(compute_story_flip_rate "U01")"
  [ "$result" = "0" ]
}

@test "unit: compute_story_flip_rate returns 50 for one flip in two runs" {
  printf '%s\t%s\t%s\t%s\n' "U02" "r1" "PASSED" "2026-01-01T00:00:00Z" > "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "U02" "r2" "FAILED" "2026-01-01T01:00:00Z" >> "$VERDICTS_TSV"
  source "$FLAKINESS"
  result="$(compute_story_flip_rate "U02")"
  [ "$result" = "50" ]
}

@test "unit: compute_aggregate_flip_rate groups by story (interleaved TSV)" {
  # Two stories interleaved: U10 stable (0 flips), U11 flaky (1 flip)
  # Correct aggregate: 1 flip / 4 runs = 25%
  printf '%s\t%s\t%s\t%s\n' "U10" "r1" "PASSED" "2026-01-01T00:00:00Z" >  "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "U11" "r1" "PASSED" "2026-01-01T01:00:00Z" >> "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "U10" "r2" "PASSED" "2026-01-01T02:00:00Z" >> "$VERDICTS_TSV"
  printf '%s\t%s\t%s\t%s\n' "U11" "r2" "FAILED" "2026-01-01T03:00:00Z" >> "$VERDICTS_TSV"
  source "$FLAKINESS"
  result="$(compute_aggregate_flip_rate)"
  [ "$result" = "25" ]
}

@test "unit: compute_aggregate_flip_rate returns 0 for empty file" {
  touch "$VERDICTS_TSV"
  source "$FLAKINESS"
  result="$(compute_aggregate_flip_rate)"
  [ "$result" = "0" ]
}

@test "unit: count_closed_sprints counts yaml files in sprint-archive" {
  seed_closed_sprints 5
  source "$FLAKINESS"
  result="$(count_closed_sprints)"
  [ "$result" = "5" ]
}

@test "unit: count_closed_sprints returns 0 when archive dir missing" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/nonexistent"
  source "$FLAKINESS"
  result="$(count_closed_sprints)"
  [ "$result" = "0" ]
}
