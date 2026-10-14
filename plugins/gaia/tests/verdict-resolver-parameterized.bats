#!/usr/bin/env bats
# verdict-resolver-parameterized.bats — E66-S1 ADR-077 generalization tests for
# the parameterized verdict-resolver.sh. Covers AC4, AC5 (TC-RSV2-FOUND-02..06).
#
# These tests exercise the new --skill parameter and confirm the four verdict
# precedence rules behave identically across non-code-review skill inputs.
# The legacy verdict-resolver.bats suite covers backward compatibility for
# gaia-code-review without --skill — this suite covers the generalized form.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/verdict-resolver.sh"
}
teardown() { common_teardown; }

# --- helpers ---

write_analysis_for_skill() {
  # write_analysis_for_skill <path> <skill-name> <checks-json>
  local path="$1" skill="$2"; shift 2
  cat > "$path" <<EOF
{
  "schema_version": "1.0",
  "story_key": "E66-S1",
  "skill": "${skill}",
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
  local path="$1"; shift
  cat > "$path" <<EOF
{ "findings": $1 }
EOF
}

# --- AC4: --skill flag accepted; non-code-review skill input works ---

@test "skill flag accepted for gaia-review-security" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-security" '[{"name":"semgrep","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-security --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
  [[ "$stderr" == *"skill=gaia-review-security"* ]]   # provenance logged
}

@test "skill flag accepted for gaia-review-qa" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-qa" '[{"name":"qa-runner","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-qa --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "skill flag accepted for gaia-review-perf" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-perf" '[{"name":"perf-bench","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-perf --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "skill flag accepted for gaia-test-automate" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-test-automate" '[{"name":"coverage","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-test-automate --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# --- AC5: precedence rules preserved under parameterized form ---

@test "errored check on non-code-review skill -> BLOCKED" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-security" '[{"name":"semgrep","status":"errored","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-security --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "tool-failed-blocking on non-code-review skill -> REQUEST_CHANGES" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-security" '[{"name":"semgrep","status":"failed","findings":[{"severity":"error","blocking":true,"message":"sql injection"}]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-security --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "LLM-Critical on non-code-review skill -> REQUEST_CHANGES" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-perf" '[{"name":"perf-bench","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[{"severity":"Critical","message":"O(n^2) hot path"}]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-perf --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "clean run on non-code-review skill -> APPROVE" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-test" '[{"name":"coverage","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[{"severity":"Warning","message":"long function"}]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-test --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# --- LLM-cannot-override invariant under --skill ---

@test "verdict-resolver --skill: tool-failed + LLM=APPROVE => REQUEST_CHANGES" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-security" '[{"name":"semgrep","status":"failed","findings":[{"severity":"error","blocking":true}]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-security --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# --- --analysis alias accepted for --analysis-results ---

@test "verdict-resolver: --analysis alias accepted as alias for --analysis-results" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-security" '[{"name":"semgrep","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --skill gaia-review-security --analysis "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# --- backward-compat: existing flags still work without --skill ---

@test "verdict-resolver: omitting --skill still works (backward compat)" {
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-code-review" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# --- review-common re-export entry point ---

@test "review-common/verdict-resolver.sh re-export: invokes parameterized resolver" {
  RC_SCRIPT="$SCRIPTS_DIR/review-common/verdict-resolver.sh"
  [ -f "$RC_SCRIPT" ] || [ -L "$RC_SCRIPT" ]
  write_analysis_for_skill "$TEST_TMP/a.json" "gaia-review-security" '[{"name":"semgrep","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$RC_SCRIPT" --skill gaia-review-security --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# ---------------------------------------------------------------------------
# Register-mode truth table: {blocking} x {disposition} x {material}
# ---------------------------------------------------------------------------
# Expected verdict: REQUEST_CHANGES iff (blocking OR material) AND disposition != resolved
# "blocking OR material" because material:true forces blocking even when the
# top-level blocking field is false.

# Helper: build a register fixture with one entry of the given parameters
_write_truth_table_register() {
  local path="$1" blk="$2" disp="$3" mat="$4"
  local rationale_field=""
  if [ "$blk" = "true" ]; then
    rationale_field=$'\n    blocking_rationale: "test rationale"'
  fi
  cat > "$path" <<YAML
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "truth table entry"
    type: bug
    severity: medium
    blocking: ${blk}${rationale_field}
    material: ${mat}
    disposition: ${disp}
    dedup_key: "src/x.ts:1:truth"
    originating_gates: [code-review]
    gate_ratings:
      - {gate: code-review, severity: medium, blocking: ${blk}, material: ${mat}}
YAML
}

@test "register truth table: blocking=true disposition=open material=false -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" true open false
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register truth table: blocking=true disposition=triage material=false -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" true triage false
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register truth table: blocking=true disposition=resolved material=false -> APPROVE" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" true resolved false
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register truth table: blocking=true disposition=unknown material=false -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" true wontfix false
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register truth table: blocking=false disposition=open material=false -> APPROVE" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" false open false
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register truth table: blocking=false disposition=triage material=false -> APPROVE" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" false triage false
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register truth table: blocking=false disposition=resolved material=false -> APPROVE" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" false resolved false
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register truth table: blocking=false disposition=unknown material=false -> APPROVE" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" false wontfix false
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register truth table: blocking=true disposition=open material=true -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" true open true
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register truth table: blocking=true disposition=triage material=true -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" true triage true
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register truth table: blocking=true disposition=resolved material=true -> APPROVE" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" true resolved true
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register truth table: blocking=true disposition=unknown material=true -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" true wontfix true
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register truth table: blocking=false disposition=open material=true -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" false open true
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register truth table: blocking=false disposition=triage material=true -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" false triage true
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register truth table: blocking=false disposition=resolved material=true -> APPROVE" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" false resolved true
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register truth table: blocking=false disposition=unknown material=true -> REQUEST_CHANGES" {
  _write_truth_table_register "$TEST_TMP/reg.yaml" false wontfix true
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}
