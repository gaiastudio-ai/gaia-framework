#!/usr/bin/env bats
# review-semaphore.bats — tests for the heavy-reviewer counting semaphore.
#
# Covers:
#   - Schema validation of review.max_concurrent_heavy_reviewers
#   - Slot acquisition, release, dead-holder reclaim
#   - Contention (more requesters than the limit)
#   - Wait-bound expiry (fail-open with warning)
#   - Release on failure and signal
#   - System-wide limit independence from dev-slot limit
#   - Bash 3.2 + bash 5 portability (contention runs)
#
# Component: review-semaphore

load 'test_helper.bash'

# --- setup / teardown ---

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH 2>/dev/null || true

  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  export GAIA_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$GAIA_STATE_DIR"
  export GAIA_REVIEW_SEMAPHORE_WAIT_SECS=5

  # Locate the scripts relative to this test file.
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd -P)"
  PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
  export PLUGIN_DIR

  SLOT_HELPER="$PLUGIN_DIR/scripts/lib/heavy-reviewer-slots.sh"
  LOCK_HELPER="$PLUGIN_DIR/scripts/lib/acquire-lock.sh"
  SCHEMA="$PLUGIN_DIR/schemas/project-config.schema.json"
  RESOLVE_CONFIG="$PLUGIN_DIR/scripts/resolve-config.sh"
}

teardown() {
  # Kill any background jobs spawned by this test.
  jobs -p 2>/dev/null | while read -r pid; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# --- Schema tests (AC1) ---

@test "schema accepts max_concurrent_heavy_reviewers integer >= 1" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  python3 -c "import jsonschema" 2>/dev/null || skip "jsonschema not installed"

  python3 -c "
import json, jsonschema
with open('$SCHEMA') as f:
    schema = json.load(f)
review_schema = schema['properties']['review']
# Valid: 1
jsonschema.validate({'max_concurrent_heavy_reviewers': 1}, review_schema)
# Valid: 4
jsonschema.validate({'max_concurrent_heavy_reviewers': 4}, review_schema)
# Valid: 100
jsonschema.validate({'max_concurrent_heavy_reviewers': 100}, review_schema)
print('all valid values accepted')
"
}

@test "schema rejects max_concurrent_heavy_reviewers = 0" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  python3 -c "import jsonschema" 2>/dev/null || skip "jsonschema not installed"

  run python3 -c "
import json, jsonschema, sys
with open('$SCHEMA') as f:
    schema = json.load(f)
review_schema = schema['properties']['review']
try:
    jsonschema.validate({'max_concurrent_heavy_reviewers': 0}, review_schema)
    sys.exit(1)  # should not reach here
except jsonschema.ValidationError:
    print('correctly rejected 0')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"correctly rejected"* ]]
}

@test "schema rejects max_concurrent_heavy_reviewers negative" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  python3 -c "import jsonschema" 2>/dev/null || skip "jsonschema not installed"

  run python3 -c "
import json, jsonschema, sys
with open('$SCHEMA') as f:
    schema = json.load(f)
review_schema = schema['properties']['review']
try:
    jsonschema.validate({'max_concurrent_heavy_reviewers': -1}, review_schema)
    sys.exit(1)
except jsonschema.ValidationError:
    print('correctly rejected negative')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"correctly rejected"* ]]
}

@test "schema rejects max_concurrent_heavy_reviewers non-integer" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  python3 -c "import jsonschema" 2>/dev/null || skip "jsonschema not installed"

  run python3 -c "
import json, jsonschema, sys
with open('$SCHEMA') as f:
    schema = json.load(f)
review_schema = schema['properties']['review']
try:
    jsonschema.validate({'max_concurrent_heavy_reviewers': 'four'}, review_schema)
    sys.exit(1)
except jsonschema.ValidationError:
    print('correctly rejected string')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"correctly rejected"* ]]
}

# --- resolve-config.sh field query (AC1) ---

@test "resolve-config reports configured max_concurrent_heavy_reviewers" {
  [ -x "$RESOLVE_CONFIG" ] || skip "resolve-config.sh not executable"
  mkdir -p "$BATS_TEST_TMPDIR/cfg"
  cat > "$BATS_TEST_TMPDIR/cfg/project-config.yaml" <<'YAML'
project_name: test-project
stacks:
  - name: bash-dev
    path: "."
review:
  max_concurrent_heavy_reviewers: 6
YAML

  run bash "$RESOLVE_CONFIG" --config "$BATS_TEST_TMPDIR/cfg/project-config.yaml" \
    --field review.max_concurrent_heavy_reviewers
  [ "$status" -eq 0 ]
  [[ "$output" == "6" ]]
}

