#!/usr/bin/env bats
# vcp-chk-25-readiness-check-positive.bats — E42-S13 positive test for
# the V1 65-item /gaia-readiness-check checklist ported to V2.
#
# Covers VCP-CHK-25 (positive) per docs/test-artifacts/test-plan.md and
# story AC1: given a readiness-report.md artifact satisfying all 65
# items, finalize.sh exits 0 and every script-verifiable item reports
# PASS.
#
# The finalize.sh under test reads READINESS_ARTIFACT (fixture path)
# so tests point at per-test fixtures rather than scanning the repo
# working tree. PROJECT_ROOT is set to the repo root so referenced
# upstream files (prd.md / architecture.md / test-plan.md) resolve on
# disk for the artifact-presence checks. Checkpoint + lifecycle-event
# side effects continue to succeed regardless of checklist outcome
# (story AC5 + E42-S1..S12 precedent).

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s13-readiness-check"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-readiness-check"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
  # Seed a self-contained PROJECT_ROOT with the upstream artifacts
  # the positive fixture references. This keeps the test environment-
  # independent (no dependency on the real repo docs/ tree).
  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/docs/planning-artifacts" "$PROJECT_ROOT/docs/test-artifacts"
  : > "$PROJECT_ROOT/docs/planning-artifacts/prd.md"
  : > "$PROJECT_ROOT/docs/planning-artifacts/architecture.md"
  : > "$PROJECT_ROOT/docs/test-artifacts/test-plan.md"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-25 — Positive: all 65 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for status frontmatter anchor" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status field present in YAML frontmatter"* ]]
}

@test "finalize.sh reports 25/25 script-verifiable PASS items" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"25/25 script-verifiable items PASS"* ]]
}

@test "output enumerates every category header" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[category: artifact presence]"* ]]
  [[ "$output" == *"[category: cross-artifact coherence]"* ]]
  [[ "$output" == *"[category: cascade resolution]"* ]]
  [[ "$output" == *"[category: traceability]"* ]]
  [[ "$output" == *"[category: sizing]"* ]]
  [[ "$output" == *"[category: gate verdict]"* ]]
}

@test "total items summary reports 65" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total items: 65"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit. Every item in the SKILL.md ## Validation
# section must carry a [script-verifiable] or [LLM-checkable] tag, and
# the count must be exactly 65.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 65 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "65" ]
}

@test "every Validation item is classified script-verifiable or LLM-checkable" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- / && !/^- \[(script-verifiable|LLM-checkable)\]/ { bad++ }
    END { print bad + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "status-frontmatter check is classified script-verifiable" {
  # Per epic design: the gate-verdict "status field" anchor MUST land
  # on script-verifiable (YAML frontmatter structural check).
  run grep -E '^\- \[script-verifiable\].*status field present in YAML frontmatter' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md ## Validation sits between ## Steps and ## Finalize" {
  run awk '
    /^## Steps/      { steps = NR }
    /^## Validation/ { validation = NR }
    /^## Finalize/   { finalize = NR }
    END {
      if (steps > 0 && validation > 0 && finalize > 0 \
          && validation > steps && validation < finalize) { print "ok" }
      else { print "bad" }
    }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "script-verifiable count is 25 in SKILL.md Validation" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[script-verifiable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "25" ]
}

@test "LLM-checkable count is 40 in SKILL.md Validation" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[LLM-checkable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "40" ]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still run on
# positive path. Observability must not be contingent on checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written on positive path" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/implementation-readiness.yaml" ] \
    || [ -f "$CHECKPOINT_PATH/gaia-readiness-check.yaml" ]
}

# -------------------------------------------------------------------------
# WORKFLOW_NAME integrity — MUST remain "implementation-readiness"
# (matches the V1 workflow id; V1 source directory is
# _gaia/lifecycle/workflows/3-solutioning/implementation-readiness/).
# -------------------------------------------------------------------------

@test "WORKFLOW_NAME in finalize.sh is implementation-readiness" {
  run grep -E '^WORKFLOW_NAME="implementation-readiness"' "$FINALIZE"
  [ "$status" -eq 0 ]
}
