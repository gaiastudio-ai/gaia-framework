#!/usr/bin/env bats
# gaia-test-a11y.bats — integration tests for /gaia-test-a11y action skill (E73-S4).
#
# Verifies (story E73-S4):
#   - SKILL.md exists with required action-skill frontmatter (AC1)
#   - axe-core-a11y, pa11y-a11y, lighthouse-a11y adapters conform to ADR-078 (AC2, AC3, AC4)
#   - Shared rubric loading from rubrics/base/a11y.json (AC5)
#   - SKILL.md Steps section implements the ADR-077 seven-phase structure (AC6)
#   - Three-state availability probe integration (AC7)
#   - Adapter selection via project config and CLI override (AC8)
#   - Verdict resolver emits correct verdict (AC9)
#   - Review Gate update on completion (AC10)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
SKILL_DIR="$PLUGIN_ROOT/skills/gaia-test-a11y"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
AXE_DIR="$ADAPTERS_DIR/axe-core-a11y"
PA11Y_DIR="$ADAPTERS_DIR/pa11y-a11y"
LH_DIR="$ADAPTERS_DIR/lighthouse-a11y"

setup() {
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-test-a11y-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# --- AC1: SKILL.md exists with action-skill frontmatter --------------------

@test "E73-S4 AC1: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "E73-S4 AC1: SKILL.md frontmatter declares deployment-phase action skill" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E '^name:[[:space:]]+gaia-test-a11y' "$f"
  grep -E '^phase:[[:space:]]+deployment' "$f"
  grep -E '^verdict:[[:space:]]+true' "$f"
  grep -E '^type:[[:space:]]+action' "$f"
}

@test "E73-S4 AC1: SKILL.md description references axe-core, pa11y, Lighthouse" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E -i 'axe' "$f"
  grep -E -i 'pa11y' "$f"
  grep -E -i 'lighthouse' "$f"
}

@test "E73-S4 AC1: SKILL.md allowed-tools includes Read and Bash" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E '^allowed-tools:.*Read' "$f"
  grep -E '^allowed-tools:.*Bash' "$f"
}

# --- AC2/AC3/AC4: each a11y adapter conforms to ADR-078 contract ---------

_assert_a11y_adapter_contract() {
  local adir="$1" provider="$2"
  [ -d "$adir" ]
  [ -f "$adir/adapter.json" ]
  jq -e . "$adir/adapter.json" >/dev/null
  jq -e --arg p "$provider" '.provider == $p' "$adir/adapter.json" >/dev/null
  jq -e '.category == "a11y-scanner"' "$adir/adapter.json" >/dev/null
  jq -e '."runtime-profile" == "subprocess"' "$adir/adapter.json" >/dev/null
  jq -e '."default-timeout-seconds" >= 1' "$adir/adapter.json" >/dev/null
  jq -e '."file-extensions" | type == "array"' "$adir/adapter.json" >/dev/null
  jq -e '."version-range" | length > 0' "$adir/adapter.json" >/dev/null
  jq -e '.description | length > 0' "$adir/adapter.json" >/dev/null
  [ -x "$adir/run.sh" ]
  [ -f "$adir/test/contract.bats" ]
}

@test "E73-S4 AC2: axe-core-a11y adapter conforms to ADR-078 contract" {
  _assert_a11y_adapter_contract "$AXE_DIR" "axe-core"
}

@test "E73-S4 AC2: axe-core-a11y run.sh accepts canonical contract flags + a11y-specific args" {
  [ -x "$AXE_DIR/run.sh" ]
  run "$AXE_DIR/run.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -- "--input"
  echo "$output" | grep -F -- "--config"
  echo "$output" | grep -F -- "--output"
  echo "$output" | grep -F -- "--timeout"
  echo "$output" | grep -F -- "--target-url"
  echo "$output" | grep -F -- "--wcag-level"
}

@test "E73-S4 AC3: pa11y-a11y adapter conforms to ADR-078 contract" {
  _assert_a11y_adapter_contract "$PA11Y_DIR" "pa11y"
}

