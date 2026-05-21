#!/usr/bin/env bats
# af-2026-05-21-7-greenfield-bootstrap.bats
#
# Regression coverage for AF-2026-05-21-7: 14 GAIA scripts defaulted to
# legacy `_memory/` paths on greenfield projects, creating a rogue
# `_memory/` directory at project root before /gaia-init had a chance to
# bootstrap `.gaia/`. Live repro 2026-05-21 via /gaia:gaia-init on a
# brand-new project — orchestration-warning.sh and lifecycle-event.sh
# both materialized `_memory/` on first invocation.
#
# This bats file covers the 3-quadrant matrix for two representative
# scripts (one Category A smart-fallback, one Category B unconditional):
#   - greenfield (neither dir present)   → canonical .gaia/memory wins
#   - post-ADR-111 (only .gaia/ present) → canonical .gaia/memory wins
#   - pre-ADR-111 (only _memory/ present, no .gaia/) → legacy back-compat
#
# Plus a 4th quadrant (Val F8): both dirs present (common in long-running
# dev environments) → canonical wins (positive-evidence guard fails on
# the `! -d .gaia/memory` clause).

load 'test_helper.bash'

setup() {
  common_setup
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# orchestration-warning.sh — Category A smart-fallback, mkdir-active
# ---------------------------------------------------------------------------

@test "AF-21-7 / orchestration-warning.sh: greenfield → canonical .gaia/memory/checkpoints/" {
  # Fresh empty dir — neither _memory/ nor .gaia/ exists.
  [ ! -d "_memory" ] && [ ! -d ".gaia" ]
  run bash "$SCRIPTS_DIR/orchestration-warning.sh" \
    --skill-class heavy-procedural --mode subagent --session-id "test-$$"
  [ "$status" -eq 0 ]
  # Canonical dir MUST exist; legacy MUST NOT.
  [ -d ".gaia/memory/checkpoints" ]
  [ ! -d "_memory" ]
}

@test "AF-21-7 / orchestration-warning.sh: post-ADR-111 → canonical wins" {
  mkdir -p ".gaia/memory/checkpoints"
  run bash "$SCRIPTS_DIR/orchestration-warning.sh" \
    --skill-class heavy-procedural --mode subagent --session-id "test-$$"
  [ "$status" -eq 0 ]
  [ -d ".gaia/memory/checkpoints" ]
  [ ! -d "_memory" ]
}

@test "AF-21-7 / orchestration-warning.sh: pre-ADR-111 (only _memory/) → legacy honored" {
  mkdir -p "_memory/checkpoints"
  run bash "$SCRIPTS_DIR/orchestration-warning.sh" \
    --skill-class heavy-procedural --mode subagent --session-id "test-$$"
  [ "$status" -eq 0 ]
  # Legacy dir must be used; canonical must NOT be created.
  [ -d "_memory/checkpoints" ]
  [ ! -d ".gaia/memory" ]
  # Sentinel landed in legacy dir.
  ls _memory/checkpoints/orchestration-warning-pending.test-* >/dev/null 2>&1
}

@test "AF-21-7 / orchestration-warning.sh: both dirs present → canonical wins (Val F8)" {
  mkdir -p ".gaia/memory/checkpoints"
  mkdir -p "_memory/checkpoints"
  run bash "$SCRIPTS_DIR/orchestration-warning.sh" \
    --skill-class heavy-procedural --mode subagent --session-id "test-$$"
  [ "$status" -eq 0 ]
  # Sentinel landed in canonical, not legacy.
  ls .gaia/memory/checkpoints/orchestration-warning-pending.test-* >/dev/null 2>&1
  ! ls _memory/checkpoints/orchestration-warning-pending.test-* >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# lifecycle-event.sh — Category B unconditional default, mkdir-active
# (the EARLIEST script in the skill chain; the actual culprit on the live
# repro — fired before orchestration-warning.sh)
# ---------------------------------------------------------------------------

@test "AF-21-7 / lifecycle-event.sh: greenfield → canonical .gaia/memory/" {
  [ ! -d "_memory" ] && [ ! -d ".gaia" ]
  run bash "$SCRIPTS_DIR/lifecycle-event.sh" --type test --workflow af-21-7-test
  [ "$status" -eq 0 ]
  [ -f ".gaia/memory/lifecycle-events.jsonl" ]
  [ ! -d "_memory" ]
}

@test "AF-21-7 / lifecycle-event.sh: pre-ADR-111 (only _memory/) → legacy honored" {
  mkdir -p "_memory"
  run bash "$SCRIPTS_DIR/lifecycle-event.sh" --type test --workflow af-21-7-test
  [ "$status" -eq 0 ]
  [ -f "_memory/lifecycle-events.jsonl" ]
  [ ! -d ".gaia/memory" ]
}

@test "AF-21-7 / lifecycle-event.sh: post-ADR-111 → canonical wins" {
  mkdir -p ".gaia/memory"
  run bash "$SCRIPTS_DIR/lifecycle-event.sh" --type test --workflow af-21-7-test
  [ "$status" -eq 0 ]
  [ -f ".gaia/memory/lifecycle-events.jsonl" ]
  [ ! -d "_memory" ]
}

# ---------------------------------------------------------------------------
# write-checkpoint.sh — Category A smart-fallback (represents the 5-script
# original-intake set: same idiom as resume-discovery, resume-checkpoint,
# append-val-iteration, dispatch-agent-turn).
# ---------------------------------------------------------------------------

@test "AF-21-7 / write-checkpoint.sh: greenfield → canonical .gaia/memory/checkpoints/" {
  [ ! -d "_memory" ] && [ ! -d ".gaia" ]
  # Minimal valid checkpoint write
  run bash "$SCRIPTS_DIR/write-checkpoint.sh" af-21-7-test 1
  [ "$status" -eq 0 ]
  [ -d ".gaia/memory/checkpoints/af-21-7-test" ]
  [ ! -d "_memory" ]
}

@test "AF-21-7 / write-checkpoint.sh: pre-ADR-111 (only _memory/) → legacy honored" {
  mkdir -p "_memory/checkpoints"
  run bash "$SCRIPTS_DIR/write-checkpoint.sh" af-21-7-test 1
  [ "$status" -eq 0 ]
  [ -d "_memory/checkpoints/af-21-7-test" ]
  [ ! -d ".gaia/memory" ]
}
