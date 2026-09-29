#!/usr/bin/env bash
# generate-report.sh — Cluster 6 e2e pass/fail PR report (E28-S51, AC6)
#
# Runs all 6 Cluster 6 architecture skills' setup.sh + finalize.sh, captures
# per-skill timing and exit codes (positive + negative gate cases), and writes
# a markdown report suitable for PR comment or CI artifact attachment.
#
# Usage: generate-report.sh <output-path> <repo-root>
#
# Exit codes:
#   0 — report generated (regardless of individual skill pass/fail)
#   1 — usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

OUTPUT="${1:?Usage: generate-report.sh <output-path> <repo-root>}"
REPO_ROOT="${2:?Usage: generate-report.sh <output-path> <repo-root>}"

SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"

SKILLS=(
  gaia-create-arch
  gaia-edit-arch
  gaia-create-epics
  gaia-readiness-check
  gaia-infra-design
  gaia-threat-model
)

# Setup temp workspace for the report run
REPORT_TMP="$(mktemp -d)"
trap 'rm -rf "$REPORT_TMP"' EXIT

export GAIA_PROJECT_ROOT="$REPORT_TMP"
export GAIA_PROJECT_PATH="$REPORT_TMP"
export GAIA_MEMORY_PATH="$REPORT_TMP/memory"
export GAIA_CHECKPOINT_PATH="$REPORT_TMP/checkpoints"
export GAIA_INSTALLED_PATH="$REPO_ROOT/plugins/gaia"
export CLAUDE_SKILL_DIR="$REPORT_TMP"
export MEMORY_PATH="$REPORT_TMP/memory"
export CHECKPOINT_PATH="$REPORT_TMP/checkpoints"
export PROJECT_ROOT="$REPORT_TMP"
export TEST_ARTIFACTS="$REPORT_TMP/docs/test-artifacts"

mkdir -p "$REPORT_TMP/memory" "$REPORT_TMP/checkpoints" "$REPORT_TMP/config" \
         "$REPORT_TMP/docs/planning-artifacts" "$REPORT_TMP/docs/test-artifacts" \
         "$REPORT_TMP/.gaia/config" "$REPORT_TMP/.gaia/state"

# Seed prerequisite artifacts for gate validation
echo "# Test Plan" > "$REPORT_TMP/docs/test-artifacts/test-plan.md"
echo "# Traceability Matrix" > "$REPORT_TMP/docs/test-artifacts/traceability-matrix.md"
echo "# CI Setup" > "$REPORT_TMP/docs/test-artifacts/ci-setup.md"
echo "# Architecture" > "$REPORT_TMP/docs/planning-artifacts/architecture.md"

cp "$REPO_ROOT/tests/cluster-6-parity/fixture/config/project-config.yaml" \
   "$REPORT_TMP/config/project-config.yaml" 2>/dev/null || true

# Seed a gate-readable config at the canonical .gaia/config/ path so the
# design-approval gate takes the not-applicable pass (headless project).
# Copy the fixture config (has all required fields for resolve-config)
# and add the compliance flag.
if [ -f "$REPORT_TMP/config/project-config.yaml" ]; then
  cp "$REPORT_TMP/config/project-config.yaml" "$REPORT_TMP/.gaia/config/project-config.yaml"
fi
printf 'compliance:\n  ui_present: false\n' >> "$REPORT_TMP/.gaia/config/project-config.yaml"

overall_pass=true
total_elapsed=0
positive_lines=()
negative_lines=()

# ---- Positive path: all six skills ----

for skill in "${SKILLS[@]}"; do
  setup_script="$SKILLS_DIR/$skill/scripts/setup.sh"
  finalize_script="$SKILLS_DIR/$skill/scripts/finalize.sh"

  setup_status="SKIP"
  finalize_status="SKIP"
  skill_start=$(date +%s)

  if [ -f "$setup_script" ]; then
    if bash "$setup_script" >/dev/null 2>&1; then
      setup_status="PASS"
    else
      setup_status="FAIL"
      overall_pass=false
    fi
  else
    setup_status="MISSING"
    overall_pass=false
  fi

  if [ -f "$finalize_script" ]; then
    if bash "$finalize_script" >/dev/null 2>&1; then
      finalize_status="PASS"
    else
      finalize_status="FAIL"
      overall_pass=false
    fi
  else
    finalize_status="MISSING"
    overall_pass=false
  fi

  skill_end=$(date +%s)
  skill_duration=$((skill_end - skill_start))
  total_elapsed=$((total_elapsed + skill_duration))

  if [ "$setup_status" = "PASS" ] && [ "$finalize_status" = "PASS" ]; then
    combined="PASS"
  else
    combined="FAIL"
  fi

  positive_lines+=("| $skill | $combined | ${skill_duration}s | setup=$setup_status finalize=$finalize_status |")
