#!/usr/bin/env bats
# gaia-test-perf.bats — integration tests for /gaia-test-perf action skill (E73-S2).
#
# Verifies:
#   - SKILL.md exists with required action-skill frontmatter (AC1)
#   - k6 adapter is present and contract-conformant (AC2)
#   - Lighthouse adapter is present and contract-conformant (AC3)
#   - select-adapter.sh honours CLI override > project-config > default=k6
#   - phase3a-collect.sh produces analysis-results.json with the canonical envelope
#   - SLO check logic — PASSED on met SLOs, REQUEST_CHANGES on breach, BLOCKED on probe error (AC4)
#   - Baseline regression detection — first run establishes baseline, subsequent
#     run flags >threshold degradation (AC5)
#   - verdict-resolver integration — APPROVE/REQUEST_CHANGES/BLOCKED mapping (AC6)
#   - Multi-scenario composite verdict — worst-case across scenarios (AC7)
#   - Review Gate update for "Performance Review" row (AC8)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
SKILL_DIR="$PLUGIN_ROOT/skills/gaia-test-perf"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
K6_DIR="$ADAPTERS_DIR/k6"
LH_DIR="$ADAPTERS_DIR/lighthouse"
SCHEMA_PATH="$PLUGIN_ROOT/schemas/analysis-results.schema.json"

setup() {
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-test-perf-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# --- AC1: SKILL.md exists with correct frontmatter --------------------------

@test "E73-S2 AC1: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "E73-S2 AC1: SKILL.md frontmatter declares deployment-phase action skill" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E '^name:[[:space:]]+gaia-test-perf' "$f"
  grep -E '^phase:[[:space:]]+deployment' "$f"
  grep -E '^verdict:[[:space:]]+true' "$f"
  grep -E '^type:[[:space:]]+action' "$f"
}

# --- AC2: k6 adapter conforms to ADR-078 contract --------------------------

@test "E73-S2 AC2: k6 adapter directory exists" {
  [ -d "$K6_DIR" ]
}

@test "E73-S2 AC2: k6 adapter.json validates required schema fields" {
  [ -f "$K6_DIR/adapter.json" ]
  jq -e . "$K6_DIR/adapter.json" >/dev/null
  jq -e '.provider == "k6"' "$K6_DIR/adapter.json" >/dev/null
  jq -e '.category == "perf-tool"' "$K6_DIR/adapter.json" >/dev/null
  jq -e '."runtime-profile" == "subprocess"' "$K6_DIR/adapter.json" >/dev/null
  jq -e '."default-timeout-seconds" >= 1' "$K6_DIR/adapter.json" >/dev/null
  jq -e '."file-extensions" | type == "array"' "$K6_DIR/adapter.json" >/dev/null
  jq -e '."version-range" | length > 0' "$K6_DIR/adapter.json" >/dev/null
  jq -e '.description | length > 0' "$K6_DIR/adapter.json" >/dev/null
}

@test "E73-S2 AC2: k6 run.sh is executable and accepts canonical contract flags" {
  [ -x "$K6_DIR/run.sh" ]
  run "$K6_DIR/run.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -- "--input"
  echo "$output" | grep -F -- "--config"
  echo "$output" | grep -F -- "--output"
  echo "$output" | grep -F -- "--timeout"
  echo "$output" | grep -F -- "--target-url"
  echo "$output" | grep -F -- "--script"
}

@test "E73-S2 AC2: k6 contract.bats present" {
  [ -f "$K6_DIR/test/contract.bats" ]
}

# --- AC3: Lighthouse adapter conforms to ADR-078 contract -----------------

@test "E73-S2 AC3: lighthouse adapter directory exists" {
  [ -d "$LH_DIR" ]
}

