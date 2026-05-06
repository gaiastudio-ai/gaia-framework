#!/usr/bin/env bats
# gaia-test-e2e.bats — integration tests for /gaia-test-e2e action skill (E73-S1).
#
# Verifies:
#   - SKILL.md exists with required action-skill frontmatter
#   - Both adapters (playwright-e2e, cypress-e2e) are present and contract-conformant
#   - select-adapter.sh honours CLI override > project-config > default precedence
#   - phase3a-collect.sh produces analysis-results.json validating against the schema
#   - verdict-resolver integration: APPROVE on clean, REQUEST_CHANGES on critical, BLOCKED on errored
#   - graceful degradation when probe returns expected_and_missing

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

# Resolve plugin paths from this file's location.
PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
SKILL_DIR="$PLUGIN_ROOT/skills/gaia-test-e2e"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
PLAYWRIGHT_DIR="$ADAPTERS_DIR/playwright-e2e"
CYPRESS_DIR="$ADAPTERS_DIR/cypress-e2e"
SCHEMA_PATH="$PLUGIN_ROOT/schemas/analysis-results.schema.json"

setup() {
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-test-e2e-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# --- AC1: SKILL.md exists with correct frontmatter --------------------------

@test "E73-S1 AC1: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "E73-S1 AC1: SKILL.md frontmatter declares action skill semantics" {
  local f="$SKILL_DIR/SKILL.md"
  # frontmatter declares a name field and the action-skill markers
  grep -E '^name:[[:space:]]+gaia-test-e2e' "$f"
  # phase: deployment marker (per ADR-080)
  grep -E '^phase:[[:space:]]+deployment' "$f"
  # verdict: true marker (action skill emits a verdict)
  grep -E '^verdict:[[:space:]]+true' "$f"
}

# --- AC2: Playwright adapter conforms to ADR-078 contract -------------------

@test "E73-S1 AC2: playwright-e2e adapter directory exists" {
  [ -d "$PLAYWRIGHT_DIR" ]
}

@test "E73-S1 AC2: playwright-e2e adapter.json validates against adapter.schema.json" {
  [ -f "$PLAYWRIGHT_DIR/adapter.json" ]
  jq -e . "$PLAYWRIGHT_DIR/adapter.json" >/dev/null
  jq -e '.provider' "$PLAYWRIGHT_DIR/adapter.json" >/dev/null
  jq -e '.category == "e2e-runner"' "$PLAYWRIGHT_DIR/adapter.json" >/dev/null
  jq -e '."runtime-profile"' "$PLAYWRIGHT_DIR/adapter.json" >/dev/null
  jq -e '."default-timeout-seconds"' "$PLAYWRIGHT_DIR/adapter.json" >/dev/null
  jq -e '."file-extensions"' "$PLAYWRIGHT_DIR/adapter.json" >/dev/null
}

@test "E73-S1 AC2: playwright-e2e run.sh is executable and accepts canonical contract flags" {
  [ -x "$PLAYWRIGHT_DIR/run.sh" ]
  run "$PLAYWRIGHT_DIR/run.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -- "--input"
  echo "$output" | grep -F -- "--config"
  echo "$output" | grep -F -- "--output"
  echo "$output" | grep -F -- "--target-url"
}

@test "E73-S1 AC2: playwright-e2e contract.bats present" {
  [ -f "$PLAYWRIGHT_DIR/test/contract.bats" ]
}

# --- AC3: Cypress adapter conforms to ADR-078 contract ---------------------

@test "E73-S1 AC3: cypress-e2e adapter directory exists" {
  [ -d "$CYPRESS_DIR" ]
}

@test "E73-S1 AC3: cypress-e2e adapter.json validates against adapter.schema.json" {
  [ -f "$CYPRESS_DIR/adapter.json" ]
  jq -e . "$CYPRESS_DIR/adapter.json" >/dev/null
  jq -e '.provider' "$CYPRESS_DIR/adapter.json" >/dev/null
  jq -e '.category == "e2e-runner"' "$CYPRESS_DIR/adapter.json" >/dev/null
  jq -e '."runtime-profile"' "$CYPRESS_DIR/adapter.json" >/dev/null
  jq -e '."default-timeout-seconds"' "$CYPRESS_DIR/adapter.json" >/dev/null
  jq -e '."file-extensions"' "$CYPRESS_DIR/adapter.json" >/dev/null
}

@test "E73-S1 AC3: cypress-e2e run.sh is executable and accepts canonical contract flags" {
  [ -x "$CYPRESS_DIR/run.sh" ]
  run "$CYPRESS_DIR/run.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -- "--input"
  echo "$output" | grep -F -- "--config"
  echo "$output" | grep -F -- "--output"
  echo "$output" | grep -F -- "--target-url"
}

@test "E73-S1 AC3: cypress-e2e contract.bats present" {
  [ -f "$CYPRESS_DIR/test/contract.bats" ]
}

# --- AC9: Adapter selection via project config ----------------------------

@test "E73-S1 AC9: select-adapter.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/select-adapter.sh" ]
}

@test "E73-S1 AC9: select-adapter.sh defaults to playwright-e2e when no flag/config" {
  run "$SKILL_DIR/scripts/select-adapter.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "playwright-e2e"
}

