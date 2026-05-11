#!/usr/bin/env bats
# audit-silent-val-bypass.bats — E84-S5 / ADR-093 audit-script coverage.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/audit-silent-val-bypass.sh"
  FAKE_CHECKPOINTS="$TEST_TMP/checkpoints"
  mkdir -p "$FAKE_CHECKPOINTS"
}
teardown() { common_teardown; }

# Helper: write an empty-state YAML (matches the bypass signature).
make_empty_state() {
  local name="$1"
  cat > "$FAKE_CHECKPOINTS/${name}.yaml" <<EOF
workflow: ${name}
step: 4
timestamp: 2026-05-09T11:15:18Z
variables: {}
files_touched: []
EOF
}

# Helper: write a valid Val-PASS YAML.
make_valid_pass() {
  local name="$1"
  cat > "$FAKE_CHECKPOINTS/${name}.yaml" <<EOF
workflow: ${name}
story_key: E40-S1
status: completed
verdict: PASS
final_status: ready-for-dev
files_touched:
  - path: docs/implementation-artifacts/E40-S1.md
    checksum: "sha256:abc"
EOF
}

# Helper: write a valid checkpoint where files_touched is empty but verdict is present.
make_valid_no_files() {
  local name="$1"
  cat > "$FAKE_CHECKPOINTS/${name}.yaml" <<EOF
workflow: ${name}
verdict: WARNING
final_status: review
variables: {}
files_touched: []
EOF
}

# ---- AC1: empty-state files detected ----

@test "AC1: single empty-state checkpoint is flagged" {
  make_empty_state validate-story
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validate-story.yaml"* ]]
  [[ "$output" == *"Empty-state matches: 1"* ]]
}

@test "AC1: multiple empty-state checkpoints all flagged" {
  make_empty_state validate-story
  make_empty_state validate-prd
  make_empty_state add-feature
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Empty-state matches: 3"* ]]
  [[ "$output" == *"validate-story.yaml"* ]]
  [[ "$output" == *"validate-prd.yaml"* ]]
  [[ "$output" == *"add-feature.yaml"* ]]
}

# ---- AC2: valid Val-PASS checkpoints NOT flagged ----

@test "AC2: valid Val-PASS checkpoint NOT flagged (no false positive)" {
  make_valid_pass validate-story-E40-S1
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Empty-state matches: 0"* ]]
  [[ "$output" != *"validate-story-E40-S1.yaml"* ]]
}

@test "AC2: valid checkpoint with verdict but empty files_touched NOT flagged" {
  # Edge case: variables: {} and files_touched: [] but verdict is present.
  # This is NOT the bypass signature — verdict means Val actually returned.
  make_valid_no_files some-skill
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Empty-state matches: 0"* ]]
}

# ---- AC2: mixed scenarios ----

@test "AC2: mixed valid + empty-state - only empty flagged" {
  make_empty_state bypass-1
  make_valid_pass real-pass-1
  make_empty_state bypass-2
  make_valid_no_files verdict-present
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Empty-state matches: 2"* ]]
  [[ "$output" == *"bypass-1.yaml"* ]]
  [[ "$output" == *"bypass-2.yaml"* ]]
  [[ "$output" != *"real-pass-1.yaml"* ]]
  [[ "$output" != *"verdict-present.yaml"* ]]
}

# ---- Edge cases ----

@test "empty checkpoint directory produces zero matches without error" {
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Empty-state matches: 0"* ]]
}

@test "non-existent checkpoint-path exits 2 with diagnostic" {
  run "$SCRIPT" --checkpoint-path "$TEST_TMP/does-not-exist"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "non-YAML files in checkpoint dir are ignored" {
  make_empty_state legit-bypass
  printf 'some text\n' > "$FAKE_CHECKPOINTS/readme.txt"
  printf '{}\n' > "$FAKE_CHECKPOINTS/some.json"
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Empty-state matches: 1"* ]]
  [[ "$output" == *"legit-bypass.yaml"* ]]
  [[ "$output" != *"readme.txt"* ]]
  [[ "$output" != *"some.json"* ]]
}

# ---- Hypothesized skill extraction ----

@test "hypothesized skill is extracted from workflow: field when present" {
  make_empty_state weird-name
  # Override the workflow field to something different.
  cat > "$FAKE_CHECKPOINTS/weird-name.yaml" <<EOF
workflow: gaia-create-story
step: 4
variables: {}
files_touched: []
EOF
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [[ "$output" == *"gaia-create-story"* ]]
}

@test "hypothesized skill falls back to basename when workflow: missing" {
  cat > "$FAKE_CHECKPOINTS/orphan.yaml" <<EOF
step: 4
variables: {}
files_touched: []
EOF
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [[ "$output" == *"orphan"* ]]
}

# ---- --days argument ----

@test "invalid --days exits 2" {
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS" --days "ninety"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--days must be"* ]]
}

@test "--days accepts integer" {
  make_empty_state recent
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS" --days 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"Empty-state matches: 1"* ]]
}

# ---- output format ----

@test "output is well-formed markdown with required columns" {
  make_empty_state validate-story
  run "$SCRIPT" --checkpoint-path "$FAKE_CHECKPOINTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| File Path |"* ]]
  [[ "$output" == *"| mtime (UTC) |"* ]]
  [[ "$output" == *"| Hypothesized Skill |"* ]]
  [[ "$output" == *"| Recommended Action |"* ]]
  [[ "$output" == *"## Summary"* ]]
  [[ "$output" == *"Files scanned"* ]]
}

# ---- usage / help ----

@test "--help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "unknown flag exits 2" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}
