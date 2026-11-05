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

@test "empty slot file named for a dead PID is reclaimed" {
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  mkdir -p "$GAIA_STATE_DIR/review-semaphore.d"
  # Get a dead PID: start a no-op background job and wait for it.
  sleep 0 &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  # Ensure it is dead.
  kill -0 "$dead_pid" 2>/dev/null && skip "PID $dead_pid unexpectedly alive"
  local empty_slot="$GAIA_STATE_DIR/review-semaphore.d/slot-${dead_pid}.XXXXXX"
  : > "$empty_slot"

  heavy_reviewer_acquire --limit 4
  heavy_reviewer_release

  # The empty slot must have been reclaimed by the count/reclaim pass.
  [ ! -f "$empty_slot" ] || {
    echo "FAIL: empty slot for dead PID was not reclaimed"
    return 1
  }
}

@test "empty slot file named for a live PID is kept" {
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  mkdir -p "$GAIA_STATE_DIR/review-semaphore.d"
  # Create an empty slot file named for a live PID (a background sleep).
  sleep 30 &
  local live_pid=$!
  local empty_slot="$GAIA_STATE_DIR/review-semaphore.d/slot-${live_pid}.XXXXXX"
  : > "$empty_slot"

  heavy_reviewer_acquire --limit 4
  heavy_reviewer_release

  # The live-PID empty slot must NOT have been reclaimed.
  [ -f "$empty_slot" ] || {
    kill "$live_pid" 2>/dev/null || true; wait "$live_pid" 2>/dev/null || true
    echo "FAIL: empty slot for live PID was incorrectly reclaimed"
    return 1
  }

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  rm -f "$empty_slot"
}

@test "TERM during slot creation leaves no leaked slot file" {
  # Deterministic test: override _hrs_create_slot to self-signal right
  # after mktemp sets _HRS_MY_SLOT but before _HRS_ACQUIRED is set.
  # The release trap must clean up the file using _HRS_MY_SLOT alone.

  run bash -c "
    source '$LOCK_HELPER'
    source '$SLOT_HELPER'
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'

    # Override _hrs_create_slot to self-signal between the mktemp
    # assignment and the _HRS_ACQUIRED=1 write.
    _hrs_create_slot() {
      _HRS_MY_SLOT=\"\$(mktemp \"\${_HRS_SLOT_DIR}/slot-\$\$.XXXXXX\")\" || {
        _HRS_MY_SLOT=''
        return 1
      }
      # Signal ourselves BEFORE _HRS_ACQUIRED is set.
      kill -TERM \$\$ 2>/dev/null
      _HRS_ACQUIRED=1
      printf '%s %s\n' \"\$\$\" \"\$(date +%s)\" > \"\$_HRS_MY_SLOT\"
    }

    heavy_reviewer_run --limit 4 -- echo CHILD-RAN
  "

  # The wrapper should exit non-zero (TERM).
  [ "$status" -ne 0 ] || {
    echo "expected non-zero exit, got $status"
    return 1
  }

  # No slot files should remain.
  local remaining
  remaining=$(find "$GAIA_STATE_DIR/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ] || {
    echo "FAIL: $remaining slot files leaked"
    ls "$GAIA_STATE_DIR/review-semaphore.d"/slot-* 2>/dev/null
    return 1
  }
}

@test "qa-test-runner installs release traps before acquire" {
  # Pin the trap-before-acquire ordering so moving the acquire call
  # above the release traps fails this test.
  local qa_runner="$PLUGIN_DIR/scripts/review-common/qa-test-runner.sh"
  [ -f "$qa_runner" ] || skip "qa-test-runner.sh not found"

  # Extract the relevant lines: the source, traps and acquire must
  # appear in that order. The trap lines must come before acquire.
  local trap_line acquire_line
  trap_line=$(/usr/bin/grep -n "trap 'heavy_reviewer_release' EXIT" "$qa_runner" | head -1 | cut -d: -f1)
  acquire_line=$(/usr/bin/grep -n 'heavy_reviewer_acquire' "$qa_runner" | head -1 | cut -d: -f1)
  [ -n "$trap_line" ] || { echo "EXIT trap line not found"; return 1; }
  [ -n "$acquire_line" ] || { echo "acquire line not found"; return 1; }
  [ "$trap_line" -lt "$acquire_line" ] || {
    echo "FAIL: EXIT trap (line $trap_line) must come before acquire (line $acquire_line)"
    return 1
  }
}

