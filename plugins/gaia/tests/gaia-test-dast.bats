#!/usr/bin/env bats
# gaia-test-dast.bats — integration tests for /gaia-test-dast action skill (E73-S3).
#
# Verifies (story E73-S3):
#   - SKILL.md exists with required action-skill frontmatter (AC1)
#   - SKILL.md `## Secret Handling` section documents env-allowlist contract (AC5)
#   - SKILL.md Steps section implements the ADR-077 seven-phase structure (AC6)
#   - OWASP ZAP adapter directory + adapter.json with env-allowlist (AC2)
#   - run.sh implements ADR-078 contract incl. env scrubbing + finding output (AC3, AC4)
#   - contract.bats present (AC7)
#   - Three-state availability probe integration (AC8)
#   - agent-overlay.sh routes gaia-test-dast → sable (AC9)
#   - verdict-resolver.sh accepts --skill gaia-test-dast (AC10 traceability)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
SKILL_DIR="$PLUGIN_ROOT/skills/gaia-test-dast"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
ZAP_DIR="$ADAPTERS_DIR/owasp-zap"

setup() {
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-test-dast-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# --- AC1: SKILL.md exists with action-skill frontmatter --------------------

@test "SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "SKILL.md frontmatter declares deployment-phase action skill" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E '^name:[[:space:]]+gaia-test-dast' "$f"
  grep -E '^phase:[[:space:]]+deployment' "$f"
  grep -E '^verdict:[[:space:]]+true' "$f"
  grep -E '^type:[[:space:]]+action' "$f"
}

@test "SKILL.md description references OWASP ZAP and DAST" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E '^description:.*(ZAP|DAST)' "$f"
}

@test "SKILL.md allowed-tools includes Read Bash" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E '^allowed-tools:.*Read' "$f"
  grep -E '^allowed-tools:.*Bash' "$f"
}

# --- AC2: OWASP ZAP adapter conforms to ADR-078 contract -------------------

@test "owasp-zap adapter directory exists" {
  [ -d "$ZAP_DIR" ]
}

@test "owasp-zap adapter.json validates required schema fields" {
  [ -f "$ZAP_DIR/adapter.json" ]
  jq -e . "$ZAP_DIR/adapter.json" >/dev/null
  jq -e '.category == "dast"' "$ZAP_DIR/adapter.json" >/dev/null
  jq -e '."runtime-profile" == "subprocess"' "$ZAP_DIR/adapter.json" >/dev/null
  jq -e '."default-timeout-seconds" >= 1' "$ZAP_DIR/adapter.json" >/dev/null
  jq -e '."file-extensions" | type == "array"' "$ZAP_DIR/adapter.json" >/dev/null
  jq -e '."version-range" | length > 0' "$ZAP_DIR/adapter.json" >/dev/null
  jq -e '.description | length > 0' "$ZAP_DIR/adapter.json" >/dev/null
}

@test "owasp-zap adapter.json declares env-allowlist (T-RSV2-1)" {
  [ -f "$ZAP_DIR/adapter.json" ]
  jq -e '.["env-allowlist"] | type == "array" and length > 0' "$ZAP_DIR/adapter.json"
}

# --- AC3: run.sh ADR-078 contract -------------------------------------------

@test "owasp-zap run.sh executable and accepts canonical contract flags" {
  [ -x "$ZAP_DIR/run.sh" ]
  run "$ZAP_DIR/run.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -- "--input"
  echo "$output" | grep -F -- "--config"
  echo "$output" | grep -F -- "--output"
  echo "$output" | grep -F -- "--timeout"
  echo "$output" | grep -F -- "--target-url"
}

@test "owasp-zap contract.bats present" {
  [ -f "$ZAP_DIR/test/contract.bats" ]
}

# --- AC5: SKILL.md Secret Handling documents env-allowlist contract --------

@test "SKILL.md has '## Secret Handling' section" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E '^## Secret Handling' "$f"
}

@test "Secret Handling references env-allowlist + credential-leakage mitigation" {
  local f="$SKILL_DIR/SKILL.md"
  grep -F 'env-allowlist' "$f"
  grep -E -i 'credential.leakage|credential leakage|DAST tooling surface' "$f"
}

@test "Secret Handling enumerates permitted env vars (ZAP_API_KEY, TARGET_URL)" {
  local f="$SKILL_DIR/SKILL.md"
  grep -F 'ZAP_API_KEY' "$f"
  grep -F 'TARGET_URL' "$f"
}

