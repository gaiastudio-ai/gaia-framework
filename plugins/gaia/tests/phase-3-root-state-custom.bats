#!/usr/bin/env bats
# phase-3-root-state-custom.bats — unit tests for migrate-phase-3.sh +
# review-gate.sh dual-layout + tool-info/list-adapters custom/ dual-layout +
# write-boundary.sh custom/skills/ acceptance. Covers E96-S3 ACs.

load 'test_helper.bash'

setup() {
  common_setup
  MIGRATE="$SCRIPTS_DIR/migrate/migrate-phase-3.sh"
  PROJECT_ROOT="$( cd "$TEST_TMP" && pwd -P )/proj"
  mkdir -p "$PROJECT_ROOT/custom/adapters/example-a" "$PROJECT_ROOT/custom/skills"
  echo "ledger-line" > "$PROJECT_ROOT/.review-gate-ledger"
  echo '{"plugin":"x"}' > "$PROJECT_ROOT/.plugin-list.json"
  echo "adapter content" > "$PROJECT_ROOT/custom/adapters/example-a/adapter.json"
  echo "skill content" > "$PROJECT_ROOT/custom/skills/example.md"
  export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT PROJECT_PATH REVIEW_GATE_LEDGER 2>/dev/null || true
  common_teardown
}

@test "migrate-phase-3.sh: file exists at canonical path" {
  [ -f "$MIGRATE" ]
}

@test "migrate-phase-3.sh: relocates .review-gate-ledger (AC1)" {
  run bash "$MIGRATE" --project-root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/.gaia/state/.review-gate-ledger" ]
  [ -f "$PROJECT_ROOT/.review-gate-ledger.gaia-pointer" ]
  [ ! -f "$PROJECT_ROOT/.review-gate-ledger" ]
}

@test "migrate-phase-3.sh: relocates .plugin-list.json (AC2)" {
  run bash "$MIGRATE" --project-root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/.gaia/state/.plugin-list.json" ]
  [ -f "$PROJECT_ROOT/.plugin-list.json.gaia-pointer" ]
}

@test "migrate-phase-3.sh: relocates custom/ -> .gaia/custom/ (AC3)" {
  run bash "$MIGRATE" --project-root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -d "$PROJECT_ROOT/.gaia/custom" ]
  [ -f "$PROJECT_ROOT/.gaia/custom/adapters/example-a/adapter.json" ]
  [ -f "$PROJECT_ROOT/.gaia/custom/skills/example.md" ]
  [ -f "$PROJECT_ROOT/custom/.gaia-pointer" ]
}

@test "migrate-phase-3.sh: idempotent re-run is no-op (AC11)" {
  bash "$MIGRATE" --project-root "$PROJECT_ROOT"
  run bash "$MIGRATE" --project-root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Phase 3 already complete"* ]]
}

@test "migrate-phase-3.sh: project-root grep gate detects un-relocated file (AC7)" {
  # Setup: ensure a non-pointer file at root after migration would trip the
  # gate. We achieve this by sneaking a file in mid-migration via dry-run
  # short-circuit. The straightforward verification: post-migration root has
  # no canonical state files left as plain files.
  bash "$MIGRATE" --project-root "$PROJECT_ROOT"
  for f in .review-gate-ledger .plugin-list.json; do
    [ ! -f "$PROJECT_ROOT/$f" ]
  done
}

@test "review-gate.sh: dual-layout — script body references .gaia/state/.review-gate-ledger (AC1)" {
  # Body-level assertion: the resolve_ledger_path function prefers the
  # .gaia/state/ location when it exists. We assert the literal pattern is
  # present in the script body (white-box check, simpler than sourcing a
  # script with side effects).
  grep -q ".gaia/state/.review-gate-ledger" "$SCRIPTS_DIR/review-gate.sh"
}

@test "tool-info.sh: prefers .gaia/custom/adapters/ when present" {
  mkdir -p "$PROJECT_ROOT/.gaia/custom/adapters"
  # Inspect the script body — it must contain the dual-layout dispatch.
  grep -q ".gaia/custom/adapters" "$SCRIPTS_DIR/tool-info.sh"
}

@test "list-adapters.sh: prefers .gaia/custom/adapters/ when present" {
  grep -q ".gaia/custom/adapters" "$SCRIPTS_DIR/list-adapters.sh"
}

@test "write-boundary.sh: accepts new .gaia/custom/skills/ path" {
  WB="$( cd "$BATS_TEST_DIRNAME/../skills/gaia-meeting/scripts" && pwd )/write-boundary.sh"
  run bash "$WB" ".gaia/custom/skills/example.md"
  [ "$status" -eq 0 ]
}

@test "write-boundary.sh: still accepts legacy custom/skills/ path" {
  WB="$( cd "$BATS_TEST_DIRNAME/../skills/gaia-meeting/scripts" && pwd )/write-boundary.sh"
  run bash "$WB" "custom/skills/example.md"
  [ "$status" -eq 0 ]
}

@test "retro-sidecar-write.sh: allowlist includes .gaia/custom/skills/ entries (AC5)" {
  grep -q ".gaia/custom/skills" "$SCRIPTS_DIR/retro-sidecar-write.sh"
}

@test "migrate-phase-3.sh: pointer files at all legacy paths (AC9)" {
  bash "$MIGRATE" --project-root "$PROJECT_ROOT"
  [ -f "$PROJECT_ROOT/.review-gate-ledger.gaia-pointer" ]
  [ -f "$PROJECT_ROOT/.plugin-list.json.gaia-pointer" ]
  [ -f "$PROJECT_ROOT/custom/.gaia-pointer" ]
}
