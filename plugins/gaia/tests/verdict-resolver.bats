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

# ---------------------------------------------------------------------------
# Register mode tests (--register flag)
# ---------------------------------------------------------------------------

# -- truth-table verdicts --

@test "register mode with one unresolved blocker yields REQUEST_CHANGES" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "null pointer"
    type: bug
    severity: critical
    blocking: true
    blocking_rationale: "Critical severity"
    material: false
    disposition: open
    dedup_key: "src/main.ts:10:nullptr"
    originating_gates: [code-review]
    gate_ratings:
      - {gate: code-review, severity: critical, blocking: true, material: false}
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register mode with all entries resolved yields APPROVE" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "null pointer"
    type: bug
    severity: critical
    blocking: true
    blocking_rationale: "Critical severity"
    material: false
    disposition: resolved
    dedup_key: "src/main.ts:10:nullptr"
    originating_gates: [code-review]
    gate_ratings:
      - {gate: code-review, severity: critical, blocking: true, material: false}
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register mode with unknown disposition counts as unresolved" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "test"
    type: bug
    severity: high
    blocking: true
    blocking_rationale: "High severity"
    material: false
    disposition: wontfix-maybe
    dedup_key: "src/x.ts:1:test"
    originating_gates: [code-review]
    gate_ratings:
      - {gate: code-review, severity: high, blocking: true, material: false}
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register mode with empty entries yields APPROVE and logs register empty" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
  printf '%s\n' "$stderr" | grep -qF "register: empty"
}

@test "register mode with truncated register yields BLOCKED exit 0" {
  printf 'schema_version: 1\nentries:\n  - id: RF-' > "$TEST_TMP/reg.yaml"
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  # Must assert stderr content so the unknown-argument exit 1 cannot satisfy this
  { printf '%s\n' "$stderr" | grep -qF "parse"; } || { printf '%s\n' "$stderr" | grep -qF "structural"; } || { printf '%s\n' "$stderr" | grep -qF "malformed"; }
}

@test "register mode with entries as scalar string yields BLOCKED exit 0" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: "not a sequence"
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  { printf '%s\n' "$stderr" | grep -qF "structural"; } || { printf '%s\n' "$stderr" | grep -qF "parse"; }
}

@test "register mode with entries as scalar number yields BLOCKED exit 0" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: 42
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  { printf '%s\n' "$stderr" | grep -qF "structural"; } || { printf '%s\n' "$stderr" | grep -qF "parse"; }
}

@test "register mode with wrong schema_version yields BLOCKED exit 0" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 99
story: TEST-S1
gate_runs: []
entries: []
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  { printf '%s\n' "$stderr" | grep -qF "structural"; } || { printf '%s\n' "$stderr" | grep -qF "schema"; }
}

@test "register mode with failed blocking tool and empty register yields REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"eslint","status":"failed","findings":[{"severity":"error","blocking":true}]}]'
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --analysis-results "$TEST_TMP/a.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register mode with coverage drop and empty register yields REQUEST_CHANGES" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
YAML
  cat > "$TEST_TMP/cd.json" <<'JSON'
{"coverage_delta": -3.5}
JSON
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --analysis-results "$TEST_TMP/a.json" --coverage-delta "$TEST_TMP/cd.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register mode with failed blocking tool and malformed register yields BLOCKED" {
  write_analysis "$TEST_TMP/a.json" '[{"name":"eslint","status":"failed","findings":[{"severity":"error","blocking":true}]}]'
  printf 'this is not valid yaml [[[' > "$TEST_TMP/reg.yaml"
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --analysis-results "$TEST_TMP/a.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  # Malformed register is parsed first, so BLOCKED wins over REQUEST_CHANGES
  { printf '%s\n' "$stderr" | grep -qF "parse"; } || { printf '%s\n' "$stderr" | grep -qF "structural"; } || { printf '%s\n' "$stderr" | grep -qF "malformed"; }
}

@test "register mode same register same verdict across six gate names" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "test blocker"
    type: bug
    severity: critical
    blocking: true
    blocking_rationale: "Critical severity"
    material: false
    disposition: open
    dedup_key: "src/x.ts:1:test"
    originating_gates: [code-review]
    gate_ratings:
      - {gate: code-review, severity: critical, blocking: true, material: false}
YAML
  local gates="gaia-code-review gaia-qa-tests gaia-review-security gaia-test-automate gaia-test-review gaia-review-perf"
  local first_verdict=""
  for gate in $gates; do
    run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" --skill "$gate"
    [ "$status" -eq 0 ]
    if [ -z "$first_verdict" ]; then
      first_verdict="$output"
    fi
    [ "$output" = "$first_verdict" ]
  done
  [ "$first_verdict" = "REQUEST_CHANGES" ]
}

@test "register mode material true low severity yields REQUEST_CHANGES" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "material risk"
    type: security
    severity: low
    blocking: true
    blocking_rationale: "Material risk: unverified auth"
    material: true
    disposition: open
    dedup_key: "src/auth.ts:1:material"
    originating_gates: [security-review]
    gate_ratings:
      - {gate: security-review, severity: low, blocking: true, material: true}
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register plus llm-findings flag exits 1 with mutual-exclusion message" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
YAML
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 1 ]
  # The error must mention BOTH flags to prove the conflict was detected,
  # not just "unknown argument: --register". Use case/grep instead of [[ ]]
  # because bash 3.2 does not trigger ERR trap on [[ ]] failure.
  local combined="${stderr:-}${output:-}"
  echo "$combined" | grep -qF "llm-findings"
  echo "$combined" | grep -qF "register"
  # Must NOT be the generic "unknown argument" rejection — the resolver
  # must have recognized --register and then rejected the combination.
  ! echo "$combined" | grep -qE "unknown arg(ument)?"
}

