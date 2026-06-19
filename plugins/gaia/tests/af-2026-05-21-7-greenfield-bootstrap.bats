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
# This bats file covers the path-resolution matrix for representative scripts.
# AF-2026-05-27-3 (ADR-111): the legacy `_memory/` fallback was REMOVED — every
# quadrant now resolves the canonical `.gaia/memory` tree:
#   - greenfield (neither dir present)        → .gaia/memory
#   - post-ADR-111 (only .gaia/ present)      → .gaia/memory
#   - stray _memory/ present (no .gaia/)      → .gaia/memory (legacy NOT honored)
#   - both dirs present                       → .gaia/memory
# (Env overrides like MEMORY_PATH / CHECKPOINT_PATH still win where supported.)

load 'test_helper.bash'

setup() {
  common_setup
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# orchestration-warning.sh — Category A smart-fallback, mkdir-active
# ---------------------------------------------------------------------------

@test "orchestration-warning.sh: greenfield → canonical .gaia/memory/checkpoints/" {
  # Fresh empty dir — neither _memory/ nor .gaia/ exists.
  [ ! -d "_memory" ] && [ ! -d ".gaia" ]
  run bash "$SCRIPTS_DIR/orchestration-warning.sh" \
    --skill-class heavy-procedural --mode subagent --session-id "test-$$"
  [ "$status" -eq 0 ]
  # Canonical dir MUST exist; legacy MUST NOT.
  [ -d ".gaia/memory/checkpoints" ]
  [ ! -d "_memory" ]
}

@test "orchestration-warning.sh: post-migration → canonical wins" {
  mkdir -p ".gaia/memory/checkpoints"
  run bash "$SCRIPTS_DIR/orchestration-warning.sh" \
    --skill-class heavy-procedural --mode subagent --session-id "test-$$"
  [ "$status" -eq 0 ]
  [ -d ".gaia/memory/checkpoints" ]
  [ ! -d "_memory" ]
}

@test "orchestration-warning.sh: stray _memory/ present → canonical .gaia/memory wins" {
  # AF-2026-05-27-3: the legacy _memory/ fallback was removed (ADR-111). Even
  # when a stray _memory/checkpoints exists, the sentinel now lands in the
  # canonical .gaia/memory/checkpoints — the legacy dir is NOT honored.
  mkdir -p "_memory/checkpoints"
  run bash "$SCRIPTS_DIR/orchestration-warning.sh" \
    --skill-class heavy-procedural --mode subagent --session-id "test-$$"
  [ "$status" -eq 0 ]
  ls .gaia/memory/checkpoints/orchestration-warning-pending.test-* >/dev/null 2>&1
  ! ls _memory/checkpoints/orchestration-warning-pending.test-* >/dev/null 2>&1
}

@test "orchestration-warning.sh: both dirs present → canonical wins (Val F8)" {
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

@test "lifecycle-event.sh: greenfield → canonical .gaia/memory/" {
  [ ! -d "_memory" ] && [ ! -d ".gaia" ]
  run bash "$SCRIPTS_DIR/lifecycle-event.sh" --type test --workflow af-21-7-test
  [ "$status" -eq 0 ]
  [ -f ".gaia/memory/lifecycle-events.jsonl" ]
  [ ! -d "_memory" ]
}

@test "lifecycle-event.sh: stray _memory/ present → canonical .gaia/memory wins" {
  # AF-2026-05-27-3: legacy _memory/ fallback removed (ADR-111). Events land in
  # .gaia/memory/ even when a stray _memory/ exists; the legacy dir is untouched.
  mkdir -p "_memory"
  run bash "$SCRIPTS_DIR/lifecycle-event.sh" --type test --workflow af-21-7-test
  [ "$status" -eq 0 ]
  [ -f ".gaia/memory/lifecycle-events.jsonl" ]
  [ ! -f "_memory/lifecycle-events.jsonl" ]
}

@test "lifecycle-event.sh: post-migration → canonical wins" {
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

@test "write-checkpoint.sh: greenfield → canonical .gaia/memory/checkpoints/" {
  [ ! -d "_memory" ] && [ ! -d ".gaia" ]
  # Minimal valid checkpoint write
  run bash "$SCRIPTS_DIR/write-checkpoint.sh" af-21-7-test 1
  [ "$status" -eq 0 ]
  [ -d ".gaia/memory/checkpoints/af-21-7-test" ]
  [ ! -d "_memory" ]
}

@test "write-checkpoint.sh: stray _memory/ present → canonical .gaia/memory wins" {
  # AF-2026-05-27-3: legacy _memory/ fallback removed (ADR-111). Checkpoints land
  # in .gaia/memory/checkpoints even when a stray _memory/checkpoints exists.
  mkdir -p "_memory/checkpoints"
  run bash "$SCRIPTS_DIR/write-checkpoint.sh" af-21-7-test 1
  [ "$status" -eq 0 ]
  [ -d ".gaia/memory/checkpoints/af-21-7-test" ]
  [ ! -d "_memory/checkpoints/af-21-7-test" ]
}
