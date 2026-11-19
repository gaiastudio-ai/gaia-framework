#!/usr/bin/env bats
# verdict-resolver.bats — unit tests for plugins/gaia/scripts/verdict-resolver.sh
# Covers verdict precedence, LLM-override invariant, edge cases, register mode,
# schema validation, AC-coverage analyzer, and Phase 3A collector.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  _FK="E$((1))-S$((1))"
  _FK99="E$((900))-S$((99))"
  _FK88="E$((900))-S$((88))"
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
  "story_key": "$_FK",
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
  grep -qF "register: empty" <<<"$stderr"
}

@test "register mode with truncated register yields BLOCKED exit 0" {
  printf 'schema_version: 1\nentries:\n  - id: RF-' > "$TEST_TMP/reg.yaml"
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  # Must assert stderr content so the unknown-argument exit 1 cannot satisfy this
  { grep -qF "parse" <<<"$stderr"; } || { grep -qF "structural" <<<"$stderr"; } || { grep -qF "malformed" <<<"$stderr"; }
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
  { grep -qF "structural" <<<"$stderr"; } || { grep -qF "parse" <<<"$stderr"; }
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
  { grep -qF "structural" <<<"$stderr"; } || { grep -qF "parse" <<<"$stderr"; }
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
  { grep -qF "structural" <<<"$stderr"; } || { grep -qF "schema" <<<"$stderr"; }
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
  { grep -qF "parse" <<<"$stderr"; } || { grep -qF "structural" <<<"$stderr"; } || { grep -qF "malformed" <<<"$stderr"; }
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
  grep -qF "llm-findings" <<<"$combined"
  grep -qF "register" <<<"$combined"
  # Must NOT be the generic "unknown argument" rejection — the resolver
  # must have recognized --register and then rejected the combination.
  if grep -qE "unknown arg(ument)?" <<<"$combined"; then
    echo "resolver fell through to generic unknown-argument rejection" >&2; false
  fi
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
  grep -qiE "analysis" <<<"$combined"
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

# ---------------------------------------------------------------------------
# Item 8 — execution-evidence rules apply even without analysis-results
# ---------------------------------------------------------------------------

@test "register mode with timed-out required suite gives BLOCKED even without analysis-results" {
  # Create a minimal valid register with no blockers
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
entries: []
gate_runs: []
YAML

  # Create execution evidence with a timed-out required suite
  cat > "$TEST_TMP/ee.json" <<'JSON'
{
  "suites": [
    {"name": "unit-tests", "required": true, "timeout": true, "exit_code": 1}
  ]
}
JSON

  # No --analysis-results, only --register and --execution-evidence
  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "register mode with failed required suite gives REQUEST_CHANGES even without analysis-results" {
  cat > "$TEST_TMP/reg.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
entries: []
gate_runs: []
YAML

  cat > "$TEST_TMP/ee.json" <<'JSON'
{
  "suites": [
    {"name": "unit-tests", "required": true, "timeout": false, "exit_code": 1}
  ]
}
JSON

  run --separate-stderr "$SCRIPT" --register "$TEST_TMP/reg.yaml" \
    --execution-evidence "$TEST_TMP/ee.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# ===========================================================================
# Payload C: schema_version present but structurally invalid
# ===========================================================================

@test "payload C (schema_version with tools instead of checks) -> BLOCKED" {
  # Payload C: has schema_version but uses "tools" key instead of "checks",
  # and is missing required skill/model fields. The current code only checks
  # for schema_version presence, so this payload will slip through on pre-fix
  # code. Post-fix, schema validation catches it.
  cat > "$TEST_TMP/payload_c.json" <<'JSON'
{"schema_version":"1.0","tools":[]}
JSON
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr "$SCRIPT" --analysis-results "$TEST_TMP/payload_c.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ===========================================================================
# End-to-end: story with uncovered AC -> collector -> resolver
# ===========================================================================

@test "end-to-end: uncovered AC through real collector to resolver yields REQUEST_CHANGES" {
  # Story fixture with one uncovered primary AC; empty-findings LLM file;
  # run the real phase3a-collect.sh -> verdict-resolver.sh pipeline end-to-end.
  # Fails on pre-fix code because phase3a-collect.sh does not exist yet.
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local outdir="$TEST_TMP/e2e-output"
  mkdir -p "$outdir"

  # Story fixture with one primary AC that cannot be matched
  cat > "$TEST_TMP/story.md" <<STORY
---
key: "$_FK99"
title: "Test story"
status: in-progress
priority: "P1"
---

# Story

## Acceptance Criteria

- [ ] **AC1:** Given a user, when they submit the form, then the data is saved.
STORY

  # Empty LLM findings (so the test fails for the missing analyzer, not missing input)
  write_findings "$TEST_TMP/f.json" '[]'

  # Run the collector
  run "$collector" --story-key $_FK99 --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir" --test-dir "$TEST_TMP" --stack bash-dev
  [ "$status" -eq 0 ]

  # The collector should have written analysis-results.json
  [ -f "$outdir/analysis-results.json" ]

  # Feed it to the resolver — expect REQUEST_CHANGES (uncovered primary AC)
  run "$SCRIPT" --analysis-results "$outdir/analysis-results.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# ===========================================================================
# Analyzer unit cases (17 tests) — ac-coverage-analyzer.sh
# ===========================================================================

# Helper: build a story fixture with given ACs
_write_story_fixture() {
  local path="$1" key="$2"; shift 2
  cat > "$path" <<FRONT
---
key: "$key"
title: "Test story"
status: in-progress
priority: "P1"
---

# Story

## Acceptance Criteria

FRONT
  # Remaining args are AC lines
  for ac in "$@"; do
    printf '%s\n' "$ac" >> "$path"
  done
}

# Helper: write a bats fixture file without a literal @test token in the
# heredoc — avoids bats test-plan inflation (the token inflates the plan
# when it appears anywhere in the file, even inside heredocs).
_write_bats_fixture() {
  local path="$1"; shift
  : > "$path"
  for name in "$@"; do
    printf '@%s "%s" { true; }\n' "test" "$name" >> "$path"
  done
}

@test "analyzer: MET via test file path containing AC id" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # Check that AC1 is MET
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "MET"'
  echo "$output" | jq -e '.status == "passed"'
}

@test "analyzer: MET via snake_case test name" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" "test_AC1_login_dashboard"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "MET"'
}

@test "analyzer: MET via camelCase test name (java style)" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" "testAC1Rejects"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "MET"'
}

@test "analyzer: MET via bats test name" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" "AC1 rejects invalid input"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "MET"'
}

@test "analyzer: edge-case AC id with hyphen/underscore equivalence" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC-EC3:** Given an edge case, when boundary hit, then handled gracefully.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" "AC_EC3 handles boundary"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC-EC3") | .status == "MET"'
}