@test "register mode action-mode with empty register and clean flags yields APPROVE" {
  # Action-mode analysis: plan present, execution success, no blocking flags.
  cat > "$TEST_TMP/a.json" <<'JSON'
{"plan":"present","execution":"success","placeholders":false,"mocks_sut":false,"breaks_suite":false}
JSON
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --analysis-results "$TEST_TMP/a.json" --action-mode
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register mode action-mode with clean flags and blocking entry yields REQUEST_CHANGES" {
  cat > "$TEST_TMP/a.json" <<'JSON'
{"plan":"present","execution":"success","placeholders":false,"mocks_sut":false,"breaks_suite":false}
JSON
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "blocker in action mode"
    type: bug
    severity: critical
    blocking: true
    blocking_rationale: "Critical severity"
    material: false
    disposition: open
    dedup_key: "src/x.ts:1:action"
    originating_gates: [test-automate]
    gate_ratings:
      - {gate: test-automate, severity: critical, blocking: true, material: false}
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --analysis-results "$TEST_TMP/a.json" --action-mode
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register mode action-mode with blocking entry same verdict as non-action mode" {
  cat > "$TEST_TMP/a.json" <<'JSON'
{"plan":"present","execution":"success","placeholders":false,"mocks_sut":false,"breaks_suite":false}
JSON
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "blocker"
    type: bug
    severity: critical
    blocking: true
    blocking_rationale: "Critical severity"
    material: false
    disposition: open
    dedup_key: "src/x.ts:1:parity"
    originating_gates: [test-automate]
    gate_ratings:
      - {gate: test-automate, severity: critical, blocking: true, material: false}
YAML
  # Non-action mode
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  local non_action="$output"

  # Action mode
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --analysis-results "$TEST_TMP/a.json" --action-mode
  [ "$status" -eq 0 ]
  local action_mode="$output"

  [ "$non_action" = "$action_mode" ]
}

@test "register mode action-mode with empty register and no analysis-results exits 1" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" --action-mode
  [ "$status" -eq 1 ]
  # Action mode always requires analysis inputs. Use grep instead of [[ ]]
  # because bash 3.2 does not trigger ERR trap on [[ ]] failure.
  local combined="${stderr:-}${output:-}"
  echo "$combined" | grep -qiE "analysis"
}

@test "register mode with no analysis-results evaluates register only" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "register-only test"
    type: security
    severity: critical
    blocking: true
    blocking_rationale: "Critical severity"
    material: false
    disposition: open
    dedup_key: "src/x.ts:1:regonly"
    originating_gates: [security-review]
    gate_ratings:
      - {gate: security-review, severity: critical, blocking: true, material: false}
YAML
  # No --analysis-results, no --llm-findings — register path only
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --skill gaia-review-security
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register mode with disagreed ratings no resolution any blocking yields REQUEST_CHANGES" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "disagreement test"
    type: bug
    severity: high
    blocking: true
    blocking_rationale: "High severity"
    material: false
    disposition: open
    dedup_key: "src/x.ts:1:disagree"
    originating_gates: [code-review, security-review]
    gate_ratings:
      - {gate: code-review, severity: medium, blocking: false, material: false}
      - {gate: security-review, severity: high, blocking: true, material: false}
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register mode after resolution to non-blocking yields APPROVE" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "resolved non-blocking"
    type: tech-debt
    severity: medium
    blocking: false
    material: false
    disposition: open
    dedup_key: "src/x.ts:1:resolved"
    originating_gates: [code-review, security-review]
    gate_ratings:
      - {gate: code-review, severity: medium, blocking: false, material: false}
      - {gate: security-review, severity: high, blocking: true, material: false}
    severity_resolution:
      resolved_severity: medium
      resolved_blocking: false
      rationale: "Reviewed: internal-only path"
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "register mode with material rating after resolution stays REQUEST_CHANGES" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries:
  - id: RF-1
    defect: "material after resolution"
    type: security
    severity: low
    blocking: true
    blocking_rationale: "Material risk"
    material: true
    disposition: open
    dedup_key: "src/x.ts:1:material-res"
    originating_gates: [code-review, security-review]
    gate_ratings:
      - {gate: code-review, severity: low, blocking: false, material: false}
      - {gate: security-review, severity: low, blocking: true, material: true}
    severity_resolution:
      resolved_severity: low
      resolved_blocking: false
      rationale: "Tried to clear but material is true"
YAML
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# -- legacy regression --

@test "legacy mode without register yields identical verdicts to existing fixtures" {
  # Existing code path: no --register -> identical behaviour
  write_analysis "$TEST_TMP/a.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]

  write_analysis "$TEST_TMP/a2.json" '[{"name":"tsc","status":"errored","findings":[]}]'
  write_findings "$TEST_TMP/f2.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a2.json" --llm-findings "$TEST_TMP/f2.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]

  write_analysis "$TEST_TMP/a3.json" '[{"name":"eslint","status":"failed","findings":[{"severity":"error","blocking":true}]}]'
  write_findings "$TEST_TMP/f3.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a3.json" --llm-findings "$TEST_TMP/f3.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]

  write_analysis "$TEST_TMP/a4.json" '[{"name":"tsc","status":"passed","findings":[]}]'
  write_findings "$TEST_TMP/f4.json" '[{"severity":"Critical","message":"x"}]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a4.json" --llm-findings "$TEST_TMP/f4.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}