@test "heavy_reviewer_run installs release traps before acquire" {
  # Pin the trap-before-acquire ordering so moving the acquire call
  # above the release traps in heavy_reviewer_run fails this test.
  local exit_trap_line acquire_line
  exit_trap_line=$(/usr/bin/grep -n "trap 'heavy_reviewer_release' EXIT" "$SLOT_HELPER" | head -1 | cut -d: -f1)
  acquire_line=$(/usr/bin/grep -n 'heavy_reviewer_acquire' "$SLOT_HELPER" | /usr/bin/grep -v '^[0-9]*:heavy_reviewer_acquire()' | /usr/bin/grep -v '#' | head -1 | cut -d: -f1)
  [ -n "$exit_trap_line" ] || { echo "EXIT trap line not found in helper"; return 1; }
  [ -n "$acquire_line" ] || { echo "acquire call line not found in helper"; return 1; }
  [ "$exit_trap_line" -lt "$acquire_line" ] || {
    echo "FAIL: EXIT trap (line $exit_trap_line) must come before acquire (line $acquire_line)"
    return 1
  }
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
  [[ "$output" == *"acquired=0"* ]] || return 1
  # The expiry warning must be logged.
  [[ "$output" == *"wait bound"*"expired"* ]] || return 1
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

# --- Signal handling (AC2 — release on interruption) ---

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
  # Use bash (not sh) for the child — dash on Linux lacks local/eval compat.
  local pids=()
  for i in $(seq 1 "$total"); do
    bash "$SLOT_HELPER" run --limit "$limit" --wait-secs 30 -- bash -c "
      $ms_cmd > '$log_dir/start-$i'
      sleep 1.5
      $ms_cmd > '$log_dir/end-$i'
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
    bash "$SLOT_HELPER" run --limit 2 --wait-secs 15 -- bash -c "
      $ms_cmd > '$log_dir/start-$i'
      sleep 1
      $ms_cmd > '$log_dir/end-$i'
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

# --- Configured limit tests (AC1/AC5) ---

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
  [[ "$output" == *"should-proceed-without-slot"* ]] || return 1
  # The warning about expiry should be logged.
  [[ "$output" == *"wait bound"*"expired"* ]] || return 1
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
  [[ "$output" == *"fifth-proceeded"* ]] || return 1
  [[ "$output" == *"wait bound"*"expired"* ]] || return 1
}

# --- Lock and slot directory paths (AC2) ---