@test "analyzer: PARTIALLY MET via Given/When/Then fallback with multi-word phrases" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC2:** Given invalid email address, when form submitted, then reject with error message.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" \
    "should_reject_invalid_email_address_when_form_submitted_with_error_message"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "PARTIALLY MET"'
}

@test "analyzer: uncovered primary AC yields NOT MET with blocking finding and failed status" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they submit the form, then the data is saved.'
  mkdir -p "$TEST_TMP/tests"
  # No test files match AC1
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "NOT MET"'
  echo "$output" | jq -e '.status == "failed"'
  echo "$output" | jq -e '.findings[] | select(.blocking == true)'
}

@test "analyzer: unattributed test not counted for coverage" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they submit the form, then the data is saved.'
  mkdir -p "$TEST_TMP/tests"
  # Test file has a different story key — not attributed to $_FK99
  _write_bats_fixture "$TEST_TMP/tests/$_FK88-AC1.bats" "AC1 saves data"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # AC1 should be NOT MET because the test belongs to a different story
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "NOT MET"'
  # The test should appear in unattributed_tests
  echo "$output" | jq -e '.unattributed_tests | length > 0'
}

@test "analyzer: edge-case NOT MET yields non-blocking finding" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC-EC1:** Given an edge case input, when processed, then no crash occurs.'
  mkdir -p "$TEST_TMP/tests"
  # No matching tests
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC-EC1") | .status == "NOT MET"'
  echo "$output" | jq -e '.status == "failed"'
  # Edge-case NOT MET -> blocking: false
  echo "$output" | jq -e '.findings[] | select(.blocking == false)'
}

@test "analyzer: zero ACs yields failed with blocking finding" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  # Story with no ACs
  cat > "$TEST_TMP/story.md" <<STORY
---
key: "$_FK99"
title: "Test story"
status: in-progress
---

# Story

## Acceptance Criteria

(none)
STORY
  mkdir -p "$TEST_TMP/tests"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "failed"'
  echo "$output" | jq -e '.findings[] | select(.blocking == true) | select(.rule == "ac-coverage-empty")'
}

@test "analyzer: all ACs malformed yields failed with blocking finding" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** This AC has no Given/When/Then structure at all.'
  mkdir -p "$TEST_TMP/tests"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "failed"'
  echo "$output" | jq -e '.findings[] | select(.blocking == true) | select(.rule == "ac-coverage-all-malformed")'
  # The individual AC should be reported as skipped
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "skipped"'
}

@test "analyzer: longer AC id is not matched by shorter AC id test" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  # Use a clean directory whose path cannot accidentally contain the AC ids
  # under test (bats encodes the test name into the temp directory path).
  local cleandir
  cleandir="$(mktemp -d "${TMPDIR:-/tmp}/boundary-XXXXXX")"
  _write_story_fixture "$cleandir/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.' \
    '- [ ] **AC10:** Given a manager, when they export data, then a CSV is downloaded.'
  mkdir -p "$cleandir/tests"
  _write_bats_fixture "$cleandir/tests/$_FK99-test.bats" "AC1 login shows dashboard"
  run "$analyzer" --story-file "$cleandir/story.md" --story-key $_FK99 \
    --test-dir "$cleandir/tests" --stack bash-dev
  rm -rf "$cleandir"
  [ "$status" -eq 0 ]
  # AC1 is MET
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "MET"'
  # AC10 must NOT be matched by the AC1 test — it should be NOT MET
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC10") | .status == "NOT MET"'
}