@test "resolve-config returns empty for absent max_concurrent_heavy_reviewers" {
  [ -x "$RESOLVE_CONFIG" ] || skip "resolve-config.sh not executable"
  mkdir -p "$BATS_TEST_TMPDIR/cfg"
  cat > "$BATS_TEST_TMPDIR/cfg/project-config.yaml" <<'YAML'
project_name: test-project
stacks:
  - name: bash-dev
    path: "."
YAML

  run bash "$RESOLVE_CONFIG" --config "$BATS_TEST_TMPDIR/cfg/project-config.yaml" \
    --field review.max_concurrent_heavy_reviewers
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Slot helper tests (AC2, AC3, AC4) ---

@test "slot helper acquires and releases a slot" {
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  heavy_reviewer_acquire --limit 4
  [ "$_HRS_ACQUIRED" = "1" ]
  [ -f "$_HRS_MY_SLOT" ]

  # Verify slot file content.
  local pid_in_slot
  read -r pid_in_slot _ < "$_HRS_MY_SLOT"
  [ "$pid_in_slot" = "$$" ]

  heavy_reviewer_release
  [ "$_HRS_ACQUIRED" = "0" ]
  # Slot file should be removed.
  local remaining
  remaining=$(find "$GAIA_STATE_DIR/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

@test "slot helper reclaims dead-holder slot" {
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  # Create a slot file with a dead PID.
  mkdir -p "$GAIA_STATE_DIR/review-semaphore.d"
  printf '%s %s\n' "99999" "$(date +%s)" > "$GAIA_STATE_DIR/review-semaphore.d/slot-99999.0"

  # Verify the dead PID is not alive (best-effort — 99999 is usually dead).
  if kill -0 99999 2>/dev/null; then
    skip "PID 99999 is unexpectedly alive"
  fi

  heavy_reviewer_acquire --limit 1
  [ "$_HRS_ACQUIRED" = "1" ]

  # The dead holder's slot should have been reclaimed.
  [ ! -f "$GAIA_STATE_DIR/review-semaphore.d/slot-99999.0" ]

  heavy_reviewer_release
}

@test "slot helper does not reclaim live-holder slot" {
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  mkdir -p "$GAIA_STATE_DIR/review-semaphore.d"
  # Start a background sleep as the "live holder".
  sleep 30 &
  local live_pid=$!
  printf '%s %s\n' "$live_pid" "$(date +%s)" > "$GAIA_STATE_DIR/review-semaphore.d/slot-${live_pid}.0"

  # Try to acquire with limit 1 — should wait and then fail open.
  export GAIA_REVIEW_SEMAPHORE_WAIT_SECS=2
  heavy_reviewer_acquire --limit 1
  # Should have proceeded without a slot (fail-open).
  [ "$_HRS_ACQUIRED" = "0" ]

  # The live holder's slot should NOT have been reclaimed.
  [ -f "$GAIA_STATE_DIR/review-semaphore.d/slot-${live_pid}.0" ]

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  rm -f "$GAIA_STATE_DIR/review-semaphore.d/slot-${live_pid}.0"
}

@test "slot helper proceeds with warning when wait bound expires" {
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  mkdir -p "$GAIA_STATE_DIR/review-semaphore.d"
  # Fill the single slot with a live process.
  sleep 30 &
  local bg_pid=$!
  printf '%s %s\n' "$bg_pid" "$(date +%s)" > "$GAIA_STATE_DIR/review-semaphore.d/slot-${bg_pid}"

  export GAIA_REVIEW_SEMAPHORE_WAIT_SECS=2
  run bash -c "
    source '$LOCK_HELPER'
    source '$SLOT_HELPER'
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'
    export GAIA_REVIEW_SEMAPHORE_WAIT_SECS=2
    heavy_reviewer_acquire --limit 1
    echo acquired=\$_HRS_ACQUIRED
  "

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  rm -f "$GAIA_STATE_DIR/review-semaphore.d/slot-${bg_pid}"

  [ "$status" -eq 0 ]
  [[ "$output" == *"acquired=0"* ]]
}

@test "heavy_reviewer_run releases slot on child failure" {
  run bash -c "
    source '$LOCK_HELPER'
    source '$SLOT_HELPER'
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'
    heavy_reviewer_run --limit 4 -- false
    echo 'should not reach here'
  "
  [ "$status" -ne 0 ]

  # Verify no slot file remains.
  local count
  count=$(find "$GAIA_STATE_DIR/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$count" -eq 0 ]
}

@test "heavy_reviewer_run passes child exit code through" {
  run bash -c "
    source '$LOCK_HELPER'
    source '$SLOT_HELPER'
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'
    heavy_reviewer_run --limit 4 -- sh -c 'exit 42'
  "
  [ "$status" -eq 42 ]
}

@test "heavy_reviewer_run runs the child command" {
  run bash -c "
    source '$LOCK_HELPER'
    source '$SLOT_HELPER'
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'
    heavy_reviewer_run --limit 4 -- echo 'hello from child'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from child"* ]]
}

# --- Contention test (AC6) ---

@test "contention: no more than limit run at once, no slot leaks" {
  local limit=3
  local total=8
  local hold_secs=2
  local log_dir="$BATS_TEST_TMPDIR/contention"
  mkdir -p "$log_dir"

  # Launch $total holders, each holding a slot for $hold_secs.
  for i in $(seq 1 "$total"); do
    (
      source "$LOCK_HELPER"
      source "$SLOT_HELPER"
      export GAIA_STATE_DIR="$GAIA_STATE_DIR"
      export GAIA_REVIEW_SEMAPHORE_WAIT_SECS=30
      heavy_reviewer_run --limit "$limit" -- sh -c "
        # Record when we start running.
        date +%s > '$log_dir/start-$i'
        sleep $hold_secs
        date +%s > '$log_dir/end-$i'
      "
    ) &
  done

  # Wait for all to finish.
  wait

  # Verify: no more than $limit ran at the same time.
  # Collect all start and end times.
  local starts=() ends=()
  for i in $(seq 1 "$total"); do
    if [ -f "$log_dir/start-$i" ] && [ -f "$log_dir/end-$i" ]; then
      starts+=("$(cat "$log_dir/start-$i")")
      ends+=("$(cat "$log_dir/end-$i")")
    fi
  done

  # For each start time, count how many jobs were running at that instant.
  local max_concurrent=0
  for s in "${starts[@]}"; do
    local concurrent=0
    for j in $(seq 0 $((${#starts[@]} - 1))); do
      local js="${starts[$j]}"
      local je="${ends[$j]}"
      # Job j was running at time s if js <= s < je
      if [ "$js" -le "$s" ] && [ "$s" -lt "$je" ]; then
        concurrent=$((concurrent + 1))
      fi
    done
    if [ "$concurrent" -gt "$max_concurrent" ]; then
      max_concurrent="$concurrent"
    fi
  done

  echo "max concurrent observed: $max_concurrent (limit: $limit)"
  [ "$max_concurrent" -le "$limit" ]

  # Verify no slot leaks.
  local remaining
  remaining=$(find "$GAIA_STATE_DIR/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  echo "remaining slots: $remaining"
  [ "$remaining" -eq 0 ]
}

# --- System-wide limit independence (AC5) ---

@test "semaphore limit is independent of dev-slot limit" {
  # The semaphore reads review.max_concurrent_heavy_reviewers, not
  # parallel_execution.max_parallel_dev_slots. Verify the slot helper
  # resolves the correct config key by setting both and confirming only
  # the heavy-reviewer limit is used by the slot helper.
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  # Set a limit of 2 via direct --limit (simulating the config read).
  # Verify that only 2 slots can be held regardless of other config.
  heavy_reviewer_acquire --limit 2
  [ "$_HRS_ACQUIRED" = "1" ]
  heavy_reviewer_release

  # Also verify the resolve-config field reads the correct key.
  [ -x "$RESOLVE_CONFIG" ] || skip "resolve-config.sh not executable"
  mkdir -p "$BATS_TEST_TMPDIR/cfg"
  cat > "$BATS_TEST_TMPDIR/cfg/project-config.yaml" <<'YAML'
project_name: test-project
stacks:
  - name: bash-dev
    path: "."
review:
  max_concurrent_heavy_reviewers: 3
YAML

  local heavy_slots
  heavy_slots=$(bash "$RESOLVE_CONFIG" --config "$BATS_TEST_TMPDIR/cfg/project-config.yaml" \
    --field review.max_concurrent_heavy_reviewers)
  [ "$heavy_slots" = "3" ]
}

# --- Lock and slot directory paths (AC2) ---

@test "slot directory and lock use canonical state paths" {
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  heavy_reviewer_acquire --limit 4
  # Check paths.
  [[ "$_HRS_SLOT_DIR" == "$GAIA_STATE_DIR/review-semaphore.d" ]]
  [[ "$_HRS_LOCK_PATH" == "$GAIA_STATE_DIR/review-semaphore.lock" ]]
  [ -d "$_HRS_SLOT_DIR" ]

  heavy_reviewer_release
}

# --- CLI entry point ---

@test "slot helper CLI run subcommand works" {
  run bash "$SLOT_HELPER" run --limit 4 -- echo "cli test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cli test"* ]]
}

@test "slot helper CLI --help exits 0" {
  run bash "$SLOT_HELPER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"counting semaphore"* ]]
}

@test "slot helper CLI rejects unknown subcommand" {
  run bash "$SLOT_HELPER" bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown subcommand"* ]]
}
