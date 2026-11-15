#!/usr/bin/env bats
# verdict-resolver-required-false-malformed-json.bats
#
# Regression tests for verdict-resolver.sh bugs:
#   1. jq (.required // true) treats required:false the same as required:null
#   2. malformed/truncated --llm-findings JSON silently yields APPROVE
#   3. wrong-shape LLM-findings JSON (valid JSON, wrong structure) yields APPROVE
#   4. unreadable or nonexistent LLM-findings file yields APPROVE
#   5. multi-document LLM-findings JSON silently loses the first document
#
# Every scenario invokes the real script entry point via bash (never sources
# internal functions, never chmod +x the real file). Fixtures use
# BATS_TEST_TMPDIR exclusively.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/verdict-resolver.sh"
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

# run_verdict -- invoke the script via bash, capture stdout (verdict) and
# stderr separately. Sets VERDICT (stdout) and STDERR_OUT (stderr file).
run_verdict() {
  STDERR_OUT="$TEST_TMP/run_stderr.txt"
  VERDICT="$(bash "$SCRIPT" "$@" 2>"$STDERR_OUT")" || true
  export VERDICT
}

# =====================================================================
# AC1 -- required:false suite excluded from pass/fail tallies
# =====================================================================

@test "required:false suite excluded -- optional failure does not block verdict" {
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

@test "required field absent defaults to true -- failure counted" {
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

@test "required field absent with timeout triggers BLOCKED" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"implicit-required","timeout":true,"exit_code":0}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "required test suite timed out" "$STDERR_OUT"
}

@test "required as string false still counts as required" {
  # the string "false" is not boolean false -- suite is still counted
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"string-false","required":"false","exit_code":1,"timeout":false}
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

@test "mixed suites -- required:true failure counted, required:false ignored" {
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
  grep -q "required test suite failed" "$STDERR_OUT"
}

@test "mixed suites -- optional timeout does not escalate to BLOCKED" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"core","required":true,"exit_code":0,"timeout":false},
    {"name":"optional-perf","required":false,"timeout":true,"exit_code":0}
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

# =====================================================================
# AC2 -- Malformed LLM-findings JSON yields BLOCKED with diagnostic
# =====================================================================

@test "malformed llm-findings JSON triggers BLOCKED with jq parse detail and file path" {
  printf '{not valid json!!!' > "$TEST_TMP/bad-llm.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/bad-llm.json"
  [ "$VERDICT" = "BLOCKED" ]
  # diagnostic must include the actual jq parse error and the file path
  grep -q "malformed LLM-findings JSON" "$STDERR_OUT"
  grep -qi "parse error" "$STDERR_OUT"
  grep -qF "$TEST_TMP/bad-llm.json" "$STDERR_OUT"
}

@test "empty llm-findings file (zero bytes) triggers BLOCKED with file path in diagnostic" {
  : > "$TEST_TMP/empty-llm.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/empty-llm.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "file is empty" "$STDERR_OUT"
  grep -qF "$TEST_TMP/empty-llm.json" "$STDERR_OUT"
}

@test "valid llm-findings with empty findings array yields APPROVE" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "APPROVE" ]
}

@test "nonexistent llm-findings path triggers BLOCKED" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/does-not-exist.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "not a regular file" "$STDERR_OUT"
}

@test "unreadable llm-findings file triggers BLOCKED" {
  write_findings "$TEST_TMP/unreadable.json" '[{"severity":"critical","message":"hidden"}]'
  chmod 000 "$TEST_TMP/unreadable.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/unreadable.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "not readable" "$STDERR_OUT"
  chmod 644 "$TEST_TMP/unreadable.json"
}

# =====================================================================
# AC3 -- Truncated-mid-object LLM JSON treated as malformed
# =====================================================================

@test "truncated mid-object llm-findings triggers BLOCKED with parse detail and file path" {
  printf '{"findings": [{"severity": "cri' > "$TEST_TMP/trunc-obj.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/trunc-obj.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "malformed LLM-findings JSON" "$STDERR_OUT"
  grep -qi "parse error" "$STDERR_OUT"
  grep -qF "$TEST_TMP/trunc-obj.json" "$STDERR_OUT"
}