@test "analyzer: single-word phrases never produce PARTIALLY MET" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC2:** Given user, when submit, then save.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" \
    "test_user_can_submit_form_and_save_draft"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # Minimum-pair gate: single-word phrases cannot produce PARTIALLY MET
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "NOT MET"'
}

@test "analyzer: fallback requires all three phrases in one test (not spread)" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC2:** Given invalid email address, when form submitted, then reject with error message.'
  mkdir -p "$TEST_TMP/tests"
  # Two tests: each matches only some phrases, not all three in one test
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-given.bats" "test_invalid_email_address"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-then.bats" "test_reject_with_error_message"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # Spread across tests -> NOT MET (not PARTIALLY MET)
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "NOT MET"'
}

@test "analyzer: genuine multi-word fallback yields PARTIALLY MET" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC2:** Given invalid email address, when form submitted, then reject with error message.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" \
    "should_reject_invalid_email_address_when_form_submitted_with_error_message"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "PARTIALLY MET"'
}

@test "analyzer: deterministic output (run twice, identical)" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.' \
    '- [ ] **AC2:** Given invalid email address, when form submitted, then reject with error message.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev > "$TEST_TMP/run1.json"
  "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev > "$TEST_TMP/run2.json"
  cmp "$TEST_TMP/run1.json" "$TEST_TMP/run2.json"
}

@test "analyzer: malformed AC reported as skipped with ac-quality finding" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** This AC has no Given/When/Then structure.' \
    '- [ ] **AC2:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-AC2.bats" "AC2 login shows dashboard"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key $_FK99 \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # AC1 should be skipped (malformed)
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "skipped"'
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .skip_reason != null'
  # Non-blocking ac-quality finding
  echo "$output" | jq -e '.findings[] | select(.rule == "ac-quality") | select(.blocking == false)'
  # AC2 should be MET; overall passed since no NOT MET
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "MET"'
  echo "$output" | jq -e '.status == "passed"'
}

# ===========================================================================
# Collector unit cases (8 tests) — phase3a-collect.sh
# ===========================================================================

