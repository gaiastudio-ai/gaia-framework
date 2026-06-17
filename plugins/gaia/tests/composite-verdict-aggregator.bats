#!/usr/bin/env bats
# composite-verdict-aggregator.bats — E66-S3 ADR-082 composite verdict GATING
#
# Tests for the deterministic shell aggregator that consumes per-gate verdicts
# (APPROVE | REQUEST_CHANGES | BLOCKED) and emits a composite verdict plus the
# Review Gate vocabulary mapping (PASSED | FAILED).
#
# Refs: ADR-082, ADR-077, ADR-075, ADR-054, ADR-042, NFR-RSV2-12.
# Story: E66-S3 — covers AC1, AC2, AC3, AC9, AC10.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/composite-verdict-aggregator.sh"
}
teardown() { common_teardown; }

# ---------- AC1: deterministic shell aggregator, first-match-wins ----------

@test "all five always-gates APPROVE, no conditional gates -> APPROVE/PASSED" {
  run --separate-stderr "$SCRIPT" \
    --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "compliance.ui_present: false" \
    --skip-mobile "platforms[] empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=APPROVE"* ]]
  [[ "$output" == *"review_gate=PASSED"* ]]
  [[ "$output" == *"included=code,qa,test,security,perf"* ]]
  [[ "$output" == *"skipped=a11y,mobile"* ]]
}

@test "one gate BLOCKED -> composite BLOCKED/FAILED" {
  run --separate-stderr "$SCRIPT" \
    --code BLOCKED --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "ui_present false" --skip-mobile "no mobile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=BLOCKED"* ]]
  [[ "$output" == *"review_gate=FAILED"* ]]
}

@test "one gate REQUEST_CHANGES -> composite REQUEST_CHANGES/FAILED" {
  run --separate-stderr "$SCRIPT" \
    --code APPROVE --qa REQUEST_CHANGES --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "x" --skip-mobile "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=REQUEST_CHANGES"* ]]
  [[ "$output" == *"review_gate=FAILED"* ]]
}

@test "mixed BLOCKED + REQUEST_CHANGES -> BLOCKED dominates" {
  run --separate-stderr "$SCRIPT" \
    --code REQUEST_CHANGES --qa BLOCKED --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "x" --skip-mobile "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=BLOCKED"* ]]
  [[ "$output" == *"review_gate=FAILED"* ]]
}

# ---------- AC2: skipped conditional gate neutrality ----------

@test "a11y conditional included and APPROVE -> all-APPROVE composite" {
  run --separate-stderr "$SCRIPT" \
    --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --a11y APPROVE --skip-mobile "platforms[] empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=APPROVE"* ]]
  [[ "$output" == *"included=code,qa,test,security,perf,a11y"* ]]
  [[ "$output" == *"skipped=mobile"* ]]
}

@test "mobile conditional included and REQUEST_CHANGES" {
  run --separate-stderr "$SCRIPT" \
    --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "ui false" --mobile REQUEST_CHANGES
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=REQUEST_CHANGES"* ]]
  [[ "$output" == *"included=code,qa,test,security,perf,mobile"* ]]
}

@test "skipped gates enumerate the skip reason" {
  run --separate-stderr "$SCRIPT" \
    --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "compliance.ui_present: false" \
    --skip-mobile "platforms[] empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a11y skipped — compliance.ui_present: false"* ]]
  [[ "$output" == *"mobile skipped — platforms[] empty"* ]]
}

# ---------- AC3: verdict mapping ----------

@test "APPROVE maps to PASSED" {
  run --separate-stderr "$SCRIPT" \
    --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "x" --skip-mobile "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review_gate=PASSED"* ]]
}

@test "REQUEST_CHANGES maps to FAILED" {
  run --separate-stderr "$SCRIPT" \
    --code REQUEST_CHANGES --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "x" --skip-mobile "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review_gate=FAILED"* ]]
}

@test "BLOCKED maps to FAILED" {
  run --separate-stderr "$SCRIPT" \
    --code APPROVE --qa BLOCKED --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "x" --skip-mobile "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review_gate=FAILED"* ]]
}

# ---------- AC9: byte-identical determinism ----------

@test "identical input -> byte-identical output across runs" {
  local out1 out2
  out1="$("$SCRIPT" --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
        --skip-a11y "x" --skip-mobile "y" 2>/dev/null)"
  out2="$("$SCRIPT" --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
        --skip-a11y "x" --skip-mobile "y" 2>/dev/null)"
  [ "$out1" = "$out2" ]
}

@test "byte-identical sha256 on repeated runs" {
  local h1 h2
  h1="$("$SCRIPT" --code BLOCKED --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
        --skip-a11y "x" --skip-mobile "y" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  h2="$("$SCRIPT" --code BLOCKED --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
        --skip-a11y "x" --skip-mobile "y" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  [ "$h1" = "$h2" ]
}

# ---------- AC10: YOLO mode invariance ----------

@test "YOLO_MODE=true does not alter composite verdict" {
  local out_yolo out_normal
  out_yolo="$(YOLO_MODE=true "$SCRIPT" --code BLOCKED --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
              --skip-a11y "x" --skip-mobile "y" 2>/dev/null)"
  out_normal="$("$SCRIPT" --code BLOCKED --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
                --skip-a11y "x" --skip-mobile "y" 2>/dev/null)"
  [ "$out_yolo" = "$out_normal" ]
}

# ---------- usage / error handling ----------

@test "usage: missing required gate -> exit 1" {
  run --separate-stderr "$SCRIPT" --code APPROVE
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing"* ]] || [[ "$stderr" == *"required"* ]]
}

@test "usage: unknown verdict value -> exit 1" {
  run --separate-stderr "$SCRIPT" \
    --code MAYBE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "x" --skip-mobile "y"
  [ "$status" -eq 1 ]
}

@test "usage: --help exits 0 with usage on stdout" {
  run --separate-stderr "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite-verdict-aggregator"* ]]
}

@test "usage: must provide either --a11y or --skip-a11y, not both" {
  run --separate-stderr "$SCRIPT" \
    --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --a11y APPROVE --skip-a11y "x" --skip-mobile "y"
  [ "$status" -eq 1 ]
}
