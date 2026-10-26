#!/usr/bin/env bats
# concurrent-sprint-compat.bats — backward compatibility tests for the
# reader/writer sweep.  Verifies single-sprint mode (max_concurrent_active
# absent or 1) produces identical behaviour after the sweep: no new state
# files, sprint-status.yaml is the sole state file, and the independence
# check is not invoked.

# shellcheck disable=SC2030,SC2031

load 'test_helper.bash'

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH

  TEST_DIR="$(mktemp -d)"
  STATE_DIR="$TEST_DIR/.gaia/state"
  IMPL_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_DIR/.gaia/config"
  mkdir -p "$STATE_DIR" "$IMPL_DIR" "$CONFIG_DIR"

  # Minimal sprint-status.yaml.
  cat > "$STATE_DIR/sprint-status.yaml" <<YAML
sprint_id: "sprint-900"
status: active
total_points: 10
goals: []
stories:
  - key: "E900-S1"
    title: "Test story"
    status: "in-progress"
    points: 5
    risk: "medium"
YAML

  # Single-sprint config (max_concurrent_active absent).
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
stacks:
  - name: bash
    path: "."
YAML

  # Planning artifacts (required by the independence gate in concurrent mode).
  local planning_dir="$TEST_DIR/.gaia/artifacts/planning-artifacts"
  mkdir -p "$planning_dir/epics"
  cat > "$planning_dir/epics-and-stories.md" <<'MD'
# Epics and Stories

## E900 — Test Epic
MD

  export PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status.yaml"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  SPRINT_STATE="$BATS_TEST_SCRIPT_DIR/scripts/sprint-state.sh"
  export SPRINT_STATE_SCRIPT_DIR="$BATS_TEST_SCRIPT_DIR/scripts"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Helper: create a story file.
create_story_file() {
  local key="$1" sprint_id="${2:-sprint-900}" status="${3:-backlog}"
  local dir="$IMPL_DIR/epic-E900-test/${key}-test-story"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<YAML
---
template: 'story'
key: "${key}"
title: "Test story ${key}"
epic: "E900"
status: ${status}
points: 3
risk: medium
sprint_id: "${sprint_id}"
predicted_touch_set: ["gaia-public/plugins/gaia/tests/fixture-${key}.txt"]
depends_on: []
blocks: []
---
# Story: Test ${key}

> **Status:** ${status}
YAML
}

# ============================================================
# AC3 / COMPAT-1: No new state files with default config
# ============================================================

@test "no new state files created with default single-sprint config" {
  # Snapshot the state directory contents before operations.
  local before
  before="$(ls -1 "$STATE_DIR" | sort)"

  # Run a reconcile (the main operation transition-story-status now delegates to).
  create_story_file "E900-S1" "sprint-900" "in-progress"
  run bash "$SPRINT_STATE" reconcile --sprint-id sprint-900
  [ "$status" -eq 0 ]

  # Snapshot after.
  local after
  after="$(ls -1 "$STATE_DIR" | sort)"

  # No new files should appear (no per-sprint files, no lock files left).
  # Filter out transient lock files that may have been cleaned up.
  local before_stable after_stable
  before_stable="$(echo "$before" | grep -v '\.lock' | grep -v '\.result')"
  after_stable="$(echo "$after" | grep -v '\.lock' | grep -v '\.result')"

  [ "$before_stable" = "$after_stable" ]

  # Specifically: no sprint-status-*.yaml files.
  local per_sprint
  per_sprint="$(find "$STATE_DIR" -maxdepth 1 -name 'sprint-status-*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$per_sprint" -eq 0 ]
}

# ============================================================
# AC3 / COMPAT-2: sprint-status.yaml is the sole state file with max=1
# ============================================================

@test "all operations target sprint-status.yaml only with max=1" {
  # With max_concurrent_active absent (default 1), every read/write
  # must target sprint-status.yaml, never a per-sprint file.
  create_story_file "E900-S1" "sprint-900" "in-progress"

  # reconcile should work on the single file.
  run bash "$SPRINT_STATE" reconcile --sprint-id sprint-900
  [ "$status" -eq 0 ]

  # Verify the file was the target (no per-sprint files exist).
  [ -f "$STATE_DIR/sprint-status.yaml" ]
  local per_sprint_count
  per_sprint_count="$(find "$STATE_DIR" -maxdepth 1 -name 'sprint-status-*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$per_sprint_count" -eq 0 ]
}