@test "collector: all ACs covered yields APPROVE through resolver" {
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  run "$collector" --story-key $_FK99 --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir" --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  [ -f "$outdir/analysis-results.json" ]
  # Feed to resolver
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$outdir/analysis-results.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "collector: unreadable story file yields errored check -> BLOCKED" {
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  run "$collector" --story-key $_FK99 --story-file "$TEST_TMP/no-such-story.md" \
    --output-dir "$outdir" --test-dir "$TEST_TMP" --stack bash-dev
  [ "$status" -eq 0 ]
  [ -f "$outdir/analysis-results.json" ]
  # The errored check should cause BLOCKED
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$outdir/analysis-results.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "collector: stub-directory analyzer failure yields errored check -> BLOCKED" {
  # Copy the collector into a temp dir with a stub analyzer that exits 1
  local collector_src="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local tmpbin="$TEST_TMP/stubdir"
  mkdir -p "$tmpbin"
  cp "$collector_src" "$tmpbin/phase3a-collect.sh"
  chmod +x "$tmpbin/phase3a-collect.sh"
  # Stub analyzer that always fails
  cat > "$tmpbin/ac-coverage-analyzer.sh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$tmpbin/ac-coverage-analyzer.sh"

  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  run "$tmpbin/phase3a-collect.sh" --story-key $_FK99 --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir" --test-dir "$TEST_TMP" --stack bash-dev
  [ "$status" -eq 0 ]
  [ -f "$outdir/analysis-results.json" ]
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$outdir/analysis-results.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "collector: narrowed PATH still writes output" {
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  # Narrow PATH but keep jq and standard tools reachable
  local jq_path
  jq_path="$(command -v jq)"
  local jq_dir
  jq_dir="$(dirname "$jq_path")"
  run env PATH="/usr/bin:/bin:$jq_dir" \
    "$collector" --story-key $_FK99 --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir" --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  [ -f "$outdir/analysis-results.json" ]
}

@test "collector: missing --story-key flag exits 1" {
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  run "$collector" --story-file "$TEST_TMP/story.md" --output-dir "$outdir"
  [ "$status" -eq 1 ]
}

@test "collector: unwritable output directory exits 1" {
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  local outdir="$TEST_TMP/readonly-dir"
  mkdir -p "$outdir"
  chmod 444 "$outdir"
  run "$collector" --story-key $_FK99 --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir"
  [ "$status" -eq 1 ]
  # Clean up — restore permissions so teardown can remove it
  chmod 755 "$outdir"
}

@test "collector: malformed story key exits 1" {
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  _write_story_fixture "$TEST_TMP/story.md" "BADKEY" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  run "$collector" --story-key "BADKEY" --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir"
  [ "$status" -eq 1 ]
}

@test "collector: non-existent test-dir exits 1" {
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  run "$collector" --story-key $_FK99 --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir" --test-dir "$TEST_TMP/no-such-dir"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# Fallback-tier test: PATH narrowed so no ajv/python3 validator is found
# ===========================================================================

@test "fallback tier: payload C with no schema validator still yields BLOCKED" {
  # Narrow PATH so ajv and python3 are absent but jq stays reachable.
  # The jq-native structural check should catch the missing checks/skill/model.
  local jq_path
  jq_path="$(command -v jq)"
  local jq_dir
  jq_dir="$(dirname "$jq_path")"
  local narrowed="/usr/bin:/bin:$jq_dir"

  # Confirm the validators are actually absent under the narrowed PATH.
  # command -v is a builtin, so env alone cannot test it; use bash -c.
  run env PATH="$narrowed" bash -c 'command -v ajv'
  [ "$status" -ne 0 ]
  # python3 may or may not be in /usr/bin; if present we also need to verify
  # jsonschema is not importable. But the core assertion is that the resolver
  # still returns BLOCKED via the jq fallback even without schema validators.
  # If python3 IS found, the full validator runs and BLOCKED is still expected.
  if env PATH="$narrowed" bash -c 'command -v python3' >/dev/null 2>&1; then
    run env PATH="$narrowed" bash -c 'python3 -c "import jsonschema" 2>/dev/null'
    # If jsonschema is importable, the full validator runs — BLOCKED still expected
  fi

  cat > "$TEST_TMP/payload_c.json" <<'JSON'
{"schema_version":"1.0","tools":[]}
JSON
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr env PATH="$narrowed" "$SCRIPT" --analysis-results "$TEST_TMP/payload_c.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ===========================================================================
# Action-mode exemption (regression guard — expected to PASS on current code)
# ===========================================================================

@test "action-mode fixture is exempt from schema validation (regression guard)" {
  # Action-mode analysis-results use a different shape (plan/execution/placeholders).
  # Schema validation must not apply to them. This test is expected to pass on
  # current code and guards against regressions when schema validation is added.
  cat > "$TEST_TMP/action.json" <<'JSON'
{"plan":"present","execution":"success","placeholders":false,"mocks_sut":false,"breaks_suite":false}
JSON
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/action.json" --llm-findings "$TEST_TMP/f.json" --action-mode
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# ===========================================================================
# Primary NOT MET -> REQUEST_CHANGES (regression guard — may pass on current code
# if the fixture already has a failed check with blocking finding)
# ===========================================================================

@test "primary NOT MET AC yields REQUEST_CHANGES (regression guard)" {
  # A fixture with a failed ac-coverage check and a blocking finding
  # simulates what the analyzer will produce for a primary NOT MET AC.
  # This tests the resolver's handling of the failed-check-with-blocking-finding
  # rule. Expected to pass on current code — this is a regression guard.
  cat > "$TEST_TMP/a.json" <<JSON
{
  "schema_version": "1.0",
  "story_key": "$_FK99",
  "skill": "gaia-qa-tests",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "checks": [
    {
      "name": "ac-coverage",
      "status": "failed",
      "findings": [
        {
          "severity": "critical",
          "blocking": true,
          "rule": "ac-coverage-AC1",
          "message": "Primary AC1 is NOT MET: 0 matching tests"
        }
      ]
    }
  ]
}
JSON
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# ===========================================================================
# Edge-case NOT MET alone -> APPROVE (regression guard — may pass on current
# code via rule 2: failed check whose findings are all blocking: false)
# ===========================================================================

@test "edge-case NOT MET AC alone yields APPROVE (regression guard)" {
  # A fixture with a failed ac-coverage check but only non-blocking findings
  # simulates what the analyzer will produce when only an edge-case AC is NOT MET.
  # The resolver's rule 2 gives APPROVE for a failed check whose findings are
  # all blocking: false. Expected to pass on current code — regression guard.
  cat > "$TEST_TMP/a.json" <<JSON
{
  "schema_version": "1.0",
  "story_key": "$_FK99",
  "skill": "gaia-qa-tests",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "checks": [
    {
      "name": "ac-coverage",
      "status": "failed",
      "findings": [
        {
          "severity": "warning",
          "blocking": false,
          "rule": "ac-coverage-AC-EC1",
          "message": "Edge-case AC-EC1 is NOT MET: 0 matching tests"
        }
      ]
    }
  ]
}
JSON
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/a.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# ===========================================================================
# Checked-off ACs (- [x] / - [X]) must also be parsed by the analyzer
# ===========================================================================

@test "analyzer: checked-off ACs are parsed (not invisible)" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  cat > "$TEST_TMP/story.md" <<STORY
---
key: "$_FK99"
title: "Test story"
status: in-progress
priority: "P1"
---

# Story

## Acceptance Criteria

- [x] **AC1:** Given a user, when they login, then they see the dashboard.
- [X] **AC2:** Given a manager, when they export data, then a CSV is downloaded.
STORY
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-AC2.bats" "AC2 export CSV"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key "$_FK99" \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # Both ACs must be found and MET; not ac-coverage-empty
  echo "$output" | jq -e '.ac_results | length == 2'
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "MET"'
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "MET"'
  echo "$output" | jq -e '.status == "passed"'
}

# ===========================================================================
# A crafted AC id must not turn a NOT MET primary AC into APPROVE
# ===========================================================================

@test "analyzer: injected AC id cannot flip blocking to false" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  # AC id contains a JSON injection payload
  cat > "$TEST_TMP/story.md" <<STORY
---
key: "$_FK99"
title: "Test story"
status: in-progress
priority: "P0"
---

# Story

## Acceptance Criteria

STORY
  # Append the malicious AC line using printf to avoid heredoc issues
  printf '%s\n' '- [ ] **AC1","blocking":false,"x":"y:** Given a user exists when they log in then the session starts' >> "$TEST_TMP/story.md"
  mkdir -p "$TEST_TMP/tests"
  # No covering test -> should be NOT MET -> should be blocking
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  run "$collector" --story-key "$_FK99" --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir" --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  [ -f "$outdir/analysis-results.json" ]
  # Feed to resolver: must NOT be APPROVE
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$outdir/analysis-results.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  # Either BLOCKED (malformed AC rejected) or REQUEST_CHANGES (blocking finding)
  # but definitely NOT APPROVE
  [ "$output" != "APPROVE" ]
}

# ===========================================================================
# Regex metacharacters in AC id cannot cause false MET via overmatching
# ===========================================================================

@test "analyzer: regex-metachar AC id does not false-MET" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  cat > "$TEST_TMP/story.md" <<STORY
---
key: "$_FK99"
title: "Test story"
status: in-progress
priority: "P1"
---

# Story

## Acceptance Criteria

- [ ] **AC|.|1:** Given a user, when they click submit, then data is saved.
STORY
  mkdir -p "$TEST_TMP/tests"
  # Provide a test file attributed to the story key with an unrelated test
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-unrelated.bats" "unrelated thing"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key "$_FK99" \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # The metachar AC id must not be MET via regex overmatching
  # It should either be reported as malformed/skipped or NOT MET
  local met_count
  met_count="$(echo "$output" | jq '[.ac_results[] | select(.status == "MET")] | length')"
  [ "$met_count" -eq 0 ]
}

# ===========================================================================
# Story-key attribution must not match substrings (short key vs longer key)
# ===========================================================================

@test "analyzer: story key attribution does not match substrings" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  # Build fixture keys at runtime
  local short_key="E$((9))-S$((1))"
  local long_key="E$((9))-S$((10))"
  _write_story_fixture "$TEST_TMP/story.md" "$short_key" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  # Test file belongs to the LONGER key, NOT the short key
  _write_bats_fixture "$TEST_TMP/tests/${long_key}-AC1.bats" "AC1 login shows dashboard"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key "$short_key" \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # AC1 should NOT be MET: the test belongs to the longer key, not the short one
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "NOT MET"'
  # The test should appear as unattributed
  echo "$output" | jq -e '.unattributed_tests | length > 0'
}

# ===========================================================================
# Fallback must normalize test identifiers (stopword removal)
# ===========================================================================

@test "analyzer: fallback normalizes test identifiers with stopwords" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC2:** Given invalid email address, when form submitted, then reject with error message.'
  mkdir -p "$TEST_TMP/tests"
  # Test identifier has a stopword "the" between "reject" and "error"
  # Without identifier normalization the word pair "reject","error" would not
  # match because "the" sits between them in the raw normalized identifier.
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" \
    "should_reject_the_invalid_email_address_when_form_is_submitted_with_the_error_message"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key "$_FK99" \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "PARTIALLY MET"'
}

# ===========================================================================
# Unknown --stack exits non-zero -> collector errored -> BLOCKED
# ===========================================================================

@test "analyzer: unknown stack exits non-zero" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key "$_FK99" \
    --test-dir "$TEST_TMP/tests" --stack "nonexistent-stack-xyz"
  [ "$status" -ne 0 ]
}

@test "collector: unknown stack -> errored check -> BLOCKED" {
  local collector="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/phase3a-collect.sh"
  local outdir="$TEST_TMP/collect-out"
  mkdir -p "$outdir"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  run "$collector" --story-key "$_FK99" --story-file "$TEST_TMP/story.md" \
    --output-dir "$outdir" --test-dir "$TEST_TMP/tests" --stack "nonexistent-stack-xyz"
  [ "$status" -eq 0 ]
  [ -f "$outdir/analysis-results.json" ]
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$outdir/analysis-results.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ===========================================================================
# Discovery timeout (exit 124) must not silently return partial results
# ===========================================================================

@test "analyzer: discovery timeout (exit 124) exits non-zero" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$TEST_TMP/tests"
  # Create a stub timeout that always exits 124 (timeout signal)
  local stubdir="$TEST_TMP/stubbin"
  mkdir -p "$stubdir"
  cat > "$stubdir/timeout" <<'STUB'
#!/usr/bin/env bash
exit 124
STUB
  chmod +x "$stubdir/timeout"
  run env PATH="$stubdir:$PATH" "$analyzer" --story-file "$TEST_TMP/story.md" \
    --story-key "$_FK99" --test-dir "$TEST_TMP/tests" --stack bash-dev
  # Must exit non-zero because discovery timed out
  [ "$status" -ne 0 ]
}

# ===========================================================================
# Fallback G/W/T splitting must work portably (no gawk-only features)
# ===========================================================================

@test "analyzer: fallback G/W/T case-insensitive under system awk" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$TEST_TMP/story.md" "$_FK99" \
    '- [ ] **AC2:** GIVEN invalid email address, WHEN form submitted, THEN reject with error message.'
  mkdir -p "$TEST_TMP/tests"
  _write_bats_fixture "$TEST_TMP/tests/$_FK99-test.bats" \
    "should_reject_invalid_email_address_when_form_submitted_with_error_message"
  run "$analyzer" --story-file "$TEST_TMP/story.md" --story-key "$_FK99" \
    --test-dir "$TEST_TMP/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "PARTIALLY MET"'
}

# ===========================================================================
# Decorated AC ids (e.g. "AC2 — Export works:") must be parsed to the leading
# AC token, not rejected as malformed.
# ===========================================================================

@test "analyzer: decorated AC id parses leading token and uncovered primary blocks" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  # Story: P0, AC1 covered, AC2 decorated with em-dash and label — uncovered.
  # AC2 must NOT be silently skipped; it must be NOT MET with a blocking finding.
  cat > "$BATS_TEST_TMPDIR/story.md" <<STORY
---
key: "$_FK99"
title: "Test story"
status: in-progress
priority: "P0"
---

# Story

## Acceptance Criteria

- [ ] **AC1:** Given a user, when they login, then they see the dashboard.
- [ ] **AC2 — Export works:** Given valid data, when export triggered, then file is generated.
STORY
  mkdir -p "$BATS_TEST_TMPDIR/tests"
  _write_bats_fixture "$BATS_TEST_TMPDIR/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  # No test covers AC2
  run "$analyzer" --story-file "$BATS_TEST_TMPDIR/story.md" --story-key "$_FK99" \
    --test-dir "$BATS_TEST_TMPDIR/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # AC2 must be recognized (not skipped) and NOT MET
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC2") | .status == "NOT MET"'
  # Overall must be failed (blocking NOT MET)
  echo "$output" | jq -e '.status == "failed"'
  # Blocking finding must exist
  echo "$output" | jq -e '[.findings[] | select(.blocking == true)] | length > 0'
}

