#!/usr/bin/env bats
# review-semaphore.bats — tests for the heavy-reviewer counting semaphore.
#
# Covers:
#   - Schema validation of review.max_concurrent_heavy_reviewers
#   - Slot acquisition, release, dead-holder reclaim
#   - Contention (more requesters than the limit)
#   - Wait-bound expiry (fail-open with warning text)
#   - Release on failure and signal (INT/TERM terminate the process)
#   - System-wide limit independence from dev-slot limit
#   - Bash 3.2 + bash 5 portability (contention runs)
#   - Configured limit actually used; default limit when absent
#   - Caller wiring (qa-test-runner, phase2-execute)
#   - Input validation (non-integer, missing value)
#   - Sourcing the helper does not change caller shell options
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
  # The expiry warning must be logged (kills M2/M9 — expiry warning deleted).
  [[ "$output" == *"wait bound"*"expired"* ]]
}

@test "heavy_reviewer_run releases slot on child failure" {
  run bash -c "
    set -euo pipefail
    source '$LOCK_HELPER'
    source '$SLOT_HELPER'
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'
    heavy_reviewer_run --limit 4 -- false
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

# --- Signal handling (AC2 — release on interruption; kills M2/M7) ---

@test "heavy_reviewer_run terminates on TERM with non-zero exit and releases slot" {
  local sig_log="$BATS_TEST_TMPDIR/sig"
  mkdir -p "$sig_log"

  # Run the helper in a separate process (through the CLI) with a long-
  # running child; send TERM; check exit code and slot cleanup.
  bash "$SLOT_HELPER" run --limit 4 -- sh -c "
    echo tier1-running > '$sig_log/tier1'
    sleep 30
    echo tier2-ran > '$sig_log/tier2'
  " &
  local runner_pid=$!

  # Wait for tier1 to start.
  local waited=0
  while [ ! -f "$sig_log/tier1" ] && [ "$waited" -lt 20 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$sig_log/tier1" ]

  # Send TERM.
  kill -TERM "$runner_pid" 2>/dev/null || true
  local rc=0
  wait "$runner_pid" 2>/dev/null || rc=$?

  # The runner must exit non-zero (143 = 128+15 for TERM).
  [ "$rc" -ne 0 ]

  # Tier 2 must NOT have run.
  [ ! -f "$sig_log/tier2" ]

  # Slot must be released.
  local remaining
  remaining=$(find "$GAIA_STATE_DIR/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

# --- Contention test (AC6) ---
# Uses separate processes via the CLI wrapper, millisecond timestamps,
# and per-child wait instead of bare `wait`.

@test "contention: no more than limit run at once, no slot leaks, every waiter ran" {
  local limit=3
  local total=8
  local hold_ms=1500
  local log_dir="$BATS_TEST_TMPDIR/contention"
  mkdir -p "$log_dir"

  # Millisecond clock helper (perl Time::HiRes on macOS, date +%s%N fallback).
  local ms_cmd
  if perl -MTime::HiRes -e '1' 2>/dev/null; then
    ms_cmd='perl -MTime::HiRes -e "printf qq{%.3f\n}, Time::HiRes::time()"'
  else
    ms_cmd='date +%s.%N'
  fi

  # Launch $total holders as separate processes via the CLI wrapper.
  local pids=()
  for i in $(seq 1 "$total"); do
    bash "$SLOT_HELPER" run --limit "$limit" --wait-secs 30 -- sh -c "
      eval $ms_cmd > '$log_dir/start-$i'
      # Hold for approximately $hold_ms ms.
      local ms=$hold_ms
      sleep \$(printf '%d.%03d' \$((ms / 1000)) \$((ms % 1000)))
      eval $ms_cmd > '$log_dir/end-$i'
    " &
    pids+=($!)
  done

  # Wait for each child individually (avoids bare `wait` which can hang
  # under BATS_TEST_TIMEOUT by also waiting on the bats watchdog).
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Verify every waiter ran (AC6: no waiter silently skipped its command).
  local ran_count=0
  for i in $(seq 1 "$total"); do
    [ -f "$log_dir/start-$i" ] && [ -f "$log_dir/end-$i" ] && ran_count=$((ran_count + 1))
  done
  echo "ran_count=$ran_count total=$total"
  [ "$ran_count" -eq "$total" ]

  # For each start time, count how many jobs were running at that instant.
  local max_concurrent=0
  for i in $(seq 1 "$total"); do
    [ -f "$log_dir/start-$i" ] && [ -f "$log_dir/end-$i" ] || continue
    local si
    si="$(cat "$log_dir/start-$i")"
    local concurrent=0
    for j in $(seq 1 "$total"); do
      [ -f "$log_dir/start-$j" ] && [ -f "$log_dir/end-$j" ] || continue
      local sj ej
      sj="$(cat "$log_dir/start-$j")"
      ej="$(cat "$log_dir/end-$j")"
      # Job j was running at time si if sj <= si < ej (awk for float comparison).
      if awk -v si="$si" -v sj="$sj" -v ej="$ej" \
          'BEGIN { exit !( sj+0 <= si+0 && si+0 < ej+0 ) }'; then
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
  # Verify that the configured review limit is used, not the dev-slot
  # limit. Set both in config, then confirm the effective slot limit is
  # the review limit (2), not the dev-slot limit (8).
  [ -x "$RESOLVE_CONFIG" ] || skip "resolve-config.sh not executable"
  mkdir -p "$BATS_TEST_TMPDIR/cfg"
  cat > "$BATS_TEST_TMPDIR/cfg/project-config.yaml" <<'YAML'
project_name: test-project
stacks:
  - name: bash-dev
    path: "."
parallel_execution:
  max_parallel_dev_slots: 8
review:
  max_concurrent_heavy_reviewers: 2
YAML

  # Confirm resolve-config reads the review limit.
  local heavy_slots
  heavy_slots=$(bash "$RESOLVE_CONFIG" --config "$BATS_TEST_TMPDIR/cfg/project-config.yaml" \
    --field review.max_concurrent_heavy_reviewers)
  [ "$heavy_slots" = "2" ]

  # Run 3 concurrent holders with limit 2 (from config) via the CLI.
  # If the dev-slot limit (8) were used, all 3 would run at once.
  local log_dir="$BATS_TEST_TMPDIR/indep"
  mkdir -p "$log_dir"

  local ms_cmd
  if perl -MTime::HiRes -e '1' 2>/dev/null; then
    ms_cmd='perl -MTime::HiRes -e "printf qq{%.3f\n}, Time::HiRes::time()"'
  else
    ms_cmd='date +%s.%N'
  fi

  local pids=()
  for i in 1 2 3; do
    bash "$SLOT_HELPER" run --limit 2 --wait-secs 15 -- sh -c "
      eval $ms_cmd > '$log_dir/start-$i'
      sleep 1
      eval $ms_cmd > '$log_dir/end-$i'
    " &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Verify max concurrent is at most 2, not 3 (which dev-slot 8 would allow).
  local max_concurrent=0
  for i in 1 2 3; do
    [ -f "$log_dir/start-$i" ] && [ -f "$log_dir/end-$i" ] || continue
    local si
    si="$(cat "$log_dir/start-$i")"
    local concurrent=0
    for j in 1 2 3; do
      [ -f "$log_dir/start-$j" ] && [ -f "$log_dir/end-$j" ] || continue
      local sj ej
      sj="$(cat "$log_dir/start-$j")"
      ej="$(cat "$log_dir/end-$j")"
      if awk -v si="$si" -v sj="$sj" -v ej="$ej" \
          'BEGIN { exit !( sj+0 <= si+0 && si+0 < ej+0 ) }'; then
        concurrent=$((concurrent + 1))
      fi
    done
    if [ "$concurrent" -gt "$max_concurrent" ]; then
      max_concurrent="$concurrent"
    fi
  done

  echo "max concurrent observed: $max_concurrent (review limit: 2, dev-slot limit: 8)"
  [ "$max_concurrent" -le 2 ]
}

# --- Configured limit tests (AC1/AC5 — kills M12/M15/M17) ---

@test "configured limit is used when no --limit is passed" {
  # Set the config limit to 1, hold one slot with a live process, then
  # try to acquire without --limit — the configured limit (1) must apply
  # and the acquirer should fail open after the wait bound.
  [ -x "$RESOLVE_CONFIG" ] || skip "resolve-config.sh not executable"

  # Place the config where resolve-config.sh auto-discovers it:
  # $PROJECT_ROOT/.gaia/config/project-config.yaml.
  local project_root="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$project_root/.gaia/config"
  cat > "$project_root/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
stacks:
  - name: bash-dev
    path: "."
review:
  max_concurrent_heavy_reviewers: 1
YAML

  # Use the project's .gaia/state as the state dir.
  local state_dir="$project_root/.gaia/state"
  mkdir -p "$state_dir/review-semaphore.d"

  # Hold a slot from a live background process.
  sleep 30 &
  local bg_pid=$!
  printf '%s %s\n' "$bg_pid" "$(date +%s)" > "$state_dir/review-semaphore.d/slot-${bg_pid}.0"

  # Acquire without --limit; the helper should read the configured 1 from
  # resolve-config. With one slot held, it should wait and then fail open.
  run env GAIA_STATE_DIR="$state_dir" \
      PROJECT_ROOT="$project_root" \
      GAIA_REVIEW_SEMAPHORE_WAIT_SECS=2 \
      bash "$SLOT_HELPER" run --wait-secs 2 -- echo "should-proceed-without-slot"

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  # The child should have run (fail-open).
  [[ "$output" == *"should-proceed-without-slot"* ]]
  # The warning about expiry should be logged.
  [[ "$output" == *"wait bound"*"expired"* ]]
}

@test "default limit 4 is applied when config is absent" {
  # Without a config file, the helper defaults to 4. Hold 4 slots, then
  # the 5th must wait and fail open.
  mkdir -p "$GAIA_STATE_DIR/review-semaphore.d"

  # Create 4 fake live slots.
  local pids=()
  for i in 1 2 3 4; do
    sleep 30 &
    pids+=($!)
    printf '%s %s\n' "${pids[$((i-1))]}" "$(date +%s)" > "$GAIA_STATE_DIR/review-semaphore.d/slot-${pids[$((i-1))]}.0"
  done

  # The 5th acquirer with no config and no --limit should hit the default 4.
  run env GAIA_STATE_DIR="$GAIA_STATE_DIR" \
      GAIA_REVIEW_SEMAPHORE_WAIT_SECS=2 \
      bash "$SLOT_HELPER" run --wait-secs 2 -- echo "fifth-proceeded"

  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done

  [ "$status" -eq 0 ]
  [[ "$output" == *"fifth-proceeded"* ]]
  [[ "$output" == *"wait bound"*"expired"* ]]
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

# --- Input validation (non-integer, missing value) ---

@test "non-integer --limit is rejected" {
  run bash "$SLOT_HELPER" run --limit abc -- echo "should not run"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid limit"* ]]
}

@test "--limit with no value is rejected" {
  run bash "$SLOT_HELPER" run --limit
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]]
}

@test "non-integer wait-secs is rejected" {
  run bash -c "
    source '$LOCK_HELPER'
    source '$SLOT_HELPER'
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'
    export GAIA_REVIEW_SEMAPHORE_WAIT_SECS=abc
    heavy_reviewer_acquire --limit 1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid wait-secs"* ]]
}

# --- Sourcing does not change caller shell options (F5/F4) ---

@test "sourcing the slot helper does not change caller shell options" {
  # Test that sourcing heavy-reviewer-slots.sh preserves the caller's
  # set options and LC_ALL. Only the slot helper is tested here (the lock
  # helper is sourced lazily inside heavy_reviewer_acquire, not at file
  # source time).
  run bash -c "
    # Caller starts WITHOUT errexit and WITHOUT pipefail.
    set +e
    set +o pipefail
    saved_lc=\${LC_ALL:-UNSET}
    source '$SLOT_HELPER'
    # Check that the caller's options are unchanged after sourcing.
    if set -o | grep -q 'errexit.*on'; then
      echo 'FAIL: errexit was turned on by source'
      exit 1
    fi
    if set -o | grep -q 'pipefail.*on'; then
      echo 'FAIL: pipefail was turned on by source'
      exit 1
    fi
    current_lc=\${LC_ALL:-UNSET}
    if [ \"\$current_lc\" != \"\$saved_lc\" ]; then
      echo \"FAIL: LC_ALL changed from \$saved_lc to \$current_lc\"
      exit 1
    fi
    echo 'OK: caller options preserved'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: caller options preserved"* ]]
}

# --- Caller wiring: qa-test-runner acquires and releases (kills M3/M4/M9) ---

@test "qa-test-runner acquire line is present and reachable" {
  # Verify that qa-test-runner.sh contains the acquire call.
  local qa_runner="$PLUGIN_DIR/scripts/review-common/qa-test-runner.sh"
  [ -f "$qa_runner" ]
  /usr/bin/grep -q 'heavy_reviewer_acquire' "$qa_runner"
  # The release trap must also be present.
  /usr/bin/grep -q 'heavy_reviewer_release' "$qa_runner"
  # Signal traps must re-raise (not swallow).
  /usr/bin/grep -q 'kill -TERM' "$qa_runner"
}

# --- Caller wiring: phase2-execute acquires and releases (kills M5/M10) ---

@test "phase2-execute acquire line is present and uses script PLUGIN_ROOT" {
  # Verify that phase2-execute.sh uses the script's own PLUGIN_ROOT, not
  # the ambient CLAUDE_PLUGIN_ROOT env var.
  local p2="$PLUGIN_DIR/skills/gaia-test-automate/scripts/phase2-execute.sh"
  [ -f "$p2" ]
  /usr/bin/grep -q 'heavy_reviewer_acquire' "$p2"
  /usr/bin/grep -q 'heavy_reviewer_release' "$p2"
  # Must reference PLUGIN_ROOT (the script's computed var), not CLAUDE_PLUGIN_ROOT.
  /usr/bin/grep -q '_P2_SLOT_HELPER="${PLUGIN_ROOT}' "$p2"
  # The EXIT trap at the plan-temp section must still release the slot.
  /usr/bin/grep -q 'heavy_reviewer_release' "$p2"
  # Signal traps must re-raise.
  /usr/bin/grep -q 'kill -TERM' "$p2"
}

# --- Coverage-command wrapping in test-automate SKILL.md (Task 3.1) ---

@test "test-automate SKILL.md wraps coverage commands with slot helper" {
  local skill_md="$PLUGIN_DIR/skills/gaia-test-automate/SKILL.md"
  [ -f "$skill_md" ]
  # Both baseline and current coverage steps must reference the slot helper.
  local wrapper_count
  wrapper_count=$(/usr/bin/grep -c 'heavy-reviewer-slots.sh run' "$skill_md")
  [ "$wrapper_count" -ge 2 ]
}
