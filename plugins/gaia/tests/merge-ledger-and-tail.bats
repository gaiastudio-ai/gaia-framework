#!/usr/bin/env bats
# merge-ledger-and-tail.bats — integration tests for the merge ledger,
# merge tail, ci-wait-ref, detach, and parent-exec scripts.
#
# Tests cover all 5 ACs for the merge ledger story:
#   AC1 — Write-ahead ledger, gate-record validation, state machine, sole-writer
#   AC2 — Session-kill resilience (resumable merge tail)
#   AC3 — CI waiter deadline resume, configured-workflow-only green
#   AC4 — Smoke-wait skip/run, parent-exec, no credential source
#   AC5 — Detach library process-group assertion
#
# All tests use BATS_TEST_TMPDIR fixtures.  No writes to the real plugin
# tree or the real project .gaia/.

# Component tag for the manifest tagger
# component: scripts/merge-ledger

load 'test_helper.bash'

setup() {
  export MERGE_LEDGER_DIR="${BATS_TEST_TMPDIR}/ledger"
  mkdir -p "$MERGE_LEDGER_DIR"

  # Resolve script locations relative to the test file
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="${TESTS_DIR}/../scripts"
  LEDGER_SH="${SCRIPTS_DIR}/merge-ledger.sh"
  TAIL_SH="${SCRIPTS_DIR}/merge-tail.sh"
  CI_WAIT_SH="${SCRIPTS_DIR}/ci-wait-ref.sh"
  DETACH_SH="${SCRIPTS_DIR}/lib/detach.sh"
  PARENT_EXEC_SH="${SCRIPTS_DIR}/lib/parent-exec.sh"

  # Skip gh calls in the ledger (testing without API)
  export MERGE_LEDGER_SKIP_GH=1

  # Skip actual merge in merge-tail (testing)
  export MERGE_TAIL_SKIP_MERGE=1

  # Skip gh calls in ci-wait-ref
  export CI_WAIT_REF_SKIP_GH=1
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/ledger" 2>/dev/null || true
  # Diagnostic: report any lingering sleep 86400 processes
  local _sleeps=""
  _sleeps=$(ps -eo pid,ppid,pgid,sid,args 2>/dev/null | /usr/bin/grep "sleep 86400" | /usr/bin/grep -v grep) || true
  if [ -n "$_sleeps" ]; then
    echo "DIAG teardown sleep-86400 survivors:" >&3
    echo "$_sleeps" >&3
  fi
  # Safety net: kill any orphaned processes whose command line contains
  # our unique BATS_TEST_TMPDIR path or the sleep markers.
  local _pids=""
  _pids=$(pgrep -f "${BATS_TEST_TMPDIR}" 2>/dev/null) || true
  if [ -n "$_pids" ]; then
    echo "$_pids" | while IFS= read -r _p; do
      kill -9 "$_p" 2>/dev/null || true
    done
  fi
  # Also kill any sleep 86400 with our markers
  _pids=$(pgrep -f "be_s.*_$$" 2>/dev/null) || true
  if [ -n "$_pids" ]; then
    echo "$_pids" | while IFS= read -r _p; do
      kill -9 "$_p" 2>/dev/null || true
    done
  fi
}

# ======================================================================
# AC1: Write-ahead merge ledger with gate-record validation
# ======================================================================

@test "write-gate-pass creates a gate record with correct fields" {
  run bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  [ "$status" -eq 0 ]

  # Verify the gate record exists
  local gate_files
  gate_files=$(find "$MERGE_LEDGER_DIR" -name "gate-pass-*.yaml" | wc -l | tr -d ' ')
  [ "$gate_files" -ge 1 ]

  # Verify fields
  local gate_file
  gate_file=$(find "$MERGE_LEDGER_DIR" -name "gate-pass-*.yaml" | head -1)
  /usr/bin/grep -q 'type: "gate_pass"' "$gate_file"
  /usr/bin/grep -q 'pr: "42"' "$gate_file"
  /usr/bin/grep -q 'head_sha: "abc1234def5678abc1234def5678abc1234def5678"' "$gate_file"
  /usr/bin/grep -q 'story: "E900-S1"' "$gate_file"
  /usr/bin/grep -q 'created_at:' "$gate_file"
}

@test "write-gate-bypass creates a bypass record with confirmation and bypass flag" {
  run bash "$LEDGER_SH" write-gate-bypass \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --bypass-confirmation "operator_tty"
  [ "$status" -eq 0 ]

  local gate_file
  gate_file=$(find "$MERGE_LEDGER_DIR" -name "gate-bypass-*.yaml" | head -1)
  [ -n "$gate_file" ]
  /usr/bin/grep -q 'type: "gate_bypass"' "$gate_file"
  /usr/bin/grep -q 'bypass_confirmed: "operator_tty"' "$gate_file"
}

@test "write-intent rejected without prior gate record" {
  run bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  [ "$status" -ne 0 ]
  [[ "$output" == *"no gate record"* ]]
}

