#!/usr/bin/env bats
# AF-2026-05-26-9: four F-17-class lifecycle-gate path bugs in the sprint-setup
# path that blocked /gaia-sprint-plan on ADR-072 strategy/-placement projects
# under strict-lifecycle mode. All four delegate path-resolution to
# validate-gate.sh (flat | strategy/ | sharded) while preserving the existing
# strict-mode + bypass-record wrapper.
#
# F1: gaia-sprint-plan/setup.sh traceability gate (bootstrap probe + active gate)
#     accepts all 3 placements, not flat-only.
# F2: gaia-dev-story/setup.sh F-33 gate resolves the sharded index.md form too.
# F3: gaia-readiness-check/setup.sh zero-byte guard resolves all 3 placements
#     before the -s check (no false "exists but empty" on a strategy/ matrix).
# F4: gaia-sprint-plan/setup.sh readiness gate keys off the readiness-report
#     frontmatter status (PASS/CONDITIONAL), not the never-written
#     readiness-check-ledger.yaml.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  PLUGIN="$REPO_ROOT/gaia-public/plugins/gaia"
  SP_SETUP="$PLUGIN/skills/gaia-sprint-plan/scripts/setup.sh"
  DS_SETUP="$PLUGIN/skills/gaia-dev-story/scripts/setup.sh"
  RC_SETUP="$PLUGIN/skills/gaia-readiness-check/scripts/setup.sh"
  VALIDATE_GATE="$PLUGIN/scripts/validate-gate.sh"
}

teardown() { common_teardown; }

# --- F1: sprint-plan traceability gate is multi-path ---

@test "AF-26-9 F1: sprint-plan setup delegates traceability to validate-gate.sh (multi-path)" {
  grep -qF 'traceability_exists' "$SP_SETUP"
  grep -qF '_trace_present' "$SP_SETUP"
}

@test "AF-26-9 F1: sprint-plan no longer hardcodes the flat-only TRACE_ART probe" {
  # The old flat-only active-gate assignment is gone.
  run grep -F 'TRACE_ART="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/test-artifacts/traceability-matrix.md"' "$SP_SETUP"
  [ "$status" -ne 0 ]
}

@test "AF-26-9 F1: sprint-plan preserves the strict-mode + bypass wrapper" {
  grep -qF -- '--bypass gaia-trace' "$SP_SETUP"
  grep -qF '_has_bypass_for' "$SP_SETUP"
  grep -qF 'strict_mode_on' "$SP_SETUP"
}

@test "AF-26-9 F1: _trace_present fallback accepts flat | strategy/ | sharded" {
  for p in 'test-artifacts/traceability-matrix.md' 'test-artifacts/strategy/traceability-matrix.md' 'test-artifacts/traceability-matrix/index.md'; do
    grep -qF "$p" "$SP_SETUP" || { echo "missing placement $p in sprint-plan fallback"; false; }
  done
}

# --- F2: dev-story F-33 gate resolves the sharded form ---

@test "AF-26-9 F2: dev-story setup resolves the sharded traceability-matrix/index.md form" {
  grep -qF 'traceability-matrix/index.md' "$DS_SETUP"
}

@test "AF-26-9 F2: dev-story still resolves strategy/ and flat placements" {
  grep -qF 'strategy/traceability-matrix.md' "$DS_SETUP"
  # flat form is resolved via the $_ta base-dir variable: $_ta/traceability-matrix.md
  grep -qF '$_ta/traceability-matrix.md' "$DS_SETUP"
}

# --- F3: readiness-check zero-byte guard is multi-path ---

@test "AF-26-9 F3: readiness-check resolves all 3 placements before the -s zero-byte check" {
  grep -qF 'strategy/traceability-matrix.md' "$RC_SETUP"
  grep -qF 'traceability-matrix/index.md' "$RC_SETUP"
}

@test "AF-26-9 F3: readiness-check no longer emits the misleading 'exists but empty' for a strategy/ matrix" {
  # The die message was reworded to name all three accepted placements.
  grep -qF 'any accepted placement' "$RC_SETUP"
}

# --- F4: sprint-plan readiness gate keys off the report, not the phantom ledger ---

@test "AF-26-9 F4: sprint-plan readiness gate keys off readiness-report frontmatter status" {
  grep -qF 'readiness_report_exists' "$SP_SETUP"
  grep -qE 'status:\[\[:space:\]\]\*\(PASS\|PASSED\|CONDITIONAL\)' "$SP_SETUP" \
    || grep -qF 'status:[[:space:]]*(PASS|PASSED|CONDITIONAL)' "$SP_SETUP"
}

@test "AF-26-9 F4: sprint-plan no longer greps the never-written ledger verdict line" {
  # The dead `readiness-check-ledger.yaml` verdict grep is gone from the gate.
  run grep -F 'verdict:[[:space:]]*PASSED' "$SP_SETUP"
  [ "$status" -ne 0 ]
}

# --- basis: validate-gate predicates accept the placements the fixes rely on ---

@test "AF-26-9 basis: validate-gate.sh traceability_exists accepts the strategy/ placement" {
  local ta="$BATS_TEST_TMPDIR/test-artifacts"
  mkdir -p "$ta/strategy"
  printf 'matrix\n' > "$ta/strategy/traceability-matrix.md"
  TEST_ARTIFACTS="$ta" run bash "$VALIDATE_GATE" traceability_exists
  [ "$status" -eq 0 ]
}

@test "AF-26-9 basis: validate-gate.sh traceability_exists accepts the sharded index.md form" {
  local ta="$BATS_TEST_TMPDIR/test-artifacts"
  mkdir -p "$ta/traceability-matrix"
  printf 'matrix\n' > "$ta/traceability-matrix/index.md"
  TEST_ARTIFACTS="$ta" run bash "$VALIDATE_GATE" traceability_exists
  [ "$status" -eq 0 ]
}

@test "AF-26-9 basis: validate-gate.sh readiness_report_exists accepts the canonical report" {
  local pa="$BATS_TEST_TMPDIR/planning-artifacts"
  mkdir -p "$pa"
  printf -- '---\nstatus: CONDITIONAL\n---\n' > "$pa/readiness-report.md"
  PLANNING_ARTIFACTS="$pa" run bash "$VALIDATE_GATE" readiness_report_exists
  [ "$status" -eq 0 ]
}
