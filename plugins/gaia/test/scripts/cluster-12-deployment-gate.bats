#!/usr/bin/env bats
# cluster-12-deployment-gate.bats — Cluster 12 integration test: deployment gate enforcement
#
# Story: E28-S95 — Test deployment cluster gate enforcement
#
# Validates that validate-gate.sh correctly enforces deployment preconditions:
#   - deployment-checklist gates HALT on missing traceability-matrix.md (AC1)
#   - deployment-checklist gates HALT on missing ci-setup.md (AC2)
#   - deployment-checklist gates pass when all artifacts present (AC3)
#   - release-plan skill produces valid output with environment progression (AC4)
#   - post-deploy-verify skill validates health endpoints (AC5)
#
# All tests exercise validate-gate.sh directly or validate skill/fixture structure.
# No LLM in the loop — deterministic bats-core tests per ADR-042.

PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SKILLS_DIR="$PLUGIN_DIR/skills"
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../fixtures/cluster-12" && pwd)"

GATE_SCRIPT="$SCRIPTS_DIR/validate-gate.sh"
DEPLOY_MULTI_GATES="traceability_exists,ci_setup_exists,readiness_report_exists"

setup() {
  TMP_DIR="$(mktemp -d)"
  mkdir -p "$TMP_DIR/docs/test-artifacts"
  mkdir -p "$TMP_DIR/docs/planning-artifacts"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# Helper: run the deployment-checklist multi-gate against $TMP_DIR
# E28-S152: readiness_report_exists resolves against PLANNING_ARTIFACTS,
# while traceability_exists / ci_setup_exists resolve against TEST_ARTIFACTS.
run_deploy_gates() {
  TEST_ARTIFACTS="$TMP_DIR/docs/test-artifacts" \
  PLANNING_ARTIFACTS="$TMP_DIR/docs/planning-artifacts" \
  run "$GATE_SCRIPT" --multi "$DEPLOY_MULTI_GATES"
}

# ---------- AC1: deployment-checklist HALTs on missing traceability ----------

@test "AC1: deployment-checklist gates HALT when traceability-matrix.md is missing" {
  # Given a fixture directory with ci-setup.md and readiness-report.md present
  # but traceability-matrix.md is intentionally ABSENT
  # E28-S152: readiness-report.md now lives under PLANNING_ARTIFACTS
  cp "$FIXTURES_DIR/fixture-ci-setup.md" "$TMP_DIR/docs/test-artifacts/ci-setup.md"
  cp "$FIXTURES_DIR/fixture-readiness-report.md" "$TMP_DIR/docs/planning-artifacts/readiness-report.md"
  # traceability-matrix.md is NOT copied — intentionally missing

  # And validate-gate.sh exists and is executable
  [ -x "$GATE_SCRIPT" ]

  # When validate-gate.sh is invoked with the deployment-checklist multi-gate
  # (same invocation as the deploy-checklist skill Step 2)
  run_deploy_gates

  # Then the gate check fails with non-zero exit code
  [ "$status" -ne 0 ]

  # And the error output contains an actionable message naming the traceability gate
  [[ "$output" == *"traceability"* ]]
}

# ---------- AC2: deployment-checklist HALTs on missing CI setup ----------

@test "AC2: deployment-checklist gates HALT when ci-setup.md is missing" {
  # Given a fixture directory with traceability-matrix.md and readiness-report.md present
  # but ci-setup.md is intentionally ABSENT
  # E28-S152: readiness-report.md now lives under PLANNING_ARTIFACTS
  cp "$FIXTURES_DIR/fixture-traceability-matrix.md" "$TMP_DIR/docs/test-artifacts/traceability-matrix.md"
  cp "$FIXTURES_DIR/fixture-readiness-report.md" "$TMP_DIR/docs/planning-artifacts/readiness-report.md"
  # ci-setup.md is NOT copied — intentionally missing

  # And validate-gate.sh exists and is executable
  [ -x "$GATE_SCRIPT" ]

  # When validate-gate.sh is invoked with the deployment-checklist multi-gate
  run_deploy_gates

  # Then the gate check fails with non-zero exit code
  [ "$status" -ne 0 ]

  # And the error output contains an actionable message naming the CI gate
  [[ "$output" == *"ci"* ]] || [[ "$output" == *"CI"* ]] || [[ "$output" == *"ci_setup"* ]]
}

# ---------- AC3: deployment-checklist succeeds when all gates pass ----------

@test "AC3: deployment-checklist gates pass when all required artifacts are present" {
  # Given a fixture directory with ALL required gate artifacts present:
  # traceability-matrix.md, ci-setup.md under TEST_ARTIFACTS;
  # readiness-report.md under PLANNING_ARTIFACTS (E28-S152).
  cp "$FIXTURES_DIR/fixture-traceability-matrix.md" "$TMP_DIR/docs/test-artifacts/traceability-matrix.md"
  cp "$FIXTURES_DIR/fixture-ci-setup.md" "$TMP_DIR/docs/test-artifacts/ci-setup.md"
  cp "$FIXTURES_DIR/fixture-readiness-report.md" "$TMP_DIR/docs/planning-artifacts/readiness-report.md"

  # And validate-gate.sh exists and is executable
  [ -x "$GATE_SCRIPT" ]

  # When validate-gate.sh is invoked with the deployment-checklist multi-gate
  run_deploy_gates

  # Then the gate check passes with exit code 0
  [ "$status" -eq 0 ]

  # And the output confirms all gates passed
  [[ "$output" == *"passed"* ]]
}

# ---------- AC4: release-plan produces valid output ----------

@test "AC4: release-plan skill is wired and fixture contains environment progression and rollback criteria" {
  # Given the gaia-release-plan SKILL.md exists with correct frontmatter
  local skill_file="$SKILLS_DIR/gaia-release-plan/SKILL.md"
  [ -f "$skill_file" ]

  # And the skill has a scripts directory with setup.sh
  local setup_script="$SKILLS_DIR/gaia-release-plan/scripts/setup.sh"
  [ -f "$setup_script" ]

  # And the release config fixture contains environment progression data
  local fixture="$FIXTURES_DIR/fixture-release-config.md"
  [ -f "$fixture" ]

  # Then the fixture contains environment progression information
  run grep -c "staging\|production\|progression" "$fixture"
  [ "$output" -ge 2 ]

  # And the fixture contains rollback criteria
  run grep -c "rollback\|Rollback" "$fixture"
  [ "$output" -ge 1 ]

  # And the SKILL.md frontmatter declares the correct skill name
  run grep "name: gaia-release-plan" "$skill_file"
  [ "$status" -eq 0 ]
}

# ---------- AC5: post-deploy-verify validates health endpoints ----------

@test "AC5: post-deploy-verify skill is wired and fixture contains health endpoint data" {
  # Given the gaia-deploy-post SKILL.md exists with correct frontmatter
  # (renamed from gaia-post-deploy to category-first gaia-deploy-post)
  local skill_file="$SKILLS_DIR/gaia-deploy-post/SKILL.md"
  [ -f "$skill_file" ]

  # And the skill has a scripts directory with setup.sh
  local setup_script="$SKILLS_DIR/gaia-deploy-post/scripts/setup.sh"
  [ -f "$setup_script" ]

  # And the health endpoints fixture contains endpoint configuration
  local fixture="$FIXTURES_DIR/fixture-health-endpoints.md"
  [ -f "$fixture" ]

  # Then the fixture contains health check endpoint definitions
  run grep -c "/health\|/readiness\|/liveness" "$fixture"
  [ "$output" -ge 2 ]

  # And the fixture contains expected status codes
  run grep -c "200" "$fixture"
  [ "$output" -ge 2 ]

  # And the SKILL.md frontmatter declares the correct skill name
  run grep "name: gaia-deploy-post" "$skill_file"
  [ "$status" -eq 0 ]
}
