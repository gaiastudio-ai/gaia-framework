#!/usr/bin/env bats
# sprint-status-dashboard-stranded-ready.bats — E81-S4
#
# Tests `sprint-status-dashboard.sh` rendering of the "Stranded ready stories"
# section. Verifies AC1 (section present with rows when matches exist),
# AC2 (suppressed when empty), AC3 (no mutation), AC4 (PASSED verdict lookup
# union over `Story Validation:` / `Story Validation (re-run):` / `/gaia-<cmd>:`
# heading patterns; most-recent entry wins), and ordering (story key ascending).
#
# Refs: AC1, AC2, AC3, AC4, AC5, TC-SSP-1

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DASHBOARD="$REPO_ROOT/plugins/gaia/scripts/sprint-status-dashboard.sh"
  FIXTURE_ROOT="$BATS_TEST_DIRNAME/fixtures/stranded-ready"

  TEST_TMP="$BATS_TEST_TMPDIR/ssdsr-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$TEST_TMP/.gaia/memory/validator-sidecar"
  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

load_fixture() {
  local name="$1"
  cp "$FIXTURE_ROOT/$name/sprint-status.yaml" "$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml"
  cp "$FIXTURE_ROOT/$name/decision-log.md" "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  # Copy all story-*.md files into the implementation-artifacts root (flat layout)
  for f in "$FIXTURE_ROOT/$name/"story-*.md; do
    [ -e "$f" ] || continue
    cp "$f" "$IMPLEMENTATION_ARTIFACTS/$(basename "$f")"
  done
  export SPRINT_STATUS_YAML="$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml"
}

snapshot_files() {
  # Snapshot sha256+mtime for every story file plus sprint-status.yaml.
  local file
  for file in "$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml" "$IMPLEMENTATION_ARTIFACTS"/story-*.md; do
    [ -e "$file" ] || continue
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$file" | awk '{print $1}'
    else
      shasum -a 256 "$file" | awk '{print $1}'
    fi
    if stat -f '%m' "$file" >/dev/null 2>&1; then
      stat -f '%m' "$file"
    else
      stat -c '%Y' "$file"
    fi
  done
}

@test "none fixture — section suppressed (AC2)" {
  load_fixture "none"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ "Stranded ready stories" ]]
}

@test "one fixture — section present with exactly one row (AC1)" {
  load_fixture "one"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Stranded ready stories" ]]
  [[ "$output" =~ "E91-S2" ]]
  [[ "$output" =~ "Stranded ready story alpha" ]]
  # Decoy MUST NOT appear in the stranded section
  ! [[ "$output" =~ "E91-S1 — Decoy" ]]
  # Hint line about /gaia-correct-course and /gaia-sprint-plan
  [[ "$output" =~ "/gaia-correct-course" ]]
  [[ "$output" =~ "/gaia-sprint-plan" ]]
}

@test "multiple fixture — three stranded rows in ascending order (AC1, AC4)" {
  load_fixture "multiple"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Stranded ready stories" ]]
  # Expected stranded: E92-S2, E92-S3, E93-S1 (ascending by key)
  [[ "$output" =~ "E92-S2" ]]
  [[ "$output" =~ "E92-S3" ]]
  [[ "$output" =~ "E93-S1" ]]
  # Order: E92-S2 before E92-S3 before E93-S1
  s2_line=$(printf '%s\n' "$output" | grep -n 'E92-S2' | head -1 | cut -d: -f1)
  s3_line=$(printf '%s\n' "$output" | grep -n 'E92-S3' | head -1 | cut -d: -f1)
  d1_line=$(printf '%s\n' "$output" | grep -n 'E93-S1' | head -1 | cut -d: -f1)
  [ -n "$s2_line" ]
  [ -n "$s3_line" ]
  [ -n "$d1_line" ]
  [ "$s2_line" -lt "$s3_line" ]
  [ "$s3_line" -lt "$d1_line" ]
}

@test "multiple fixture — decoys excluded (FAILED, UNVERIFIED, in-progress, recency-edge)" {
  load_fixture "multiple"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  # Stranded-ready section header should appear, then check each decoy is NOT
  # inside the stranded section. We carve the stranded section out by line range.
  stranded_start=$(printf '%s\n' "$output" | grep -n 'Stranded ready stories' | head -1 | cut -d: -f1)
  [ -n "$stranded_start" ]
  stranded_block=$(printf '%s\n' "$output" | tail -n +"$stranded_start")
  # In-progress decoy E92-S1 must NOT be in the stranded section
  ! [[ "$stranded_block" =~ "E92-S1" ]]
  # FAILED decoy E92-S4 must NOT be in the stranded section
  ! [[ "$stranded_block" =~ "E92-S4" ]]
  # UNVERIFIED decoy (no log entry) E92-S5 must NOT be in the stranded section
  ! [[ "$stranded_block" =~ "E92-S5" ]]
  # Recency-edge decoy E92-S6 (older PASSED then newer FAILED) must NOT appear —
  # most-recent entry rule excludes it
  ! [[ "$stranded_block" =~ "E92-S6" ]]
}

@test "no-mutation invariant — fixture files byte-identical after render (AC3)" {
  load_fixture "multiple"
  before=$(snapshot_files)
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  after=$(snapshot_files)
  [ "$before" = "$after" ]
}
