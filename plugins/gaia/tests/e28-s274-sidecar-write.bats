#!/usr/bin/env bats
# Tests for sidecar-write.sh — general-purpose agent sidecar writer.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sidecar-write.sh"
  TMPROOT="${BATS_TEST_TMPDIR}/project-$$"
  mkdir -p "$TMPROOT"
}

teardown() {
  rm -rf "$TMPROOT"
}

@test "creates sidecar dir and decision-log on first write (AC1)" {
  run bash "$SCRIPT" --agent zara --slug test-decision \
    --decision "Test decision text" --root "$TMPROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  [ -d "$TMPROOT/.gaia/memory/zara-sidecar" ]
  [ -f "$TMPROOT/.gaia/memory/zara-sidecar/decision-log.md" ]
}

@test "decision-log contains the written entry (AC2)" {
  bash "$SCRIPT" --agent zara --slug review-finding \
    --decision "Decided to mitigate XSS via CSP" --root "$TMPROOT"
  grep -q "slug: review-finding" "$TMPROOT/.gaia/memory/zara-sidecar/decision-log.md"
  grep -q "Decided to mitigate XSS via CSP" "$TMPROOT/.gaia/memory/zara-sidecar/decision-log.md"
}

@test "appends to existing decision-log without overwriting (AC3)" {
  bash "$SCRIPT" --agent nate --slug first \
    --decision "First entry" --root "$TMPROOT"
  bash "$SCRIPT" --agent nate --slug second \
    --decision "Second entry" --root "$TMPROOT"
  local log="$TMPROOT/.gaia/memory/nate-sidecar/decision-log.md"
  grep -q "First entry" "$log"
  grep -q "Second entry" "$log"
}

@test "duplicate entry is skipped idempotently (AC4)" {
  bash "$SCRIPT" --agent zara --slug dup-test \
    --decision "Same text" --root "$TMPROOT"
  run bash "$SCRIPT" --agent zara --slug dup-test \
    --decision "Same text" --root "$TMPROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped"* ]]
}

@test "missing --agent exits with error (AC5)" {
  run bash "$SCRIPT" --slug foo --decision bar --root "$TMPROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--agent is required"* ]]
}

@test "missing --slug exits with error (AC6)" {
  run bash "$SCRIPT" --agent zara --decision bar --root "$TMPROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--slug is required"* ]]
}

@test "--help prints usage and exits 0 (AC7)" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"sidecar-write.sh"* ]]
  [[ "$output" == *"--agent"* ]]
}

@test "sidecar_write function is callable when sourced (AC8)" {
  # Source the script and call the function directly — satisfies the
  # public-function coverage gate.
  (
    source "$SCRIPT"
    sidecar_write "val" "source-test" "Sourced call" "$TMPROOT"
  )
  [ -f "$TMPROOT/.gaia/memory/val-sidecar/decision-log.md" ]
  grep -q "Sourced call" "$TMPROOT/.gaia/memory/val-sidecar/decision-log.md"
}

@test "--agent with path traversal is rejected (AC-traversal)" {
  run bash "$SCRIPT" --agent '../evil' --slug test \
    --decision "Escape attempt" --root "$TMPROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --agent"* ]]
  # No write outside .gaia/memory/
  [ ! -d "$TMPROOT/../evil-sidecar" ]
}

@test "--slug with slash is rejected (AC-slug-slash)" {
  run bash "$SCRIPT" --agent zara --slug 'sub/dir' \
    --decision "Slash attempt" --root "$TMPROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --slug"* ]]
}

@test "two different long decisions with same slug are both written (AC-dedup-full)" {
  # Generate two genuinely different decisions that share the same first 200 chars
  local prefix
  prefix="$(printf 'A%.0s' {1..250})"
  local decision_a="${prefix}-UNIQUE-ALPHA"
  local decision_b="${prefix}-UNIQUE-BRAVO"

  bash "$SCRIPT" --agent nate --slug long-test \
    --decision "$decision_a" --root "$TMPROOT"
  run bash "$SCRIPT" --agent nate --slug long-test \
    --decision "$decision_b" --root "$TMPROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local log="$TMPROOT/.gaia/memory/nate-sidecar/decision-log.md"
  grep -q "UNIQUE-ALPHA" "$log"
  grep -q "UNIQUE-BRAVO" "$log"
}