# ============================================================
# AC3 / COMPAT-3: independence-check.sh not invoked when max=1
# ============================================================

@test "independence check not invoked with single-sprint config" {
  # The independence-check.sh script should not be called when
  # max_concurrent_active is absent or 1.

  # Verify the independence-check.sh exists (dependency on S9).
  local indep_check="$BATS_TEST_SCRIPT_DIR/scripts/independence-check.sh"
  [ -f "$indep_check" ]

  # Run a sprint-state.sh operation and capture stderr.
  create_story_file "E900-S1" "sprint-900" "in-progress"
  run bash "$SPRINT_STATE" reconcile --sprint-id sprint-900 2>&1
  [ "$status" -eq 0 ]

  # The output must NOT mention independence-check.
  [[ "$output" != *"independence-check"* ]]
}

# ============================================================
# AC3 / COMPAT-5: Structural assertion (no nested bats)
# ============================================================

@test "no per-sprint state files or migration markers in single-sprint mode" {
  # This is the structural assertion companion to the CI-level regression
  # gate (full bats suite with default config). It asserts that the state
  # directory contains only pre-concurrent files.

  # Run operations.
  create_story_file "E900-S1" "sprint-900" "in-progress"
  run bash "$SPRINT_STATE" reconcile --sprint-id sprint-900
  [ "$status" -eq 0 ]

  # No per-sprint files.
  local per_sprint
  per_sprint="$(find "$STATE_DIR" -maxdepth 1 -name 'sprint-status-*.yaml' ! -name '*.lock' ! -name '*.result' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$per_sprint" -eq 0 ]

  # No concurrent resource ledger.
  [ ! -f "$STATE_DIR/.concurrent-resource-ledger.json" ]

  # No migration marker.
  [ ! -f "$STATE_DIR/.sprint-migration-complete" ]
}

# ============================================================
# AC-EC8: Full lifecycle with default config creates no new files
# ============================================================

@test "sprint lifecycle with default config creates no concurrent artifacts" {
  # Use the pre-seeded sprint (already active from setup).
  # Inject a new story and run reconcile to exercise the lifecycle.
  create_story_file "E900-S2" "sprint-900" "backlog"
  run bash "$SPRINT_STATE" inject --story E900-S2 --sprint-id sprint-900
  [ "$status" -eq 0 ]

  # Reconcile (the path transition-story-status.sh now takes).
  create_story_file "E900-S1" "sprint-900" "in-progress"
  run bash "$SPRINT_STATE" reconcile --sprint-id sprint-900
  [ "$status" -eq 0 ]

  # Verify: no concurrent artifacts.
  local per_sprint
  per_sprint="$(find "$STATE_DIR" -maxdepth 1 -name 'sprint-status-*.yaml' ! -name '*.lock' ! -name '*.result' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$per_sprint" -eq 0 ]
  [ ! -f "$STATE_DIR/.concurrent-resource-ledger.json" ]
  [ ! -f "$STATE_DIR/.sprint-migration-complete" ]

  # sprint-status.yaml is the sole state file.
  [ -f "$STATE_DIR/sprint-status.yaml" ]
}

# ============================================================
# AC-EC3: Third-party hooks read compatibility proxy
# ============================================================

@test "compatibility proxy readable at the default path" {
  # In single-sprint mode, sprint-status.yaml IS the state file (not a proxy).
  # Verify it is readable and contains the expected data.
  [ -f "$STATE_DIR/sprint-status.yaml" ]
  [ -r "$STATE_DIR/sprint-status.yaml" ]

  local sid
  sid="$(awk '/^sprint_id:/ {gsub(/"/, ""); print $2}' "$STATE_DIR/sprint-status.yaml")"
  [ "$sid" = "sprint-900" ]
}

# ============================================================
# AC1/AC8: Two-sprint isolation — transition targets correct file
# ============================================================