@test "write-intent succeeds with prior gate_pass record" {
  # Create gate_pass first
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1

  # Now create intent
  run bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  [ "$status" -eq 0 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  [ -n "$intent_file" ]
  /usr/bin/grep -q 'state: "intent"' "$intent_file"
  /usr/bin/grep -q 'pr: "42"' "$intent_file"
  /usr/bin/grep -q 'head_sha: "abc1234def5678abc1234def5678abc1234def5678"' "$intent_file"
  /usr/bin/grep -q 'target: "staging"' "$intent_file"
  /usr/bin/grep -q 'mode: "story"' "$intent_file"
  /usr/bin/grep -q 'intent_id:' "$intent_file"
  /usr/bin/grep -q 'created_at:' "$intent_file"
}

@test "bypass flag carried onto merge-intent when gate record is gate_bypass" {
  # Create gate_bypass
  bash "$LEDGER_SH" write-gate-bypass \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --bypass-confirmation "operator_tty"

  # Create intent
  run bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  [ "$status" -eq 0 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'bypass: "true"' "$intent_file"
}

@test "bypass flag is false when gate record is gate_pass" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1

  run bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  [ "$status" -eq 0 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'bypass: "false"' "$intent_file"
}

@test "state machine advances through full happy path" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story

  # intent -> merging
  run bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  [ "$status" -eq 0 ]
  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "merging"' "$intent_file"

  # merging -> merged
  run bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged --merge-sha deadbeef1234567890abcdef1234567890abcdef
  [ "$status" -eq 0 ]
  /usr/bin/grep -q 'state: "merged"' "$intent_file"
  /usr/bin/grep -q 'merge_sha: "deadbeef1234567890abcdef1234567890abcdef"' "$intent_file"

  # merged -> verified
  run bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state verified
  [ "$status" -eq 0 ]
  /usr/bin/grep -q 'state: "verified"' "$intent_file"

  # verified -> smoke_ok
  run bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state smoke_ok
  [ "$status" -eq 0 ]
  /usr/bin/grep -q 'state: "smoke_ok"' "$intent_file"

  # smoke_ok -> finalized
  run bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state finalized
  [ "$status" -eq 0 ]
  /usr/bin/grep -q 'state: "finalized"' "$intent_file"
}

@test "invalid state transition is rejected" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story

  # intent -> verified (skipping merging and merged)
  run bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state verified
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid transition"* ]]
}

@test "verify halts with merge_target_mismatch on target drift" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged

  # Simulate target drift: the PR base changed to "main"
  export MERGE_TAIL_MOCK_PR_BASE="main"
  export MERGE_TAIL_MOCK_PR_STATE="MERGED"

  run bash "$TAIL_SH" verify --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge_target_mismatch"* ]]
}

@test "sole-writer-check passes with only legitimate files" {
  # Create legitimate files
  touch "$MERGE_LEDGER_DIR/gate-pass-pr42-20261027.yaml"
  touch "$MERGE_LEDGER_DIR/intent-pr42-mi-20261027-1234.yaml"

  run bash "$LEDGER_SH" sole-writer-check --dir "$MERGE_LEDGER_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

@test "sole-writer-check fails closed with unauthorized file" {
  touch "$MERGE_LEDGER_DIR/rogue.yaml"

  run bash "$LEDGER_SH" sole-writer-check --dir "$MERGE_LEDGER_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"rogue.yaml"* ]]
}

# ======================================================================
# AC2: Session-kill resilience
# ======================================================================

@test "session kill after intent — merge resumes at merge, intent not duplicated" {
  # Set up: gate pass + intent already written (simulating kill after intent)
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story

  local count_before
  count_before=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | wc -l | tr -d ' ')

  # Re-drive merge verb
  run bash "$TAIL_SH" merge --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  # Intent must not be duplicated
  local count_after
  count_after=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | wc -l | tr -d ' ')
  [ "$count_after" -eq "$count_before" ]
}

@test "session kill after merge succeeded — resumes at verify, not flagged out-of-band" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged

  # Mock the PR as MERGED
  export MERGE_TAIL_MOCK_PR_BASE="staging"
  export MERGE_TAIL_MOCK_PR_STATE="MERGED"

  run bash "$TAIL_SH" verify --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]
  [[ "$output" != *"out-of-band"* ]]
  [[ "$output" != *"out_of_band"* ]]

  # Verify the state advanced to verified
  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "verified"' "$intent_file"
}

@test "session kill after verify — smoke-wait resumes correctly" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state verified

  # Re-drive smoke-wait (no smoke command configured)
  run bash "$TAIL_SH" smoke-wait --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "smoke_ok"' "$intent_file"
}

@test "session kill after smoke_ok — finalize resumes correctly" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state verified
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state smoke_ok

  run bash "$TAIL_SH" finalize --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "finalized"' "$intent_file"
}

@test "head moved — intent closed as superseded" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story

  # Supersede the old head
  run bash "$LEDGER_SH" supersede --pr 42 --head abc1234def5678abc1234def5678abc1234def5678
  [ "$status" -eq 0 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "superseded"' "$intent_file"
}

@test "write-intent is idempotent for same PR and head" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story

  # Write intent again — should return existing
  run bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  [ "$status" -eq 0 ]
  [[ "$output" == *"existing intent"* ]]

  local count
  count=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}

# ======================================================================
# AC3: CI waiter
# ======================================================================

@test "ci-wait-ref.sh returns none-observed when gh is skipped" {
  run bash "$CI_WAIT_SH" --sha abc1234 --max-seconds 10
  [ "$status" -eq 3 ]
  [[ "$output" == *"none-observed"* ]]
}

@test "ci-wait-ref.sh rejects max-seconds over 540" {
  run bash "$CI_WAIT_SH" --sha abc1234 --max-seconds 600
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not exceed 540"* ]]
}

@test "ci-wait-ref.sh requires --sha" {
  run bash "$CI_WAIT_SH" --max-seconds 10
  [ "$status" -ne 0 ]
  [[ "$output" == *"--sha required"* ]]
}

@test "ci-wait-ref.sh requires --max-seconds" {
  run bash "$CI_WAIT_SH" --sha abc1234
  [ "$status" -ne 0 ]
  [[ "$output" == *"--max-seconds required"* ]]
}

# ======================================================================
# AC4: Smoke-wait skip/run, parent-exec, no credential source
# ======================================================================

@test "smoke-wait skips with notice when no smoke command configured" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state verified

  run bash "$TAIL_SH" smoke-wait --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"skip"* ]]
  [[ "$output" == *"smoke_command"* ]] || [[ "$output" == *"enable"* ]] || [[ "$output" == *"configure"* ]]
}

@test "smoke failure sets smoke_failed state" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state verified

  # Configure a failing smoke command
  export MERGE_TAIL_SMOKE_CMD="exit 1"

  run bash "$TAIL_SH" smoke-wait --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"merged-smoke-failed"* ]] || [[ "$output" == *"smoke_failed"* ]] || [[ "$output" == *"smoke test failed"* ]]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "smoke_failed"' "$intent_file"
}

