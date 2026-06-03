#!/usr/bin/env bats
# artifact-type-schemas.bats — E108-S5 / TC-ATS coverage for the shared
# JSON-schema validator helper scripts/lib/validate-artifact-schema.sh.
#
# NEW file per epic Val F6 — do NOT fold these into adapter-schema-contract.bats
# (that file is E70-S1 adapter-pattern scoped).
#
# Test scenarios traced to the story Test Scenarios table:
#   TS1 (AC2)      — Source the lib; validate_artifact_schema is defined; no side effects
#   TS2 (AC1)      — Header has shebang + set -euo pipefail + LC_ALL=C
#   TS3 (AC3)      — No backend → exit 3 + [SKIP] stderr line
#   TS4 (AC4/AC5)  — (backend-guarded) valid JSON instance → exit 0
#   TS5 (AC5)      — (backend-guarded) invalid JSON instance → exit 1 + findings
#   TS6 (AC5)      — Missing args → exit 2
#   TS7 (AC7)      — This NEW bats file exists, distinct from adapter-schema-contract.bats
#   AC6            — mktemp+trap cleanup; bash 3.2 / LC_ALL=C portable (header grep)

load 'test_helper.bash'

setup() {
  common_setup
  # This bats file lives at tests/ (one level), so use the top-level
  # test_helper.bash which exports SCRIPTS_DIR; derive LIB_DIR from it.
  LIB_DIR="$SCRIPTS_DIR/lib"
  SCRIPT="$LIB_DIR/validate-artifact-schema.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/artifact-type-schemas"
  # Repo paths used by the E108-S1 nfr-assessment coverage.
  SCHEMAS_DIR="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)"
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  NFR_SCHEMA="$SCHEMAS_DIR/nfr-assessment.schema.json"
  NFR_FIXTURE="$FIX/nfr-assessment-valid.md"
  # Repo paths used by the E108-S2 performance-test-plan coverage.
  PERF_SCHEMA="$SCHEMAS_DIR/performance-test-plan.schema.json"
  PERF_FIXTURE="$FIX/performance-test-plan-valid.md"
  # Repo paths used by the E108-S3 threat-model coverage.
  TM_SCHEMA="$SCHEMAS_DIR/threat-model.schema.json"
  TM_FIXTURE="$FIX/threat-model-valid.md"
  # Repo paths used by the E108-S4 infrastructure-design coverage.
  INFRA_SCHEMA="$SCHEMAS_DIR/infrastructure-design.schema.json"
  INFRA_FIXTURE="$FIX/infrastructure-design-valid.md"
}

teardown() { common_teardown; }

# Detect whether a JSON-schema validator backend is available on this host.
# Mirrors the cascade inside the helper: ajv first, then python3+jsonschema.
_has_backend() {
  if command -v ajv >/dev/null 2>&1; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# AC1 — header invariants
# ---------------------------------------------------------------------------

@test "TS2/AC1: script exists with shebang, set -euo pipefail, LC_ALL=C" {
  [ -f "$SCRIPT" ]
  run head -n1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == "#!/usr/bin/env bash" ]]
  grep -q 'set -euo pipefail' "$SCRIPT"
  grep -Eq '^LC_ALL=C' "$SCRIPT"
}

