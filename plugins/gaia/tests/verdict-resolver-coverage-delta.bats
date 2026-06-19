#!/usr/bin/env bats
# verdict-resolver-coverage-delta.bats — E67-S3 coverage-delta integration tests
# for verdict-resolver.sh (FR-RSV2-2, TC-RSV2-TESTAUTOMATE-3, AC2, AC3, AC4, AC6).
#
# Validates the new --coverage-delta flag and the precedence rule inserted
# between LLM-Critical and the default APPROVE branch:
#
#   1. errored                             -> BLOCKED
#   2. tool-failed-blocking                -> REQUEST_CHANGES
#   3. LLM-Critical                        -> REQUEST_CHANGES
#   4. coverage_delta <= 0  (NEW)          -> REQUEST_CHANGES
#   5. otherwise                           -> APPROVE
#
# Backward compatibility (AC6): omitting --coverage-delta preserves the
# original four-rule behavior — existing verdict-resolver.bats /
# verdict-resolver-parameterized.bats suites must remain green.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/verdict-resolver.sh"
}
teardown() { common_teardown; }

# --- helpers -----------------------------------------------------------

write_analysis() {
  local path="$1" checks="$2"
  cat > "$path" <<EOF
{
  "schema_version": "1.0",
  "story_key": "E67-S3",
  "skill": "gaia-test-automate",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": $checks
}
EOF
}

write_findings() {
  local path="$1" findings="$2"
  cat > "$path" <<EOF
{ "findings": $findings }
EOF
}

write_coverage_delta() {
  # write_coverage_delta <path> <delta> <baseline> <current>
  local path="$1" delta="$2" baseline="$3" current="$4"
  cat > "$path" <<EOF
{"coverage_delta": ${delta}, "baseline": ${baseline}, "current": ${current}}
EOF
}

# --- AC2: positive delta -> APPROVE ------------------------------------

@test "positive coverage delta -> APPROVE" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"coverage","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  write_coverage_delta "$TEST_TMP/cd.json" 5.0 80.0 85.0
  run --separate-stderr "$SCRIPT" --skill gaia-test-automate \
      --analysis-results "$TEST_TMP/a.json" \
      --llm-findings "$TEST_TMP/f.json" \
      --coverage-delta "$TEST_TMP/cd.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# --- AC3: zero delta -> REQUEST_CHANGES --------------------------------

@test "zero coverage delta -> REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"coverage","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  write_coverage_delta "$TEST_TMP/cd.json" 0.0 80.0 80.0
  run --separate-stderr "$SCRIPT" --skill gaia-test-automate \
      --analysis-results "$TEST_TMP/a.json" \
      --llm-findings "$TEST_TMP/f.json" \
      --coverage-delta "$TEST_TMP/cd.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
  [[ "$stderr" == *"coverage_delta"* ]]
}

# --- AC4: negative delta -> REQUEST_CHANGES ----------------------------

@test "negative coverage delta -> REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"coverage","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  write_coverage_delta "$TEST_TMP/cd.json" -2.5 80.0 77.5
  run --separate-stderr "$SCRIPT" --skill gaia-test-automate \
      --analysis-results "$TEST_TMP/a.json" \
      --llm-findings "$TEST_TMP/f.json" \
      --coverage-delta "$TEST_TMP/cd.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
  [[ "$stderr" == *"coverage_delta"* ]] || [[ "$stderr" == *"-2.5"* ]] || [[ "$stderr" == *"regression"* ]]
}

# --- AC6: precedence preserved -- errored beats negative delta --------

@test "errored check beats negative coverage delta -> BLOCKED" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"coverage","status":"errored","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  write_coverage_delta "$TEST_TMP/cd.json" -2.5 80.0 77.5
  run --separate-stderr "$SCRIPT" --skill gaia-test-automate \
      --analysis-results "$TEST_TMP/a.json" \
      --llm-findings "$TEST_TMP/f.json" \
      --coverage-delta "$TEST_TMP/cd.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# --- AC6: tool-failed-blocking beats negative delta ------------------

@test "tool-failed-blocking beats negative coverage delta -> REQUEST_CHANGES (failure-driven)" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"coverage","status":"failed","findings":[{"severity":"error","blocking":true,"message":"runner crashed"}]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  write_coverage_delta "$TEST_TMP/cd.json" -2.5 80.0 77.5
  run --separate-stderr "$SCRIPT" --skill gaia-test-automate \
      --analysis-results "$TEST_TMP/a.json" \
      --llm-findings "$TEST_TMP/f.json" \
      --coverage-delta "$TEST_TMP/cd.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# --- AC6: LLM-Critical beats positive delta (no spurious APPROVE) ----

@test "LLM-Critical with positive delta still -> REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"coverage","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[{"severity":"Critical","message":"unsafe pattern"}]'
  write_coverage_delta "$TEST_TMP/cd.json" 5.0 80.0 85.0
  run --separate-stderr "$SCRIPT" --skill gaia-test-automate \
      --analysis-results "$TEST_TMP/a.json" \
      --llm-findings "$TEST_TMP/f.json" \
      --coverage-delta "$TEST_TMP/cd.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# --- AC6: backward compat -- omitting --coverage-delta unchanged -----

@test "omitting --coverage-delta preserves pre-S3 behavior" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"coverage","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-test-automate \
      --analysis-results "$TEST_TMP/a.json" \
      --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}