@test "truncated mid-array llm-findings triggers BLOCKED with parse detail and file path" {
  printf '{"findings": [' > "$TEST_TMP/trunc-arr.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/trunc-arr.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "malformed LLM-findings JSON" "$STDERR_OUT"
  grep -qi "parse error\|unexpected" "$STDERR_OUT"
  grep -qF "$TEST_TMP/trunc-arr.json" "$STDERR_OUT"
}

# =====================================================================
# Wrong-shape LLM-findings JSON (valid JSON, wrong structure)
# =====================================================================

@test "llm-findings as bare array triggers BLOCKED with shape diagnostic" {
  printf '[{"severity":"critical"}]' > "$TEST_TMP/bare-array.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/bare-array.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "wrong shape" "$STDERR_OUT"
}

@test "llm-findings as scalar triggers BLOCKED" {
  printf '0' > "$TEST_TMP/scalar.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/scalar.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "wrong shape" "$STDERR_OUT"
}

@test "llm-findings object with findings as string triggers BLOCKED" {
  printf '{"findings":"x"}' > "$TEST_TMP/findings-str.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/findings-str.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "wrong shape" "$STDERR_OUT"
}

@test "llm-findings object with findings null triggers BLOCKED" {
  printf '{"findings":null}' > "$TEST_TMP/findings-null.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/findings-null.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "wrong shape" "$STDERR_OUT"
}

@test "llm-findings object without findings key triggers BLOCKED" {
  printf '{}' > "$TEST_TMP/no-findings.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/no-findings.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "wrong shape" "$STDERR_OUT"
}

@test "llm-findings with findings as nested object (not array) triggers BLOCKED" {
  # findings is an object of keyed entries instead of an array
  printf '{"findings":{"a":{"severity":"low"}}}' > "$TEST_TMP/findings-obj.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/findings-obj.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "wrong shape" "$STDERR_OUT"
}

@test "multi-document llm-findings JSON triggers BLOCKED" {
  # two back-to-back JSON objects -- the first has a critical, the second
  # is empty. jq without -s only sees the last document, losing the critical.
  printf '{"findings":[{"severity":"Critical"}]} {"findings":[]}\n' > "$TEST_TMP/multi-doc.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/multi-doc.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "wrong shape" "$STDERR_OUT"
}

# =====================================================================
# Critical finding with valid shape still yields REQUEST_CHANGES
# =====================================================================

@test "valid findings with critical severity yields REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[{"severity":"critical","message":"off-by-one"}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "REQUEST_CHANGES" ]
}

@test "findings with mixed valid and type-error entries triggers BLOCKED" {
  # a non-string severity causes a jq runtime error during critical check
  printf '{"findings":[{"severity":"critical"},{"severity":5}]}' > "$TEST_TMP/mixed-types.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/mixed-types.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "critical check failed" "$STDERR_OUT"
}

# =====================================================================
# Non-object suite entry rejected as BLOCKED
# =====================================================================

@test "non-object entry in suites array yields BLOCKED" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    "not-an-object",
    {"name":"real","required":true,"timeout":true}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -qi "non-object" "$STDERR_OUT"
}

# =====================================================================
# Strict boolean .skipped check (only true bypasses suite evaluation)
# =====================================================================

@test "skipped=0 does not bypass suite checks (strict boolean)" {
  # .skipped=0 must not be treated as "skipped". Suite checks must run
  # and the required-timeout suite must trigger BLOCKED.
  printf '{"skipped":0,"suites":[{"name":"s","required":true,"timeout":true}]}' \
    > "$TEST_TMP/ee.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "timed out" "$STDERR_OUT"
}

@test "skipped=empty-string does not bypass suite checks" {
  printf '{"skipped":"","suites":[{"name":"s","required":true,"timeout":true}]}' \
    > "$TEST_TMP/ee.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "BLOCKED" ]
}