@test "AC6: helper declares mktemp + trap cleanup (no leaked temp on conversion)" {
  grep -q 'mktemp' "$SCRIPT"
  grep -q 'trap' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# AC2 — sourceable, function-defined, no top-level side effects
# ---------------------------------------------------------------------------

@test "TS1/AC2: sourcing the lib defines validate_artifact_schema with no side effects" {
  run bash -c "source '$SCRIPT' && type -t validate_artifact_schema"
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "AC2: source guard prevents redefinition warnings on double-source" {
  run bash -c "source '$SCRIPT'; source '$SCRIPT'; echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — exit-code contract
# ---------------------------------------------------------------------------

@test "TS6/AC5: missing args → exit 2 (usage error)" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "AC5: unreadable schema file → exit 2 (usage error)" {
  run bash "$SCRIPT" "$TEST_TMP/nope.schema.json" "$FIX/valid-instance.json"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC3 — backend detection + graceful SKIP
# ---------------------------------------------------------------------------

@test "TS3/AC3: no backend → exit 3 + [SKIP] line" {
  if _has_backend; then
    skip "backend present on host; SKIP path not exercised here"
  fi
  run bash "$SCRIPT" "$FIX/valid.schema.json" "$FIX/valid-instance.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"[SKIP]"* ]]
  [[ "$output" == *"validate-artifact-schema"* ]]
}

# ---------------------------------------------------------------------------
# AC4 / AC5 — validation behavior (backend-guarded)
# ---------------------------------------------------------------------------

@test "TS4/AC4: valid JSON instance → exit 0" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$SCRIPT" "$FIX/valid.schema.json" "$FIX/valid-instance.json"
  [ "$status" -eq 0 ]
}

@test "TS5/AC5: invalid JSON instance → exit 1 + findings on stderr" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$SCRIPT" "$FIX/valid.schema.json" "$FIX/invalid-instance.json"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC7 — this is the NEW file, distinct from adapter-schema-contract.bats
# ---------------------------------------------------------------------------

@test "TS7/AC7: this bats file is the new artifact-type-schemas.bats, separate from adapter-schema-contract.bats" {
  [ -f "${BATS_TEST_DIRNAME}/artifact-type-schemas.bats" ]
  [ -f "${BATS_TEST_DIRNAME}/adapter-schema-contract.bats" ]
  # The two are distinct files (epic Val F6).
  [ "${BATS_TEST_DIRNAME}/artifact-type-schemas.bats" != "${BATS_TEST_DIRNAME}/adapter-schema-contract.bats" ]
}

# ===========================================================================
# E108-S1 — nfr-assessment schema + /gaia-nfr References + enum 16→17
# ===========================================================================

# TS1/AC1 — schema file exists and is valid JSON.
@test "E108-S1 TS1/AC1: nfr-assessment.schema.json exists and is valid JSON" {
  [ -f "$NFR_SCHEMA" ]
  # Validate JSON well-formedness without depending on jq (not guaranteed on
  # the bare host). python3 is present even when jsonschema is not; fall back
  # to a portable brace/quote sanity check if python3 is absent too.
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import json,sys; json.load(open('$NFR_SCHEMA'))"
    [ "$status" -eq 0 ]
  else
    # Minimal sanity: starts with '{', ends with '}'.
    run head -c1 "$NFR_SCHEMA"
    [ "$output" = "{" ]
  fi
}

# TS2/AC1 — draft-2020-12 + non-test-artifacts/strategy/ $id.
@test "E108-S1 TS2/AC1: schema declares draft-2020-12 and a non-strategy-scoped \$id" {
  grep -q 'json-schema.org/draft/2020-12/schema' "$NFR_SCHEMA"
  grep -q '"\$id"' "$NFR_SCHEMA"
  # The $id MUST NOT be scoped to test-artifacts/strategy/ (E105-S2 coordination).
  # Check the $id LINE specifically — the corpus-instance path may legitimately
  # appear in a `description`/annotation elsewhere in the schema.
  run grep '"\$id"' "$NFR_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" != *"test-artifacts/strategy"* ]]
}

# TS3/AC2 — required frontmatter fields + template const.
@test "E108-S1 TS3/AC2: schema requires template/version/date/project and pins template const" {
  grep -q '"template"' "$NFR_SCHEMA"
  grep -q '"version"' "$NFR_SCHEMA"
  grep -q '"date"' "$NFR_SCHEMA"
  grep -q '"project"' "$NFR_SCHEMA"
  grep -q 'nfr-assessment' "$NFR_SCHEMA"
}

# AC3 — eight-section annotation present.
@test "E108-S1 AC3: schema documents the eight canonical H2 sections" {
  grep -q 'Code Quality Baselines' "$NFR_SCHEMA"
  grep -q 'Security Posture' "$NFR_SCHEMA"
  grep -q 'Performance Baselines' "$NFR_SCHEMA"
  grep -q 'Accessibility Status' "$NFR_SCHEMA"
  grep -q 'Test Coverage Baselines' "$NFR_SCHEMA"
  grep -q 'CI/CD Assessment' "$NFR_SCHEMA"
  grep -q 'Migration' "$NFR_SCHEMA"
  grep -q 'NFR Baseline Summary' "$NFR_SCHEMA"
}

# TS4/AC2/AC6 — (backend-guarded) known-good fixture validates → exit 0.
@test "E108-S1 TS4/AC6: known-good nfr-assessment fixture validates (exit 0)" {
  [ -f "$NFR_FIXTURE" ]
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$SCRIPT" "$NFR_SCHEMA" "$NFR_FIXTURE"
  [ "$status" -eq 0 ]
}

# TS5/AC5 — enum extended 16→17 contains nfr-assessment.
@test "E108-S1 TS5/AC5: val-validate artifact_type enum contains nfr-assessment" {
  local skill="$SKILLS_DIR/gaia-val-validate/SKILL.md"
  [ -f "$skill" ]
  # The enum line carries 'artifact_type' + the backticked value.
  grep -q '`nfr-assessment`' "$skill"
}

# TS6/AC4 — /gaia-nfr SKILL.md has a ## References section.
@test "E108-S1 TS6/AC4: gaia-nfr SKILL.md has a ## References section" {
  local skill="$SKILLS_DIR/gaia-nfr/SKILL.md"
  [ -f "$skill" ]
  grep -Eq '^## References[[:space:]]*$' "$skill"
  # The References section names the new schema.
  grep -q 'nfr-assessment.schema.json' "$skill"
}

# ===========================================================================
# E108-S2 — performance-test-plan schema + /gaia-perf-testing References + enum 17→18
# ===========================================================================

# TS1/AC1 — schema file exists and is valid JSON.
@test "E108-S2 TS1/AC1: performance-test-plan.schema.json exists and is valid JSON" {
  [ -f "$PERF_SCHEMA" ]
  # Validate JSON well-formedness without depending on jq (not guaranteed on
  # the bare host). python3 is present even when jsonschema is not; fall back
  # to a portable brace sanity check if python3 is absent too.
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import json,sys; json.load(open('$PERF_SCHEMA'))"
    [ "$status" -eq 0 ]
  else
    run head -c1 "$PERF_SCHEMA"
    [ "$output" = "{" ]
  fi
}

# TS2/AC1 — draft-2020-12 + non-test-artifacts/strategy/ $id.
@test "E108-S2 TS2/AC1: schema declares draft-2020-12 and a non-strategy-scoped \$id" {
  grep -q 'json-schema.org/draft/2020-12/schema' "$PERF_SCHEMA"
  grep -q '"\$id"' "$PERF_SCHEMA"
  # The $id MUST NOT be scoped to test-artifacts/strategy/ (E105-S2 coordination).
  # Check the $id LINE specifically — the corpus-instance path may legitimately
  # appear in a `description`/annotation elsewhere in the schema.
  run grep '"\$id"' "$PERF_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" != *"test-artifacts/strategy"* ]]
}