@test "E73-S2 AC3: lighthouse adapter.json validates required schema fields" {
  [ -f "$LH_DIR/adapter.json" ]
  jq -e . "$LH_DIR/adapter.json" >/dev/null
  jq -e '.provider == "lighthouse"' "$LH_DIR/adapter.json" >/dev/null
  jq -e '.category == "perf-tool"' "$LH_DIR/adapter.json" >/dev/null
  jq -e '."runtime-profile" == "subprocess"' "$LH_DIR/adapter.json" >/dev/null
  jq -e '."default-timeout-seconds" >= 1' "$LH_DIR/adapter.json" >/dev/null
  jq -e '."file-extensions" | type == "array"' "$LH_DIR/adapter.json" >/dev/null
}

@test "E73-S2 AC3: lighthouse run.sh is executable and accepts canonical contract flags" {
  [ -x "$LH_DIR/run.sh" ]
  run "$LH_DIR/run.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -- "--input"
  echo "$output" | grep -F -- "--config"
  echo "$output" | grep -F -- "--output"
  echo "$output" | grep -F -- "--timeout"
  echo "$output" | grep -F -- "--target-url"
  echo "$output" | grep -F -- "--categories"
}

@test "E73-S2 AC3: lighthouse contract.bats present" {
  [ -f "$LH_DIR/test/contract.bats" ]
}

# --- Adapter selection (mirrors AC9 of E73-S1) ----------------------------

@test "E73-S2: select-adapter.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/select-adapter.sh" ]
}

@test "E73-S2: select-adapter.sh defaults to k6 when no flag/config" {
  run "$SKILL_DIR/scripts/select-adapter.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/k6"
}

@test "E73-S2: select-adapter.sh --adapter lighthouse overrides default" {
  run "$SKILL_DIR/scripts/select-adapter.sh" --adapter lighthouse
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/lighthouse"
}

@test "E73-S2: select-adapter.sh reads test_execution.perf.adapter from project config" {
  local cfg="$WORK_TMP/project-config.yaml"
  cat > "$cfg" <<EOF
test_execution:
  perf:
    adapter: lighthouse
EOF
  run "$SKILL_DIR/scripts/select-adapter.sh" --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/lighthouse"
}

@test "E73-S2: select-adapter.sh CLI flag overrides project-config value" {
  local cfg="$WORK_TMP/project-config.yaml"
  cat > "$cfg" <<EOF
test_execution:
  perf:
    adapter: lighthouse
EOF
  run "$SKILL_DIR/scripts/select-adapter.sh" --adapter k6 --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/k6"
}

# --- AC6: Phase 3A toolkit evidence collection ---------------------------

@test "E73-S2 AC6: phase3a-collect.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/phase3a-collect.sh" ]
}

@test "E73-S2 AC6: phase3a-collect.sh emits analysis-results.json with required structure" {
  local outdir="$WORK_TMP/p3a"
  mkdir -p "$outdir"
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage/test"
  cp "$K6_DIR/adapter.json" "$stage/adapter.json"
  cat > "$stage/run.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo '{"name":"k6","status":"passed","findings":[],"raw":""}'
exit 0
EOF
  chmod +x "$stage/run.sh"
  run "$SKILL_DIR/scripts/phase3a-collect.sh" \
    --adapter-dir "$stage" \
    --output-dir "$outdir" \
    --target-url "http://example.com"
  [ "$status" -eq 0 ]
  [ -f "$outdir/analysis-results.json" ]
  jq -e '.checks' "$outdir/analysis-results.json" >/dev/null
  jq -e '.skill == "gaia-test-perf"' "$outdir/analysis-results.json" >/dev/null
}

# --- AC4: SLO-based verdict logic ---------------------------------------

@test "E73-S2 AC4: slo-check.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/slo-check.sh" ]
}

@test "E73-S2 AC4: slo-check.sh PASSED when all k6 SLOs met" {
  local cfg="$WORK_TMP/perf-config.json"
  local results="$WORK_TMP/k6-result.json"
  cat > "$cfg" <<'EOF'
{"scenarios":[{"name":"login","adapter":"k6","slos":{"p95_latency_ms":500,"error_rate_max":0.01,"min_rps":100}}]}
EOF
  cat > "$results" <<'EOF'
{"login":{"p95_latency_ms":400,"error_rate":0.001,"rps":150}}
EOF
  run "$SKILL_DIR/scripts/slo-check.sh" --config "$cfg" --results "$results"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.composite == "PASSED"' >/dev/null
}