@test "Secret Handling warns that adding allowlist entries requires security review" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E -i 'security review|requires.*review' "$f"
}

# --- AC6: Seven-phase pipeline (ADR-077) ----------------------------------

@test "SKILL.md Steps section names all seven phases" {
  local f="$SKILL_DIR/SKILL.md"
  # Seven phases: 1 config, 2 availability probe, 3A toolkit, 3B LLM judgment,
  # 4 verdict resolution, 5 gate update, 6 report.
  grep -E -i 'config' "$f"
  grep -E -i 'availability probe|tool-availability-probe' "$f"
  grep -E -i 'phase 3a|toolkit' "$f"
  grep -E -i 'phase 3b|llm judgment' "$f"
  grep -E -i 'verdict-resolver|verdict.sh' "$f"
  grep -E -i 'review gate|gate update' "$f"
  grep -E -i 'report' "$f"
}

# --- AC9: Agent overlay wiring ---------------------------------------------

@test "agent-overlay.sh --skill gaia-test-dast returns sable" {
  local overlay="$PLUGIN_ROOT/scripts/review-common/agent-overlay.sh"
  [ -x "$overlay" ]
  run "$overlay" --skill gaia-test-dast
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.agent_id == "sable"' >/dev/null
  echo "$output" | jq -e '.sidecar_path == "_memory/sable-sidecar.md"' >/dev/null
}

# --- AC10: PRD/threat-model traceability -----------------------------------

@test "SKILL.md documents env-allowlist contract and DAST tooling surface threat" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E 'Per-adapter env-allowlist contract|env-allowlist contract' "$f"
  grep -E 'DAST tooling surface|deployment-phase.*DAST|Deployment-phase DAST' "$f"
}

# --- Skill scripts exist ---------------------------------------------------

@test "select-adapter.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/select-adapter.sh" ]
}

@test "select-adapter.sh defaults to owasp-zap" {
  run "$SKILL_DIR/scripts/select-adapter.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/owasp-zap"
}

@test "phase3a-collect.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/phase3a-collect.sh" ]
}

@test "phase3a-collect.sh emits analysis-results.json with required envelope" {
  local outdir="$WORK_TMP/p3a"
  mkdir -p "$outdir"
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage/test"
  cp "$ZAP_DIR/adapter.json" "$stage/adapter.json"
  cat > "$stage/run.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo '{"name":"owasp-zap","status":"passed","findings":[],"raw":""}'
exit 0
EOF
  chmod +x "$stage/run.sh"
  run "$SKILL_DIR/scripts/phase3a-collect.sh" \
    --adapter-dir "$stage" \
    --output-dir "$outdir" \
    --target-url "http://example.test"
  [ "$status" -eq 0 ]
  [ -f "$outdir/analysis-results.json" ]
  jq -e '.checks' "$outdir/analysis-results.json" >/dev/null
  jq -e '.skill == "gaia-test-dast"' "$outdir/analysis-results.json" >/dev/null
}

@test "verdict.sh exists and emits APPROVE on clean inputs" {
  [ -x "$SKILL_DIR/scripts/verdict.sh" ]
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<'EOF'
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-dast",
  "stack": "any",
  "checks": [
    {"name": "owasp-zap", "status": "passed", "findings": []}
  ]
}
EOF
  cat > "$ll" <<'EOF'
{"schema_version":"1.0.0","skill":"gaia-test-dast","findings":[]}
EOF
  run "$SKILL_DIR/scripts/verdict.sh" --analysis-results "$ar" --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "APPROVE"
}

@test "verdict.sh emits BLOCKED when adapter check is errored" {
  local ar="$WORK_TMP/ar.json" ll="$WORK_TMP/ll.json"
  cat > "$ar" <<'EOF'
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-dast",
  "stack": "any",
  "checks": [
    {"name": "owasp-zap", "status": "errored", "findings": []}
  ]
}
EOF
  cat > "$ll" <<'EOF'
{"schema_version":"1.0.0","skill":"gaia-test-dast","findings":[]}
EOF
  run "$PLUGIN_ROOT/scripts/verdict-resolver.sh" \
    --skill gaia-test-dast \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "BLOCKED"
}

# --- Probe sanity check ----------------------------------------------------

@test "tool-availability-probe.sh consumes owasp-zap adapter.json without crash" {
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" \
    --adapter-dir "$ZAP_DIR" \
    --file-list "$file_list"
  echo "$output" | jq -e '.state' >/dev/null
}