done

# ---- Negative path: E28-S47 gate (missing test-plan.md) ----

neg_start=$(date +%s)
rm -f "$REPORT_TMP/docs/test-artifacts/test-plan.md"
if bash "$SKILLS_DIR/gaia-create-epics/scripts/setup.sh" >/dev/null 2>&1; then
  neg47_status="FAIL (should have HALTed)"
  overall_pass=false
else
  neg47_status="PASS (HALTed as expected)"
fi
neg_end=$(date +%s)
neg47_duration=$((neg_end - neg_start))
negative_lines+=("| E28-S47: missing test-plan.md | $neg47_status | ${neg47_duration}s | create-epics setup.sh |")

# Restore test-plan.md for subsequent tests
echo "# Test Plan" > "$REPORT_TMP/docs/test-artifacts/test-plan.md"

# ---- Negative path: E28-S48 gate (missing traceability-matrix.md) ----

neg_start=$(date +%s)
rm -f "$REPORT_TMP/docs/test-artifacts/traceability-matrix.md"
if bash "$SKILLS_DIR/gaia-readiness-check/scripts/setup.sh" >/dev/null 2>&1; then
  neg48a_status="FAIL (should have HALTed)"
  overall_pass=false
else
  neg48a_status="PASS (HALTed as expected)"
fi
neg_end=$(date +%s)
neg48a_duration=$((neg_end - neg_start))
negative_lines+=("| E28-S48: missing traceability-matrix.md | $neg48a_status | ${neg48a_duration}s | readiness-check setup.sh |")

# Restore traceability-matrix.md
echo "# Traceability Matrix" > "$REPORT_TMP/docs/test-artifacts/traceability-matrix.md"

# ---- Negative path: E28-S48 gate (missing ci-setup.md) ----

neg_start=$(date +%s)
rm -f "$REPORT_TMP/docs/test-artifacts/ci-setup.md"
if bash "$SKILLS_DIR/gaia-readiness-check/scripts/setup.sh" >/dev/null 2>&1; then
  neg48b_status="FAIL (should have HALTed)"
  overall_pass=false
else
  neg48b_status="PASS (HALTed as expected)"
fi
neg_end=$(date +%s)
neg48b_duration=$((neg_end - neg_start))
negative_lines+=("| E28-S48: missing ci-setup.md | $neg48b_status | ${neg48b_duration}s | readiness-check setup.sh |")

# ---- Write the report ----

if $overall_pass; then
  verdict="PASS"
else
  verdict="FAIL"
fi

cat > "$OUTPUT" <<REPORT
# Cluster 6 Architecture Skills — E2E Report

**Verdict:** $verdict
**Total duration:** ${total_elapsed}s
**Date:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Positive Path Results (AC1/AC4)

| Skill | Status | Duration | Details |
|-------|--------|----------|---------|
$(printf '%s\n' "${positive_lines[@]}")

## Negative Path Results (AC2/AC3) — Gate Enforcement

| Scenario | Status | Duration | Skill |
|----------|--------|----------|-------|
$(printf '%s\n' "${negative_lines[@]}")

## Summary

- **6** architecture skills tested end-to-end (positive path)
- **3** negative gate enforcement scenarios verified
- All gates exercised via shared validate-gate.sh (E28-S19)
- Checkpoint and lifecycle-event emission verified by the bats suite

## References

- E28-S47: create-epics requires test-plan.md (ADR-042)
- E28-S48: readiness-check requires traceability-matrix.md + ci-setup.md (ADR-042)
- E28-S51: Test architecture cluster with gate enforcement
REPORT

echo "Report written to $OUTPUT"
exit 0