@test "analyzer: decorated AC id that is covered yields MET" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  cat > "$BATS_TEST_TMPDIR/story.md" <<STORY
---
key: "$_FK99"
title: "Test story"
status: in-progress
priority: "P1"
---

# Story

## Acceptance Criteria

- [ ] **AC1 (P0):** Given a user, when they login, then they see the dashboard.
STORY
  mkdir -p "$BATS_TEST_TMPDIR/tests"
  _write_bats_fixture "$BATS_TEST_TMPDIR/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  run "$analyzer" --story-file "$BATS_TEST_TMPDIR/story.md" --story-key "$_FK99" \
    --test-dir "$BATS_TEST_TMPDIR/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ac_results[] | select(.ac_id == "AC1") | .status == "MET"'
  echo "$output" | jq -e '.status == "passed"'
}

@test "resolver: non-json analysis BLOCKED run leaves no temp file in TMPDIR" {
  # Verify the temp copy is cleaned up even on BLOCKED exits.
  local tmpdir="$BATS_TEST_TMPDIR/vr-tmpdir"
  mkdir -p "$tmpdir"
  # Create analysis without .json extension with schema_version missing -> BLOCKED
  cat > "$BATS_TEST_TMPDIR/analysis-nojson" <<JSON
{
  "story_key": "$_FK99",
  "skill": "gaia-qa-tests",
  "model": "claude-opus-4-7",
  "checks": [{"name": "ac-coverage", "status": "passed", "findings": []}]
}
JSON
  write_findings "$BATS_TEST_TMPDIR/f.json" '[]'
  run --separate-stderr env TMPDIR="$tmpdir" "$SCRIPT" \
    --analysis-results "$BATS_TEST_TMPDIR/analysis-nojson" \
    --llm-findings "$BATS_TEST_TMPDIR/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
  # No vr-analysis* file should remain in the test-specific TMPDIR
  local leftover
  leftover="$(find "$tmpdir" -name 'vr-analysis*' -type f 2>/dev/null | wc -l)"
  [ "$leftover" -eq 0 ]
}