# TS3/AC2 — required frontmatter fields + template const.
@test "E108-S2 TS3/AC2: schema requires template/version/date/project and pins template const" {
  grep -q '"template"' "$PERF_SCHEMA"
  grep -q '"version"' "$PERF_SCHEMA"
  grep -q '"date"' "$PERF_SCHEMA"
  grep -q '"project"' "$PERF_SCHEMA"
  grep -q 'performance-test-plan' "$PERF_SCHEMA"
}

# AC3 — seven-section annotation present.
@test "E108-S2 AC3: schema documents the seven canonical H2 sections" {
  grep -q 'Overview' "$PERF_SCHEMA"
  grep -q 'Performance Budgets' "$PERF_SCHEMA"
  grep -q 'Test Scenarios' "$PERF_SCHEMA"
  grep -q 'Profiling Targets' "$PERF_SCHEMA"
  grep -q 'CI Performance Gates' "$PERF_SCHEMA"
  grep -q 'Monitoring and Regression Detection' "$PERF_SCHEMA"
  grep -q 'Execution Schedule' "$PERF_SCHEMA"
}

# TS4/AC2/AC6 — (backend-guarded) known-good fixture validates → exit 0.
@test "E108-S2 TS4/AC6: known-good performance-test-plan fixture validates (exit 0)" {
  [ -f "$PERF_FIXTURE" ]
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$SCRIPT" "$PERF_SCHEMA" "$PERF_FIXTURE"
  [ "$status" -eq 0 ]
}

# TS5/AC5 — enum extended 17→18 contains performance-test-plan.
@test "E108-S2 TS5/AC5: val-validate artifact_type enum contains performance-test-plan" {
  local skill="$SKILLS_DIR/gaia-val-validate/SKILL.md"
  [ -f "$skill" ]
  # The enum line carries 'artifact_type' + the backticked value.
  grep -q '`performance-test-plan`' "$skill"
}

# TS6/AC4 — /gaia-perf-testing SKILL.md has a ## References section.
@test "E108-S2 TS6/AC4: gaia-perf-testing SKILL.md has a ## References section" {
  local skill="$SKILLS_DIR/gaia-perf-testing/SKILL.md"
  [ -f "$skill" ]
  grep -Eq '^## References[[:space:]]*$' "$skill"
  # The References section names the new schema.
  grep -q 'performance-test-plan.schema.json' "$skill"
}

# ===========================================================================
# E108-S3 — threat-model schema + /gaia-threat-model References — NO enum change
# ===========================================================================