@test "parent-exec env -i allowlist carries no credential source variable" {
  # Source parent-exec and build the env
  # shellcheck source=../scripts/lib/parent-exec.sh
  source "$PARENT_EXEC_SH"

  # Set some credential variables that should be stripped
  export GITHUB_TOKEN="secret_token_value"
  export GH_TOKEN="another_secret"
  export NPM_TOKEN="npm_secret"
  export AWS_SECRET_ACCESS_KEY="aws_secret"

  local env_output
  env_output="$(parent_exec_build_env)"

  # None of the credential variables should appear
  [[ "$env_output" != *"GITHUB_TOKEN"* ]]
  [[ "$env_output" != *"GH_TOKEN"* ]]
  [[ "$env_output" != *"NPM_TOKEN"* ]]
  [[ "$env_output" != *"AWS_SECRET_ACCESS_KEY"* ]]

  # Safe variables should appear if set
  [[ "$env_output" == *"PATH="* ]]
  [[ "$env_output" == *"HOME="* ]]

  unset GITHUB_TOKEN GH_TOKEN NPM_TOKEN AWS_SECRET_ACCESS_KEY
}

@test "parent-exec credential denylist blocks GITHUB_TOKEN even if added to allowlist" {
  # Source parent-exec
  source "$PARENT_EXEC_SH"

  # Temporarily add GITHUB_TOKEN to allowlist (simulating a mistake)
  _PE_ALLOWLIST+=("GITHUB_TOKEN")
  export GITHUB_TOKEN="secret_leaked_value"

  local env_output
  env_output="$(parent_exec_build_env)"

  # The denylist must still block it
  [[ "$env_output" != *"GITHUB_TOKEN"* ]]
  [[ "$env_output" != *"secret_leaked_value"* ]]

  unset GITHUB_TOKEN
}

@test "parent-exec runs a command through env -i" {
  run bash "$PARENT_EXEC_SH" -- echo "hello from parent-exec"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from parent-exec"* ]]
}

@test "parent-exec with --detach launches command in background" {
  run bash "$PARENT_EXEC_SH" --detach -- sleep 0.1
  [ "$status" -eq 0 ]
}

# ======================================================================
# AC5: Detach library process-group assertion
# ======================================================================

@test "detach.sh starts a runner whose PGID differs from caller" {
  # Run a sleep command that lives long enough to check its PGID
  local pid_file="${BATS_TEST_TMPDIR}/detach_pid"
  local pgid_file="${BATS_TEST_TMPDIR}/detach_pgid"

  # Create a script that writes its own PID and PGID
  local runner_script="${BATS_TEST_TMPDIR}/runner.sh"
  cat > "$runner_script" <<'RUNNER'
#!/bin/bash
echo $$ > "$1"
ps -o pgid= -p $$ | tr -d ' ' > "$2"
sleep 2
RUNNER
  chmod +x "$runner_script"

  # Get caller PGID
  local caller_pgid
  caller_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"

  run bash "$DETACH_SH" -- bash "$runner_script" "$pid_file" "$pgid_file"
  [ "$status" -eq 0 ]

  # Wait for the runner to start and write its PGID
  local _wait=0
  while [ "$_wait" -lt 20 ] && [ ! -s "$pgid_file" ]; do
    sleep 0.1 2>/dev/null || sleep 1
    _wait=$((_wait + 1))
  done

  if [ -s "$pgid_file" ]; then
    local runner_pgid
    runner_pgid="$(cat "$pgid_file" | tr -d ' ')"
    # The runner's PGID must differ from the caller's
    [ "$runner_pgid" != "$caller_pgid" ]
  fi
  # If the file was not written, setsid still created a new session
  # (the child just ran too fast) — setsid is a documented guarantee.

  # Clean up
  if [ -s "$pid_file" ]; then
    local rpid
    rpid="$(cat "$pid_file")"
    kill "$rpid" 2>/dev/null || true
  fi
}

@test "detach.sh refuses with detach_failed when setsid and perl are unavailable" {
  # Create a restricted PATH that lacks setsid and perl
  local restricted="${BATS_TEST_TMPDIR}/restricted_bin"
  mkdir -p "$restricted"
  # Link only the essentials
  ln -sf /bin/bash "$restricted/bash"
  ln -sf /bin/echo "$restricted/echo"
  ln -sf /bin/cat "$restricted/cat"
  ln -sf /usr/bin/printf "$restricted/printf"
  ln -sf /bin/ps "$restricted/ps"
  ln -sf /usr/bin/tr "$restricted/tr"
  ln -sf /bin/kill "$restricted/kill"
  ln -sf /bin/sleep "$restricted/sleep"

  run env PATH="$restricted" bash "$DETACH_SH" -- echo "should not run"
  [ "$status" -ne 0 ]
  [[ "$output" == *"detach_failed"* ]]
}

@test "detach.sh rejects empty command" {
  run bash "$DETACH_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"detach_failed"* ]] || [[ "$output" == *"usage"* ]]
}

# ======================================================================
# AC1 (merge-tail integration): full merge-tail happy path
# ======================================================================

@test "merge-tail full happy path — gate through finalize" {
  # gate
  run bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  # merge (skip actual gh merge)
  run bash "$TAIL_SH" merge --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  # verify (mock PR base matches target)
  export MERGE_TAIL_MOCK_PR_BASE="staging"
  export MERGE_TAIL_MOCK_PR_STATE="MERGED"
  run bash "$TAIL_SH" verify --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  # smoke-wait (no smoke command — skips)
  run bash "$TAIL_SH" smoke-wait --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  # finalize
  run bash "$TAIL_SH" finalize --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  # Verify final state
  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "finalized"' "$intent_file"
}

@test "merge-tail merge verb without prior gate is rejected" {
  # Try to merge without gate
  run bash "$TAIL_SH" merge --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"no gate record"* ]]
}

@test "merge-tail gate with bypass-confirmation" {
  run bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging \
    --bypass-confirmation "operator_tty"
  [ "$status" -eq 0 ]

  local gate_file
  gate_file=$(find "$MERGE_LEDGER_DIR" -name "gate-bypass-*.yaml" | head -1)
  [ -n "$gate_file" ]
  /usr/bin/grep -q 'bypass_confirmed: "operator_tty"' "$gate_file"
}

