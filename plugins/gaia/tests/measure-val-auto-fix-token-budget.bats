#!/usr/bin/env bats
# measure-val-auto-fix-token-budget.bats — unit tests for E44-S9 NFR-VCP-2
# token-budget verification harness (scripts/measure-val-auto-fix-token-budget.sh).
#
# The harness reads three inputs (single-pass baseline cost, per-iteration cost,
# 3-iteration loop total cost), computes the two NFR-VCP-2 ratios, and emits a
# pass/fail verdict against the bounds (≤2x per iteration, ≤6x total loop).
# It can read measurements from the E44-S8 checkpoint custom.val_loop_iterations
# array (preferred path per AC5) or from explicit CLI flags (fallback path).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/measure-val-auto-fix-token-budget.sh"
}
teardown() { common_teardown; }

@test "harness: --help exits 0 and shows usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"token-budget"* || "$output" == *"token budget"* || "$output" == *"baseline"* ]]
}

@test "harness: missing required inputs exits non-zero with actionable error" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"baseline"* || "$output" == *"checkpoint"* ]]
}

@test "harness: AC1 — per-iteration ratio ≤ 2.0 reports PASS" {
  # baseline 1000, iteration 1500 → ratio 1.5, well under 2.0
  run "$SCRIPT" --baseline 1000 --iteration-1 1500 --loop-total 4500
  [ "$status" -eq 0 ]
  [[ "$output" == *"per_iteration_ratio"* ]]
  [[ "$output" == *"1.5"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "harness: AC1 — per-iteration ratio > 2.0 reports FAIL with measured ratio" {
  # baseline 1000, iteration 2300 → ratio 2.3, exceeds 2.0
  run "$SCRIPT" --baseline 1000 --iteration-1 2300 --loop-total 4500
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"2.3"* ]]
  [[ "$output" == *"per-iteration"* ]]
}

@test "harness: AC2 — total loop ratio ≤ 6.0 reports PASS" {
  # baseline 1000, loop_total 5000 → ratio 5.0, under 6.0
  run "$SCRIPT" --baseline 1000 --iteration-1 1500 --loop-total 5000
  [ "$status" -eq 0 ]
  [[ "$output" == *"total_loop_ratio"* ]]
  [[ "$output" == *"5"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "harness: AC2 — total loop ratio > 6.0 reports FAIL" {
  # baseline 1000, loop_total 6500 → ratio 6.5, exceeds 6.0
  run "$SCRIPT" --baseline 1000 --iteration-1 1500 --loop-total 6500
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"6.5"* ]]
  [[ "$output" == *"total"* ]]
}

@test "harness: AC1 boundary — per-iteration ratio exactly 2.0 reports PASS (inclusive bound)" {
  run "$SCRIPT" --baseline 1000 --iteration-1 2000 --loop-total 5000
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "harness: AC2 boundary — total loop ratio exactly 6.0 reports PASS (inclusive bound)" {
  run "$SCRIPT" --baseline 1000 --iteration-1 1500 --loop-total 6000
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "harness: AC5 — reads token_estimate from checkpoint val_loop_iterations array" {
  # Build a fake checkpoint with the E44-S8 custom.val_loop_iterations schema.
  cat > "$TEST_TMP/checkpoint.json" <<'EOF'
{
  "workflow": "gaia-brainstorm",
  "step": 7,
  "custom": {
    "val_loop_iterations": [
      {"iteration_number": 1, "token_estimate": 1500, "findings": ["x"]},
      {"iteration_number": 2, "token_estimate": 1500, "findings": ["y"]},
      {"iteration_number": 3, "token_estimate": 1500, "findings": ["z"]}
    ]
  }
}
EOF
  run "$SCRIPT" --baseline 1000 --checkpoint "$TEST_TMP/checkpoint.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"data_source: checkpoint"* ]]
  [[ "$output" == *"per_iteration_ratio"* ]]
  [[ "$output" == *"1.5"* ]]
  [[ "$output" == *"total_loop_ratio"* ]]
  [[ "$output" == *"4.5"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "harness: AC5 — falls back to external when checkpoint lacks token_estimate" {
  cat > "$TEST_TMP/checkpoint-empty.json" <<'EOF'
{
  "workflow": "gaia-brainstorm",
  "step": 7,
  "custom": {
    "val_loop_iterations": [
      {"iteration_number": 1, "findings": ["x"]},
      {"iteration_number": 2, "findings": ["y"]}
    ]
  }
}
EOF
  run "$SCRIPT" --baseline 1000 --iteration-1 1500 --loop-total 4500 --checkpoint "$TEST_TMP/checkpoint-empty.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"data_source: external"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "harness: invalid baseline (non-numeric) exits non-zero" {
  run "$SCRIPT" --baseline abc --iteration-1 1500 --loop-total 4500
  [ "$status" -ne 0 ]
  [[ "$output" == *"baseline"* || "$output" == *"numeric"* ]]
}

@test "harness: zero baseline exits non-zero (division-by-zero guard)" {
  run "$SCRIPT" --baseline 0 --iteration-1 1500 --loop-total 4500
  [ "$status" -ne 0 ]
  [[ "$output" == *"baseline"* || "$output" == *"zero"* ]]
}

@test "harness: emits measurement_date in ISO 8601 format on success" {
  run "$SCRIPT" --baseline 1000 --iteration-1 1500 --loop-total 4500
  [ "$status" -eq 0 ]
  [[ "$output" =~ measurement_date:\ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]
}

@test "harness: emits both ratios in machine-readable key:value format" {
  run "$SCRIPT" --baseline 1000 --iteration-1 1500 --loop-total 4500
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline_tokens: 1000"* ]]
  [[ "$output" == *"iteration_1_tokens: 1500"* ]]
  [[ "$output" == *"loop_total_tokens: 4500"* ]]
}
