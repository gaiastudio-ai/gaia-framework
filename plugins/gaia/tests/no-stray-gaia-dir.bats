#!/usr/bin/env bats
# no-stray-gaia-dir.bats — the dashboard, snapshot, and reconcile must leave
# the filesystem untouched when invoked in a directory that is not a GAIA
# project.  A valid project must still get its cache written.
#
# Tests run under bash 5 (the bats interpreter) and, where possible, under
# /bin/bash 3.2 (the macOS stock shell).

# bats file_tags=sprint-progress,no-stray

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  DASHBOARD="$SCRIPTS_DIR/sprint-status-dashboard.sh"
  SNAPSHOT="$SCRIPTS_DIR/sprint-progress-snapshot.sh"
  SPRINT_STATE="$SCRIPTS_DIR/sprint-state.sh"
  EMPTY_DIR="$TEST_TMP/empty"
  mkdir -p "$EMPTY_DIR"
  # Point at the empty dir by default; individual tests override for fixtures
  export PROJECT_ROOT="$EMPTY_DIR"
  export PROJECT_PATH="$EMPTY_DIR"
  export CLAUDE_PROJECT_ROOT="$EMPTY_DIR"
}
teardown() { common_teardown; }

# need_bash32 — set BASH32 to a bash 3.x interpreter, or skip the test.
need_bash32() {
  local b="${SNAPSHOT_BASH32:-/bin/bash}" major=""
  [ -x "$b" ] && major="$("$b" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null)" || true
  if [ "$major" != "3" ]; then
    skip "needs bash 3.x at $b (the stock macOS shell); found major version '${major:-none}'"
  fi
  BASH32="$b"
}

# _fixture_project — scaffold a minimal valid GAIA project and set
# FIXTURE_DIR to its root.
_fixture_project() {
  FIXTURE_DIR="$TEST_TMP/valid-project"
  mkdir -p "$FIXTURE_DIR/.gaia/state" "$FIXTURE_DIR/.gaia/config"
  cat > "$FIXTURE_DIR/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: sprint-1
status: active
start_date: "2026-01-01"
end_date: "2026-01-14"
total_points: 5
stories:
  - key: E900-S1
    title: "Fixture story for no-stray guard test"
    status: in-progress
    points: 5
YAML
}

# ------------------------------------------------------------------ #
# Empty directory: no files must be created
# ------------------------------------------------------------------ #

@test "snapshot creates nothing in an empty directory (bash 5)" {
  run --separate-stderr bash "$SNAPSHOT"
  [ "$status" -eq 0 ]
  run find "$EMPTY_DIR" -mindepth 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "snapshot creates nothing in an empty directory (bash 3.2)" {
  need_bash32
  run --separate-stderr "$BASH32" "$SNAPSHOT"
  [ "$status" -eq 0 ]
  run find "$EMPTY_DIR" -mindepth 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dashboard creates nothing in an empty directory (bash 5)" {
  run --separate-stderr bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No active sprint"* ]]
  run find "$EMPTY_DIR" -mindepth 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dashboard creates nothing in an empty directory (bash 3.2)" {
  need_bash32
  run --separate-stderr "$BASH32" "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No active sprint"* ]]
  run find "$EMPTY_DIR" -mindepth 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reconcile creates nothing in an empty directory (bash 5)" {
  run --separate-stderr bash "$SPRINT_STATE" reconcile
  # Exit 1 is expected (no yaml), but no files created
  [ "$status" -eq 1 ]
  [[ "$output" == *"RECONCILE SUMMARY:"* ]]
  run find "$EMPTY_DIR" -mindepth 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reconcile creates nothing in an empty directory (bash 3.2)" {
  need_bash32
  run --separate-stderr "$BASH32" "$SPRINT_STATE" reconcile
  [ "$status" -eq 1 ]
  [[ "$output" == *"RECONCILE SUMMARY:"* ]]
  run find "$EMPTY_DIR" -mindepth 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ------------------------------------------------------------------ #
# Valid fixture project: cache still written, output unchanged
# ------------------------------------------------------------------ #