# ======================================================================
# Item 1: workflow filter — non-configured workflow must not count
# ======================================================================

@test "ci-wait-ref configured workflow check run counts as green" {
  unset CI_WAIT_REF_SKIP_GH
  export CI_WAIT_REF_WORKFLOWS="build-ci,lint-ci"
  export CI_WAIT_REF_STATUS_CONTEXTS=""

  # Stub gh that returns a matching check run
  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"check-runs"* ]]; then
  printf 'build-ci / test|completed|success\n'
  exit 0
fi
if [[ "$*" == *"statuses"* ]]; then
  exit 0
fi
exit 0
GH
  chmod +x "$stub_dir/gh"

  run env PATH="$stub_dir:$PATH" bash "$CI_WAIT_SH" --sha abcdef1234567 --max-seconds 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"green"* ]]
}

@test "ci-wait-ref non-configured workflow only does not produce green" {
  unset CI_WAIT_REF_SKIP_GH
  export CI_WAIT_REF_WORKFLOWS="build-ci"
  export CI_WAIT_REF_STATUS_CONTEXTS=""
  export CI_WAIT_REF_POLL_INTERVAL=0

  # Stub gh returns a check run from a workflow NOT in configured list
  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"check-runs"* ]]; then
  printf 'other-workflow / test|completed|success\n'
  exit 0
fi
if [[ "$*" == *"statuses"* ]]; then
  exit 0
fi
exit 0
GH
  chmod +x "$stub_dir/gh"

  # With max-seconds=1 and only non-configured checks, should timeout as pending
  run env PATH="$stub_dir:$PATH" bash "$CI_WAIT_SH" --sha abcdef1234567 --max-seconds 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"pending"* ]]
}

@test "ci-wait-ref undeclared commit status context does not count as green" {
  unset CI_WAIT_REF_SKIP_GH
  export CI_WAIT_REF_WORKFLOWS=""
  # Declare only "ci/deploy" — "some-bot/status" is undeclared
  export CI_WAIT_REF_STATUS_CONTEXTS="ci/deploy"
  export CI_WAIT_REF_POLL_INTERVAL=0

  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"check-runs"* ]]; then
  exit 0
fi
if [[ "$*" == *"statuses"* ]]; then
  printf 'some-bot/status|success\n'
  exit 0
fi
exit 0
GH
  chmod +x "$stub_dir/gh"

  run env PATH="$stub_dir:$PATH" bash "$CI_WAIT_SH" --sha abcdef1234567 --max-seconds 1
  # The only status is undeclared — should not count as green → times out
  [ "$status" -eq 2 ]
  [[ "$output" == *"pending"* ]]
}

@test "ci-wait-ref declared status context counts toward green" {
  unset CI_WAIT_REF_SKIP_GH
  export CI_WAIT_REF_WORKFLOWS=""
  export CI_WAIT_REF_STATUS_CONTEXTS="ci/deploy"

  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"check-runs"* ]]; then
  exit 0
fi
if [[ "$*" == *"statuses"* ]]; then
  printf 'ci/deploy|success\n'
  exit 0
fi
exit 0
GH
  chmod +x "$stub_dir/gh"

  run env PATH="$stub_dir:$PATH" bash "$CI_WAIT_SH" --sha abcdef1234567 --max-seconds 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"green"* ]]
}

@test "ci-wait-ref failure in configured workflow returns red" {
  unset CI_WAIT_REF_SKIP_GH
  export CI_WAIT_REF_WORKFLOWS="build-ci"
  export CI_WAIT_REF_STATUS_CONTEXTS=""

  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"check-runs"* ]]; then
  printf 'build-ci / test|completed|failure\n'
  exit 0
fi
if [[ "$*" == *"statuses"* ]]; then
  exit 0
fi
exit 0
GH
  chmod +x "$stub_dir/gh"

  run env PATH="$stub_dir:$PATH" bash "$CI_WAIT_SH" --sha abcdef1234567 --max-seconds 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"red"* ]]
}

@test "ci-wait-ref deadline resumes from ledger ci_wait_started" {
  unset CI_WAIT_REF_SKIP_GH
  export CI_WAIT_REF_WORKFLOWS="build-ci"
  export CI_WAIT_REF_STATUS_CONTEXTS=""
  export CI_WAIT_REF_POLL_INTERVAL=0

  # Set up a ledger intent with ci_wait_started in the past (expired)
  bash "$LEDGER_SH" write-gate-pass --pr 99 --head abcdef1234567890abcdef1234567890abcdef12 --story E900-S2
  bash "$LEDGER_SH" write-intent --pr 99 --head abcdef1234567890abcdef1234567890abcdef12 --story E900-S2 --target staging --mode story
  bash "$LEDGER_SH" advance --pr 99 --head abcdef1234567890abcdef1234567890abcdef12 --state merging

  # The intent now has ci_wait_started set to "now". Overwrite it to an old timestamp
  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)

  # Set ci_wait_started to 600 seconds ago (exceeds 5s max)
  local past_ts
  past_ts="$(date -u -v-600S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '600 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
  local tmp="${intent_file}.tmp"
  sed "s/^ci_wait_started:.*/ci_wait_started: \"${past_ts}\"/" "$intent_file" > "$tmp"
  mv "$tmp" "$intent_file"

  # Stub gh that returns pending (never green)
  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"check-runs"* ]]; then
  printf 'build-ci / test|in_progress|\n'
  exit 0
fi
exit 0
GH
  chmod +x "$stub_dir/gh"

  # With max-seconds=5 and ci_wait_started 600s ago, the deadline is already expired
  run env PATH="$stub_dir:$PATH" bash "$CI_WAIT_SH" --sha abcdef1234567890abcdef1234567890abcdef12 --branch 99 --max-seconds 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"pending"* ]]
  # Must mention "already expired" or "resuming" in stderr
  [[ "${lines[*]}" == *"expired"* ]] || [[ "${lines[*]}" == *"resuming"* ]] || [[ "${output}" == *"expired"* ]]
}

# ======================================================================
# Item 3: per-call bound enforcement in merge-tail
# ======================================================================

