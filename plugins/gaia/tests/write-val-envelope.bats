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

# E55-S13 D4 (TC-DSF-4): when CHECKPOINT_PATH env-var is unset, the helper
# MUST resolve the checkpoint dir via resolve-config.sh `checkpoint_path`,
# combined with `project_root`, instead of falling back to the CWD-relative
# `_memory/checkpoints` literal. Without this, sentinels land in whatever
# directory the orchestrator happened to be running from when Val was
# dispatched, and `assert_agent_envelope` (which itself runs from project
# root) cannot find them.
@test "TC-DSF-4: CHECKPOINT_PATH unset -> resolves via resolve-config.sh, sentinel lands at project-root path" {
  # Arrange: per-test "project root" with a config/project-config.yaml.
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/config" "$proj/_memory/checkpoints"
  cat > "$proj/config/project-config.yaml" <<YAML
schema_version: "2.0.0"
config_phase: full
project_name: test
project_root: $proj
project_path: gaia-public
memory_path: _memory
checkpoint_path: _memory/checkpoints
installed_path: ~/.claude/plugins/cache/gaia
framework_version: "1.151.0"
date: "2026-05-13"
YAML

  local artifact="/tmp/d4-fixture-artifact"
  local envelope='{"agent":"val","persona_sig":"val-dev-d4test","timestamp":"2026-05-13T18:00:00Z","artifact_path":"'"$artifact"'","verdict":"PASSED"}'

  # Act: invoke from a deep CWD with CHECKPOINT_PATH UNSET. The helper MUST
  # resolve the project-root checkpoint dir via the config (not "$PWD/_memory/checkpoints").
  local deep_cwd="$TEST_TMP/somewhere/else"
  mkdir -p "$deep_cwd"
  ( cd "$deep_cwd" && unset CHECKPOINT_PATH && \
    GAIA_SHARED_CONFIG="$proj/config/project-config.yaml" "$HELPER" --envelope "$envelope" ) > "$TEST_TMP/d4-out.txt" 2>&1
  [ "$?" -eq 0 ] || { cat "$TEST_TMP/d4-out.txt"; false; }

  # Assert: sentinel landed at the project-root path, not under deep_cwd.
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  [ -f "$proj/_memory/checkpoints/val-envelope-${expected_hash}.json" ]
  [ ! -f "$deep_cwd/_memory/checkpoints/val-envelope-${expected_hash}.json" ]
}

# TC-DSF-4b: explicit CHECKPOINT_PATH override MUST still win over the
# config-resolver fallback (preserves test-fixture override semantics).
@test "TC-DSF-4b: CHECKPOINT_PATH env-var override still wins over config resolver" {
  local override_dir="$TEST_TMP/override-checkpoints"
  mkdir -p "$override_dir"
  local artifact="/tmp/d4b-fixture-artifact"
  local envelope='{"agent":"val","persona_sig":"val-dev-d4btest","timestamp":"2026-05-13T18:00:00Z","artifact_path":"'"$artifact"'","verdict":"PASSED"}'
  CHECKPOINT_PATH="$override_dir" run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  [ -f "$override_dir/val-envelope-${expected_hash}.json" ]
}

# ============================================================================
# E87-S8 / AF-2026-06-03-2 / ADR-130 — TC-OSV-1, TC-OSV-2, TC-OSV-5:
# OPTIONAL `original_status` envelope field (additive). NFR-95 golden
# invariant: original_status MUST NOT be added to any required-field set;
# every existing envelope without it MUST write exactly as before.
# ============================================================================

# TC-OSV-1: writer preserves `original_status` when present (pass-through).
@test "TC-OSV-1: writer preserves original_status field when present" {
  local artifact="/tmp/osv1-artifact"
  local envelope='{"agent":"val","persona_sig":"val-dev-osv1","timestamp":"2026-06-03T12:00:00Z","artifact_path":"'"$artifact"'","verdict":"PASSED","original_status":"WARNING"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  local sentinel="$CHECKPOINT_DIR/val-envelope-${expected_hash}.json"
  [ -f "$sentinel" ]
  # The written sentinel must carry original_status verbatim.
  run jq -r '.original_status' "$sentinel"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# TC-OSV-2: writer output unchanged when original_status absent (back-compat).
@test "TC-OSV-2: writer output has no original_status key when input lacks it" {
  local artifact="/tmp/osv2-artifact"
  local envelope='{"agent":"val","persona_sig":"val-dev-osv2","timestamp":"2026-06-03T12:00:00Z","artifact_path":"'"$artifact"'","verdict":"PASSED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  local sentinel="$CHECKPOINT_DIR/val-envelope-${expected_hash}.json"
  [ -f "$sentinel" ]
  # original_status must be ABSENT (jq `has` returns false).
  run jq -e 'has("original_status")' "$sentinel"
  [ "$status" -ne 0 ]
}

# TC-OSV-5 (writer half): NFR-95 — original_status is NOT a required field.
# An envelope MISSING it still writes fine (exit 0). This pins the invariant
# against any future strict-schema regression in the required-key loop.
@test "TC-OSV-5w: NFR-95 — envelope without original_status writes successfully (not required)" {
  local artifact="/tmp/osv5w-artifact"
  local envelope='{"agent":"val","persona_sig":"val-dev-osv5w","timestamp":"2026-06-03T12:00:00Z","artifact_path":"'"$artifact"'","verdict":"FAILED"}'
  CHECKPOINT_PATH="$CHECKPOINT_DIR" run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  # Error stream must NOT complain about a missing original_status field.
  [[ "$output" != *"original_status"* ]]
}
