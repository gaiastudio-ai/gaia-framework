#!/usr/bin/env bats
# qa-verdict-integration.bats — E67-S4 bats coverage for verdict-resolver.sh
# integration with execution-evidence.json (AC5, AC6, AC9).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
}
teardown() { common_teardown; }

write_passing_evidence() {
  cat > "$1" <<'EOF'
{
  "tier": "tier_1",
  "context": "local",
  "wall_clock_seconds": 0.5,
  "skipped": false,
  "bridge_used": false,
  "suites": [
    {"name": "tier_1", "command": "true", "exit_code": 0,
     "duration_seconds": 0.1, "pass_count": 0, "fail_count": 0,
     "timeout": false, "required": true}
  ]
}
EOF
}

write_failing_evidence() {
  cat > "$1" <<'EOF'
{
  "tier": "tier_1",
  "context": "local",
  "wall_clock_seconds": 0.5,
  "skipped": false,
  "bridge_used": false,
  "suites": [
    {"name": "tier_1", "command": "false", "exit_code": 1,
     "duration_seconds": 0.1, "pass_count": 0, "fail_count": 1,
     "timeout": false, "required": true}
  ]
}
EOF
}

write_timeout_evidence() {
  cat > "$1" <<'EOF'
{
  "tier": "tier_1",
  "context": "local",
  "wall_clock_seconds": 1.5,
  "skipped": false,
  "bridge_used": false,
  "suites": [
    {"name": "tier_1", "command": "sleep 30", "exit_code": 124,
     "duration_seconds": 1.0, "pass_count": 0, "fail_count": 0,
     "timeout": true, "required": true}
  ]
}
EOF
}

write_clean_analysis() {
  # No deterministic findings.
  cat > "$1" <<'EOF'
{
  "schema_version": "1.0",
  "checks": []
}
EOF
}

write_empty_llm_findings() {
  cat > "$1" <<'EOF'
{"findings": []}
EOF
}

# --- AC5: required failing test -> REQUEST_CHANGES ---------------------

@test "AC5: required tier_1 failure with --execution-evidence -> REQUEST_CHANGES" {
  write_failing_evidence "$TEST_TMP/execution-evidence.json"
  write_clean_analysis "$TEST_TMP/analysis-results.json"
  write_empty_llm_findings "$TEST_TMP/llm-findings.json"
  run --separate-stderr "$VERDICT_RESOLVER" \
    --analysis-results "$TEST_TMP/analysis-results.json" \
    --llm-findings "$TEST_TMP/llm-findings.json" \
    --execution-evidence "$TEST_TMP/execution-evidence.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# --- AC6: timeout -> BLOCKED ------------------------------------------

@test "AC6: tier_1 timeout with --execution-evidence -> BLOCKED" {
  write_timeout_evidence "$TEST_TMP/execution-evidence.json"
  write_clean_analysis "$TEST_TMP/analysis-results.json"
  write_empty_llm_findings "$TEST_TMP/llm-findings.json"
  run --separate-stderr "$VERDICT_RESOLVER" \
    --analysis-results "$TEST_TMP/analysis-results.json" \
    --llm-findings "$TEST_TMP/llm-findings.json" \
    --execution-evidence "$TEST_TMP/execution-evidence.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# --- AC9: passing evidence -> APPROVE ---------------------------------

@test "AC9: passing evidence + clean analysis -> APPROVE" {
  write_passing_evidence "$TEST_TMP/execution-evidence.json"
  write_clean_analysis "$TEST_TMP/analysis-results.json"
  write_empty_llm_findings "$TEST_TMP/llm-findings.json"
  run --separate-stderr "$VERDICT_RESOLVER" \
    --analysis-results "$TEST_TMP/analysis-results.json" \
    --llm-findings "$TEST_TMP/llm-findings.json" \
    --execution-evidence "$TEST_TMP/execution-evidence.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# --- AC9: timeout precedence over failure ------------------------------

@test "AC9: timeout precedence wins over failure (BLOCKED > REQUEST_CHANGES)" {
  cat > "$TEST_TMP/execution-evidence.json" <<'EOF'
{
  "tier": "tier_1",
  "context": "local",
  "wall_clock_seconds": 1.5,
  "skipped": false,
  "bridge_used": false,
  "suites": [
    {"name": "tier_1", "command": "sleep 30", "exit_code": 124,
     "duration_seconds": 1.0, "pass_count": 0, "fail_count": 0,
     "timeout": true, "required": true},
    {"name": "tier_2", "command": "false", "exit_code": 1,
     "duration_seconds": 0.1, "pass_count": 0, "fail_count": 1,
     "timeout": false, "required": true}
  ]
}
EOF
  write_clean_analysis "$TEST_TMP/analysis-results.json"
  write_empty_llm_findings "$TEST_TMP/llm-findings.json"
  run --separate-stderr "$VERDICT_RESOLVER" \
    --analysis-results "$TEST_TMP/analysis-results.json" \
    --llm-findings "$TEST_TMP/llm-findings.json" \
    --execution-evidence "$TEST_TMP/execution-evidence.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# --- AC9: backward compat without --execution-evidence -----------------

@test "AC9: omitting --execution-evidence preserves pre-S4 behavior (APPROVE on clean inputs)" {
  write_clean_analysis "$TEST_TMP/analysis-results.json"
  write_empty_llm_findings "$TEST_TMP/llm-findings.json"
  run --separate-stderr "$VERDICT_RESOLVER" \
    --analysis-results "$TEST_TMP/analysis-results.json" \
    --llm-findings "$TEST_TMP/llm-findings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# --- AC7: skipped evidence is non-blocking -----------------------------

@test "AC7: skipped evidence (test_execution absent) is non-blocking" {
  cat > "$TEST_TMP/execution-evidence.json" <<'EOF'
{
  "tier": "none",
  "context": "local",
  "wall_clock_seconds": 0,
  "skipped": true,
  "bridge_used": false,
  "suites": []
}
EOF
  write_clean_analysis "$TEST_TMP/analysis-results.json"
  write_empty_llm_findings "$TEST_TMP/llm-findings.json"
  run --separate-stderr "$VERDICT_RESOLVER" \
    --analysis-results "$TEST_TMP/analysis-results.json" \
    --llm-findings "$TEST_TMP/llm-findings.json" \
    --execution-evidence "$TEST_TMP/execution-evidence.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}