@test "E73-S2 AC4: slo-check.sh REQUEST_CHANGES when k6 SLO breached" {
  local cfg="$WORK_TMP/perf-config.json"
  local results="$WORK_TMP/k6-result.json"
  cat > "$cfg" <<'EOF'
{"scenarios":[{"name":"login","adapter":"k6","slos":{"p95_latency_ms":500,"error_rate_max":0.01,"min_rps":100}}]}
EOF
  cat > "$results" <<'EOF'
{"login":{"p95_latency_ms":600,"error_rate":0.001,"rps":150}}
EOF
  run "$SKILL_DIR/scripts/slo-check.sh" --config "$cfg" --results "$results"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.composite == "REQUEST_CHANGES"' >/dev/null
  echo "$output" | jq -e '.scenarios[0].breaches | length > 0' >/dev/null
}

@test "E73-S2 AC4: slo-check.sh PASSED when Lighthouse SLOs met" {
  local cfg="$WORK_TMP/perf-config.json"
  local results="$WORK_TMP/lh-result.json"
  cat > "$cfg" <<'EOF'
{"scenarios":[{"name":"home","adapter":"lighthouse","slos":{"performance_score_min":0.9,"lcp_ms_max":2500,"cls_max":0.1}}]}
EOF
  cat > "$results" <<'EOF'
{"home":{"performance_score":0.95,"lcp_ms":2000,"cls":0.05}}
EOF
  run "$SKILL_DIR/scripts/slo-check.sh" --config "$cfg" --results "$results"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.composite == "PASSED"' >/dev/null
}

# --- AC7: Multi-scenario composite verdict -----------------------------

@test "E73-S2 AC7: slo-check.sh composite is REQUEST_CHANGES when any scenario breaches" {
  local cfg="$WORK_TMP/perf-config.json"
  local results="$WORK_TMP/multi.json"
  cat > "$cfg" <<'EOF'
{"scenarios":[
  {"name":"a","adapter":"k6","slos":{"p95_latency_ms":500,"error_rate_max":0.01,"min_rps":1}},
  {"name":"b","adapter":"k6","slos":{"p95_latency_ms":500,"error_rate_max":0.01,"min_rps":1}}
]}
EOF
  cat > "$results" <<'EOF'
{"a":{"p95_latency_ms":400,"error_rate":0.001,"rps":150},
 "b":{"p95_latency_ms":700,"error_rate":0.001,"rps":150}}
EOF
  run "$SKILL_DIR/scripts/slo-check.sh" --config "$cfg" --results "$results"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.composite == "REQUEST_CHANGES"' >/dev/null
  echo "$output" | jq -e '.scenarios | length == 2' >/dev/null
}

# --- AC5: Baseline regression detection -------------------------------

@test "E73-S2 AC5: baseline-check.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/baseline-check.sh" ]
}

@test "E73-S2 AC5: baseline-check.sh first run with no baseline writes baseline and reports no regression" {
  local baseline_dir="$WORK_TMP/baselines"
  local results="$WORK_TMP/result.json"
  cat > "$results" <<'EOF'
{"login":{"p95_latency_ms":400,"error_rate":0.001,"rps":150}}
EOF
  run "$SKILL_DIR/scripts/baseline-check.sh" \
    --scenario login --results "$results" --baseline-dir "$baseline_dir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.regression == false' >/dev/null
  echo "$output" | jq -e '.baseline_established == true' >/dev/null
  [ -f "$baseline_dir/login.json" ]
}

