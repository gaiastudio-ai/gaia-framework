#!/usr/bin/env bats
# phase-exit-gate.bats — unit tests for plugins/gaia/scripts/lib/phase-exit-gate.sh
# Covers AC7, AC11 of E96-S1 (ADR-111). Maps to TC-GLM-1.
#
# Scenarios:
#   1. All 3 criteria pass -> phase marked done
#   2. find-count mismatch -> automatic rollback + halt
#   3. sha256 diff non-zero -> automatic rollback + halt
#   4. bats-baseline regression (test count drops) -> automatic rollback + halt
#   5. Rollback restores pre-migration state byte-identically

load 'test_helper.bash'

setup() {
  common_setup
  GATE="$SCRIPTS_DIR/lib/phase-exit-gate.sh"
  PROJECT_ROOT="$TEST_TMP/proj"
  mkdir -p "$PROJECT_ROOT/config" "$PROJECT_ROOT/.gaia-migrate-backup"
  export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"

  # Seed a pre-migration source tree
  echo "alpha" > "$PROJECT_ROOT/config/a.txt"
  echo "beta"  > "$PROJECT_ROOT/config/b.txt"
  mkdir -p "$PROJECT_ROOT/config/sub"
  echo "gamma" > "$PROJECT_ROOT/config/sub/c.txt"

  # Pre-phase tarball
  cd "$PROJECT_ROOT"
  tar -czf .gaia-migrate-backup/phase-1-test.tar.gz config/
  shasum -a 256 .gaia-migrate-backup/phase-1-test.tar.gz | awk '{print $1}' > .gaia-migrate-backup/phase-1-test.tar.gz.sha256

  # Pre-migration sha256 manifest
  MANIFEST="$PROJECT_ROOT/.gaia-migrate-backup/phase-1-manifest.txt"
  ( cd "$PROJECT_ROOT/config" && find . -type f | sort | xargs shasum -a 256 ) > "$MANIFEST"
  export MANIFEST

  # Move config/ -> .gaia/config/ to simulate Phase 1 atomic move
  mkdir -p "$PROJECT_ROOT/.gaia"
  mv "$PROJECT_ROOT/config" "$PROJECT_ROOT/.gaia/config"
  mkdir -p "$PROJECT_ROOT/config"
  echo "MOVED TO .gaia/config/" > "$PROJECT_ROOT/config/.gaia-pointer"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT MANIFEST 2>/dev/null || true
  common_teardown
}

@test "phase-exit-gate.sh: file exists at canonical path" {
  [ -f "$GATE" ]
}

@test "phase-exit-gate.sh: all 3 criteria pass -> exit 0 (AC7a)" {
  run bash "$GATE" \
    --source-dir "$PROJECT_ROOT/.gaia/config" \
    --manifest "$MANIFEST" \
    --bats-baseline 10 --bats-current 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "phase-exit-gate.sh: missing manifest file -> rollback + halt (AC7b)" {
  # E96-S6: Criterion 2 rewritten from `find -type f | wc -l` parity to
  # per-manifest-row existence check. Deleting a manifest-recorded file
  # still triggers rollback — only the error wording changed.
  rm "$PROJECT_ROOT/.gaia/config/a.txt"
  run bash "$GATE" \
    --source-dir "$PROJECT_ROOT/.gaia/config" \
    --manifest "$MANIFEST" \
    --bats-baseline 10 --bats-current 10 \
    --tarball "$PROJECT_ROOT/.gaia-migrate-backup/phase-1-test.tar.gz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"per-file existence"* ]] || [[ "$output" == *"missing file"* ]] || [[ "$output" == *"file count mismatch"* ]] || [[ "$output" == *"find-count"* ]]
}

@test "phase-exit-gate.sh: sha256 diff -> rollback + halt (AC7c)" {
  echo "corrupted" > "$PROJECT_ROOT/.gaia/config/a.txt"
  run bash "$GATE" \
    --source-dir "$PROJECT_ROOT/.gaia/config" \
    --manifest "$MANIFEST" \
    --bats-baseline 10 --bats-current 10 \
    --tarball "$PROJECT_ROOT/.gaia-migrate-backup/phase-1-test.tar.gz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256"* ]] || [[ "$output" == *"hash mismatch"* ]]
}

@test "phase-exit-gate.sh: bats-baseline regression -> halt (AC7a)" {
  run bash "$GATE" \
    --source-dir "$PROJECT_ROOT/.gaia/config" \
    --manifest "$MANIFEST" \
    --bats-baseline 10 --bats-current 8 \
    --tarball "$PROJECT_ROOT/.gaia-migrate-backup/phase-1-test.tar.gz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bats"* ]] || [[ "$output" == *"baseline"* ]]
}

@test "phase-exit-gate.sh: rollback restores byte-identical pre-state (AC11e)" {
  rm "$PROJECT_ROOT/.gaia/config/a.txt"
  # Trigger rollback
  bash "$GATE" \
    --source-dir "$PROJECT_ROOT/.gaia/config" \
    --manifest "$MANIFEST" \
    --bats-baseline 10 --bats-current 10 \
    --tarball "$PROJECT_ROOT/.gaia-migrate-backup/phase-1-test.tar.gz" || true
  # After rollback, config/ should be restored at legacy path
  [ -f "$PROJECT_ROOT/config/a.txt" ]
  [ "$(cat "$PROJECT_ROOT/config/a.txt")" = "alpha" ]
  [ "$(cat "$PROJECT_ROOT/config/b.txt")" = "beta" ]
  [ "$(cat "$PROJECT_ROOT/config/sub/c.txt")" = "gamma" ]
}

@test "phase-exit-gate.sh: tarball-sha256 mismatch refuses rollback (AC5)" {
  # Corrupt the tarball
  echo "trash" >> "$PROJECT_ROOT/.gaia-migrate-backup/phase-1-test.tar.gz"
  rm "$PROJECT_ROOT/.gaia/config/a.txt"
  run bash "$GATE" \
    --source-dir "$PROJECT_ROOT/.gaia/config" \
    --manifest "$MANIFEST" \
    --bats-baseline 10 --bats-current 10 \
    --tarball "$PROJECT_ROOT/.gaia-migrate-backup/phase-1-test.tar.gz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL"* ]] || [[ "$output" == *"tarball"* ]]
}