# TS1/AC1 — schema file exists and is valid JSON.
@test "E108-S3 TS1/AC1: threat-model.schema.json exists and is valid JSON" {
  [ -f "$TM_SCHEMA" ]
  # Validate JSON well-formedness without depending on jq (not guaranteed on
  # the bare host). python3 is present even when jsonschema is not; fall back
  # to a portable brace sanity check if python3 is absent too.
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import json,sys; json.load(open('$TM_SCHEMA'))"
    [ "$status" -eq 0 ]
  else
    run head -c1 "$TM_SCHEMA"
    [ "$output" = "{" ]
  fi
}

# TS2/AC1 — draft-2020-12 + non-strategy-scoped $id.
@test "E108-S3 TS2/AC1: schema declares draft-2020-12 and a non-strategy-scoped \$id" {
  grep -q 'json-schema.org/draft/2020-12/schema' "$TM_SCHEMA"
  grep -q '"\$id"' "$TM_SCHEMA"
  # The $id MUST NOT be scoped to test-artifacts/strategy/ (E105-S2 coordination).
  # Check the $id LINE specifically — the corpus-instance path may legitimately
  # appear in a `description`/annotation elsewhere in the schema.
  run grep '"\$id"' "$TM_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" != *"test-artifacts/strategy"* ]]
  [[ "$output" != *"strategy"* ]]
}

# TS3/AC2 — required frontmatter fields + template const.
@test "E108-S3 TS3/AC2: schema requires template/version/date/project and pins template const" {
  grep -q '"template"' "$TM_SCHEMA"
  grep -q '"version"' "$TM_SCHEMA"
  grep -q '"date"' "$TM_SCHEMA"
  grep -q '"project"' "$TM_SCHEMA"
  grep -q 'threat-model' "$TM_SCHEMA"
}

# TS4/AC3 — nine-section annotation present.
@test "E108-S3 TS4/AC3: schema documents the nine canonical H2 sections" {
  grep -q 'Assets Inventory' "$TM_SCHEMA"
  grep -q 'Trust Boundaries' "$TM_SCHEMA"
  grep -q 'STRIDE Analysis' "$TM_SCHEMA"
  grep -q 'DREAD Scoring' "$TM_SCHEMA"
  grep -q 'Mitigation Strategies' "$TM_SCHEMA"
  grep -q 'Security Requirements' "$TM_SCHEMA"
  grep -q 'Risk Acceptance Register' "$TM_SCHEMA"
  grep -q 'Threat Model Diagram' "$TM_SCHEMA"
  grep -q 'Summary' "$TM_SCHEMA"
}

# TS5/AC2/AC6 — (backend-guarded) known-good fixture validates → exit 0.
@test "E108-S3 TS5/AC6: known-good threat-model fixture validates (exit 0)" {
  [ -f "$TM_FIXTURE" ]
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$SCRIPT" "$TM_SCHEMA" "$TM_FIXTURE"
  [ "$status" -eq 0 ]
}

# TS6/AC5 — enum ALREADY contains threat-model (asserted, NOT edited by this story).
@test "E108-S3 TS6/AC5: val-validate artifact_type enum already contains threat-model (no enum change)" {
  local skill="$SKILLS_DIR/gaia-val-validate/SKILL.md"
  [ -f "$skill" ]
  # threat-model is at position 5 in the enum — present before E108-S3.
  grep -q '`threat-model`' "$skill"
}

# TS7/AC4 — /gaia-threat-model SKILL.md has a ## References section.
@test "E108-S3 TS7/AC4: gaia-threat-model SKILL.md has a ## References section" {
  local skill="$SKILLS_DIR/gaia-threat-model/SKILL.md"
  [ -f "$skill" ]
  grep -Eq '^## References[[:space:]]*$' "$skill"
  # The References section names the new schema.
  grep -q 'threat-model.schema.json' "$skill"
}

# ===========================================================================
# E108-S4 — infrastructure-design schema + /gaia-infra-design References + enum 18→19
# ===========================================================================

# TS1/AC1 — schema file exists and is valid JSON.
@test "E108-S4 TS1/AC1: infrastructure-design.schema.json exists and is valid JSON" {
  [ -f "$INFRA_SCHEMA" ]
  # Validate JSON well-formedness without depending on jq (not guaranteed on
  # the bare host). python3 is present even when jsonschema is not; fall back
  # to a portable brace sanity check if python3 is absent too.
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import json,sys; json.load(open('$INFRA_SCHEMA'))"
    [ "$status" -eq 0 ]
  else
    run head -c1 "$INFRA_SCHEMA"
    [ "$output" = "{" ]
  fi
}

