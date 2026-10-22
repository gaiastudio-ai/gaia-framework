#!/usr/bin/env bats
# verdict-resolver-required-false-malformed-json.bats
#
# Regression tests for two verdict-resolver.sh bugs:
#   1. jq (.required // true) treats required:false the same as required:null
#   2. malformed/truncated --llm-findings JSON silently yields APPROVE
#
# Every scenario invokes the real script entry point (never sources internal
# functions). Fixtures use BATS_TEST_TMPDIR exclusively.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/verdict-resolver.sh"
  [ -x "$SCRIPT" ] || chmod +x "$SCRIPT"
}
teardown() { common_teardown; }

# --- helpers (thin wrappers that build JSON via the real schema) ---

write_analysis() {
  # write_analysis <path> <checks-json-array>
  local path="$1"; shift
  cat > "$path" <<ENDOFANALYSIS
{
  "schema_version": "1.0",
  "story_key": "E900-S1",
  "skill": "gaia-code-review",
  "skill_version": "1.0",
  "model": "test-model",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": $1
}
ENDOFANALYSIS
}

write_findings() {
  # write_findings <path> <findings-json-array>
  local path="$1"; shift
  cat > "$path" <<ENDOFFINDINGS
{
  "findings": $1
}
ENDOFFINDINGS
}

write_execution_evidence() {
  # write_execution_evidence <path> <suites-json-array>
  local path="$1"; shift
  cat > "$path" <<ENDOFEVIDENCE
{
  "skipped": false,
  "suites": $1
}
ENDOFEVIDENCE
}

# run_verdict -- invoke the script, capture stdout (verdict) and stderr
# separately. Sets VERDICT (stdout) and STDERR_OUT (stderr content).
run_verdict() {
  STDERR_OUT="$TEST_TMP/run_stderr.txt"
  VERDICT="$(bash "$SCRIPT" "$@" 2>"$STDERR_OUT")" || true
  export VERDICT
}

# =====================================================================
# AC1 -- required:false suite excluded from pass/fail tallies
# =====================================================================

@test "required:false suite excluded -- optional failure does not block verdict" {
  # S1.1: suite "unit" required:true passes, suite "optional-e2e" required:false fails
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"unit","required":true,"exit_code":0,"timeout":false},
    {"name":"optional-e2e","required":false,"exit_code":1,"timeout":false}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "APPROVE" ]
  ! grep -q "required test suite failed" "$STDERR_OUT"
}

@test "required:false suite excluded from timeout check" {
  # S1.2: optional-slow required:false with timeout:true should not trigger BLOCKED
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"optional-slow","required":false,"timeout":true,"exit_code":0}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "APPROVE" ]
  ! grep -q "required test suite timed out" "$STDERR_OUT"
}

@test "required field absent (null) defaults to true -- failure counts" {
  # S1.3: suite with no required field should default to required:true
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"implicit-required","exit_code":1,"timeout":false}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "REQUEST_CHANGES" ]
  grep -q "required test suite failed" "$STDERR_OUT"
}

@test "mixed suites -- only required:true failure counted, required:false ignored" {
  # S1.4: core (req:true, pass), integration (req:true, fail), smoke (req:false, fail)
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"core","required":true,"exit_code":0,"timeout":false},
    {"name":"integration","required":true,"exit_code":1,"timeout":false},
    {"name":"smoke","required":false,"exit_code":1,"timeout":false}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "REQUEST_CHANGES" ]
}

# =====================================================================
# AC2 -- Malformed LLM-findings JSON yields BLOCKED with diagnostic
# =====================================================================

@test "malformed llm-findings JSON triggers BLOCKED" {
  # S2.1: invalid JSON syntax
  printf '{not valid json!!!' > "$TEST_TMP/bad-llm.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/bad-llm.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "bad-llm.json" "$STDERR_OUT"
  grep -qi "parse\|malformed\|invalid" "$STDERR_OUT"
}

@test "empty llm-findings file (zero bytes) triggers BLOCKED" {
  # S2.2: zero-byte file
  : > "$TEST_TMP/empty-llm.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/empty-llm.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "empty-llm.json" "$STDERR_OUT"
}

@test "valid llm-findings with empty findings array yields APPROVE" {
  # S2.3: contrast -- valid JSON with no findings is still APPROVE
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "APPROVE" ]
}

# =====================================================================
# AC3 -- Truncated-mid-object LLM JSON treated as malformed
# =====================================================================

@test "truncated mid-object llm-findings triggers BLOCKED" {
  # S3.1: partial JSON object
  printf '{"findings": [{"severity": "cri' > "$TEST_TMP/trunc-obj.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/trunc-obj.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "trunc-obj.json" "$STDERR_OUT"
  grep -qi "parse\|malformed\|invalid" "$STDERR_OUT"
}

@test "truncated mid-array llm-findings triggers BLOCKED" {
  # S3.2: open bracket never closed
  printf '{"findings": [' > "$TEST_TMP/trunc-arr.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/trunc-arr.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "trunc-arr.json" "$STDERR_OUT"
}