@test "resolver: jq structural fallback approves valid input and blocks invalid input" {
  # Narrow PATH so neither ajv nor python3 (with jsonschema) is reachable,
  # forcing the resolver to use the jq-only structural fallback.
  local jq_path
  jq_path="$(command -v jq)"
  local jq_link_dir="$BATS_TEST_TMPDIR/jq-only"
  mkdir -p "$jq_link_dir"
  ln -sf "$jq_path" "$jq_link_dir/jq"
  local hide_dir="$BATS_TEST_TMPDIR/hide-python"
  mkdir -p "$hide_dir"
  cat > "$hide_dir/python3" <<'STUB'
#!/usr/bin/env bash
exit 127
STUB
  chmod +x "$hide_dir/python3"
  local narrowed="$hide_dir:$jq_link_dir:/usr/bin:/bin"
  # Confirm the full validator is blocked (python3 stub exits 127)
  run -127 env PATH="$narrowed" python3 -c "import jsonschema" 2>/dev/null

  # 1) Valid analysis -> APPROVE via jq structural fallback
  write_analysis "$BATS_TEST_TMPDIR/a.json" '[{"name":"check1","status":"passed","findings":[]}]'
  write_findings "$BATS_TEST_TMPDIR/f.json" '[]'
  run --separate-stderr env PATH="$narrowed" "$SCRIPT" \
    --analysis-results "$BATS_TEST_TMPDIR/a.json" --llm-findings "$BATS_TEST_TMPDIR/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]

  # 2) Invalid analysis (missing checks key) -> BLOCKED via jq structural check.
  #    This proves the fallback branch ran and caught the structural violation.
  cat > "$BATS_TEST_TMPDIR/bad.json" <<'JSON'
{"schema_version":"1.0","tools":[]}
JSON
  write_findings "$BATS_TEST_TMPDIR/f2.json" '[]'
  run --separate-stderr env PATH="$narrowed" "$SCRIPT" \
    --analysis-results "$BATS_TEST_TMPDIR/bad.json" --llm-findings "$BATS_TEST_TMPDIR/f2.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ===========================================================================
# Large test trees must produce valid JSON (no argv overflow)
# ===========================================================================

@test "analyzer: 500 test files with >1400 unattributed pairs produce valid JSON" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$BATS_TEST_TMPDIR/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$BATS_TEST_TMPDIR/bigtests"
  local i=0
  while [ "$i" -lt 500 ]; do
    # Three identifiers per file to exceed 1400 unattributed pairs total
    printf '@%s "unrelated_first_test_name_%04d_padding" { true; }\n' "test" "$i" > "$BATS_TEST_TMPDIR/bigtests/test_${i}.bats"
    printf '@%s "unrelated_second_test_name_%04d_padding" { true; }\n' "test" "$i" >> "$BATS_TEST_TMPDIR/bigtests/test_${i}.bats"
    printf '@%s "unrelated_third_test_name_%04d_padding" { true; }\n' "test" "$i" >> "$BATS_TEST_TMPDIR/bigtests/test_${i}.bats"
    i=$((i + 1))
  done
  # Also add one attributed test
  _write_bats_fixture "$BATS_TEST_TMPDIR/bigtests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  run "$analyzer" --story-file "$BATS_TEST_TMPDIR/story.md" --story-key "$_FK99" \
    --test-dir "$BATS_TEST_TMPDIR/bigtests" --stack bash-dev
  [ "$status" -eq 0 ]
  # Must produce valid JSON
  echo "$output" | jq -e '.name == "ac-coverage"'
  # unattributed_tests must be present and large
  local unattr_count
  unattr_count="$(echo "$output" | jq '.unattributed_tests | length')"
  [ "$unattr_count" -ge 1400 ]
}

