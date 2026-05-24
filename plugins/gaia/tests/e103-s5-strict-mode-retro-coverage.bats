#!/usr/bin/env bats
# e103-s5-strict-mode-retro-coverage.bats
# Story: E103-S5 — --strict-lifecycle helper + retro bypass section + coverage metric.
# Origin: AF-2026-05-24-3. Traces to: NFR-083, ADR-120, TC-LOE-5.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  STRICT_HELPER="$REPO_ROOT/gaia-public/plugins/gaia/scripts/lib/lifecycle-strict-mode.sh"
  SCHEMA="$REPO_ROOT/gaia-public/plugins/gaia/schemas/project-config.schema.json"
  RETRO_SKILL="$REPO_ROOT/gaia-public/plugins/gaia/skills/gaia-retro/SKILL.md"
  COVERAGE="$REPO_ROOT/.gaia/state/lifecycle-gate-coverage.json"
}

teardown() { common_teardown; }

@test "TC-LOE-5a: project-config.schema.json declares lifecycle.strict_mode" {
  [ -f "$SCHEMA" ]
  jq -e '.properties.lifecycle.properties.strict_mode.type == "boolean"' "$SCHEMA" >/dev/null
}

@test "TC-LOE-5b: lifecycle_strict_mode_enabled returns 0 when no config and no env" {
  unset GAIA_STRICT_LIFECYCLE
  PROJECT_CONFIG="/nonexistent/path" run bash "$STRICT_HELPER" lifecycle_strict_mode_enabled
  [ "$status" -eq 0 ]
}

@test "TC-LOE-5c: GAIA_STRICT_LIFECYCLE=0 overrides default" {
  GAIA_STRICT_LIFECYCLE=0 run bash "$STRICT_HELPER" lifecycle_strict_mode_enabled
  [ "$status" -eq 1 ]
}

@test "TC-LOE-5d: GAIA_STRICT_LIFECYCLE=1 keeps strict mode ON" {
  GAIA_STRICT_LIFECYCLE=1 run bash "$STRICT_HELPER" lifecycle_strict_mode_enabled
  [ "$status" -eq 0 ]
}

@test "TC-LOE-5e: gaia-retro SKILL.md references the Bypasses section + lifecycle helper" {
  [ -f "$RETRO_SKILL" ]
  grep -qF "Bypasses (ADR-120" "$RETRO_SKILL"
  grep -qF "lifecycle_list_bypasses_for_sprint" "$RETRO_SKILL"
}

@test "TC-LOE-5f: lifecycle-gate-coverage.json exists and validates basic structure" {
  # Project-root-evidence assertion; skip outside the project-root workspace.
  [ -f "$COVERAGE" ] || skip "project-root .gaia/state/lifecycle-gate-coverage.json not present"
  jq -e '.target_coverage_pct == 100' "$COVERAGE" >/dev/null
  jq -e '.mandatory_skills | length >= 10' "$COVERAGE" >/dev/null
  jq -e '.implemented_pct_of_e103_scope == 100' "$COVERAGE" >/dev/null
}
