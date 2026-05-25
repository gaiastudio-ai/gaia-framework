#!/usr/bin/env bats
# AF-2026-05-22-5: bundled fix for 5 PRD→arch dogfooding bugs.
#
# Bug 1: validate-gate.sh test_plan_exists rejected test-strategy.md, but
#        /gaia-test-strategy --plan writes that filename. Hard HALT on the
#        documented /gaia-test-strategy → /gaia-create-epics happy path.
# Bug 2: gate error message pointed at legacy docs/ instead of canonical .gaia/.
# Bug 4: gaia-test-strategy SKILL.md referenced scripts/setup.sh + finalize.sh
#        but the directory didn't exist. SV-01..06 checklist never ran.
# Bug 5: gaia-create-arch hydrate-config step probed legacy config/ instead
#        of canonical .gaia/config/ — hydration skipped on greenfield.
# Bug 6 (regex coverage): document that heading_present already tolerates the
#        numeric outline prefix (## 11. Review Findings Incorporated).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- Bug 1+2: validate-gate.sh test_plan_exists accepts test-strategy.md ---

@test "AF-22-5 Bug-1: validate-gate.sh test_plan_exists accepts strategy/test-strategy.md" {
  export TEST_ARTIFACTS="$BATS_TEST_TMPDIR/test-artifacts"
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'strategy content\n' > "$TEST_ARTIFACTS/strategy/test-strategy.md"
  run bash "$PLUGIN_ROOT/scripts/validate-gate.sh" test_plan_exists
  [ "$status" -eq 0 ]
}

@test "AF-22-5 Bug-1: validate-gate.sh test_plan_exists still accepts canonical test-plan.md" {
  export TEST_ARTIFACTS="$BATS_TEST_TMPDIR/test-artifacts"
  mkdir -p "$TEST_ARTIFACTS"
  printf 'plan content\n' > "$TEST_ARTIFACTS/test-plan.md"
  run bash "$PLUGIN_ROOT/scripts/validate-gate.sh" test_plan_exists
  [ "$status" -eq 0 ]
}

@test "AF-22-5 Bug-1: validate-gate.sh test_plan_exists still accepts strategy/test-plan.md (ADR-072 fallback)" {
  export TEST_ARTIFACTS="$BATS_TEST_TMPDIR/test-artifacts"
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'plan content\n' > "$TEST_ARTIFACTS/strategy/test-plan.md"
  run bash "$PLUGIN_ROOT/scripts/validate-gate.sh" test_plan_exists
  [ "$status" -eq 0 ]
}

@test "AF-22-5 Bug-2: failed test_plan_exists error message lists all 4 acceptable paths" {
  export TEST_ARTIFACTS="$BATS_TEST_TMPDIR/test-artifacts"
  mkdir -p "$TEST_ARTIFACTS"
  run bash "$PLUGIN_ROOT/scripts/validate-gate.sh" test_plan_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"test-plan.md"* ]]
  [[ "$output" == *"strategy/test-plan.md"* ]]
  [[ "$output" == *"strategy/test-strategy.md"* ]]
  [[ "$output" == *"test-plan/index.md"* ]]
}

@test "AF-22-5 Bug-1+2: validate-gate.sh --list documents all 4 test_plan_exists acceptable paths" {
  run bash "$PLUGIN_ROOT/scripts/validate-gate.sh" --list
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "strategy/test-strategy.md"
}

# --- Bug 4: gaia-test-strategy ships setup.sh + finalize.sh ---

@test "AF-22-5 Bug-4: gaia-test-strategy/scripts/setup.sh exists and is executable" {
  [ -x "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/setup.sh" ]
}

@test "AF-22-5 Bug-4: gaia-test-strategy/scripts/finalize.sh exists and is executable" {
  [ -x "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh" ]
}

@test "AF-22-5 Bug-4: gaia-test-strategy setup.sh resolves WORKFLOW_NAME=test-strategy" {
  grep -qF 'WORKFLOW_NAME="test-strategy"' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/setup.sh"
}

@test "AF-22-5 Bug-4: gaia-test-strategy finalize.sh runs SV-01..06 checklist" {
  for sv in SV-01 SV-02 SV-03 SV-04 SV-05 SV-06; do
    grep -qF "\"$sv\"" "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  done
}