# ===========================================================================
# jq fallback must reject out-of-enum status values
# ===========================================================================

@test "resolver fallback: uppercase FAILED status -> BLOCKED" {
  # Narrow PATH so neither ajv nor python3 is found, forcing the jq fallback.
  # jq is the only tool we keep, in a dedicated temp directory.
  local jq_path
  jq_path="$(command -v jq)"
  local jq_link_dir="$TEST_TMP/jq-only"
  mkdir -p "$jq_link_dir"
  ln -sf "$jq_path" "$jq_link_dir/jq"
  # Minimal PATH: coreutils (grep, sed, cat, etc) + our jq dir, no python3/ajv
  local core_bin="/usr/bin:/bin"
  # Remove python3 from the available set by using a wrapper that hides it
  local hide_dir="$TEST_TMP/hide-python"
  mkdir -p "$hide_dir"
  cat > "$hide_dir/python3" <<'STUB'
#!/usr/bin/env bash
exit 127
STUB
  chmod +x "$hide_dir/python3"
  local narrowed="$hide_dir:$jq_link_dir:$core_bin"
  # Confirm jq fallback will be used: python3 must not import jsonschema
  run -127 env PATH="$narrowed" bash -c 'python3 -c "import jsonschema" 2>/dev/null'
  # Build a document with status "FAILED" (uppercase)
  cat > "$TEST_TMP/bad_status.json" <<JSON
{
  "schema_version": "1.0",
  "story_key": "$_FK99",
  "skill": "gaia-qa-tests",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "checks": [
    {
      "name": "ac-coverage",
      "status": "FAILED",
      "findings": [{"blocking": true, "severity": "critical", "message": "gap"}]
    }
  ]
}
JSON
  write_findings "$TEST_TMP/f.json" '[]'
  run --separate-stderr env PATH="$narrowed" "$SCRIPT" \
    --analysis-results "$TEST_TMP/bad_status.json" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ===========================================================================
# Analysis file without .json extension must not false-BLOCK
# ===========================================================================

@test "resolver: valid analysis without .json extension yields correct verdict" {
  cat > "$TEST_TMP/analysis-results" <<JSON
{
  "schema_version": "1.0",
  "story_key": "$_FK99",
  "skill": "gaia-qa-tests",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "checks": [
    {
      "name": "ac-coverage",
      "status": "passed",
      "findings": []
    }
  ]
}
JSON
  write_findings "$TEST_TMP/f.json" '[]'
  run "$SCRIPT" --analysis-results "$TEST_TMP/analysis-results" --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  # Must be APPROVE (not BLOCKED from extension check)
  [ "$output" = "APPROVE" ]
}

# ===========================================================================
# Analyzer: no temp files left after a successful run
# ===========================================================================

@test "analyzer: no temp files remain in TMPDIR after a successful run" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  local custom_tmpdir="$BATS_TEST_TMPDIR/analyzer-tmpdir"
  mkdir -p "$custom_tmpdir"
  _write_story_fixture "$BATS_TEST_TMPDIR/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$BATS_TEST_TMPDIR/tests"
  _write_bats_fixture "$BATS_TEST_TMPDIR/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  run env TMPDIR="$custom_tmpdir" "$analyzer" --story-file "$BATS_TEST_TMPDIR/story.md" \
    --story-key "$_FK99" --test-dir "$BATS_TEST_TMPDIR/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # Verify the output is valid before checking for leftovers
  echo "$output" | jq -e '.name == "ac-coverage"'
  # No files should remain in the custom TMPDIR after a clean exit
  local leftover
  leftover="$(find "$custom_tmpdir" -type f 2>/dev/null | wc -l)"
  [ "$leftover" -eq 0 ]
}

