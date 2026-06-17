#!/usr/bin/env bats
# validate-gate.bats — unit tests for plugins/gaia/scripts/validate-gate.sh
# Public functions covered: abs_path, gate_path, list_gates, evaluate_gate,
# main.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/validate-gate.sh"
  export TEST_ARTIFACTS="$TEST_TMP/test-artifacts"
  mkdir -p "$TEST_ARTIFACTS"
}
teardown() { common_teardown; }

@test "validate-gate.sh: --help prints usage on stdout and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *[Uu]sage* ]]
}

@test "validate-gate.sh: --list enumerates all gate types" {
  run "$SCRIPT" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_plan_exists"* ]]
  [[ "$output" == *"traceability_exists"* ]]
  [[ "$output" == *"ci_setup_exists"* ]]
  [[ "$output" == *"atdd_exists"* ]]
  [[ "$output" == *"readiness_report_exists"* ]]
  [[ "$output" == *"file_exists"* ]]
}

@test "validate-gate.sh: test_plan_exists happy path returns 0" {
  printf 'x' > "$TEST_ARTIFACTS/test-plan.md"
  run "$SCRIPT" test_plan_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: missing test-plan.md fails with stable error format" {
  run "$SCRIPT" test_plan_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: test_plan_exists failed"* ]]
  # AF-2026-05-22-5: test_plan_exists now lists all 4 acceptable paths
  # ("expected one of:" instead of "expected:"). Accept either form.
  [[ "$output" == *"expected:"* ]] || [[ "$output" == *"expected one of:"* ]]
}

@test "validate-gate.sh: traceability_exists happy path" {
  printf 'x' > "$TEST_ARTIFACTS/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: atdd_exists requires --story" {
  run "$SCRIPT" atdd_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"--story"* ]]
}

@test "validate-gate.sh: atdd_exists resolves story key" {
  printf 'x' > "$TEST_ARTIFACTS/atdd-E1-S1.md"
  run "$SCRIPT" atdd_exists --story E1-S1
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: file_exists multi-file happy path" {
  printf 'x' > "$TEST_TMP/a.md"; printf 'x' > "$TEST_TMP/b.md"
  run "$SCRIPT" file_exists --file "$TEST_TMP/a.md" --file "$TEST_TMP/b.md"
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: file_exists first-missing fails with clear error" {
  printf 'x' > "$TEST_TMP/a.md"
  run "$SCRIPT" file_exists --file "$TEST_TMP/a.md" --file "$TEST_TMP/missing.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing.md"* ]]
}

@test "validate-gate.sh: --multi happy path reports aggregate pass" {
  printf 'x' > "$TEST_ARTIFACTS/test-plan.md"
  printf 'x' > "$TEST_ARTIFACTS/traceability-matrix.md"
  printf 'x' > "$TEST_ARTIFACTS/ci-setup.md"
  run "$SCRIPT" --multi "test_plan_exists,traceability_exists,ci_setup_exists"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 gates passed"* ]]
}

@test "validate-gate.sh: --multi fails fast on first missing gate" {
  printf 'x' > "$TEST_ARTIFACTS/test-plan.md"
  run "$SCRIPT" --multi "test_plan_exists,traceability_exists"
  [ "$status" -eq 1 ]
  [[ "$output" == *"traceability_exists"* ]]
}

@test "validate-gate.sh: unknown gate type fails with non-zero" {
  run "$SCRIPT" bogus_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"bogus_gate"* ]]
}

@test "validate-gate.sh: missing file error names absolute path" {
  # E28-S152: readiness_report_exists now resolves against PLANNING_ARTIFACTS
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  run "$SCRIPT" readiness_report_exists
  [ "$status" -eq 1 ]
  local abs
  abs="$(cd "$PLANNING_ARTIFACTS" && pwd)"
  [[ "$output" == *"$abs/readiness-report.md"* ]]
}

# --- E28-S152: readiness_report_exists resolves against PLANNING_ARTIFACTS ---

@test "validate-gate.sh: readiness_report_exists happy path uses PLANNING_ARTIFACTS" {
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  printf '# Readiness\n' > "$PLANNING_ARTIFACTS/readiness-report.md"
  run "$SCRIPT" readiness_report_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: readiness_report_exists fails when PLANNING_ARTIFACTS file missing" {
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  # No readiness-report.md created under PLANNING_ARTIFACTS
  # Also create one under TEST_ARTIFACTS to prove the old path is no longer used
  printf '# Stale\n' > "$TEST_ARTIFACTS/readiness-report.md"
  run "$SCRIPT" readiness_report_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"readiness_report_exists failed"* ]]
}

# --- E28-S97: epics_and_stories_exists gate type ---

