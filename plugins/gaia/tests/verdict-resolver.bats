#!/usr/bin/env bats
# verdict-resolver.bats — unit tests for plugins/gaia/scripts/verdict-resolver.sh (E65-S1)
# Covers TC-DEJ-VERDICT-01..04, TC-DEJ-OVERRIDE-1, EC-1, EC-2, EC-10.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/verdict-resolver.sh"
}
teardown() { common_teardown; }

# --- helpers ---

write_analysis() {
  # write_analysis <path> <checks-json>
  local path="$1"; shift
  cat > "$path" <<EOF
{
  "schema_version": "1.0",
  "story_key": "E65-S1",
  "skill": "gaia-code-review",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": $1
}
EOF
}

write_findings() {
  # write_findings <path> <findings-json>
  local path="$1"; shift
  cat > "$path" <<EOF
{
  "findings": $1
}
EOF
}

# --- happy-path & precedence ---

@test "verdict-resolver.sh: --help exits 0 and lists usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict-resolver.sh"* ]]
}

@test "errored check -> BLOCKED" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"errored","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "tool failed-blocking -> REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"failed","findings":[{"severity":"error","blocking":true,"message":"type error"}]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "LLM-Critical finding -> REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[{"severity":"Critical","message":"off-by-one"}]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "all pass + no Critical -> APPROVE" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]},{"name":"eslint","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[{"severity":"Warning","message":"long function"}]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# --- LLM-cannot-override invariant ---

@test "tool-failed + LLM=APPROVE => REQUEST_CHANGES (LLM cannot override)" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"failed","findings":[{"severity":"error","blocking":true}]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "tool=passed + LLM=Critical => REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[{"severity":"Critical","message":"null deref"}]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# --- edge cases ---

@test "all-skipped checks -> APPROVE (default rule)" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"skipped","skip_reason":"not applicable","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "empty checks array -> APPROVE" {
  write_analysis "$TEST_TMP/a.json" '[]'
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "malformed JSON -> BLOCKED + stderr error; exit 0" {
  printf '{ "schema_version": "1.0", "checks":' > "$TEST_TMP/a.json"   # truncated
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  [[ "$stderr" == *"malformed analysis-results.json"* ]]
}

@test "missing schema_version -> BLOCKED" {
  cat > "$TEST_TMP/a.json" <<'EOF'
{ "story_key":"X", "checks": [] }
EOF
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  [[ "$stderr" == *"missing schema_version"* ]]
}

@test "errored + tool-failed + LLM-Critical collision -> BLOCKED (errored wins)" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"errored","findings":[]},{"name":"eslint","status":"failed","findings":[{"severity":"error","blocking":true}]}]'
  write_findings "$TEST_TMP/f.json" '[{"severity":"Critical","message":"x"}]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "verdict-resolver.sh: missing --analysis-results -> exit 1 (caller error)" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "verdict-resolver.sh: missing analysis file path -> BLOCKED + stderr" {
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --analysis-results "$TEST_TMP/does-not-exist.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  [[ "$stderr" == *"file not found"* ]]
}