@test "E73-S4 AC3: pa11y-a11y run.sh accepts canonical contract flags + a11y-specific args" {
  [ -x "$PA11Y_DIR/run.sh" ]
  run "$PA11Y_DIR/run.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -- "--target-url"
  echo "$output" | grep -F -- "--wcag-level"
}

@test "E73-S4 AC4: lighthouse-a11y adapter conforms to ADR-078 contract" {
  _assert_a11y_adapter_contract "$LH_DIR" "lighthouse"
}

@test "E73-S4 AC4: lighthouse-a11y run.sh accepts --categories accessibility" {
  [ -x "$LH_DIR/run.sh" ]
  run "$LH_DIR/run.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -- "--target-url"
  echo "$output" | grep -F -- "--categories"
}

# --- AC5: Shared rubric loading from E69-S2 ----------------------------------

@test "E73-S4 AC5: SKILL.md references shared a11y rubric (rubrics/base/a11y.json)" {
  local f="$SKILL_DIR/SKILL.md"
  grep -F 'rubrics/base/a11y.json' "$f"
}

@test "E73-S4 AC5: SKILL.md references WCAG level escalation (AA / AAA)" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E -i 'wcag.*aa' "$f"
  grep -E -i 'aaa' "$f"
}

@test "E73-S4 AC5: rubrics/base/a11y.json exists (E68-S3 + E69-S2 prerequisite)" {
  [ -f "$PLUGIN_ROOT/rubrics/base/a11y.json" ]
  jq -e '.skill == "a11y"' "$PLUGIN_ROOT/rubrics/base/a11y.json" >/dev/null
}

@test "E73-S4 AC5: rubrics/regimes/wcag-2.1-aa.json present (level escalation source)" {
  [ -f "$PLUGIN_ROOT/rubrics/regimes/wcag-2.1-aa.json" ]
}

@test "E73-S4 AC5: rubrics/regimes/wcag-2.1-aaa.json present (AAA opt-in regime)" {
  [ -f "$PLUGIN_ROOT/rubrics/regimes/wcag-2.1-aaa.json" ]
}

# --- AC6: Seven-phase pipeline (ADR-077) -----------------------------------

@test "E73-S4 AC6: SKILL.md Steps section names all seven ADR-077 phases" {
  local f="$SKILL_DIR/SKILL.md"
  grep -E -i 'config' "$f"
  grep -E -i 'availability probe|tool-availability-probe' "$f"
  grep -E -i 'phase 3a|toolkit' "$f"
  grep -E -i 'phase 3b|llm judgment' "$f"
  grep -E -i 'verdict-resolver|verdict.sh' "$f"
  grep -E -i 'review gate|gate update' "$f"
  grep -E -i 'report' "$f"
}

# --- AC7: Three-state availability probe ----------------------------------

@test "E73-S4 AC7: tool-availability-probe.sh consumes axe-core-a11y adapter.json without crash" {
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" \
    --adapter-dir "$AXE_DIR" \
    --file-list "$file_list"
  echo "$output" | jq -e '.state' >/dev/null
}

@test "E73-S4 AC7: tool-availability-probe.sh consumes pa11y-a11y adapter.json without crash" {
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" \
    --adapter-dir "$PA11Y_DIR" \
    --file-list "$file_list"
  echo "$output" | jq -e '.state' >/dev/null
}

@test "E73-S4 AC7: tool-availability-probe.sh consumes lighthouse-a11y adapter.json without crash" {
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" \
    --adapter-dir "$LH_DIR" \
    --file-list "$file_list"
  echo "$output" | jq -e '.state' >/dev/null
}

# --- AC8: Adapter selection via project config + CLI override -------------

@test "E73-S4 AC8: select-adapter.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/select-adapter.sh" ]
}

@test "E73-S4 AC8: select-adapter.sh defaults to axe-core-a11y" {
  run "$SKILL_DIR/scripts/select-adapter.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/axe-core-a11y"
}