# TS2/AC1 — draft-2020-12 + non-strategy-scoped $id.
@test "E108-S4 TS2/AC1: schema declares draft-2020-12 and a non-strategy-scoped \$id" {
  grep -q 'json-schema.org/draft/2020-12/schema' "$INFRA_SCHEMA"
  grep -q '"\$id"' "$INFRA_SCHEMA"
  # The $id MUST NOT be scoped to test-artifacts/strategy/ (E105-S2 coordination).
  # Check the $id LINE specifically — the corpus-instance path may legitimately
  # appear in a `description`/annotation elsewhere in the schema.
  run grep '"\$id"' "$INFRA_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" != *"test-artifacts/strategy"* ]]
  [[ "$output" != *"strategy"* ]]
}

# TS3/AC2 — required frontmatter fields + template const.
@test "E108-S4 TS3/AC2: schema requires template/version/date/project and pins template const" {
  grep -q '"template"' "$INFRA_SCHEMA"
  grep -q '"version"' "$INFRA_SCHEMA"
  grep -q '"date"' "$INFRA_SCHEMA"
  grep -q '"project"' "$INFRA_SCHEMA"
  grep -q 'infrastructure-design' "$INFRA_SCHEMA"
}

# AC3 — eleven-section annotation present.
@test "E108-S4 AC3: schema documents the eleven canonical H2 sections" {
  grep -q 'Infrastructure Context' "$INFRA_SCHEMA"
  grep -q 'Environment Design' "$INFRA_SCHEMA"
  grep -q 'Deployment Topology' "$INFRA_SCHEMA"
  grep -q 'CI/CD Pipeline Design' "$INFRA_SCHEMA"
  grep -q 'State Management' "$INFRA_SCHEMA"
  grep -q 'Observability Plan' "$INFRA_SCHEMA"
  grep -q 'Rollback Strategies' "$INFRA_SCHEMA"
  grep -q 'Security Hardening' "$INFRA_SCHEMA"
  grep -q 'Dependency Management' "$INFRA_SCHEMA"
  grep -q 'Implementation Milestones' "$INFRA_SCHEMA"
  grep -q 'Decision Rationale Summary' "$INFRA_SCHEMA"
}

# TS4/AC2/AC6 — (backend-guarded) known-good fixture validates → exit 0.
@test "E108-S4 TS4/AC6: known-good infrastructure-design fixture validates (exit 0)" {
  [ -f "$INFRA_FIXTURE" ]
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$SCRIPT" "$INFRA_SCHEMA" "$INFRA_FIXTURE"
  [ "$status" -eq 0 ]
}

# TS5/AC5 — enum extended 18→19 contains infrastructure-design.
@test "E108-S4 TS5/AC5: val-validate artifact_type enum contains infrastructure-design" {
  local skill="$SKILLS_DIR/gaia-val-validate/SKILL.md"
  [ -f "$skill" ]
  # The enum line carries 'artifact_type' + the backticked value.
  grep -q '`infrastructure-design`' "$skill"
}

# TS5b/AC5 — enum now totals 19 backticked values on the artifact_type enum line.
@test "E108-S4 TS5b/AC5: val-validate artifact_type enum totals 19 values" {
  local skill="$SKILLS_DIR/gaia-val-validate/SKILL.md"
  [ -f "$skill" ]
  # The enum is on the single 'One of:' table row. Extract the segment from
  # 'One of:' up to the first '. ' that ends the enum list, then count the
  # backticked tokens within ONLY that segment (the row carries other backticked
  # tokens — e.g. `gaia-document-rulesets`, schema filenames — outside the list).
  local line seg count
  line="$(grep -E 'artifact_type.*One of:' "$skill" | head -n1)"
  [ -n "$line" ]
  seg="$(printf '%s\n' "$line" | sed 's/.*One of://; s/\. .*//')"
  count="$(printf '%s\n' "$seg" | grep -o '`[a-z0-9-]*`' | wc -l | tr -d ' ')"
  [ "$count" -eq 19 ]
}

# TS6/AC4 — /gaia-infra-design SKILL.md has a ## References section.
@test "E108-S4 TS6/AC4: gaia-infra-design SKILL.md has a ## References section" {
  local skill="$SKILLS_DIR/gaia-infra-design/SKILL.md"
  [ -f "$skill" ]
  grep -Eq '^## References[[:space:]]*$' "$skill"
  # The References section names the new schema.
  grep -q 'infrastructure-design.schema.json' "$skill"
}