@test "transition updates per-sprint file, not the other sprint" {
  # Start from a clean state for the two-sprint setup.
  rm -f "$STATE_DIR/sprint-status.yaml"

  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
sprint:
  max_concurrent_active: 2
stacks:
  - name: bash
    path: "."
YAML

  # Seed sprint-900 and advance to sprint-901.
  run bash "$SPRINT_STATE" init --sprint-id sprint-900
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" transition --sprint sprint-900 --to active
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" advance --sprint-id sprint-901
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" transition --sprint sprint-901 --to active
  [ "$status" -eq 0 ]

  # Inject a story into sprint-901 (the NON-proxy sprint).
  create_story_file "E900-S5" "sprint-901" "backlog"
  run bash "$SPRINT_STATE" inject --story E900-S5 --sprint-id sprint-901
  [ "$status" -eq 0 ]

  # Snapshot sprint-900's per-sprint file before the transition.
  local sprint900_file="$STATE_DIR/sprint-status-sprint-900.yaml"
  local sprint901_file="$STATE_DIR/sprint-status-sprint-901.yaml"
  [ -f "$sprint900_file" ]
  [ -f "$sprint901_file" ]
  local snap900
  snap900="$(cat "$sprint900_file")"

  # Update the story file to the new status (simulates rewrite_frontmatter).
  create_story_file "E900-S5" "sprint-901" "in-progress"

  # Call reconcile with --sprint-id sprint-901 (what transition-story-status.sh does).
  run bash "$SPRINT_STATE" reconcile --sprint-id sprint-901
  [ "$status" -eq 0 ]

  # sprint-901's file should reflect the update.
  local s901_status
  s901_status="$(awk '/key:.*E900-S5/{found=1} found && /status:/{gsub(/"/, ""); print $2; exit}' "$sprint901_file")"
  [ "$s901_status" = "in-progress" ]

  # sprint-900's file must be UNTOUCHED.
  local snap900_after
  snap900_after="$(cat "$sprint900_file")"
  [ "$snap900" = "$snap900_after" ]
}

@test "dropping --sprint-id from reconcile misses the non-proxy sprint" {
  rm -f "$STATE_DIR/sprint-status.yaml"

  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
sprint:
  max_concurrent_active: 2
stacks:
  - name: bash
    path: "."
YAML

  run bash "$SPRINT_STATE" init --sprint-id sprint-900
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" transition --sprint sprint-900 --to active
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" advance --sprint-id sprint-901
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" transition --sprint sprint-901 --to active
  [ "$status" -eq 0 ]

  # Inject story into sprint-901 (non-proxy).
  create_story_file "E900-S6" "sprint-901" "backlog"
  run bash "$SPRINT_STATE" inject --story E900-S6 --sprint-id sprint-901
  [ "$status" -eq 0 ]

  # Update story to in-progress.
  create_story_file "E900-S6" "sprint-901" "in-progress"

  # Reconcile WITHOUT --sprint-id — targets the proxy (sprint-900).
  # The story is in sprint-901's file, so the proxy reconcile finds nothing.
  run bash "$SPRINT_STATE" reconcile
  [ "$status" -eq 0 ]

  # sprint-901's file should NOT have been updated (reconcile hit the proxy).
  local sprint901_file="$STATE_DIR/sprint-status-sprint-901.yaml"
  local s901_status
  s901_status="$(awk '/key:.*E900-S6/{found=1} found && /status:/{gsub(/"/, ""); print $2; exit}' "$sprint901_file")"
  # Still "backlog" because reconcile without --sprint-id targeted the proxy.
  [ "$s901_status" = "backlog" ]
}

# ============================================================
# AC1: Pure readers get correct data in two-sprint setup
# ============================================================

@test "pure readers return correct data from proxy in two-sprint mode" {
  rm -f "$STATE_DIR/sprint-status.yaml"

  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
sprint:
  max_concurrent_active: 2
stacks:
  - name: bash
    path: "."
YAML

  run bash "$SPRINT_STATE" init --sprint-id sprint-900
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" transition --sprint sprint-900 --to active
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" advance --sprint-id sprint-901
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" transition --sprint sprint-901 --to active
  [ "$status" -eq 0 ]

  create_story_file "E900-S7" "sprint-901" "in-progress"
  run bash "$SPRINT_STATE" inject --story E900-S7 --sprint-id sprint-901
  [ "$status" -eq 0 ]

  # The proxy (sprint-status.yaml) mirrors the last-activated sprint (sprint-901).
  local proxy="$STATE_DIR/sprint-status.yaml"
  [ -f "$proxy" ]

  # Reader 1: sprint-status-dashboard.sh reads the proxy when no --sprint given.
  local dashboard="$BATS_TEST_SCRIPT_DIR/scripts/sprint-status-dashboard.sh"
  if [ -x "$dashboard" ]; then
    run bash "$dashboard"
    # Should succeed (may warn about missing cache, but exit 0).
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  fi

  # Reader 2: resolve-artifact-path.sh returns the proxy path.
  local resolver="$BATS_TEST_SCRIPT_DIR/scripts/lib/resolve-artifact-path.sh"
  if [ -x "$resolver" ]; then
    local resolved
    resolved="$(bash "$resolver" sprint_status --project-root "$TEST_DIR" --existing-only 2>/dev/null || true)"
    [ -n "$resolved" ]
  fi

  # Reader 3: proxy contains the last-activated sprint's data.
  local proxy_sid
  proxy_sid="$(awk '/^sprint_id:/ {gsub(/"/, ""); print $2}' "$proxy")"
  [ "$proxy_sid" = "sprint-901" ]

  # Reader 4: per-sprint resolve-file returns the correct file.
  run bash "$SPRINT_STATE" resolve-file --sprint sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-status-sprint-900.yaml"* ]]

  # Reader 5: per-sprint resolve-file for sprint-901.
  run bash "$SPRINT_STATE" resolve-file --sprint sprint-901
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-status-sprint-901.yaml"* ]]
}