@test "E73-S4 AC8: select-adapter.sh honours --adapter CLI override" {
  run "$SKILL_DIR/scripts/select-adapter.sh" --adapter pa11y-a11y
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/pa11y-a11y"
}

@test "E73-S4 AC8: select-adapter.sh reads test_execution.a11y.adapter from project-config" {
  local cfg="$WORK_TMP/project-config.yaml"
  cat > "$cfg" <<'EOF'
test_execution:
  a11y:
    adapter: lighthouse-a11y
EOF
  run "$SKILL_DIR/scripts/select-adapter.sh" --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/lighthouse-a11y"
}

@test "E73-S4 AC8: select-adapter.sh CLI override beats project-config" {
  local cfg="$WORK_TMP/project-config.yaml"
  cat > "$cfg" <<'EOF'
test_execution:
  a11y:
    adapter: pa11y-a11y
EOF
  run "$SKILL_DIR/scripts/select-adapter.sh" --adapter axe-core-a11y --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "/axe-core-a11y"
}

# --- AC9: Verdict resolver emits correct verdict --------------------------

@test "E73-S4 AC9: phase3a-collect.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/phase3a-collect.sh" ]
}

@test "E73-S4 AC9: phase3a-collect.sh emits analysis-results.json with required envelope" {
  local outdir="$WORK_TMP/p3a"
  mkdir -p "$outdir"
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage/test"
  cp "$AXE_DIR/adapter.json" "$stage/adapter.json"
  cat > "$stage/run.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo '{"name":"axe-core-a11y","status":"passed","findings":[],"raw":""}'
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
  jq -e '.skill == "gaia-test-a11y"' "$outdir/analysis-results.json" >/dev/null
}

@test "E73-S4 AC9: verdict.sh exists and emits APPROVE on clean inputs" {
  [ -x "$SKILL_DIR/scripts/verdict.sh" ]
  local ar="$WORK_TMP/analysis-results.json"
  local ll="$WORK_TMP/llm-findings.json"
  cat > "$ar" <<'EOF'
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-a11y",
  "stack": "any",
  "checks": [
    {"name": "axe-core-a11y", "status": "passed", "findings": []}
  ]
}
EOF
  cat > "$ll" <<'EOF'
{"schema_version":"1.0.0","skill":"gaia-test-a11y","findings":[]}
EOF
  run "$SKILL_DIR/scripts/verdict.sh" --analysis-results "$ar" --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "APPROVE"
}

@test "E73-S4 AC9: verdict.sh emits BLOCKED when adapter check is errored" {
  local ar="$WORK_TMP/ar.json" ll="$WORK_TMP/ll.json"
  cat > "$ar" <<'EOF'
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-a11y",
  "stack": "any",
  "checks": [
    {"name": "axe-core-a11y", "status": "errored", "findings": []}
  ]
}
EOF
  cat > "$ll" <<'EOF'
{"schema_version":"1.0.0","skill":"gaia-test-a11y","findings":[]}
EOF
  run "$PLUGIN_ROOT/scripts/verdict-resolver.sh" \
    --skill gaia-test-a11y \
    --analysis-results "$ar" \
    --llm-findings "$ll"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "BLOCKED"
}

# --- AC10: PRD/threat-model traceability -----------------------------------

@test "E73-S4 AC10: SKILL.md documents env-var-only credentials and deployment-phase action skill contract" {
  local f="$SKILL_DIR/SKILL.md"
  grep -qiE 'env.var.only credentials|Env-var-only credentials' "$f"
  grep -qiE 'deployment.phase action skill|deployment-phase action skill' "$f"
}

# --- Agent overlay wiring (already shipped, sanity check) ------------------

@test "E73-S4: agent-overlay.sh --skill gaia-test-a11y returns sable" {
  local overlay="$PLUGIN_ROOT/scripts/review-common/agent-overlay.sh"
  [ -x "$overlay" ]
  run "$overlay" --skill gaia-test-a11y
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.agent_id == "sable"' >/dev/null
  echo "$output" | jq -e '.sidecar_path == "_memory/sable-sidecar.md"' >/dev/null
}
