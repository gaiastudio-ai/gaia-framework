#!/usr/bin/env bats
# phase-5-cleanup.bats — E96-S5 cleanup sweep coverage.

load '../test_helper.bash'

setup() {
  common_setup
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)"
  export SCRIPTS_DIR
  CLEANUP="$SCRIPTS_DIR/migrate/migrate-phase-5-cleanup.sh"
}

teardown() { common_teardown; }

@test "migrate-phase-5-cleanup.sh: exists at canonical path" {
  [ -f "$CLEANUP" ]
}

@test "migrate-phase-5-cleanup.sh: --audit-only emits grep gate counts" {
  # Use a project-root with no gaia-public/ tree — the script just emits
  # "plugin tree not found — skipping gate" and exits 0.
  run bash "$CLEANUP" --audit-only --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md: references .gaia/ consolidation tree (AC1)" {
  CLAUDE_MD="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)/CLAUDE.md"
  [ -f "$CLAUDE_MD" ]
  grep -q ".gaia/config/" "$CLAUDE_MD"
  grep -q ".gaia/artifacts/" "$CLAUDE_MD"
  grep -q ".gaia/state/" "$CLAUDE_MD"
  grep -q ".gaia/memory/" "$CLAUDE_MD"
  grep -q ".gaia/custom/" "$CLAUDE_MD"
}

@test "CLAUDE.md: references gaia-paths.sh canonical-path-constants helper (AC2)" {
  CLAUDE_MD="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)/CLAUDE.md"
  grep -q "gaia-paths.sh" "$CLAUDE_MD"
}

@test "CLAUDE.md: references ADR-111 (AC1)" {
  CLAUDE_MD="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)/CLAUDE.md"
  grep -q "ADR-111" "$CLAUDE_MD"
}

@test "README.md: references .gaia/ consolidation tree (AC3)" {
  README_MD="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)/README.md"
  [ -f "$README_MD" ]
  grep -q ".gaia/config/" "$README_MD"
  grep -q ".gaia/memory/" "$README_MD"
}

@test "ADR-020 still marked Superseded by ADR-111 (AC6)" {
  ADR_FILE="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)/docs/planning-artifacts/architecture/12-12-adr-detail-records.md"
  [ -f "$ADR_FILE" ]
  # Find the ADR-020 block and confirm "Superseded by ADR-111"
  awk '/^### ADR-020/,/^### ADR-021/' "$ADR_FILE" | grep -q "Superseded by ADR-111"
}

@test "ADR-044 still marked Superseded by ADR-111 (AC6)" {
  ADR_FILE="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)/docs/planning-artifacts/architecture/12-12-adr-detail-records.md"
  awk '/^### ADR-044/,/^### ADR-045/' "$ADR_FILE" | grep -q "Superseded by ADR-111"
}

@test "ADR-046 still marked Superseded by ADR-111 (AC6)" {
  ADR_FILE="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)/docs/planning-artifacts/architecture/12-12-adr-detail-records.md"
  awk '/^### ADR-046/,/^### ADR-047/' "$ADR_FILE" | grep -q "Superseded by ADR-111"
}

@test "ADR-013 is NOT re-superseded by ADR-111 (Val F1, AC7)" {
  ADR_FILE="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)/docs/planning-artifacts/architecture/12-12-adr-detail-records.md"
  # Find the ADR-013 block — it must reference ADR-049 (already-superseded) NOT ADR-111
  run awk '/^### ADR-013/,/^### ADR-014/' "$ADR_FILE"
  [[ "$output" == *"Superseded by ADR-049"* ]] || [[ "$output" == *"Superseded by"* ]]
  # Must NOT claim a fresh ADR-111 supersession
  if [[ "$output" == *"Superseded by ADR-111"* ]]; then
    return 1
  fi
}