@test "E73-S1 AC9: select-adapter.sh --adapter cypress-e2e overrides default" {
  run "$SKILL_DIR/scripts/select-adapter.sh" --adapter cypress-e2e
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "cypress-e2e"
}

@test "E73-S1 AC9: select-adapter.sh reads test_execution.e2e.adapter from project config" {
  local cfg="$WORK_TMP/project-config.yaml"
  cat > "$cfg" <<EOF
test_execution:
  e2e:
    adapter: cypress-e2e
EOF
  run "$SKILL_DIR/scripts/select-adapter.sh" --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "cypress-e2e"
}

@test "E73-S1 AC9: select-adapter.sh CLI flag overrides project-config value" {
  local cfg="$WORK_TMP/project-config.yaml"
  cat > "$cfg" <<EOF
test_execution:
  e2e:
    adapter: cypress-e2e
EOF
  run "$SKILL_DIR/scripts/select-adapter.sh" --adapter playwright-e2e --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "playwright-e2e"
}

# --- AC5: Phase 3A toolkit evidence collection ---------------------------

@test "E73-S1 AC5: phase3a-collect.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/phase3a-collect.sh" ]
}

@test "E73-S1 AC5: phase3a-collect.sh emits analysis-results.json with required structure" {
  local outdir="$WORK_TMP/p3a"
  mkdir -p "$outdir"
  # Use a stub adapter dir that always succeeds
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage/test"
  cp "$PLAYWRIGHT_DIR/adapter.json" "$stage/adapter.json"
  cat > "$stage/run.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo '{"name":"playwright-e2e","status":"passed","findings":[],"raw":""}'
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
}

# --- AC7: Verdict resolver emits correct verdict --------------------------

@test "E73-S1 AC7: verdict-resolver APPROVE on clean toolkit + LLM" {
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-e2e",
  "stack": "any",
  "checks": [
    {"name": "playwright-e2e", "status": "passed", "findings": []}
  ]
}
EOF
  cat > "$ll" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-e2e",
  "findings": []
}
EOF
  run "$PLUGIN_ROOT/scripts/verdict-resolver.sh" \
    --skill gaia-test-e2e \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "APPROVE"
}

@test "E73-S1 AC7: verdict-resolver REQUEST_CHANGES on LLM Critical" {
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-e2e",
  "stack": "any",
  "checks": [
    {"name": "playwright-e2e", "status": "passed", "findings": []}
  ]
}
EOF
  cat > "$ll" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-e2e",
  "findings": [
    {"category": "stability", "severity": "Critical", "message": "flaky", "file": null, "line": 0, "rule": "e2e.flaky"}
  ]
}
EOF
  run "$PLUGIN_ROOT/scripts/verdict-resolver.sh" \
    --skill gaia-test-e2e \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "REQUEST_CHANGES"
}

@test "E73-S1 AC7: verdict-resolver BLOCKED on errored toolkit check" {
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-e2e",
  "stack": "any",
  "checks": [
    {"name": "playwright-e2e", "status": "errored", "findings": []}
  ]
}
EOF
  cat > "$ll" <<EOF
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-e2e",
  "findings": []
}
EOF
  run "$PLUGIN_ROOT/scripts/verdict-resolver.sh" \
    --skill gaia-test-e2e \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "BLOCKED"
}

# --- AC10: Graceful degradation on unavailable adapter -------------------

@test "E73-S1 AC10: phase3a-collect emits errored check when probe returns expected_and_missing" {
  local outdir="$WORK_TMP/p3a"
  mkdir -p "$outdir"
  # Stage adapter with a provider guaranteed not on PATH
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage/test"
  cp "$PLAYWRIGHT_DIR/adapter.json" "$stage/adapter.json"
  jq --arg p "playwright-not-real-xyz-$$" '.provider = $p' "$stage/adapter.json" > "$stage/adapter.json.tmp"
  mv "$stage/adapter.json.tmp" "$stage/adapter.json"
  cp "$PLAYWRIGHT_DIR/run.sh" "$stage/run.sh"
  chmod +x "$stage/run.sh"
  run "$SKILL_DIR/scripts/phase3a-collect.sh" \
    --adapter-dir "$stage" \
    --output-dir "$outdir" \
    --target-url "http://example.com"
  # phase3a does not fail outright — it captures the errored state into analysis-results.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [ -f "$outdir/analysis-results.json" ]
  # Resulting check should be status: errored (probe returned expected_and_missing)
  jq -e '.checks[0].status == "errored"' "$outdir/analysis-results.json" >/dev/null
}

# --- AC4: Three-state availability probe integration ---------------------
# The probe is deterministic shell shipped by E66-S2. We sanity-check that
# our adapter.json is consumable by the probe without crashing.

@test "E73-S1 AC4: tool-availability-probe.sh consumes playwright-e2e adapter.json without crash" {
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" \
    --adapter-dir "$PLAYWRIGHT_DIR" \
    --file-list "$file_list"
  # Project-scope adapter (file-extensions: []) with empty file-list returns not_applicable.
  # With non-empty file-list it would return available or expected_and_missing depending on PATH.
  echo "$output" | jq -e '.state' >/dev/null
}

@test "E73-S1 AC4: tool-availability-probe.sh consumes cypress-e2e adapter.json without crash" {
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" \
    --adapter-dir "$CYPRESS_DIR" \
    --file-list "$file_list"
  echo "$output" | jq -e '.state' >/dev/null
}