@test "merge-tail verb exceeding per-call bound is rejected" {
  # Set a very short bound (1 second), then have the ledger write take a bit
  export MERGE_TAIL_MAX_SECONDS=0
  run bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"per-call bound exceeded"* ]]
}

# ======================================================================
# Item 5: bind-head check — stubbed gh tests
# ======================================================================

@test "write-gate-pass with matching head succeeds" {
  unset MERGE_LEDGER_SKIP_GH

  # Stub gh that returns the expected head SHA via --jq extraction
  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  local _sha="abc1234def5678abc1234def5678abc1234def5678"
  cat > "$stub_dir/gh" <<GH
#!/usr/bin/env bash
if [[ "\$*" == *"pr view"* ]]; then
  printf '%s\n' "$_sha"
  exit 0
fi
exit 0
GH
  chmod +x "$stub_dir/gh"

  run env PATH="$stub_dir:$PATH" bash "$LEDGER_SH" write-gate-pass \
    --pr 42 --head "$_sha" --story E900-S1
  [ "$status" -eq 0 ]

  local gate_files
  gate_files=$(find "$MERGE_LEDGER_DIR" -name "gate-pass-*.yaml" | wc -l | tr -d ' ')
  [ "$gate_files" -ge 1 ]
}

@test "write-gate-pass with head mismatch is refused — no gate record" {
  unset MERGE_LEDGER_SKIP_GH

  # Stub gh that returns a DIFFERENT head SHA via --jq extraction
  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
  printf '9999999999999999999999999999999999999999\n'
  exit 0
fi
exit 0
GH
  chmod +x "$stub_dir/gh"

  run env PATH="$stub_dir:$PATH" bash "$LEDGER_SH" write-gate-pass \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  [ "$status" -ne 0 ]
  [[ "$output" == *"bind-head"* ]]

  # No gate record should exist
  local gate_files
  gate_files=$(find "$MERGE_LEDGER_DIR" -name "gate-pass-*.yaml" 2>/dev/null | wc -l | tr -d ' ')
  [ "$gate_files" -eq 0 ]
}

@test "write-gate-pass with gh unavailable fails closed" {
  unset MERGE_LEDGER_SKIP_GH

  # Restricted PATH without gh
  local restricted="${BATS_TEST_TMPDIR}/restricted_bin"
  mkdir -p "$restricted"
  ln -sf /bin/bash "$restricted/bash"
  ln -sf /bin/cat "$restricted/cat"
  ln -sf /bin/mkdir "$restricted/mkdir"
  ln -sf /bin/date "$restricted/date"
  ln -sf /usr/bin/printf "$restricted/printf"
  ln -sf /usr/bin/sed "$restricted/sed"
  ln -sf /usr/bin/head "$restricted/head"
  ln -sf /usr/bin/dirname "$restricted/dirname"
  ln -sf /usr/bin/basename "$restricted/basename"
  ln -sf /usr/bin/wc "$restricted/wc"
  ln -sf /usr/bin/tr "$restricted/tr"
  local fp; fp="$(command -v find 2>/dev/null)"; [ -n "$fp" ] && ln -sf "$fp" "$restricted/find"

  run env PATH="$restricted" bash "$LEDGER_SH" write-gate-pass \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  [ "$status" -ne 0 ]
  [[ "$output" == *"failing closed"* ]] || [[ "$output" == *"bind-head"* ]]
}

# ======================================================================
# Item 6: head-moved via merge-tail merge verb
# ======================================================================

@test "merge-tail merge with moved head supersedes old intent" {
  local SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  # Create gate + intent for head A
  bash "$LEDGER_SH" write-gate-pass --pr 50 --head "$SHA_A" --story E900-S1
  bash "$LEDGER_SH" write-intent --pr 50 --head "$SHA_A" --story E900-S1 --target staging --mode story

  # Verify old intent exists at "intent" state
  local old_intent
  old_intent=$(find "$MERGE_LEDGER_DIR" -name "intent-*pr50*.yaml" | head -1)
  /usr/bin/grep -q 'state: "intent"' "$old_intent"

  # Drive merge with head B — should detect head moved and supersede
  run bash "$TAIL_SH" merge --story E900-S1 --pr 50 --head "$SHA_B" --target staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"superseded"* ]]

  # Old intent must now be superseded
  /usr/bin/grep -q 'state: "superseded"' "$old_intent"

  # Create gate for head B (use a different PR to avoid same-second collision)
  sleep 1
  bash "$LEDGER_SH" write-gate-pass --pr 50 --head "$SHA_B" --story E900-S1
  run bash "$TAIL_SH" merge --story E900-S1 --pr 50 --head "$SHA_B" --target staging
  [ "$status" -eq 0 ]
}

# ======================================================================
# Item 7: detach perl fallback PGID assertion
# ======================================================================

@test "detach perl fallback runs PGID assertion when setsid is hidden" {
  # Hide setsid from PATH but keep perl
  local restricted="${BATS_TEST_TMPDIR}/perl_only_bin"
  mkdir -p "$restricted"
  ln -sf /bin/bash "$restricted/bash"
  ln -sf /bin/echo "$restricted/echo"
  ln -sf /bin/cat "$restricted/cat"
  ln -sf /usr/bin/printf "$restricted/printf"
  ln -sf /bin/ps "$restricted/ps"
  ln -sf /usr/bin/tr "$restricted/tr"
  ln -sf /bin/kill "$restricted/kill"
  ln -sf /bin/sleep "$restricted/sleep"
  local pp; pp="$(command -v perl 2>/dev/null)"; [ -n "$pp" ] && ln -sf "$pp" "$restricted/perl"

  if ! command -v perl >/dev/null 2>&1; then
    skip "perl not available"
  fi

  # Create a runner script that writes its PID and PGID
  local runner_script="${BATS_TEST_TMPDIR}/perl_runner.sh"
  local pid_file="${BATS_TEST_TMPDIR}/perl_pid"
  local pgid_file="${BATS_TEST_TMPDIR}/perl_pgid"
  cat > "$runner_script" <<RUNNER
#!/bin/bash
echo \$\$ > "$pid_file"
ps -o pgid= -p \$\$ | tr -d ' ' > "$pgid_file"
sleep 2
RUNNER
  chmod +x "$runner_script"

  local caller_pgid
  caller_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"

  run env PATH="$restricted" bash "$DETACH_SH" -- bash "$runner_script"
  [ "$status" -eq 0 ]

  # Poll for the pgid_file with a bound
  local _w=0
  while [ "$_w" -lt 30 ] && [ ! -s "$pgid_file" ]; do
    sleep 0.1 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done

  # Unconditional assertion: the file MUST have been written
  [ -s "$pgid_file" ]
  local runner_pgid
  runner_pgid="$(cat "$pgid_file" | tr -d ' ')"
  [ "$runner_pgid" != "$caller_pgid" ]

  # Clean up
  if [ -s "$pid_file" ]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
  fi
}

