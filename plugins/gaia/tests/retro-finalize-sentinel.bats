#!/usr/bin/env bats
# retro-finalize-sentinel.bats — E92-S2 fail-closed Val-sidecar sentinel for /gaia-retro.
#
# Covers TC-OEXP-4 (mirror of TC-OEXP-3 for /gaia-retro/scripts/finalize.sh).

load 'test_helper.bash'

setup() {
  common_setup
  FINALIZE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts" && pwd)/finalize.sh"
  export FINALIZE

  MEM_ROOT="$TEST_TMP/_memory"
  mkdir -p "$MEM_ROOT/validator-sidecar" "$MEM_ROOT/checkpoints"
  export MEM_ROOT
  export CHECKPOINT_PATH="$MEM_ROOT/checkpoints"
}

teardown() {
  common_teardown
}

stage_run_started() {
  # F-21 (AF-2026-05-26-1): finalize.sh now checks the retrospective.yaml
  # marker (the extension checkpoint.sh actually writes), not .json. Seed the
  # .yaml form so the run-started precondition is satisfied.
  printf 'workflow: retrospective\nts: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$CHECKPOINT_PATH/retrospective.yaml"
}

write_sidecar_newer() {
  sleep 1
  printf '### [2026-05-15] Retrospective sprint-46\n' \
    >> "$MEM_ROOT/validator-sidecar/decision-log.md"
}

# ---------------- Test A: in-window sidecar -> exit 0 ----------------
@test "TC-OEXP-4 Test A: in-window Val sidecar entry passes retro finalize precondition" {
  stage_run_started
  write_sidecar_newer
  GAIA_FINALIZE_SENTINEL_REQUIRED=1 CLAUDE_PROJECT_ROOT="$TEST_TMP" \
    run "$FINALIZE"
  [ "$status" -eq 0 ]
}

# ---------------- Test B: missing sidecar -> non-zero + canonical error ----------------
@test "TC-OEXP-4 Test B: missing Val sidecar entry fails retro finalize with canonical error" {
  stage_run_started
  GAIA_FINALIZE_SENTINEL_REQUIRED=1 CLAUDE_PROJECT_ROOT="$TEST_TMP" \
    run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Val sidecar write missing"* ]]
  [[ "$output" == *"Step 7 must be invoked before finalize"* ]]
}

# ---------------- Test C: out-of-window sidecar -> non-zero ----------------
@test "TC-OEXP-4 Test C: out-of-window Val sidecar entry fails retro finalize" {
  printf '### [2026-05-14] Prior retro entry\n' \
    >> "$MEM_ROOT/validator-sidecar/decision-log.md"
  sleep 1
  stage_run_started
  GAIA_FINALIZE_SENTINEL_REQUIRED=1 CLAUDE_PROJECT_ROOT="$TEST_TMP" \
    run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Val sidecar write missing"* ]]
}

# ---------------- Backward-compat ----------------
@test "TC-OEXP-4 backward-compat: GAIA_FINALIZE_SENTINEL_REQUIRED unset preserves legacy behavior" {
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}