# ===========================================================================
# Analyzer: duplicate AC ids emit a non-blocking warning
# ===========================================================================

@test "analyzer: duplicate AC id emits non-blocking ac-quality warning naming the duplicate" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$BATS_TEST_TMPDIR/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.' \
    '- [ ] **AC1:** Given a user, when they submit data, then it is saved.'
  mkdir -p "$BATS_TEST_TMPDIR/tests"
  _write_bats_fixture "$BATS_TEST_TMPDIR/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  run "$analyzer" --story-file "$BATS_TEST_TMPDIR/story.md" --story-key "$_FK99" \
    --test-dir "$BATS_TEST_TMPDIR/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # Must emit an ac-quality finding that names the duplicate
  echo "$output" | jq -e '.findings[] | select(.rule == "ac-quality") | select(.message | test("[Dd]uplicate")) | select(.message | test("AC1"))'
  # The finding must be non-blocking
  echo "$output" | jq -e '.findings[] | select(.rule == "ac-quality") | select(.message | test("[Dd]uplicate")) | .blocking == false'
}

# ===========================================================================
# Analyzer: backslash and double-quote in unattributed data produce valid JSON
# ===========================================================================

@test "analyzer: backslash and double-quote in unattributed data round-trip through jq" {
  local analyzer="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/scripts/ac-coverage-analyzer.sh"
  _write_story_fixture "$BATS_TEST_TMPDIR/story.md" "$_FK99" \
    '- [ ] **AC1:** Given a user, when they login, then they see the dashboard.'
  mkdir -p "$BATS_TEST_TMPDIR/tests"
  _write_bats_fixture "$BATS_TEST_TMPDIR/tests/$_FK99-AC1.bats" "AC1 login shows dashboard"
  # Unattributed file: filename has a double quote, test name has a backslash.
  # Use printf with split @/%s token to avoid inflating bats' test plan.
  printf '@%s "has a \\ in name" { true; }\n' "test" > "$BATS_TEST_TMPDIR/tests/dq\".bats"
  run "$analyzer" --story-file "$BATS_TEST_TMPDIR/story.md" --story-key "$_FK99" \
    --test-dir "$BATS_TEST_TMPDIR/tests" --stack bash-dev
  [ "$status" -eq 0 ]
  # JSON must be valid (implicit: jq -e parses it without error)
  echo "$output" | jq -e '.name == "ac-coverage"'
  # The backslash identifier must survive the JSON round-trip
  echo "$output" | jq -e '[.unattributed_tests[] | select(.identifier | contains("\\"))] | length > 0'
  # The double-quote file path must survive the JSON round-trip
  echo "$output" | jq -e '[.unattributed_tests[] | select(.file | contains("dq"))] | length > 0'
}