@test "slot directory and lock use canonical state paths" {
  source "$LOCK_HELPER"
  source "$SLOT_HELPER"

  heavy_reviewer_acquire --limit 4
  # Check paths.
  [ "$_HRS_SLOT_DIR" = "$GAIA_STATE_DIR/review-semaphore.d" ]
  [ "$_HRS_LOCK_PATH" = "$GAIA_STATE_DIR/review-semaphore.lock" ]
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

# --- Sourcing does not change caller shell options ---

@test "sourcing the slot helper does not change caller shell options" {
  # Test that sourcing heavy-reviewer-slots.sh preserves the caller's
  # set options, pipefail, and LC_ALL. Only the slot helper is tested
  # here (the lock helper is sourced lazily inside heavy_reviewer_acquire,
  # not at file source time).
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
    echo 'OK: caller options preserved (pipefail off)'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: caller options preserved"* ]] || return 1
}

@test "sourcing the slot helper preserves caller pipefail when on" {
  # When a caller has pipefail ON before sourcing, it must stay on after.
  run bash -c "
    set -euo pipefail
    source '$SLOT_HELPER'
    if ! set -o | grep -q 'pipefail.*on'; then
      echo 'FAIL: pipefail was turned off by source'
      exit 1
    fi
    echo 'OK: pipefail preserved as on'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: pipefail preserved"* ]] || return 1
}

# --- Caller wiring: qa-test-runner acquires and releases ---

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

# --- Caller wiring: phase2-execute acquires and releases ---

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

# --- Default limit pinned at exactly 4 (AC1) ---

@test "default limit 4: the 4th of 4 acquires without waiting" {
  # With 3 live slots held, a 4th acquirer must succeed immediately
  # (not wait and fail open). This pins the default at exactly 4.
  mkdir -p "$GAIA_STATE_DIR/review-semaphore.d"

  local pids=()
  for i in 1 2 3; do
    sleep 30 &
    pids+=($!)
    printf '%s %s\n' "${pids[$((i-1))]}" "$(date +%s)" > "$GAIA_STATE_DIR/review-semaphore.d/slot-${pids[$((i-1))]}.0"
  done

  # The 4th acquirer with no config and no --limit should succeed (default 4).
  run env GAIA_STATE_DIR="$GAIA_STATE_DIR" \
      GAIA_REVIEW_SEMAPHORE_WAIT_SECS=3 \
      bash "$SLOT_HELPER" run --wait-secs 3 -- echo "fourth-acquired"

  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done

  [ "$status" -eq 0 ]
  # The child must have run without a wait-bound warning.
  [[ "$output" == *"fourth-acquired"* ]] || return 1
  # There must be no expiry warning (it acquired a slot, not failed open).
  if [[ "$output" == *"wait bound"*"expired"* ]]; then
    echo "FAIL: the 4th acquirer should not have waited"
    return 1
  fi
}

# --- Mutex-failure retry path (AC3) ---

@test "mutex failure retries instead of proceeding immediately" {
  # Hold the semaphore lock for 11 seconds (longer than the 10s acquire
  # timeout), so the first acquire_lock call fails. The helper should
  # then retry. After the lock is released, the retry succeeds and a
  # slot is acquired. Without the retry the helper would return
  # immediately with no slot, so the child sees 0 slot files.
  source "$LOCK_HELPER"

  mkdir -p "$GAIA_STATE_DIR/review-semaphore.d"
  local lockfile="$GAIA_STATE_DIR/review-semaphore.lock"
  local slot_marker="$BATS_TEST_TMPDIR/slot-seen"

  # Hold the lock for 11 seconds (one second past the 10s acquire timeout).
  (
    source "$LOCK_HELPER"
    acquire_lock "$lockfile" 5 42 || exit 1
    sleep 11
    release_lock 42
  ) &
  local holder_pid=$!
  sleep 0.3  # let the holder grab the lock

  # The child reports how many slot files exist during execution.
  run env GAIA_STATE_DIR="$GAIA_STATE_DIR" \
      GAIA_REVIEW_SEMAPHORE_WAIT_SECS=20 \
      bash "$SLOT_HELPER" run --limit 4 --wait-secs 20 -- \
        bash -c "count=\$(ls '$GAIA_STATE_DIR/review-semaphore.d'/slot-* 2>/dev/null | wc -l); echo slot-count=\$count > '$slot_marker'"

  wait "$holder_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [ -f "$slot_marker" ]
  # With the retry, a slot was acquired (count >= 1). Without the retry
  # no slot file is created, so count is 0.
  local count
  count=$(sed 's/slot-count=//' "$slot_marker" | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "no usable lock primitive proceeds at once with one warning" {
  # With neither flock nor ln on PATH, the helper should detect the
  # permanent failure up front and proceed without a slot immediately
  # rather than retrying until the wait bound.
  local shim_dir="$BATS_TEST_TMPDIR/no-lock-shim/bin"
  mkdir -p "$shim_dir"
  # Provide only the tools heavy-reviewer-slots.sh and acquire-lock.sh need
  # at runtime, deliberately excluding flock and ln.
  local t
  for t in sh bash env perl python3 jq seq awk sed grep cat printf \
           mktemp rm mkdir dirname basename find tail head sort uniq \
           wc date tr cut tee stat readlink sleep kill; do
    local p
    p="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$p" "$shim_dir/$t"
  done

  local start_epoch end_epoch elapsed
  start_epoch="$(date +%s)"
  run env -u GAIA_PARALLEL_EXECUTION \
      PATH="$shim_dir" \
      GAIA_STATE_DIR="$GAIA_STATE_DIR" \
      GAIA_REVIEW_SEMAPHORE_WAIT_SECS=6 \
      bash "$SLOT_HELPER" run --limit 4 --wait-secs 6 -- echo CHILD-RAN
  end_epoch="$(date +%s)"
  elapsed=$(( end_epoch - start_epoch ))

  [ "$status" -eq 0 ]
  # The child must still run (fail-open).
  [[ "$output" == *"CHILD-RAN"* ]] || return 1
  # Exactly one warning line about no lock primitive.
  local warn_count
  warn_count=$(/usr/bin/grep -c 'no usable lock primitive' <<< "$output" 2>/dev/null || echo 0)
  [ "$warn_count" -eq 1 ] || {
    echo "expected 1 warning, got $warn_count"
    return 1
  }
  # Must complete in well under the 6s wait bound (immediate).
  [ "$elapsed" -lt 3 ] || {
    echo "took ${elapsed}s, expected < 3s"
    return 1
  }
}

# --- stdin passthrough (regression check) ---

@test "heavy_reviewer_run passes stdin through to the child" {
  run bash -c "
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'
    printf 'hello-from-stdin\n' | bash '$SLOT_HELPER' run --limit 4 -- cat
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-from-stdin"* ]] || return 1
}

# --- Signal handling kills the child process group (regression) ---

@test "TERM to the wrapper process group leaves no orphaned grandchildren" {
  # Launch the wrapper in its own process group, send TERM to the group,
  # and verify no grandchild survives. The wrapped command spawns a real
  # background grandchild (sleep) and records its PID. Killing only the
  # direct child would leave the grandchild running.
  local gc_file="$BATS_TEST_TMPDIR/gc-pid-term"

  bash -c "
    set -m
    GAIA_STATE_DIR='$GAIA_STATE_DIR' \
      bash '$SLOT_HELPER' run --limit 4 -- \
        bash -c 'sleep 30 & echo \$! > \"$gc_file\"; wait' &
    W=\$!
    set +m
    tries=0
    while [ ! -f '$gc_file' ] && [ \$tries -lt 40 ]; do
      sleep 0.1; tries=\$((tries + 1))
    done
    sleep 0.2
    kill -TERM -- -\$W 2>/dev/null || true
    wait \$W 2>/dev/null || true
  " &
  local outer_pid=$!
  wait "$outer_pid" 2>/dev/null || true
  sleep 0.5

  [ -f "$gc_file" ] || { echo "grandchild never started"; return 1; }
  local gc_pid
  gc_pid=$(cat "$gc_file")

  if kill -0 "$gc_pid" 2>/dev/null; then
    echo "FAIL: grandchild survived TERM (pid $gc_pid)"
    kill "$gc_pid" 2>/dev/null || true
    return 1
  fi
}

@test "INT to the wrapper process group leaves no orphaned grandchildren" {
  # Same as the TERM test but with INT (Ctrl-C). Perl resets SIGINT to
  # SIG_DFL before exec so the wrapper can actually receive and trap INT
  # (bats backgrounds with SIG_IGN for INT; bash refuses to override it).
  command -v perl >/dev/null 2>&1 || skip "perl not available"
  local gc_file="$BATS_TEST_TMPDIR/gc-pid-int"
  local wrapper_pid_file="$BATS_TEST_TMPDIR/wrapper-pid-int"

  # Use perl to reset SIGINT, then exec the wrapper. The wrapper runs
  # in a subshell with set -m so it gets its own process group.
  bash -c "
    set -m
    perl -e '\$SIG{INT} = \"DEFAULT\"; exec @ARGV' \
      env GAIA_STATE_DIR='$GAIA_STATE_DIR' \
        bash '$SLOT_HELPER' run --limit 4 -- \
          bash -c 'sleep 300 & echo \$! > \"$gc_file\"; wait' &
    W=\$!
    set +m
    echo \$W > '$wrapper_pid_file'
    tries=0
    while [ ! -f '$gc_file' ] && [ \$tries -lt 40 ]; do
      sleep 0.1; tries=\$((tries + 1))
    done
    sleep 0.2
    kill -INT \$W 2>/dev/null || true
    wait \$W 2>/dev/null || true
  " &
  local outer_pid=$!
  wait "$outer_pid" 2>/dev/null || true
  sleep 0.5

  [ -f "$gc_file" ] || { echo "grandchild never started"; return 1; }
  local gc_pid
  gc_pid=$(cat "$gc_file")

  if kill -0 "$gc_pid" 2>/dev/null; then
    echo "FAIL: grandchild survived INT (pid $gc_pid)"
    kill "$gc_pid" 2>/dev/null || true
    return 1
  fi
}

# --- Behavioural caller wiring: qa-test-runner (AC2) ---

@test "qa-test-runner takes a slot while running and releases on success" {
  # Run qa-test-runner.sh with a tier command that checks for a slot file
  # via a marker. The tier command writes to a file so we can verify a
  # slot existed during execution, even though the runner captures tier output.
  local qa_runner="$PLUGIN_DIR/scripts/review-common/qa-test-runner.sh"
  [ -f "$qa_runner" ] || skip "qa-test-runner.sh not found"

  local fixture="$BATS_TEST_TMPDIR/qa-fixture"
  mkdir -p "$fixture/.gaia/state" "$fixture/workdir"
  local slot_marker="$fixture/slot-seen"

  # The tier command: check if a slot file exists and write the result to a marker file.
  cat > "$fixture/project-config.yaml" <<YAML
project_root: $fixture
project_path: $fixture
memory_path: $fixture/_memory
checkpoint_path: $fixture/_memory/checkpoints
installed_path: $fixture
framework_version: "1.225.0"
date: "2026-11-04"
test_execution:
  tier_1:
    placement: local
    command: "bash -c 'ls $fixture/.gaia/state/review-semaphore.d/slot-* >/dev/null 2>&1 && echo HELD > $slot_marker || echo NONE > $slot_marker; true'"
    timeout_seconds: 30
YAML

  run env \
    GAIA_STATE_DIR="$fixture/.gaia/state" \
    GAIA_EXECUTION_CONTEXT=local \
    PROJECT_ROOT="$fixture" \
    CLAUDE_PROJECT_ROOT="" \
    CLAUDE_PLUGIN_ROOT="" \
    PROJECT_PATH="" \
    bash "$qa_runner" \
      --story-key "E900-S1" \
      --workdir "$fixture/workdir" \
      --config "$fixture/project-config.yaml"

  [ "$status" -eq 0 ]

  # A slot must have been held during the tier.
  [ -f "$slot_marker" ]
  /usr/bin/grep -q 'HELD' "$slot_marker"

  # After completion, no slot files should remain.
  local remaining
  remaining=$(find "$fixture/.gaia/state/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

@test "qa-test-runner releases slot even when a tier command fails" {
  local qa_runner="$PLUGIN_DIR/scripts/review-common/qa-test-runner.sh"
  [ -f "$qa_runner" ] || skip "qa-test-runner.sh not found"

  local fixture="$BATS_TEST_TMPDIR/qa-fail-fixture"
  mkdir -p "$fixture/.gaia/state" "$fixture/workdir"

  cat > "$fixture/project-config.yaml" <<YAML
project_root: $fixture
project_path: $fixture
memory_path: $fixture/_memory
checkpoint_path: $fixture/_memory/checkpoints
installed_path: $fixture
framework_version: "1.225.0"
date: "2026-11-04"
test_execution:
  tier_1:
    placement: local
    command: "false"
    timeout_seconds: 30
YAML

  run env \
    GAIA_STATE_DIR="$fixture/.gaia/state" \
    GAIA_EXECUTION_CONTEXT=local \
    PROJECT_ROOT="$fixture" \
    CLAUDE_PROJECT_ROOT="" \
    CLAUDE_PLUGIN_ROOT="" \
    PROJECT_PATH="" \
    bash "$qa_runner" \
      --story-key "E900-S2" \
      --workdir "$fixture/workdir" \
      --config "$fixture/project-config.yaml"

  # The runner records tier failures as evidence (exit 0 is expected).
  # Slot must be released regardless of tier outcome.
  local remaining
  remaining=$(find "$fixture/.gaia/state/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

@test "qa-test-runner TERM during a tier exits non-zero and releases slot" {
  local qa_runner="$PLUGIN_DIR/scripts/review-common/qa-test-runner.sh"
  [ -f "$qa_runner" ] || skip "qa-test-runner.sh not found"

  local fixture="$BATS_TEST_TMPDIR/qa-term-fixture"
  mkdir -p "$fixture/.gaia/state" "$fixture/workdir"
  local tier2_marker="$fixture/tier2-ran"

  # Tier 1 sleeps for a while (so we can send TERM); tier 2 should never run.
  cat > "$fixture/project-config.yaml" <<YAML
project_root: $fixture
project_path: $fixture
memory_path: $fixture/_memory
checkpoint_path: $fixture/_memory/checkpoints
installed_path: $fixture
framework_version: "1.225.0"
date: "2026-11-04"
test_execution:
  tier_1:
    placement: local
    command: "bash -c 'echo tier1-started > $fixture/tier1-started; sleep 30'"
    timeout_seconds: 60
  tier_2:
    placement: local
    command: "bash -c 'echo tier2-ran > $tier2_marker'"
    timeout_seconds: 30
YAML

  env \
    GAIA_STATE_DIR="$fixture/.gaia/state" \
    GAIA_EXECUTION_CONTEXT=local \
    PROJECT_ROOT="$fixture" \
    CLAUDE_PROJECT_ROOT="" \
    CLAUDE_PLUGIN_ROOT="" \
    PROJECT_PATH="" \
    bash "$qa_runner" \
      --story-key "E900-S3" \
      --workdir "$fixture/workdir" \
      --config "$fixture/project-config.yaml" &
  local runner_pid=$!

  # Wait for tier 1 to start.
  local waited=0
  while [ ! -f "$fixture/tier1-started" ] && [ "$waited" -lt 40 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$fixture/tier1-started" ]

  # Send TERM to the runner.
  kill -TERM "$runner_pid" 2>/dev/null || true
  local rc=0
  wait "$runner_pid" 2>/dev/null || rc=$?

  # Runner must exit non-zero.
  [ "$rc" -ne 0 ]

  # Tier 2 must NOT have run.
  [ ! -f "$tier2_marker" ]

  # Slot must be released.
  local remaining
  remaining=$(find "$fixture/.gaia/state/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

@test "qa-test-runner INT during a tier exits non-zero and releases slot" {
  local qa_runner="$PLUGIN_DIR/scripts/review-common/qa-test-runner.sh"
  [ -f "$qa_runner" ] || skip "qa-test-runner.sh not found"
  command -v perl >/dev/null 2>&1 || skip "perl not available"

  local fixture="$BATS_TEST_TMPDIR/qa-int-fixture"
  mkdir -p "$fixture/.gaia/state" "$fixture/workdir"

  cat > "$fixture/project-config.yaml" <<YAML
project_root: $fixture
project_path: $fixture
memory_path: $fixture/_memory
checkpoint_path: $fixture/_memory/checkpoints
installed_path: $fixture
framework_version: "1.225.0"
date: "2026-11-04"
test_execution:
  tier_1:
    placement: local
    command: "bash -c 'echo tier1-started > $fixture/tier1-started; sleep 30'"
    timeout_seconds: 60
YAML

  # Perl resets SIGINT to SIG_DFL before exec. This undoes the SIG_IGN
  # that non-interactive bash sets for background processes, so the
  # runner's INT trap actually fires on kill -INT.
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
    env \
      GAIA_STATE_DIR="$fixture/.gaia/state" \
      GAIA_EXECUTION_CONTEXT=local \
      PROJECT_ROOT="$fixture" \
      CLAUDE_PROJECT_ROOT="" \
      CLAUDE_PLUGIN_ROOT="" \
      PROJECT_PATH="" \
      bash "$qa_runner" \
        --story-key "E900-S3" \
        --workdir "$fixture/workdir" \
        --config "$fixture/project-config.yaml" &
  local runner_pid=$!

  local waited=0
  while [ ! -f "$fixture/tier1-started" ] && [ "$waited" -lt 80 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$fixture/tier1-started" ] || {
    kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true
    echo "tier1 never started"; return 1
  }

  kill -INT "$runner_pid" 2>/dev/null || true
  local rc=0
  wait "$runner_pid" 2>/dev/null || rc=$?

  [ "$rc" -ne 0 ] || { echo "expected non-zero rc, got $rc"; return 1; }

  local remaining
  remaining=$(find "$fixture/.gaia/state/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

# --- Behavioural caller wiring: phase2-execute (AC2) ---
# These tests drive the real phase2-execute.sh with a fixture that reaches
# the slot acquire at Step 4 (ledger + approved plan + empty sources/tests).

_p2_make_fixture() {
  # Build a phase2-execute fixture that passes Steps 0-3 and reaches the
  # slot acquire. Takes one argument: the fixture root directory.
  # Optional second argument: a test_file path to include in proposed_tests.
  local fx="$1"
  local test_file="${2:-}"
  mkdir -p "$fx/state/review-semaphore.d" "$fx/gaia-public/plugins/gaia/tests"

  # test-environment.yaml with the tier allowlist.
  cat > "$fx/te.yaml" <<YAML
---
tier_directories:
  - "$fx/gaia-public/plugins/gaia/tests"
YAML

  # Ledger with a PASSED entry for the plan.
  printf 'E900-S10\ttest-automate-plan\tplan-1\tPASSED\n' > "$fx/ledger"

  # Approved plan. When a test_file is given, include it so phase2 writes
  # it in Step 3 and executes it via bats in Step 4.
  mkdir -p "$fx/plans"
  local tests_json='[]'
  if [ -n "$test_file" ]; then
    tests_json='[{"test_file":"'"$test_file"'","test_cases":[{"name":"generated case","assertion":"passes"}]}]'
  fi
  cat > "$fx/plans/p.md" <<YAML
---
template: test-automate-plan
story_key: "E900-S10"
plan_id: "plan-1"
phase: approved
approval:
  verdict: "PASSED"
  verdict_plan_id: "plan-1"
analyzed_sources: []
proposed_tests: ${tests_json}
---

# plan
YAML
}

@test "phase2-execute takes a slot during execution and releases on success" {
  local p2="$PLUGIN_DIR/skills/gaia-test-automate/scripts/phase2-execute.sh"
  [ -f "$p2" ] || skip "phase2-execute.sh not found"

  local fixture="$BATS_TEST_TMPDIR/p2-slot"
  _p2_make_fixture "$fixture"

  # Run under bash -x and capture the trace. The trace will show mktemp
  # creating a slot file (heavy_reviewer_acquire) and rm -f removing it
  # (heavy_reviewer_release). With a stubbed acquire, neither appears.
  env -u CLAUDE_PLUGIN_ROOT GAIA_STATE_DIR="$fixture/state" \
    bash -x "$p2" --story E900-S10 --plan "$fixture/plans/p.md" \
    --ledger "$fixture/ledger" --test-env "$fixture/te.yaml" \
    --project-root "$fixture" >"$fixture/out" 2>"$fixture/trace" || true

  # The trace must show a slot file was created (mktemp in the slot dir).
  /usr/bin/grep -q 'review-semaphore.d/slot-' "$fixture/trace"

  # After completion, no slot files should remain (the slot was released).
  local remaining
  remaining=$(find "$fixture/state/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

@test "phase2-execute TERM during execution exits non-zero and releases slot" {
  local p2="$PLUGIN_DIR/skills/gaia-test-automate/scripts/phase2-execute.sh"
  [ -f "$p2" ] || skip "phase2-execute.sh not found"
  command -v bats >/dev/null 2>&1 || skip "bats not on PATH"

  local fixture="$BATS_TEST_TMPDIR/p2-term"
  local test_file="$fixture/gaia-public/plugins/gaia/tests/slow.bats"
  _p2_make_fixture "$fixture" "$test_file"

  # A background watcher replaces the generated test file with a slow
  # version as soon as Step 3 writes it. Step 4 then runs bats on the
  # slow file, keeping phase2 alive long enough to receive TERM.
  (
    while [ ! -f "$test_file" ]; do sleep 0.02; done
    printf '#!/usr/bin/env bats\n# Generated by phase2-execute.sh\n' > "$test_file"
    printf '@test "slow" { sleep 30; }\n' >> "$test_file"
  ) &
  local watcher_pid=$!

  env -u CLAUDE_PLUGIN_ROOT GAIA_STATE_DIR="$fixture/state" \
    bash "$p2" --story E900-S10 --plan "$fixture/plans/p.md" \
    --ledger "$fixture/ledger" --test-env "$fixture/te.yaml" \
    --project-root "$fixture" >"$fixture/out" 2>&1 &
  local p2_pid=$!

  # Wait for the slot to appear (phase2 reached Step 4 and bats is running).
  local waited=0
  while [ "$waited" -lt 80 ]; do
    if ls "$fixture/state/review-semaphore.d"/slot-* >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # Assert the slot appeared; if not, the test cannot prove anything.
  ls "$fixture/state/review-semaphore.d"/slot-* >/dev/null 2>&1 || {
    kill "$p2_pid" 2>/dev/null || true; wait "$p2_pid" 2>/dev/null || true
    kill "$watcher_pid" 2>/dev/null || true; wait "$watcher_pid" 2>/dev/null || true
    echo "FAIL: slot file never appeared"; return 1
  }

  # Send TERM.
  kill -TERM "$p2_pid" 2>/dev/null || true
  local rc=0
  wait "$p2_pid" 2>/dev/null || rc=$?
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  # Must exit non-zero.
  [ "$rc" -ne 0 ]

  # Slot must be released via the EXIT/TERM trap.
  local remaining
  remaining=$(find "$fixture/state/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

@test "phase2-execute INT during execution exits non-zero and releases slot" {
  local p2="$PLUGIN_DIR/skills/gaia-test-automate/scripts/phase2-execute.sh"
  [ -f "$p2" ] || skip "phase2-execute.sh not found"
  command -v bats >/dev/null 2>&1 || skip "bats not on PATH"
  command -v perl >/dev/null 2>&1 || skip "perl not available"

  local fixture="$BATS_TEST_TMPDIR/p2-int"
  local test_file="$fixture/gaia-public/plugins/gaia/tests/slow.bats"
  _p2_make_fixture "$fixture" "$test_file"

  (
    while [ ! -f "$test_file" ]; do sleep 0.02; done
    printf '#!/usr/bin/env bats\n# Generated by phase2-execute.sh\n' > "$test_file"
    printf '@test "slow" { sleep 30; }\n' >> "$test_file"
  ) &
  local watcher_pid=$!

  # Perl resets SIGINT to SIG_DFL before exec. This undoes the SIG_IGN
  # that non-interactive bash sets for background processes, so the
  # runner's INT trap actually fires on kill -INT.
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
    env -u CLAUDE_PLUGIN_ROOT GAIA_STATE_DIR="$fixture/state" \
      bash "$p2" --story E900-S10 --plan "$fixture/plans/p.md" \
      --ledger "$fixture/ledger" --test-env "$fixture/te.yaml" \
      --project-root "$fixture" >"$fixture/out" 2>&1 &
  local p2_pid=$!

  local waited=0
  while [ "$waited" -lt 80 ]; do
    if ls "$fixture/state/review-semaphore.d"/slot-* >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  ls "$fixture/state/review-semaphore.d"/slot-* >/dev/null 2>&1 || {
    kill "$p2_pid" 2>/dev/null || true; wait "$p2_pid" 2>/dev/null || true
    kill "$watcher_pid" 2>/dev/null || true; wait "$watcher_pid" 2>/dev/null || true
    echo "FAIL: slot file never appeared"; return 1
  }

  kill -INT "$p2_pid" 2>/dev/null || true
  local rc=0
  wait "$p2_pid" 2>/dev/null || rc=$?
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  [ "$rc" -ne 0 ] || { echo "expected non-zero rc, got $rc"; return 1; }

  local remaining
  remaining=$(find "$fixture/state/review-semaphore.d" -name 'slot-*' 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ]
}

# --- AC5: independence test reads configured value (not explicit --limit) ---

@test "semaphore independence: configured limit used without explicit --limit" {
  # Set review limit to 2 and dev-slot limit to 8 in config. Run 3
  # concurrent holders WITHOUT --limit. If the dev-slot limit (8) were
  # used, all 3 would run at once; with the review limit (2), max
  # concurrent must be 2.
  [ -x "$RESOLVE_CONFIG" ] || skip "resolve-config.sh not executable"

  local project_root="$BATS_TEST_TMPDIR/indep-proj"
  mkdir -p "$project_root/.gaia/config" "$project_root/.gaia/state"
  cat > "$project_root/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
stacks:
  - name: bash-dev
    path: "."
parallel_execution:
  max_parallel_dev_slots: 8
review:
  max_concurrent_heavy_reviewers: 2
YAML

  local state_dir="$project_root/.gaia/state"
  local log_dir="$BATS_TEST_TMPDIR/indep-log"
  mkdir -p "$log_dir"

  local ms_cmd
  if perl -MTime::HiRes -e '1' 2>/dev/null; then
    ms_cmd='perl -MTime::HiRes -e "printf qq{%.3f\n}, Time::HiRes::time()"'
  else
    ms_cmd='date +%s.%N'
  fi

  local pids=()
  for i in 1 2 3; do
    env GAIA_STATE_DIR="$state_dir" \
        PROJECT_ROOT="$project_root" \
      bash "$SLOT_HELPER" run --wait-secs 15 -- bash -c "
        $ms_cmd > '$log_dir/start-$i'
        sleep 1
        $ms_cmd > '$log_dir/end-$i'
      " &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Verify max concurrent is at most 2.
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

# --- Library-mode run preserves caller traps ---

@test "library-mode heavy_reviewer_run does not wipe caller traps" {
  run bash -c "
    source '$LOCK_HELPER'
    source '$SLOT_HELPER'
    export GAIA_STATE_DIR='$GAIA_STATE_DIR'
    # Set caller traps.
    trap 'echo caller-exit-cleanup' EXIT
    trap 'echo caller-int' INT
    heavy_reviewer_run --limit 4 -- true
    # After run returns, caller traps should still be set.
    exit_trap=\$(trap -p EXIT)
    int_trap=\$(trap -p INT)
    if [ -z \"\$exit_trap\" ]; then
      echo 'FAIL: EXIT trap was wiped'
      exit 1
    fi
    if [ -z \"\$int_trap\" ]; then
      echo 'FAIL: INT trap was wiped'
      exit 1
    fi
    echo 'OK: caller traps preserved'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: caller traps preserved"* ]] || return 1
}