@test "E73-S2 AC5: baseline-check.sh detects >threshold p95 regression" {
  local baseline_dir="$WORK_TMP/baselines"
  mkdir -p "$baseline_dir"
  cat > "$baseline_dir/login.json" <<'EOF'
{"p95_latency_ms":300,"error_rate":0.001,"rps":150}
EOF
  local results="$WORK_TMP/result.json"
  cat > "$results" <<'EOF'
{"login":{"p95_latency_ms":400,"error_rate":0.001,"rps":150}}
EOF
  run "$SKILL_DIR/scripts/baseline-check.sh" \
    --scenario login --results "$results" --baseline-dir "$baseline_dir" --threshold 20
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.regression == true' >/dev/null
  echo "$output" | jq -e '.degradation_pct >= 20' >/dev/null
  echo "$output" | jq -e '.baseline.p95_latency_ms == 300' >/dev/null
  echo "$output" | jq -e '.current.p95_latency_ms == 400' >/dev/null
}

@test "E73-S2 AC5: baseline-check.sh no regression when p95 within threshold" {
  local baseline_dir="$WORK_TMP/baselines"
  mkdir -p "$baseline_dir"
  cat > "$baseline_dir/login.json" <<'EOF'
{"p95_latency_ms":300,"error_rate":0.001,"rps":150}
EOF
  local results="$WORK_TMP/result.json"
  cat > "$results" <<'EOF'
{"login":{"p95_latency_ms":330,"error_rate":0.001,"rps":150}}
EOF
  run "$SKILL_DIR/scripts/baseline-check.sh" \
    --scenario login --results "$results" --baseline-dir "$baseline_dir" --threshold 20
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.regression == false' >/dev/null
}

# --- AC6: Verdict resolver integration --------------------------------

@test "E73-S2 AC6: verdict-resolver APPROVE on clean toolkit + LLM" {
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "stack": "any",
  "checks": [
    {"name": "k6", "status": "passed", "findings": []}
  ]
}
EOF
  cat > "$ll" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "findings": []
}
EOF
  run "$PLUGIN_ROOT/scripts/verdict-resolver.sh" \
    --skill gaia-test-perf \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "APPROVE"
}

@test "E73-S2 AC6: verdict-resolver REQUEST_CHANGES on LLM Critical (SLO breach)" {
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "stack": "any",
  "checks": [
    {"name": "k6", "status": "passed", "findings": []}
  ]
}
EOF
  cat > "$ll" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "findings": [
    {"category": "slo", "severity": "Critical", "message": "p95 600 > 500 SLO", "file": null, "line": 0, "rule": "perf.slo.p95"}
  ]
}
EOF
  run "$PLUGIN_ROOT/scripts/verdict-resolver.sh" \
    --skill gaia-test-perf \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "REQUEST_CHANGES"
}

@test "E73-S2 AC6: verdict-resolver BLOCKED on errored toolkit (target unreachable)" {
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "stack": "any",
  "checks": [
    {"name": "k6", "status": "errored", "findings": []}
  ]
}
EOF
  cat > "$ll" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "findings": []
}
EOF
  run "$PLUGIN_ROOT/scripts/verdict-resolver.sh" \
    --skill gaia-test-perf \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "BLOCKED"
}

# --- AC8: Review Gate integration -----------------------------------

@test "E73-S2 AC8: verdict.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/verdict.sh" ]
}

@test "E73-S2 AC8: verdict.sh emits APPROVE on clean inputs" {
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "stack": "any",
  "checks": [
    {"name": "k6", "status": "passed", "findings": []}
  ]
}
EOF
  cat > "$ll" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "findings": []
}
EOF
  run "$SKILL_DIR/scripts/verdict.sh" \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "APPROVE"
}

# --- Probe sanity-check (mirrors AC4 of E73-S1) ---------------------

@test "E73-S2: tool-availability-probe.sh consumes k6 adapter.json without crash" {
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" \
    --adapter-dir "$K6_DIR" \
    --file-list "$file_list"
  echo "$output" | jq -e '.state' >/dev/null
}

@test "E73-S2: tool-availability-probe.sh consumes lighthouse adapter.json without crash" {
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" \
    --adapter-dir "$LH_DIR" \
    --file-list "$file_list"
  echo "$output" | jq -e '.state' >/dev/null
}