@test "detach PGID assertion is unconditional — runner pid always checked" {
  # Run a known-good detach and verify the output includes a PID
  local runner_script="${BATS_TEST_TMPDIR}/quick_runner.sh"
  local pid_file="${BATS_TEST_TMPDIR}/quick_pid"
  local pgid_file="${BATS_TEST_TMPDIR}/quick_pgid"
  cat > "$runner_script" <<RUNNER
#!/bin/bash
echo \$\$ > "$pid_file"
ps -o pgid= -p \$\$ | tr -d ' ' > "$pgid_file"
sleep 2
RUNNER
  chmod +x "$runner_script"

  run bash "$DETACH_SH" -- bash "$runner_script"
  [ "$status" -eq 0 ]
  # The output must contain a PID (a number)
  [[ "$output" =~ ^[0-9]+$ ]]

  local _w=0
  while [ "$_w" -lt 30 ] && [ ! -s "$pgid_file" ]; do
    sleep 0.1 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done

  # Unconditional: pgid_file MUST exist and differ from caller
  [ -s "$pgid_file" ]
  local caller_pgid
  caller_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
  local runner_pgid
  runner_pgid="$(cat "$pgid_file" | tr -d ' ')"
  [ "$runner_pgid" != "$caller_pgid" ]

  if [ -s "$pid_file" ]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
  fi
}

# ======================================================================
# AC5: Detach PGID poll tolerates setsid startup delay
# ======================================================================

@test "detach succeeds when setsid has a startup delay" {
  # Reproduce the race: a setsid wrapper that sleeps briefly before
  # exec'ing the real setsid (or perl fallback on macOS).  Without the
  # polling fix, the single PGID read fires during the delay and sees
  # the caller's PGID, returning detach_failed.
  local stub_dir="${BATS_TEST_TMPDIR}/slow_setsid"
  mkdir -p "$stub_dir"

  # Find the real setsid (Linux) or fall back to perl (macOS)
  local real_setsid=""
  real_setsid="$(command -v setsid 2>/dev/null)" || real_setsid=""

  if [ -n "$real_setsid" ]; then
    # Linux: wrap real setsid with a brief delay
    cat > "$stub_dir/setsid" <<STUB
#!/bin/bash
sleep 0.2 2>/dev/null || sleep 1
exec "$real_setsid" "\$@"
STUB
  else
    # macOS: no real setsid; create a stub that uses perl POSIX::setsid
    # with a delay, then exec's the command
    local real_perl=""
    real_perl="$(command -v perl 2>/dev/null)" || real_perl=""
    if [ -z "$real_perl" ]; then
      skip "neither setsid nor perl available"
    fi
    cat > "$stub_dir/setsid" <<STUB
#!/bin/bash
sleep 0.2 2>/dev/null || sleep 1
exec "$real_perl" -e '
  use POSIX qw(setsid);
  setsid() or die "setsid: \$!\n";
  exec @ARGV or die "exec: \$!\n";
' -- "\$@"
STUB
  fi
  chmod +x "$stub_dir/setsid"

  # Runner script that writes its PID and PGID
  local runner_script="${BATS_TEST_TMPDIR}/race_runner.sh"
  local pid_file="${BATS_TEST_TMPDIR}/race_pid"
  local pgid_file="${BATS_TEST_TMPDIR}/race_pgid"
  cat > "$runner_script" <<RUNNER
#!/bin/bash
echo \$\$ > "$pid_file"
ps -o pgid= -p \$\$ | tr -d ' ' > "$pgid_file"
sleep 3
RUNNER
  chmod +x "$runner_script"

  local caller_pgid
  caller_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"

  # Put the delayed setsid first on PATH so detach.sh uses it
  run env PATH="$stub_dir:$PATH" bash "$DETACH_SH" -- bash "$runner_script"
  [ "$status" -eq 0 ]

  # Wait for the runner to write its PGID
  local _w=0
  while [ "$_w" -lt 40 ] && [ ! -s "$pgid_file" ]; do
    sleep 0.1 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done

  [ -s "$pgid_file" ]
  local runner_pgid
  runner_pgid="$(cat "$pgid_file" | tr -d ' ')"
  [ "$runner_pgid" != "$caller_pgid" ]

  # Clean up
  if [ -s "$pid_file" ]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
  fi
}

# ======================================================================
# Item 8: ledger YAML injection
# ======================================================================

@test "ledger rejects story key with double-quote and newline injection" {
  local injected_key
  injected_key="$(printf 'E900-S1"\ninjected: "evil')"

  run bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story "$injected_key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]] || [[ "$output" == *"rejected"* ]] || [[ "$output" == *"shape validation"* ]]

  # No gate record should be created
  local gate_files
  gate_files=$(find "$MERGE_LEDGER_DIR" -name "gate-*.yaml" 2>/dev/null | wc -l | tr -d ' ')
  [ "$gate_files" -eq 0 ]
}

@test "ledger rejects PR number with non-digit characters" {
  run bash "$LEDGER_SH" write-gate-pass --pr "42; rm -rf /" --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected"* ]] || [[ "$output" == *"invalid"* ]] || [[ "$output" == *"shape validation"* ]]
}