# =====================================================================
# Whitespace in severity value is trimmed before comparison
# =====================================================================

@test "severity with leading and trailing whitespace yields REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  printf '{"findings":[{"severity":" critical "}]}' > "$TEST_TMP/f.json"

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "REQUEST_CHANGES" ]
}

@test "severity with tab padding yields REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  printf '{"findings":[{"severity":"\\tcritical\\t"}]}' > "$TEST_TMP/f.json"

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "REQUEST_CHANGES" ]
}

# =====================================================================
# Directory path as --llm-findings yields "not a regular file"
# =====================================================================

@test "directory as llm-findings yields not-a-regular-file diagnostic" {
  mkdir -p "$TEST_TMP/somedir"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/somedir"
  [ "$VERDICT" = "BLOCKED" ]
  grep -qi "not a regular file" "$STDERR_OUT"
}

# =====================================================================
# Null and empty-object findings entries rejected as BLOCKED
# =====================================================================

@test "findings array containing null entry yields BLOCKED" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  printf '{"findings":[null]}' > "$TEST_TMP/f.json"

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "BLOCKED" ]
}

@test "findings array containing empty object yields BLOCKED" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  printf '{"findings":[{}]}' > "$TEST_TMP/f.json"

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "BLOCKED" ]
}

@test "findings array with object missing severity key yields BLOCKED" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  printf '{"findings":[{"message":"no severity here"}]}' > "$TEST_TMP/f.json"

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "BLOCKED" ]
}

# Regression guard: empty findings array still yields APPROVE.
@test "empty findings array still yields APPROVE (regression guard)" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$VERDICT" = "APPROVE" ]
}

# =====================================================================
# Unused _llm_crit_err variable removed
# =====================================================================

@test "no dead _llm_crit_err variable in verdict-resolver.sh" {
  local count
  count="$(grep -c '_llm_crit_err' "$SCRIPTS_DIR/verdict-resolver.sh" || true)"
  [ "$count" -eq 0 ]
}

# =====================================================================
# Suite name appears in failure diagnostic
# =====================================================================

@test "required suite failure diagnostic includes the suite name" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"integration","required":true,"exit_code":1,"timeout":false}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "REQUEST_CHANGES" ]
  grep -q "integration" "$STDERR_OUT"
}

@test "timed-out suite diagnostic includes the suite name" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"slow-e2e","required":true,"timeout":true,"exit_code":0}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "slow-e2e" "$STDERR_OUT"
}

# =====================================================================
# Exec forwarder delegates to canonical copy
# =====================================================================

@test "review-common forwarder resolves target to canonical verdict-resolver.sh" {
  # The forwarder at scripts/review-common/verdict-resolver.sh must contain
  # an exec that targets ../verdict-resolver.sh (the canonical copy).
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"
  [ -f "$forwarder" ]
  grep -q 'exec.*\$TARGET' "$forwarder"
  # TARGET is defined relative to SCRIPT_DIR — verify it resolves to the canonical.
  local resolved
  resolved="$(bash -c 'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; TARGET="$SCRIPT_DIR/../verdict-resolver.sh"; cd "$(dirname "$TARGET")" && printf "%s/%s" "$(pwd)" "$(basename "$TARGET")"' "$forwarder")"
  [ -f "$resolved" ]
  [ "$resolved" = "$SCRIPTS_DIR/verdict-resolver.sh" ]
}

# Regression guard: both paths produce identical output for a basic fixture.
@test "forwarder and canonical produce identical output for basic fixture (regression guard)" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  local canonical="$SCRIPTS_DIR/verdict-resolver.sh"
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"

  local out_c err_c rc_c out_f err_f rc_f
  out_c="$(bash "$canonical" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" 2>"$TEST_TMP/err_c.txt")" && rc_c=0 || rc_c=$?
  err_c="$(cat "$TEST_TMP/err_c.txt")"
  out_f="$(bash "$forwarder" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" 2>"$TEST_TMP/err_f.txt")" && rc_f=0 || rc_f=$?
  err_f="$(cat "$TEST_TMP/err_f.txt")"

  [ "$out_c" = "$out_f" ]
  [ "$rc_c" = "$rc_f" ]
  [ "$err_c" = "$err_f" ]
}

