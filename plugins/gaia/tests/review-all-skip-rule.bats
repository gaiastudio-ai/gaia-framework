#!/usr/bin/env bats
# review-all-skip-rule.bats — E69-S4 conditional-skip update for /gaia-review-all
#
# Tests the deterministic conditional-trigger evaluator that reads project-config
# (compliance.ui_present, platforms[]) and emits the canonical aggregator argv
# fragment for `composite-verdict-aggregator.sh`. Also tests the aggregator's
# degenerate-case path (zero included gates) per AC-EC3.
#
# Coverage:
#   - AC6  conditional gate skipped when trigger condition not met
#   - AC7  composite report enumerates included vs skipped (via aggregator)
#   - AC8  skipped gates excluded from precedence (via aggregator)
#   - AC-EC2 all conditionals skipped + all always-on APPROVE -> APPROVE
#   - AC-EC3 zero included gates -> WARNING + APPROVE
#
# Refs: E69-S4, FR-RSV2-44, ADR-082.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  EVAL="$SCRIPTS_DIR/review-common/conditional-trigger-eval.sh"
  AGG="$SCRIPTS_DIR/review-common/composite-verdict-aggregator.sh"
  CONFIG_DIR="$TEST_TMP/config"
  mkdir -p "$CONFIG_DIR"
}
teardown() { common_teardown; }

write_config() {
  # write_config <ui_present> <platforms-csv-or-empty>
  local ui="$1" platforms="$2"
  {
    printf 'compliance:\n  ui_present: %s\n' "$ui"
    if [ -n "$platforms" ]; then
      printf 'platforms: [%s]\n' "$platforms"
    else
      printf 'platforms: []\n'
    fi
  } > "$CONFIG_DIR/project-config.yaml"
}

# ---------- AC6: trigger evaluation maps to skip flags ----------

@test "ui_present=false -> emits --skip-a11y with reason" {
  write_config false "web"
  run --separate-stderr "$EVAL" --shared "$CONFIG_DIR/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--skip-a11y"* ]]
  [[ "$output" == *"compliance.ui_present: false"* ]]
}

@test "ui_present=true -> emits --a11y placeholder (caller fills verdict)" {
  write_config true "web,ios"
  run --separate-stderr "$EVAL" --shared "$CONFIG_DIR/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a11y=included"* ]]
}

@test "platforms excludes mobile -> emits --skip-mobile with reason" {
  write_config true "web"
  run --separate-stderr "$EVAL" --shared "$CONFIG_DIR/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--skip-mobile"* ]]
  [[ "$output" == *"platforms[] excludes mobile"* ]]
}

@test "platforms includes ios -> mobile included" {
  write_config true "web,ios"
  run --separate-stderr "$EVAL" --shared "$CONFIG_DIR/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mobile=included"* ]]
}

@test "platforms includes android -> mobile included" {
  write_config true "android"
  run --separate-stderr "$EVAL" --shared "$CONFIG_DIR/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mobile=included"* ]]
}

# ---------- AC-EC2: all conditionals skipped + all always-on APPROVE -> APPROVE ----------

@test "both conditionals skipped + all always-on APPROVE -> composite APPROVE" {
  run --separate-stderr "$AGG" \
    --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "compliance.ui_present: false" \
    --skip-mobile "platforms[] excludes mobile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=APPROVE"* ]]
  [[ "$output" == *"review_gate=PASSED"* ]]
  [[ "$output" == *"included=code,qa,test,security,perf"* ]]
  [[ "$output" == *"skipped=a11y,mobile"* ]]
}

# ---------- AC-EC3: zero included gates degenerate case ----------

@test "allow-zero-included with all gates skipped -> WARNING + APPROVE" {
  run --separate-stderr "$AGG" \
    --allow-zero-included \
    --skip-code "no code changes" \
    --skip-qa "no qa changes" \
    --skip-test "no test changes" \
    --skip-security "n/a" \
    --skip-perf "n/a" \
    --skip-a11y "ui_present: false" \
    --skip-mobile "platforms[] empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=APPROVE"* ]]
  [[ "$output" == *"review_gate=PASSED"* ]]
  [[ "$output" == *"WARNING: No review gates included"* ]]
  [[ "$output" == *"included="* ]]
}

@test "without --allow-zero-included, --skip-code rejected" {
  # The opt-in flag MUST be required for the degenerate case; default behaviour
  # remains: always-on gates are required.
  run --separate-stderr "$AGG" \
    --skip-code "n/a" \
    --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "x" --skip-mobile "y"
  [ "$status" -eq 1 ]
}

# ---------- AC8: skipped gates excluded from precedence ----------

@test "skipped conditional contributes neutrally; precedence on included only" {
  run --separate-stderr "$AGG" \
    --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "x" --mobile REQUEST_CHANGES
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=REQUEST_CHANGES"* ]]
  [[ "$output" == *"included=code,qa,test,security,perf,mobile"* ]]
}

# ---------- determinism / YOLO invariance ----------

@test "determinism: trigger-eval output is byte-identical on identical input" {
  write_config true "web,ios"
  local h1 h2
  h1="$("$EVAL" --shared "$CONFIG_DIR/project-config.yaml" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  h2="$("$EVAL" --shared "$CONFIG_DIR/project-config.yaml" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  [ "$h1" = "$h2" ]
}

@test "YOLO: trigger-eval invariant under YOLO_MODE=true" {
  write_config true "web,ios"
  local out_yolo out_normal
  out_yolo="$(YOLO_MODE=true "$EVAL" --shared "$CONFIG_DIR/project-config.yaml" 2>/dev/null)"
  out_normal="$("$EVAL" --shared "$CONFIG_DIR/project-config.yaml" 2>/dev/null)"
  [ "$out_yolo" = "$out_normal" ]
}

# ---------- usage ----------

@test "usage: --help exits 0" {
  run --separate-stderr "$EVAL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"conditional-trigger-eval"* ]]
}
