#!/usr/bin/env bats
# write-val-envelope.bats — E87-S7 / ADR-105
#
# Tests the orchestrator-side sentinel writer helper introduced by the
# Val sentinel-write writer shift (E87-S7, ADR-105). The helper replaces
# the prior E87-S2 contract where Val wrote the sentinel from inside its
# sub-agent context (which the Claude Code substrate's content-integrity
# guard false-flagged as forgery — AI-2026-05-13-13 incident).
#
# Contract: takes a parsed sentinel_envelope JSON object from Val's
# ADR-037 return, validates required fields, computes the sentinel path
# from sha256(artifact_path), and writes atomically via tempfile + mv.
#
# Coverage:
#   TC-WVE-1 — valid envelope writes sentinel + emits correct path
#   TC-WVE-2 — missing required field (agent) rejected
#   TC-WVE-3 — missing required field (persona_sig) rejected
#   TC-WVE-4 — wrong agent value rejected
#   TC-WVE-5 — malformed JSON rejected
#   TC-WVE-6 — hash path correctness (sha256 first 16 hex)
#   TC-WVE-7 — atomic write (sibling tempfile + mv)
#   TC-WVE-8 — overwrites existing sentinel for same artifact_path

load 'test_helper.bash'

setup() {
  common_setup
  HELPER="$SCRIPTS_DIR/lib/write-val-envelope.sh"
  CHECKPOINT_DIR="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_DIR"
}

teardown() { common_teardown; }

@test "TC-WVE-1: valid envelope writes sentinel + prints sentinel path on stdout" {
  local artifact="/tmp/some-artifact"
  local envelope='{"agent":"val","persona_sig":"val-dev-deadbeef00000000","timestamp":"2026-05-13T17:52:45Z","artifact_path":"'"$artifact"'","verdict":"PASSED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  # Expected hash for artifact_path
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  local expected_path="$CHECKPOINT_DIR/val-envelope-${expected_hash}.json"
  [[ "$output" == *"$expected_path"* ]]
  [ -f "$expected_path" ]
}

@test "TC-WVE-2: missing 'agent' field rejected with non-zero exit" {
  local envelope='{"persona_sig":"val-dev-deadbeef00000000","timestamp":"2026-05-13T17:52:45Z","artifact_path":"/tmp/x","verdict":"PASSED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent"* ]]
}

@test "TC-WVE-3: missing 'persona_sig' field rejected with non-zero exit" {
  local envelope='{"agent":"val","timestamp":"2026-05-13T17:52:45Z","artifact_path":"/tmp/x","verdict":"PASSED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"persona_sig"* ]]
}

@test "TC-WVE-4: agent value != 'val' is rejected" {
  local envelope='{"agent":"architect","persona_sig":"val-dev-deadbeef00000000","timestamp":"2026-05-13T17:52:45Z","artifact_path":"/tmp/x","verdict":"PASSED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent"* ]]
}

@test "TC-WVE-5: malformed JSON envelope rejected" {
  local envelope='{not valid json'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -ne 0 ]
}

@test "TC-WVE-6: hash path uses sha256(artifact_path) first 16 hex" {
  local artifact="AF-2026-05-13-1"
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  local envelope='{"agent":"val","persona_sig":"val-dev-x","timestamp":"2026-05-13T17:52:45Z","artifact_path":"'"$artifact"'","verdict":"PASSED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_DIR/val-envelope-${expected_hash}.json" ]
}

@test "TC-WVE-7: write is atomic (no .tmp file left behind on success)" {
  local artifact="/tmp/atomic-test"
  local envelope='{"agent":"val","persona_sig":"val-dev-x","timestamp":"2026-05-13T17:52:45Z","artifact_path":"'"$artifact"'","verdict":"PASSED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  # No .tmp files left in the checkpoint dir
  run find "$CHECKPOINT_DIR" -name "*.tmp"
  [ -z "$output" ]
}

@test "TC-WVE-8: re-write for same artifact_path overwrites prior sentinel" {
  local artifact="/tmp/rewrite-test"
  local envelope_v1='{"agent":"val","persona_sig":"val-dev-v1","timestamp":"2026-05-13T17:52:45Z","artifact_path":"'"$artifact"'","verdict":"PASSED"}'
  local envelope_v2='{"agent":"val","persona_sig":"val-dev-v2","timestamp":"2026-05-13T18:00:00Z","artifact_path":"'"$artifact"'","verdict":"FAILED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope_v1"
  [ "$status" -eq 0 ]
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope_v2"
  [ "$status" -eq 0 ]
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  # File contents reflect v2 (most recent write)
  local contents
  contents=$(cat "$CHECKPOINT_DIR/val-envelope-${expected_hash}.json")
  [[ "$contents" == *"val-dev-v2"* ]]
  [[ "$contents" == *"FAILED"* ]]
}

@test "TC-WVE-9: --envelope-stdin reads JSON from stdin" {
  local artifact="/tmp/stdin-test"
  local envelope='{"agent":"val","persona_sig":"val-dev-x","timestamp":"2026-05-13T17:52:45Z","artifact_path":"'"$artifact"'","verdict":"PASSED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run bash -c "printf '%s' '$envelope' | '$HELPER' --envelope-stdin"
  [ "$status" -eq 0 ]
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  [ -f "$CHECKPOINT_DIR/val-envelope-${expected_hash}.json" ]
}

@test "TC-WVE-10: helper script header references ADR-105 (E87-S7 trace)" {
  [ -f "$HELPER" ]
  run head -40 "$HELPER"
  [[ "$output" == *"ADR-105"* ]]
}