# =====================================================================
# Forwarder unchanged — all fixes in canonical only
# =====================================================================

# Regression guard: forwarder is still a pure exec wrapper (~28 lines).
@test "review-common forwarder is a pure exec wrapper (regression guard)" {
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"
  local line_count
  line_count="$(wc -l < "$forwarder" | tr -d ' ')"
  # Allow a small tolerance (25-35 lines) for minor formatting.
  [ "$line_count" -ge 20 ] && [ "$line_count" -le 35 ]
  # Must contain exec and must NOT contain verdict-logic keywords.
  grep -q 'exec "\$TARGET"' "$forwarder"
  ! grep -q 'emit\|BLOCKED\|REQUEST_CHANGES\|APPROVE' "$forwarder"
}

@test "forwarder parity holds for non-object suite entry fixture" {
  # Exercise the AC1 fixture through both paths — they must produce
  # identical results (both BLOCKED once the fix lands).
  printf '{"skipped":false,"suites":["not-an-object",{"name":"real","required":true,"timeout":true}]}' \
    > "$TEST_TMP/ee.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  local canonical="$SCRIPTS_DIR/verdict-resolver.sh"
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"

  local out_c rc_c out_f rc_f
  out_c="$(bash "$canonical" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" --execution-evidence "$TEST_TMP/ee.json" 2>/dev/null)" && rc_c=0 || rc_c=$?
  out_f="$(bash "$forwarder" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" --execution-evidence "$TEST_TMP/ee.json" 2>/dev/null)" && rc_f=0 || rc_f=$?

  [ "$out_c" = "$out_f" ]
  [ "$rc_c" = "$rc_f" ]
  # Both must be BLOCKED after the fix.
  [ "$out_c" = "BLOCKED" ]
}

@test "forwarder parity holds for whitespace-severity fixture" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  printf '{"findings":[{"severity":" critical "}]}' > "$TEST_TMP/f.json"

  local canonical="$SCRIPTS_DIR/verdict-resolver.sh"
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"

  local out_c rc_c out_f rc_f
  out_c="$(bash "$canonical" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" 2>/dev/null)" && rc_c=0 || rc_c=$?
  out_f="$(bash "$forwarder" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" 2>/dev/null)" && rc_f=0 || rc_f=$?

  [ "$out_c" = "$out_f" ]
  [ "$rc_c" = "$rc_f" ]
  [ "$out_c" = "REQUEST_CHANGES" ]
}

@test "forwarder parity holds for null-findings fixture" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  printf '{"findings":[null]}' > "$TEST_TMP/f.json"

  local canonical="$SCRIPTS_DIR/verdict-resolver.sh"
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"

  local out_c rc_c out_f rc_f
  out_c="$(bash "$canonical" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" 2>/dev/null)" && rc_c=0 || rc_c=$?
  out_f="$(bash "$forwarder" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" 2>/dev/null)" && rc_f=0 || rc_f=$?

  [ "$out_c" = "$out_f" ]
  [ "$rc_c" = "$rc_f" ]
  [ "$out_c" = "BLOCKED" ]
}

# =====================================================================
# Non-string suite names must not cause fail-open
# =====================================================================

@test "object-valued suite name does not cause fail-open on timeout rule" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":{"x":1},"required":true,"timeout":true,"exit_code":0}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "BLOCKED" ]
  grep -q "timed out" "$STDERR_OUT"
}

@test "array-valued suite name does not cause fail-open on failure rule" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":["a"],"required":true,"exit_code":1,"timeout":false}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  run_verdict \
    --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$VERDICT" = "REQUEST_CHANGES" ]
  grep -q "failed" "$STDERR_OUT"
}

# =====================================================================
# Forwarder parity: additional fixture coverage
# =====================================================================