@test "validate-gate.sh: epics_and_stories_exists happy path returns 0" {
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  printf '# Epics\n' > "$PLANNING_ARTIFACTS/epics-and-stories.md"
  run "$SCRIPT" epics_and_stories_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: epics_and_stories_exists fails when file missing" {
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  run "$SCRIPT" epics_and_stories_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"epics_and_stories_exists failed"* ]]
  [[ "$output" == *"expected:"* ]]
}

@test "validate-gate.sh: --list includes epics_and_stories_exists" {
  run "$SCRIPT" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"epics_and_stories_exists"* ]]
}

# --- E28-S198: prd_exists gate type ---

@test "validate-gate.sh: prd_exists happy path returns 0" {
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  printf '# PRD\n' > "$PLANNING_ARTIFACTS/prd.md"
  run "$SCRIPT" prd_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: prd_exists fails when file missing with stable error format" {
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  run "$SCRIPT" prd_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: prd_exists failed"* ]]
  [[ "$output" == *"expected:"* ]]
  local abs
  abs="$(cd "$PLANNING_ARTIFACTS" && pwd)"
  [[ "$output" == *"$abs/prd.md"* ]]
}

@test "validate-gate.sh: prd_exists fails when file is zero bytes" {
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  : > "$PLANNING_ARTIFACTS/prd.md"
  run "$SCRIPT" prd_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"prd_exists failed"* ]]
}

@test "validate-gate.sh: prd_exists honors PLANNING_ARTIFACTS env var override" {
  export PLANNING_ARTIFACTS="$TEST_TMP/custom-planning"
  mkdir -p "$PLANNING_ARTIFACTS"
  printf '# PRD\n' > "$PLANNING_ARTIFACTS/prd.md"
  run "$SCRIPT" prd_exists
  [ "$status" -eq 0 ]
  [[ "$output" != *"failed"* ]]
}

@test "validate-gate.sh: --list includes prd_exists" {
  run "$SCRIPT" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"prd_exists"* ]]
}

@test "validate-gate.sh: --help includes prd_exists in enumeration" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"prd_exists"* ]]
}

# --- E53-S233: dual-layout acceptance (flat OR sharded {name}/index.md) ---
# Fixtures live under tests/fixtures/{sharded,flat,empty}-planning-artifacts/.
# The fixtures path is resolved relative to BATS_TEST_DIRNAME (the tests/ dir).

@test "validate-gate.sh: prd_exists accepts sharded prd/index.md layout" {
  export PLANNING_ARTIFACTS="$BATS_TEST_DIRNAME/fixtures/sharded-planning-artifacts/docs/planning-artifacts"
  # Fixture has prd/index.md but NO flat prd.md.
  [ ! -f "$PLANNING_ARTIFACTS/prd.md" ]
  [ -s "$PLANNING_ARTIFACTS/prd/index.md" ]
  run "$SCRIPT" prd_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: epics_and_stories_exists accepts sharded epics-and-stories/index.md layout" {
  # NOTE: AC2 literal fixture text in story E53-S233 says `epics/index.md`, but Task 1
  # mandates generic ${P%.md}/index.md derivation per AC9. Fixture path here matches
  # the generic rule (epics-and-stories/index.md). See Findings table for downstream
  # follow-up (project's real layout uses `epics/index.md`, requiring either a flat-path
  # update in validate-gate.sh or a project-side rename).
  export PLANNING_ARTIFACTS="$BATS_TEST_DIRNAME/fixtures/sharded-planning-artifacts/docs/planning-artifacts"
  [ ! -f "$PLANNING_ARTIFACTS/epics-and-stories.md" ]
  [ -s "$PLANNING_ARTIFACTS/epics-and-stories/index.md" ]
  run "$SCRIPT" epics_and_stories_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: prd_exists still accepts legacy flat prd.md layout (regression guard)" {
  export PLANNING_ARTIFACTS="$BATS_TEST_DIRNAME/fixtures/flat-planning-artifacts/docs/planning-artifacts"
  # Fixture has flat prd.md but NO sharded prd/index.md.
  [ -s "$PLANNING_ARTIFACTS/prd.md" ]
  [ ! -f "$PLANNING_ARTIFACTS/prd/index.md" ]
  run "$SCRIPT" prd_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: epics_and_stories_exists still accepts legacy flat layout (regression guard)" {
  export PLANNING_ARTIFACTS="$BATS_TEST_DIRNAME/fixtures/flat-planning-artifacts/docs/planning-artifacts"
  [ -s "$PLANNING_ARTIFACTS/epics-and-stories.md" ]
  [ ! -f "$PLANNING_ARTIFACTS/epics/index.md" ]
  run "$SCRIPT" epics_and_stories_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: AC6 prd_exists fails with canonical message reporting flat path when neither layout exists" {
  export PLANNING_ARTIFACTS="$TEST_TMP/empty-planning-artifacts/docs/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS"
  run "$SCRIPT" prd_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: prd_exists failed"* ]]
  [[ "$output" == *"expected:"* ]]
  # Reported path is the FLAT path (preserves log-parser contract).
  local abs
  abs="$(cd "$PLANNING_ARTIFACTS" && pwd)"
  [[ "$output" == *"$abs/prd.md"* ]]
  # Reported path is NOT the sharded path.
  [[ "$output" != *"$abs/prd/index.md"* ]]
}

