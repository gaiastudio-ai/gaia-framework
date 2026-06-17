#!/usr/bin/env bats
# agent-overlay.bats — unit tests for plugins/gaia/scripts/review-common/agent-overlay.sh (E66-S1, ADR-077)
# Covers TC-RSV2-OVERLAY-01..15 (15 skill variants), TC-RSV2-OVERLAY-STACK-01..07 (7 stacks),
# TC-RSV2-OVERLAY-ERR-01 (unknown skill -> exit 1 + stderr).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/agent-overlay.sh"
}
teardown() { common_teardown; }

# --- helpers ---

assert_json_field() {
  # assert_json_field <output> <field> <expected>
  local output="$1" field="$2" expected="$3"
  printf '%s\n' "$output" | grep -F "\"${field}\":\"${expected}\"" >/dev/null
}

# --- ADR-077 wiring table — 15 skill-name variants (11 logical rows) ---

@test "gaia-review-qa -> vera" {
  run "$SCRIPT" --skill gaia-review-qa
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "vera"
  assert_json_field "$output" "sidecar_path" "_memory/vera-sidecar.md"
}

@test "gaia-review-test -> sable" {
  run "$SCRIPT" --skill gaia-review-test
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "sable"
  assert_json_field "$output" "sidecar_path" "_memory/sable-sidecar.md"
}

@test "gaia-test-automate -> sable" {
  run "$SCRIPT" --skill gaia-test-automate
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "sable"
  assert_json_field "$output" "sidecar_path" "_memory/sable-sidecar.md"
}

@test "gaia-review-security -> zara" {
  run "$SCRIPT" --skill gaia-review-security
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "zara"
  assert_json_field "$output" "sidecar_path" "_memory/zara-sidecar.md"
}

@test "gaia-review-perf -> juno" {
  run "$SCRIPT" --skill gaia-review-perf
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "juno"
  assert_json_field "$output" "sidecar_path" "_memory/juno-sidecar.md"
}

@test "gaia-review-mobile -> talia" {
  run "$SCRIPT" --skill gaia-review-mobile
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "talia"
  assert_json_field "$output" "sidecar_path" "_memory/talia-sidecar.md"
}

@test "gaia-validate-design-a11y -> christy" {
  run "$SCRIPT" --skill gaia-validate-design-a11y
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "christy"
  assert_json_field "$output" "sidecar_path" "_memory/christy-sidecar.md"
}

@test "gaia-test-e2e -> sable" {
  run "$SCRIPT" --skill gaia-test-e2e
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "sable"
}

@test "gaia-test-perf -> sable" {
  run "$SCRIPT" --skill gaia-test-perf
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "sable"
}

@test "gaia-test-dast -> sable" {
  run "$SCRIPT" --skill gaia-test-dast
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "sable"
}

@test "gaia-test-a11y -> sable" {
  run "$SCRIPT" --skill gaia-test-a11y
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "sable"
}

@test "gaia-test-mobile-e2e -> talia" {
  run "$SCRIPT" --skill gaia-test-mobile-e2e
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "talia"
}

@test "gaia-test-device-matrix -> talia" {
  run "$SCRIPT" --skill gaia-test-device-matrix
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "talia"
}

@test "gaia-deploy -> soren" {
  run "$SCRIPT" --skill gaia-deploy
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "soren"
  assert_json_field "$output" "sidecar_path" "_memory/soren-sidecar.md"
}

# E69-S2: gaia-review-a11y is the conditional pre-merge a11y gate.
# Pre-merge a11y review is a UX-design concern -> Christy.
# (Christy already owns gaia-validate-design-a11y; Sable owns post-deploy gaia-test-a11y.)
@test "gaia-review-a11y -> christy" {
  run "$SCRIPT" --skill gaia-review-a11y
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "christy"
  assert_json_field "$output" "sidecar_path" "_memory/christy-sidecar.md"
}

@test "gaia-review-code without --stack -> stack-required diagnostic" {
  # gaia-review-code is stack-conditional. Without --stack, exit 1 with diagnostic.
  run --separate-stderr "$SCRIPT" --skill gaia-review-code
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--stack"* ]] || [[ "$stderr" == *"stack"* ]]
}

# --- per-stack persona resolution (gaia-review-code) ---

@test "gaia-review-code --stack ts-dev" {
  run "$SCRIPT" --skill gaia-review-code --stack ts-dev
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "ts-dev"
  assert_json_field "$output" "sidecar_path" "_memory/ts-dev-sidecar.md"
}

@test "gaia-review-code --stack java-dev" {
  run "$SCRIPT" --skill gaia-review-code --stack java-dev
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "java-dev"
  assert_json_field "$output" "sidecar_path" "_memory/java-dev-sidecar.md"
}

@test "gaia-review-code --stack python-dev" {
  run "$SCRIPT" --skill gaia-review-code --stack python-dev
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "python-dev"
  assert_json_field "$output" "sidecar_path" "_memory/python-dev-sidecar.md"
}

@test "gaia-review-code --stack go-dev" {
  run "$SCRIPT" --skill gaia-review-code --stack go-dev
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "go-dev"
  assert_json_field "$output" "sidecar_path" "_memory/go-dev-sidecar.md"
}

@test "gaia-review-code --stack flutter-dev" {
  run "$SCRIPT" --skill gaia-review-code --stack flutter-dev
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "flutter-dev"
  assert_json_field "$output" "sidecar_path" "_memory/flutter-dev-sidecar.md"
}

@test "gaia-review-code --stack mobile-dev" {
  run "$SCRIPT" --skill gaia-review-code --stack mobile-dev
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "mobile-dev"
  assert_json_field "$output" "sidecar_path" "_memory/mobile-dev-sidecar.md"
}

@test "gaia-review-code --stack angular-dev" {
  run "$SCRIPT" --skill gaia-review-code --stack angular-dev
  [ "$status" -eq 0 ]
  assert_json_field "$output" "agent_id" "angular-dev"
  assert_json_field "$output" "sidecar_path" "_memory/angular-dev-sidecar.md"
}

# --- error contract ---

@test "unknown skill -> exit 1 + stderr diagnostic" {
  run --separate-stderr "$SCRIPT" --skill gaia-not-a-real-skill
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"unknown"* ]] || [[ "$stderr" == *"unsupported"* ]] || [[ "$stderr" == *"not"* ]]
}

@test "agent-overlay.sh: --help exits 0 and lists usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-overlay.sh"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "agent-overlay.sh: missing --skill -> exit 1" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "agent-overlay.sh: invalid --stack for gaia-review-code -> exit 1" {
  run --separate-stderr "$SCRIPT" --skill gaia-review-code --stack not-a-real-stack
  [ "$status" -eq 1 ]
}

@test "agent-overlay.sh: JSON output is single-line and parseable" {
  run "$SCRIPT" --skill gaia-review-qa
  [ "$status" -eq 0 ]
  # exactly one line of output
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  # contains both required fields
  [[ "$output" == *"\"agent_id\""* ]]
  [[ "$output" == *"\"sidecar_path\""* ]]
}