@test "forwarder parity holds for skipped=0 fixture" {
  printf '{"skipped":0,"suites":[{"name":"s","required":true,"timeout":true}]}' \
    > "$TEST_TMP/ee.json"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  local canonical="$SCRIPTS_DIR/verdict-resolver.sh"
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"

  local out_c err_c rc_c out_f err_f rc_f
  out_c="$(bash "$canonical" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" --execution-evidence "$TEST_TMP/ee.json" 2>"$TEST_TMP/err_c.txt")" && rc_c=0 || rc_c=$?
  err_c="$(cat "$TEST_TMP/err_c.txt")"
  out_f="$(bash "$forwarder" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" --execution-evidence "$TEST_TMP/ee.json" 2>"$TEST_TMP/err_f.txt")" && rc_f=0 || rc_f=$?
  err_f="$(cat "$TEST_TMP/err_f.txt")"

  [ "$out_c" = "$out_f" ]
  [ "$rc_c" = "$rc_f" ]
  [ "$err_c" = "$err_f" ]
  [ "$out_c" = "BLOCKED" ]
}

@test "forwarder parity holds for directory-as-llm-findings fixture" {
  mkdir -p "$TEST_TMP/somedir"
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'

  local canonical="$SCRIPTS_DIR/verdict-resolver.sh"
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"

  local out_c err_c rc_c out_f err_f rc_f
  out_c="$(bash "$canonical" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/somedir" 2>"$TEST_TMP/err_c.txt")" && rc_c=0 || rc_c=$?
  err_c="$(cat "$TEST_TMP/err_c.txt")"
  out_f="$(bash "$forwarder" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/somedir" 2>"$TEST_TMP/err_f.txt")" && rc_f=0 || rc_f=$?
  err_f="$(cat "$TEST_TMP/err_f.txt")"

  [ "$out_c" = "$out_f" ]
  [ "$rc_c" = "$rc_f" ]
  [ "$err_c" = "$err_f" ]
  [ "$out_c" = "BLOCKED" ]
}

@test "forwarder parity holds for suite-name-in-diagnostic fixture" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":"integration","required":true,"exit_code":1,"timeout":false}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  local canonical="$SCRIPTS_DIR/verdict-resolver.sh"
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"

  local out_c err_c rc_c out_f err_f rc_f
  out_c="$(bash "$canonical" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" --execution-evidence "$TEST_TMP/ee.json" 2>"$TEST_TMP/err_c.txt")" && rc_c=0 || rc_c=$?
  err_c="$(cat "$TEST_TMP/err_c.txt")"
  out_f="$(bash "$forwarder" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" --execution-evidence "$TEST_TMP/ee.json" 2>"$TEST_TMP/err_f.txt")" && rc_f=0 || rc_f=$?
  err_f="$(cat "$TEST_TMP/err_f.txt")"

  [ "$out_c" = "$out_f" ]
  [ "$rc_c" = "$rc_f" ]
  [ "$err_c" = "$err_f" ]
  [ "$out_c" = "REQUEST_CHANGES" ]
  grep -q "integration" "$TEST_TMP/err_c.txt"
}

@test "forwarder parity holds for object-name timeout fixture" {
  write_execution_evidence "$TEST_TMP/ee.json" '[
    {"name":{"x":1},"required":true,"timeout":true,"exit_code":0}
  ]'
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'

  local canonical="$SCRIPTS_DIR/verdict-resolver.sh"
  local forwarder="$SCRIPTS_DIR/review-common/verdict-resolver.sh"

  local out_c rc_c out_f rc_f
  out_c="$(bash "$canonical" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" --execution-evidence "$TEST_TMP/ee.json" 2>/dev/null)" && rc_c=0 || rc_c=$?
  out_f="$(bash "$forwarder" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json" --execution-evidence "$TEST_TMP/ee.json" 2>/dev/null)" && rc_f=0 || rc_f=$?

  [ "$out_c" = "$out_f" ]
  [ "$rc_c" = "$rc_f" ]
  [ "$out_c" = "BLOCKED" ]
}