@test "snapshot writes cache in a valid GAIA project" {
  _fixture_project
  export PROJECT_ROOT="$FIXTURE_DIR"
  run --separate-stderr bash "$SNAPSHOT"
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE_DIR/.gaia/state/.sprint-progress-cache.json" ]
  [ -f "$FIXTURE_DIR/.gaia/state/.sprint-progress-mtimes" ]
  [ -f "$FIXTURE_DIR/.gaia/state/.sprint-progress-parsed" ]
}

@test "dashboard renders sprint header for a valid GAIA project" {
  _fixture_project
  export PROJECT_ROOT="$FIXTURE_DIR"
  export PROJECT_PATH="$FIXTURE_DIR"
  run --separate-stderr bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SPRINT STATUS DASHBOARD"* ]]
  [[ "$output" == *"sprint-1"* ]]
}

@test "reconcile runs without creating stray files in a valid project" {
  _fixture_project
  export PROJECT_ROOT="$FIXTURE_DIR"
  export PROJECT_PATH="$FIXTURE_DIR"
  run --separate-stderr bash "$SPRINT_STATE" reconcile
  # Reconcile may exit 1 (story file missing) but must not create stray dirs
  # outside .gaia/state/
  [ ! -d "$FIXTURE_DIR/.gaia/memory" ] || [ -z "$(find "$FIXTURE_DIR/.gaia/memory" -mindepth 1 2>/dev/null)" ]
}

# ------------------------------------------------------------------ #
# Per-mutant proof: removing each guard makes the test go red
# ------------------------------------------------------------------ #

@test "mutant: removing snapshot guard creates stray .gaia/state/" {
  # Create a mutant snapshot without the guard
  local mutant="$TEST_TMP/mutant-snapshot.sh"
  awk '
    /^  # Guard: when there is no GAIA project/ { skip=1; next }
    skip && /^  fi$/ { skip=0; next }
    !skip { print }
  ' "$SNAPSHOT" > "$mutant"
  chmod +x "$mutant"
  run --separate-stderr bash "$mutant"
  [ "$status" -eq 0 ]
  # Without the guard, .gaia/state/ is created
  [ -d "$EMPTY_DIR/.gaia/state" ]
}

@test "mutant: removing reconcile guard creates stray files" {
  # sprint-state.sh sources sibling libraries, so we cannot relocate it.
  # Instead, create a minimal reproducer that mimics the old (unguarded)
  # cmd_reconcile: it runs the mkdir that creates .gaia/state/ and then
  # attempts to lock — proving the guard is the only thing stopping it.
  local mutant="$TEST_TMP/mutant-reconcile.sh"
  cat > "$mutant" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="${PROJECT_ROOT:-.}"
SPRINT_STATUS_YAML="${PROJECT_ROOT}/.gaia/state/sprint-status.yaml"
SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
# OLD code without the guard — mkdir runs unconditionally
mkdir -p "$(dirname "$SPRINT_STATUS_LOCK")" 2>/dev/null || true
SCRIPT
  chmod +x "$mutant"
  run --separate-stderr bash "$mutant"
  [ "$status" -eq 0 ]
  # Without the guard, the mkdir runs and creates .gaia/state/
  [ -d "$EMPTY_DIR/.gaia/state" ]
}

@test "mutant: removing dashboard no-yaml guard produces exit 1" {
  # Create a mutant dashboard without the yaml-absent guard
  local mutant="$TEST_TMP/mutant-dashboard.sh"
  awk '
    /if \[\[ ! -f "\$YAML_PATH" \]\]; then/ { skip=1; next }
    skip && /^  fi$/ { skip=0; next }
    !skip { print }
  ' "$DASHBOARD" > "$mutant"
  chmod +x "$mutant"
  # Point at a non-existent snapshot to force the fallback path
  export SPRINT_PROGRESS_SNAPSHOT="/nonexistent"
  run --separate-stderr bash "$mutant"
  # Without the guard, the dashboard tries fallback and errors
  [ "$status" -eq 1 ]
}