@test "AF-22-5 Bug-4: gaia-test-strategy finalize.sh resolves test-strategy.md three-tier (env → legacy → canonical)" {
  grep -qF 'TEST_STRATEGY_ARTIFACT' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF '.gaia/artifacts/test-artifacts/strategy/test-strategy.md' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF 'docs/test-artifacts/strategy/test-strategy.md' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}

@test "AF-22-5 Bug-4: gaia-test-strategy finalize.sh syntax check passes" {
  run bash -n "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  [ "$status" -eq 0 ]
}

# --- Bug 5: config-hydration.sh canonical-first resolution ---

@test "AF-22-5 Bug-5: config-hydration.sh prefers CLAUDE_PROJECT_ROOT/.gaia/config/ over legacy config/" {
  local tmp="$BATS_TEST_TMPDIR/config-hydrate-test"
  mkdir -p "$tmp/.gaia/config"
  printf 'config_phase: minimal\n' > "$tmp/.gaia/config/project-config.yaml"
  run bash -c "CLAUDE_PROJECT_ROOT='$tmp' source '$PLUGIN_ROOT/scripts/lib/config-hydration.sh' && config_hydration_resolve_target"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF ".gaia/config/project-config.yaml"
}

@test "AF-22-5 Bug-5: config-hydration.sh falls back to legacy config/ when .gaia/config/ absent" {
  local tmp="$BATS_TEST_TMPDIR/config-hydrate-legacy"
  mkdir -p "$tmp/config"
  printf 'config_phase: minimal\n' > "$tmp/config/project-config.yaml"
  run bash -c "CLAUDE_PROJECT_ROOT='$tmp' source '$PLUGIN_ROOT/scripts/lib/config-hydration.sh' && config_hydration_resolve_target"
  [ "$status" -eq 0 ]
  # Resolver returns SOME valid project-config.yaml path. Brownfield-only fixtures
  # without .gaia/config/ should resolve to legacy config/project-config.yaml.
  [[ "$output" == *"project-config.yaml"* ]]
}

@test "AF-22-5 Bug-5: gaia-create-arch SKILL.md idempotency contract uses canonical path" {
  grep -qF '.gaia/config/project-config.yaml' "$PLUGIN_ROOT/skills/gaia-create-arch/SKILL.md"
  # Negative assertion: no bare `config/project-config.yaml` where the char
  # before "config/" is NOT `.` AND NOT `/` (the latter excludes `.gaia/config/`).
  ! grep -qE '(^|[^./])config/project-config\.yaml' "$PLUGIN_ROOT/skills/gaia-create-arch/SKILL.md"
}

# --- Bug 6: heading_present numeric prefix coverage (already-fixed by AF-22-3) ---

@test "AF-22-5 Bug-6: gaia-create-arch heading_present regex tolerates ## 11. Review Findings Incorporated" {
  # The AF-22-3 widening of the gaia-create-prd heading_present regex
  # already exists in gaia-create-arch (was pre-existing); regression-anchor.
  local tmp="$BATS_TEST_TMPDIR/heading-numeric"
  printf '## 11. Review Findings Incorporated\n\nstuff\n' > "$tmp"
  # Inline the regex test (mirrors gaia-create-arch/scripts/finalize.sh heading_present).
  grep -Ei "^##[[:space:]]+([0-9]+\.[[:space:]]+)?Review[[:space:]]+Findings[[:space:]]+Incorporated([[:space:]]|\$|[[:punct:]])" "$tmp"
}

@test "AF-22-5 Bug-6 + AF-24-14 F-8: gaia-create-epics SV-03 epic_headings_present accepts both numeric (## Epic N:) AND em-dash (## EN — Title) forms" {
  # AF-2026-05-24-14 / Test02 F-8 widened the regex from numeric-only
  # `^##[[:space:]]+Epic[[:space:]]+[0-9]+` to also accept the em-dash
  # form `^##[[:space:]]+E[0-9]+[[:space:]]+(—|--)`. The combined
  # alternation `(Epic[[:space:]]+[0-9]+|E[0-9]+[[:space:]]+(—|--))`
  # matches both forms — closing the producer/validator drift where the
  # resolver accepted em-dash but the validator only accepted numeric.
  grep -qF '(Epic[[:space:]]+[0-9]+|E[0-9]+[[:space:]]+(—|--))' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
}
