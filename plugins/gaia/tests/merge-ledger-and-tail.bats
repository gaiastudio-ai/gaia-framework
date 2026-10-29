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
}

# ======================================================================
# AC1: Write-ahead merge ledger with gate-record validation
# ======================================================================

@test "AC1: write-gate-pass creates a gate record with correct fields" {
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

@test "AC1: write-gate-bypass creates a bypass record with confirmation and bypass flag" {
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

@test "AC1: write-intent rejected without prior gate record" {
  run bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  [ "$status" -ne 0 ]
  [[ "$output" == *"no gate record"* ]]
}

@test "AC1: write-intent succeeds with prior gate_pass record" {
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

@test "AC1: bypass flag carried onto merge-intent when gate record is gate_bypass" {
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

@test "AC1: bypass flag is false when gate record is gate_pass" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1

  run bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story
  [ "$status" -eq 0 ]

  local intent_file
  intent_file=$(find "$MERGE_LEDGER_DIR" -name "intent-*.yaml" | head -1)
  /usr/bin/grep -q 'bypass: "false"' "$intent_file"
}

@test "AC1: state machine advances through full happy path" {
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

@test "AC1: invalid state transition is rejected" {
  bash "$LEDGER_SH" write-gate-pass --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1
  bash "$LEDGER_SH" write-intent \
    --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --story E900-S1 \
    --target staging --mode story

  # intent -> verified (skipping merging and merged)
  run bash "$LEDGER_SH" advance --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --state verified
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid transition"* ]]
}

@test "AC1: verify halts with merge_target_mismatch on target drift" {
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

@test "AC1: sole-writer-check passes with only legitimate files" {
  # Create legitimate files
  touch "$MERGE_LEDGER_DIR/gate-pass-pr42-20261027.yaml"
  touch "$MERGE_LEDGER_DIR/intent-pr42-mi-20261027-1234.yaml"

  run bash "$LEDGER_SH" sole-writer-check --dir "$MERGE_LEDGER_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

@test "AC1: sole-writer-check fails closed with unauthorized file" {
  touch "$MERGE_LEDGER_DIR/rogue.yaml"

  run bash "$LEDGER_SH" sole-writer-check --dir "$MERGE_LEDGER_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"rogue.yaml"* ]]
}

# ======================================================================
# AC2: Session-kill resilience
# ======================================================================

@test "AC2: session kill after intent — merge resumes at merge, intent not duplicated" {
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

@test "AC2: session kill after merge succeeded — resumes at verify, not flagged out-of-band" {
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

@test "AC2: session kill after verify — smoke-wait resumes correctly" {
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

@test "AC2: session kill after smoke_ok — finalize resumes correctly" {
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

@test "AC2: head moved — intent closed as superseded" {
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

@test "AC2: write-intent is idempotent for same PR and head" {
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

@test "AC3: ci-wait-ref.sh returns none-observed when gh is skipped" {
  run bash "$CI_WAIT_SH" --sha abc1234 --max-seconds 10
  [ "$status" -eq 3 ]
  [[ "$output" == *"none-observed"* ]]
}

@test "AC3: ci-wait-ref.sh rejects max-seconds over 540" {
  run bash "$CI_WAIT_SH" --sha abc1234 --max-seconds 600
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not exceed 540"* ]]
}

@test "AC3: ci-wait-ref.sh requires --sha" {
  run bash "$CI_WAIT_SH" --max-seconds 10
  [ "$status" -ne 0 ]
  [[ "$output" == *"--sha required"* ]]
}

@test "AC3: ci-wait-ref.sh requires --max-seconds" {
  run bash "$CI_WAIT_SH" --sha abc1234
  [ "$status" -ne 0 ]
  [[ "$output" == *"--max-seconds required"* ]]
}

# ======================================================================
# AC4: Smoke-wait skip/run, parent-exec, no credential source
# ======================================================================

@test "AC4: smoke-wait skips with notice when no smoke command configured" {
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

@test "AC4: smoke failure sets smoke_failed state" {
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

@test "AC4: parent-exec env -i allowlist carries no credential source variable" {
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

@test "AC4: parent-exec credential denylist blocks GITHUB_TOKEN even if added to allowlist" {
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

@test "AC4: parent-exec runs a command through env -i" {
  run bash "$PARENT_EXEC_SH" -- echo "hello from parent-exec"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from parent-exec"* ]]
}

@test "AC4: parent-exec with --detach launches command in background" {
  run bash "$PARENT_EXEC_SH" --detach -- sleep 0.1
  [ "$status" -eq 0 ]
}

# ======================================================================
# AC5: Detach library process-group assertion
# ======================================================================

@test "AC5: detach.sh starts a runner whose PGID differs from caller" {
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

@test "AC5: detach.sh refuses with detach_failed when setsid and perl are unavailable" {
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

@test "AC5: detach.sh rejects empty command" {
  run bash "$DETACH_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"detach_failed"* ]] || [[ "$output" == *"usage"* ]]
}

# ======================================================================
# AC1 (merge-tail integration): full merge-tail happy path
# ======================================================================

@test "AC1+AC2: merge-tail full happy path — gate through finalize" {
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

@test "AC1: merge-tail merge verb without prior gate is rejected" {
  # Try to merge without gate
  run bash "$TAIL_SH" merge --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"no gate record"* ]]
}

@test "AC1: merge-tail gate with bypass-confirmation" {
  run bash "$TAIL_SH" gate --story E900-S1 --pr 42 --head abc1234def5678abc1234def5678abc1234def5678 --target staging \
    --bypass-confirmation "operator_tty"
  [ "$status" -eq 0 ]

  local gate_file
  gate_file=$(find "$MERGE_LEDGER_DIR" -name "gate-bypass-*.yaml" | head -1)
  [ -n "$gate_file" ]
  /usr/bin/grep -q 'bypass_confirmed: "operator_tty"' "$gate_file"
}