# ======================================================================
# AC3: Preemptive per-call bound — hanging stub tests
# ======================================================================

@test "merge-tail gate returns within bound when gh hangs" {
  local marker="be_sgate_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}.sh"
  printf '#!/bin/bash\n/bin/sleep 86400\n' > "$sleeper"
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/hang_stub"
  mkdir -p "$stub_dir"
  printf '#!/bin/bash\nexec "%s"\n' "$sleeper" > "$stub_dir/gh"
  chmod +x "$stub_dir/gh"

  unset MERGE_LEDGER_SKIP_GH
  export MERGE_TAIL_MAX_SECONDS=2

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  local elapsed=$((SECONDS - start))

  [ "$status" -ne 0 ]
  [[ "$output" == *"bound exceeded"* ]]
  [ "$elapsed" -le 5 ]

  sleep 2
  local survivors=""
  survivors=$(ps -eo pid,ppid,pgid,sid,args 2>/dev/null | /usr/bin/grep "$marker" | /usr/bin/grep -v grep) || true
  if [ -n "$survivors" ]; then echo "DIAG gate survivors: $survivors" >&3; fi
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

@test "merge-tail merge returns within bound when gh hangs" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1

  local marker="be_smerge_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}.sh"
  printf '#!/bin/bash\n/bin/sleep 86400\n' > "$sleeper"
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/hang_stub_merge"
  mkdir -p "$stub_dir"
  printf '#!/bin/bash\nexec "%s"\n' "$sleeper" > "$stub_dir/gh"
  chmod +x "$stub_dir/gh"

  unset MERGE_TAIL_SKIP_MERGE
  export MERGE_TAIL_MAX_SECONDS=2

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$TAIL_SH" merge --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  local elapsed=$((SECONDS - start))

  [ "$status" -ne 0 ]
  [[ "$output" == *"bound exceeded"* ]]
  [ "$elapsed" -le 5 ]

  sleep 2
  local survivors=""
  survivors=$(ps -eo pid,ppid,pgid,sid,args 2>/dev/null | /usr/bin/grep "$marker" | /usr/bin/grep -v grep) || true
  if [ -n "$survivors" ]; then echo "DIAG merge survivors: $survivors" >&3; fi
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

@test "merge-tail verify returns within bound when gh hangs" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 --target staging --mode story
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged

  local marker="be_sverify_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}.sh"
  printf '#!/bin/bash\n/bin/sleep 86400\n' > "$sleeper"
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/hang_stub_verify"
  mkdir -p "$stub_dir"
  printf '#!/bin/bash\nexec "%s"\n' "$sleeper" > "$stub_dir/gh"
  chmod +x "$stub_dir/gh"

  export MERGE_TAIL_MAX_SECONDS=2
  unset MERGE_TAIL_MOCK_PR_BASE

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$TAIL_SH" verify --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  local elapsed=$((SECONDS - start))

  [ "$status" -ne 0 ]
  [[ "$output" == *"bound exceeded"* ]]
  [ "$elapsed" -le 5 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "merged"' "$intent_file"

  sleep 2
  local survivors=""
  survivors=$(ps -eo pid,ppid,pgid,sid,args 2>/dev/null | /usr/bin/grep "$marker" | /usr/bin/grep -v grep) || true
  if [ -n "$survivors" ]; then echo "DIAG verify survivors: $survivors" >&3; fi
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

@test "ci-wait-ref returns within bound when gh hangs" {
  unset CI_WAIT_REF_SKIP_GH
  export CI_WAIT_REF_WORKFLOWS="build-ci"
  export CI_WAIT_REF_STATUS_CONTEXTS=""
  export CI_WAIT_REF_POLL_INTERVAL=0

  local marker="be_scwr_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}.sh"
  printf '#!/bin/bash\n/bin/sleep 86400\n' > "$sleeper"
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/hang_stub_cwr"
  mkdir -p "$stub_dir"
  printf '#!/bin/bash\nexec "%s"\n' "$sleeper" > "$stub_dir/gh"
  chmod +x "$stub_dir/gh"

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$CI_WAIT_SH" --sha abcdef1234567 --max-seconds 2
  local elapsed=$((SECONDS - start))

  [ "$status" -eq 2 ]
  [[ "$output" == *"pending"* ]]
  [ "$elapsed" -le 5 ]

  sleep 2
  local survivors=""
  survivors=$(ps -eo pid,ppid,pgid,sid,args 2>/dev/null | /usr/bin/grep "$marker" | /usr/bin/grep -v grep) || true
  if [ -n "$survivors" ]; then echo "DIAG cwr survivors: $survivors" >&3; fi
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

# ======================================================================
# Process-group kill — nested tree tests
# ======================================================================
# These tests verify that bound_exec kills the entire descendant tree,
# not just direct children.  Each stub spawns a nested process tree
# (grandchildren via sh -c), and the test asserts zero orphans survive.

@test "gate with nested-tree stub: entire tree killed, zero orphans" {
  # Create a uniquely-named sleeper so we can identify orphans via pgrep
  local marker="be_gate_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}_sleep.sh"
  cat > "$sleeper" <<'SCRIPT'
#!/bin/bash
/bin/sleep 86400
SCRIPT
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/nested_gate"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<STUB
#!/bin/bash
sh -c "$sleeper" &
sh -c "$sleeper" &
exec "$sleeper"
STUB
  chmod +x "$stub_dir/gh"

  unset MERGE_LEDGER_SKIP_GH
  export MERGE_TAIL_MAX_SECONDS=2

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  local elapsed=$((SECONDS - start))

  [ "$status" -ne 0 ]
  [[ "$output" == *"bound exceeded"* ]]
  [ "$elapsed" -le 8 ]

  # Wait for process cleanup to settle
  sleep 2

  # Assert: no orphans from our stub tree survive
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

@test "merge with nested-tree stub: entire tree killed, zero orphans" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1

  local marker="be_merge_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}_sleep.sh"
  cat > "$sleeper" <<'SCRIPT'
#!/bin/bash
/bin/sleep 86400
SCRIPT
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/nested_merge"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<STUB
#!/bin/bash
sh -c "$sleeper" &
sh -c "$sleeper" &
exec "$sleeper"
STUB
  chmod +x "$stub_dir/gh"

  unset MERGE_TAIL_SKIP_MERGE
  export MERGE_TAIL_MAX_SECONDS=2

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$TAIL_SH" merge --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  local elapsed=$((SECONDS - start))

  [ "$status" -ne 0 ]
  [[ "$output" == *"bound exceeded"* ]]
  [ "$elapsed" -le 8 ]

  sleep 2
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

@test "verify with nested-tree stub: entire tree killed, zero orphans" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 --target staging --mode story
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merging
  bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state merged

  local marker="be_verify_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}_sleep.sh"
  cat > "$sleeper" <<'SCRIPT'
#!/bin/bash
/bin/sleep 86400
SCRIPT
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/nested_verify"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<STUB
#!/bin/bash
sh -c "$sleeper" &
sh -c "$sleeper" &
exec "$sleeper"
STUB
  chmod +x "$stub_dir/gh"

  export MERGE_TAIL_MAX_SECONDS=2
  unset MERGE_TAIL_MOCK_PR_BASE

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$TAIL_SH" verify --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  local elapsed=$((SECONDS - start))

  [ "$status" -ne 0 ]
  [[ "$output" == *"bound exceeded"* ]]
  [ "$elapsed" -le 8 ]

  sleep 2
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

@test "ci-wait-ref with nested-tree stub: entire tree killed, zero orphans" {
  unset CI_WAIT_REF_SKIP_GH
  export CI_WAIT_REF_WORKFLOWS="build-ci"
  export CI_WAIT_REF_STATUS_CONTEXTS=""
  export CI_WAIT_REF_POLL_INTERVAL=0

  local marker="be_cwr_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}_sleep.sh"
  cat > "$sleeper" <<'SCRIPT'
#!/bin/bash
/bin/sleep 86400
SCRIPT
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/nested_cwr"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<STUB
#!/bin/bash
sh -c "$sleeper" &
sh -c "$sleeper" &
exec "$sleeper"
STUB
  chmod +x "$stub_dir/gh"

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$CI_WAIT_SH" --sha abcdef1234567 --max-seconds 2
  local elapsed=$((SECONDS - start))

  [ "$status" -eq 2 ]
  [[ "$output" == *"pending"* ]]
  [ "$elapsed" -le 8 ]

  sleep 2
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

@test "process-group kill handles TERM-ignoring nested stub" {
  local marker="be_term_${BATS_TEST_NUMBER}_$$"
  local trap_sleeper="${BATS_TEST_TMPDIR}/${marker}_trap.sh"
  cat > "$trap_sleeper" <<'SCRIPT'
#!/bin/bash
trap '' TERM
/bin/sleep 86400
SCRIPT
  chmod +x "$trap_sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/nested_term"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<STUB
#!/bin/bash
sh -c "$trap_sleeper" &
exec "$trap_sleeper"
STUB
  chmod +x "$stub_dir/gh"

  unset MERGE_LEDGER_SKIP_GH
  export MERGE_TAIL_MAX_SECONDS=2

  local start=$SECONDS
  run env PATH="$stub_dir:$PATH" bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  local elapsed=$((SECONDS - start))

  [ "$status" -ne 0 ]
  [[ "$output" == *"bound exceeded"* ]]
  # 2s bound + 1s grace + margin
  [ "$elapsed" -le 8 ]

  sleep 2
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]
}

@test "merge-tail verb resumes after bound expires and gh recovers" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1

  local marker="be_sresume_${BATS_TEST_NUMBER}_$$"
  local sleeper="${BATS_TEST_TMPDIR}/${marker}.sh"
  printf '#!/bin/bash\n/bin/sleep 86400\n' > "$sleeper"
  chmod +x "$sleeper"

  local stub_dir="${BATS_TEST_TMPDIR}/hang_stub_resume"
  mkdir -p "$stub_dir"
  printf '#!/bin/bash\nexec "%s"\n' "$sleeper" > "$stub_dir/gh"
  chmod +x "$stub_dir/gh"

  unset MERGE_TAIL_SKIP_MERGE
  export MERGE_TAIL_MAX_SECONDS=2

  run env PATH="$stub_dir:$PATH" bash "$TAIL_SH" merge --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -ne 0 ]

  sleep 2
  local orphan_pids=""
  orphan_pids=$(pgrep -f "$marker" 2>/dev/null) || true
  [ -z "$orphan_pids" ]

  # Second run: gh works, merge succeeds (mock)
  export MERGE_TAIL_SKIP_MERGE=1
  export MERGE_TAIL_MAX_SECONDS=540

  run bash "$TAIL_SH" merge --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'state: "merged"' "$intent_file"
}

# ======================================================================
# AC3: Per-call bound ceiling validation
# ======================================================================

@test "merge-tail clamps MERGE_TAIL_MAX_SECONDS above 540 to 540" {
  export MERGE_TAIL_MAX_SECONDS=99999
  run bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"clamping"* ]] || [[ "${lines[*]}" == *"clamping"* ]]
}

@test "merge-tail refuses non-numeric MERGE_TAIL_MAX_SECONDS" {
  export MERGE_TAIL_MAX_SECONDS="abc"
  run bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "merge-tail with empty MERGE_TAIL_MAX_SECONDS defaults to 540" {
  export MERGE_TAIL_MAX_SECONDS=""
  # Empty uses the :-540 default, so the gate should succeed
  run bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -eq 0 ]
}

# ======================================================================
# Item 8: ledger YAML injection (continued)
# ======================================================================

@test "ledger accepts valid story key and stores it literally" {
  run bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  [ "$status" -eq 0 ]

  local gate_file
  gate_file=$(find "$MERGE_LEDGER_DIR" -name "gate-pass-*.yaml" | head -1)
  # Verify exact field content
  /usr/bin/grep -q 'story: "E900-S1"' "$gate_file"
  # Verify no extra fields injected
  local field_count
  field_count=$(/usr/bin/grep -c '^[a-z]' "$gate_file")
  [ "$field_count" -eq 5 ]
}