@test "validate-gate.sh: AC7 prd_exists fails with empty-file message naming sharded index.md when only sharded layout is 0 bytes" {
  export PLANNING_ARTIFACTS="$TEST_TMP/zero-byte-planning/docs/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS/prd"
  : > "$PLANNING_ARTIFACTS/prd/index.md"
  # No flat prd.md.
  run "$SCRIPT" prd_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"prd_exists failed"* ]]
  [[ "$output" == *"file is empty (0 bytes)"* ]]
  # Empty-file message reports the actual resolved path (sharded index.md), not the flat path.
  local abs
  abs="$(cd "$PLANNING_ARTIFACTS" && pwd)"
  [[ "$output" == *"$abs/prd/index.md"* ]]
}

@test "validate-gate.sh: AC8 --list documents dual-layout for prd_exists and epics_and_stories_exists" {
  run "$SCRIPT" --list
  [ "$status" -eq 0 ]
  # Affected gates show both layouts via the generic ${P%.md}/index.md derivation.
  [[ "$output" == *"prd.md"*"OR"*"prd/index.md"* ]]
  [[ "$output" == *"epics-and-stories.md"*"OR"*"epics-and-stories/index.md"* ]]
  # Unaffected gates remain single-layout.
  [[ "$output" == *"file_exists"*"--file"* ]]
  [[ "$output" == *"atdd-{story}.md"* ]]
}

@test "validate-gate.sh: AC9 resolver code path contains no hardcoded gate names (genericity)" {
  # Inspect check_file_nonempty body — must not reference prd_exists or
  # epics_and_stories_exists by name.
  local body
  body=$(awk '/^check_file_nonempty\(\)/,/^\}/' "$SCRIPT")
  [[ "$body" != *"prd_exists"* ]]
  [[ "$body" != *"epics_and_stories_exists"* ]]
}

# --- E53-S233 end ---

# --- Brownfield legacy directory-name alias for epics_and_stories_exists ---
# When a project's shard root predates ADR-070 it may live at `epics/index.md`
# instead of the canonical `epics-and-stories/index.md`. The resolver's Step 3
# accepts that legacy form so add-feature and other gate-guarded skills do
# not falsely halt on brownfield projects.

@test "validate-gate.sh: epics_and_stories_exists accepts legacy epics/index.md (brownfield alias)" {
  export PLANNING_ARTIFACTS="$TEST_TMP/legacy-epics-shard/docs/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS/epics"
  printf '# Epics shard index\n' > "$PLANNING_ARTIFACTS/epics/index.md"
  # No flat epics-and-stories.md AND no canonical epics-and-stories/index.md.
  [ ! -f "$PLANNING_ARTIFACTS/epics-and-stories.md" ]
  [ ! -f "$PLANNING_ARTIFACTS/epics-and-stories/index.md" ]
  run "$SCRIPT" epics_and_stories_exists
  [ "$status" -eq 0 ]
}

@test "validate-gate.sh: epics_and_stories_exists fails when legacy epics/index.md is empty (0 bytes)" {
  export PLANNING_ARTIFACTS="$TEST_TMP/legacy-epics-shard-empty/docs/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS/epics"
  : > "$PLANNING_ARTIFACTS/epics/index.md"
  run "$SCRIPT" epics_and_stories_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"file is empty (0 bytes)"* ]]
  local abs
  abs="$(cd "$PLANNING_ARTIFACTS" && pwd)"
  [[ "$output" == *"$abs/epics/index.md"* ]]
}

@test "validate-gate.sh: epics_and_stories_exists prefers flat over legacy epics/index.md" {
  export PLANNING_ARTIFACTS="$TEST_TMP/both-flat-and-legacy/docs/planning-artifacts"
  mkdir -p "$PLANNING_ARTIFACTS/epics"
  printf '# Flat epics\n' > "$PLANNING_ARTIFACTS/epics-and-stories.md"
  printf '# Legacy shard index\n' > "$PLANNING_ARTIFACTS/epics/index.md"
  run "$SCRIPT" epics_and_stories_exists
  [ "$status" -eq 0 ]
}

# --- end brownfield alias tests ---