# ============================================================
# AC1/AC8: Real transition-story-status.sh targets correct per-sprint file
# ============================================================

@test "real transition-story-status.sh updates non-proxy sprint file" {
  # Two active sprints: sprint-900 (last-activated = proxy) and sprint-901.
  # Transition a sprint-901 story via the REAL transition-story-status.sh.
  # Assert sprint-901's per-sprint file is updated and sprint-900's is unchanged.
  rm -f "$STATE_DIR/sprint-status.yaml"

  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
sprint:
  max_concurrent_active: 2
stacks:
  - name: bash
    path: "."
YAML

  # Bootstrap two active sprints.
  run bash "$SPRINT_STATE" init --sprint-id sprint-900
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" transition --sprint sprint-900 --to active
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" advance --sprint-id sprint-901
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE" transition --sprint sprint-901 --to active
  [ "$status" -eq 0 ]

  # Inject a story into sprint-901.
  create_story_file "E900-S8" "sprint-901" "ready-for-dev"
  run bash "$SPRINT_STATE" inject --story E900-S8 --sprint-id sprint-901
  [ "$status" -eq 0 ]

  # Set up epics-and-stories.md (transition-story-status.sh requires it).
  local planning_dir="$TEST_DIR/.gaia/artifacts/planning-artifacts"
  local memory_dir="$TEST_DIR/.gaia/memory"
  mkdir -p "$planning_dir" "$memory_dir"
  cat > "$planning_dir/epics-and-stories.md" <<'EOF'
# Epics and Stories

## E900 — Test epic

### Story E900-S8: Two-sprint isolation test

- **Status:** ready-for-dev
EOF

  # Snapshot sprint-900's file.
  local sprint900_file="$STATE_DIR/sprint-status-sprint-900.yaml"
  local sprint901_file="$STATE_DIR/sprint-status-sprint-901.yaml"
  [ -f "$sprint900_file" ]
  [ -f "$sprint901_file" ]
  local snap900
  snap900="$(cat "$sprint900_file")"

  # Run the REAL transition-story-status.sh.
  local tss="$BATS_TEST_SCRIPT_DIR/scripts/transition-story-status.sh"
  [ -x "$tss" ]
  run env \
    PROJECT_PATH="$TEST_DIR" \
    IMPLEMENTATION_ARTIFACTS="$IMPL_DIR" \
    PLANNING_ARTIFACTS="$planning_dir" \
    MEMORY_PATH="$memory_dir" \
    SPRINT_STATUS_YAML="$STATE_DIR/sprint-status.yaml" \
    STORY_STATUS_LOCK="$memory_dir/.tss-test.lock" \
    GAIA_SKIP_ORPHAN_SWEEP=1 \
    GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    "$tss" E900-S8 --to in-progress
  [ "$status" -eq 0 ]

  # sprint-901's per-sprint file must show the new status.
  local s901_status
  s901_status="$(awk '/key:.*E900-S8/{found=1} found && /status:/{gsub(/"/, ""); print $2; exit}' "$sprint901_file")"
  [ "$s901_status" = "in-progress" ]

  # sprint-900's file must be byte-unchanged.
  local snap900_after
  snap900_after="$(cat "$sprint900_file")"
  [ "$snap900" = "$snap900_after" ]
}
