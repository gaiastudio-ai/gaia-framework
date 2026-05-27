#!/usr/bin/env bats
# triage-findings-finalize-sentinel.bats — E92-S2 fail-closed Val-sidecar sentinel.
#
# Covers TC-OEXP-3:
#   Test A: Val sidecar entry written within run window -> finalize exits 0.
#   Test B: No Val sidecar entry -> finalize exits non-zero, canonical error.
#   Test C: Val sidecar entry exists but is OLDER than the run checkpoint
#           -> finalize exits non-zero (out-of-window must not satisfy).

load 'test_helper.bash'

setup() {
  common_setup
  FINALIZE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts" && pwd)/finalize.sh"
  export FINALIZE

  # Isolated .gaia/memory tree per test
  MEM_ROOT="$TEST_TMP/.gaia/memory"
  mkdir -p "$MEM_ROOT/validator-sidecar" "$MEM_ROOT/checkpoints"
  export MEM_ROOT
  export CHECKPOINT_PATH="$MEM_ROOT/checkpoints"
}

teardown() {
  common_teardown
}

# Helper: stage an in-progress triage run by writing the checkpoint marker.
stage_run_started() {
  printf '{"workflow":"triage-findings","ts":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$CHECKPOINT_PATH/triage-findings.json"
}

# Helper: write a Val sidecar entry NEWER than the checkpoint (i.e., within window).
write_sidecar_newer() {
  sleep 1   # ensure mtime is strictly newer
  printf '### [2026-05-15] Triage Findings: 0 items\n\nrecorded.\n' \
    >> "$MEM_ROOT/validator-sidecar/decision-log.md"
}

# Helper: write a Val sidecar entry OLDER than the checkpoint.
write_sidecar_older() {
  printf '### [2026-05-14] Prior triage entry\n' \
    >> "$MEM_ROOT/validator-sidecar/decision-log.md"
  # Now stage the run-started checkpoint AFTER the sidecar so the sidecar is older.
  sleep 1
  stage_run_started
}

# ---------------- Test A: in-window sidecar -> exit 0 ----------------
@test "TC-OEXP-3 Test A: in-window Val sidecar entry passes finalize precondition" {
  stage_run_started
  write_sidecar_newer
  GAIA_FINALIZE_SENTINEL_REQUIRED=1 CLAUDE_PROJECT_ROOT="$TEST_TMP" \
    run "$FINALIZE"
  [ "$status" -eq 0 ]
}

# ---------------- Test B: missing sidecar -> non-zero + canonical error ----------------
@test "TC-OEXP-3 Test B: missing Val sidecar entry fails finalize with canonical error" {
  stage_run_started
  # No sidecar write at all.
  GAIA_FINALIZE_SENTINEL_REQUIRED=1 CLAUDE_PROJECT_ROOT="$TEST_TMP" \
    run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Val sidecar write missing"* ]]
  [[ "$output" == *"Step 7 must be invoked before finalize"* ]]
}

# ---------------- Test C: out-of-window sidecar -> non-zero ----------------
@test "TC-OEXP-3 Test C: out-of-window Val sidecar entry fails finalize" {
  write_sidecar_older
  # write_sidecar_older() stages the checkpoint AFTER the sidecar, so the
  # sidecar's mtime is older than the checkpoint — should fail.
  GAIA_FINALIZE_SENTINEL_REQUIRED=1 CLAUDE_PROJECT_ROOT="$TEST_TMP" \
    run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Val sidecar write missing"* ]]
}

# ---------------- Backward-compat: env var unset -> legacy behavior ----------------
@test "TC-OEXP-3 backward-compat: GAIA_FINALIZE_SENTINEL_REQUIRED unset preserves legacy behavior" {
  # No sentinel marker exported -> finalize must NOT enforce the guard.
  # (Mirror of gaia-add-feature/finalize.sh:77 conditional FEATURE_ID guard.)
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}
