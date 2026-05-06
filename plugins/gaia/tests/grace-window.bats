#!/usr/bin/env bats
# grace-window.bats — E66-S3 ADR-082 7-day grace window helper
#
# Tests for grace-window.sh, which compares a flip activation timestamp to
# "now" and emits the gating mode (WARNING-with-explanation during the 7-day
# window; BLOCK after).
#
# Refs: ADR-082, NFR-RSV2-6.
# Story: E66-S3 — covers AC6, AC7.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/grace-window.sh"
}
teardown() { common_teardown; }

# ---------- AC6: grace window WARNING ----------

@test "AC6 (TC-7): flip 3 days ago -> WARNING mode" {
  # 3 days = 259200 seconds
  local now flip
  now=1714694400  # 2024-05-03T00:00:00Z arbitrary fixed epoch
  flip=$((now - 3*86400))
  run --separate-stderr "$SCRIPT" --flip-timestamp "$flip" --now "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=WARNING"* ]]
  [[ "$output" == *"days_remaining=4"* ]]
}

@test "AC6: flip 0 days ago (just deployed) -> WARNING mode, days_remaining=7" {
  local now flip
  now=1714694400
  flip="$now"
  run --separate-stderr "$SCRIPT" --flip-timestamp "$flip" --now "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=WARNING"* ]]
  [[ "$output" == *"days_remaining=7"* ]]
}

@test "AC6: flip 6 days ago (last day of grace) -> WARNING, days_remaining=1" {
  local now flip
  now=1714694400
  flip=$((now - 6*86400))
  run --separate-stderr "$SCRIPT" --flip-timestamp "$flip" --now "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=WARNING"* ]]
  [[ "$output" == *"days_remaining=1"* ]]
}

# ---------- AC7: hard block after grace ----------

@test "AC7 (TC-8): flip 8 days ago -> BLOCK mode" {
  local now flip
  now=1714694400
  flip=$((now - 8*86400))
  run --separate-stderr "$SCRIPT" --flip-timestamp "$flip" --now "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=BLOCK"* ]]
}

@test "AC7: flip exactly 7 days ago (boundary) -> BLOCK mode (grace expired)" {
  local now flip
  now=1714694400
  flip=$((now - 7*86400))
  run --separate-stderr "$SCRIPT" --flip-timestamp "$flip" --now "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=BLOCK"* ]]
}

# ---------- usage / error handling ----------

@test "usage: missing --flip-timestamp -> exit 1" {
  run --separate-stderr "$SCRIPT" --now 1714694400
  [ "$status" -eq 1 ]
}

@test "usage: --help exits 0 with usage" {
  run --separate-stderr "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"grace-window"* ]]
}

@test "AC6: WARNING mode includes resolution recommendation text" {
  local now flip
  now=1714694400
  flip=$((now - 2*86400))
  run --separate-stderr "$SCRIPT" --flip-timestamp "$flip" --now "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolve before grace window closes"* ]] || [[ "$output" == *"recommendation"* ]]
}

@test "no --now flag falls back to system clock (smoke test)" {
  # Use a flip timestamp 100 days ago — must be BLOCK regardless of when test runs.
  local now flip
  now="$(date -u +%s)"
  flip=$((now - 100*86400))
  run --separate-stderr "$SCRIPT" --flip-timestamp "$flip"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=BLOCK"* ]]
}
