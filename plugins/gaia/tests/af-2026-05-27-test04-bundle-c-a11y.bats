#!/usr/bin/env bats
# AF-2026-05-27 — Test04 Bundle C: a11y gate residual.
#
#   F-012: gaia-validate-design-a11y no longer silently soft-skips on
#          compliance.ui_present!=true — it auto-detects UI from ux-design.md
#          when ui_present is unset, and emits an ACTIONABLE message otherwise.
#   F-013: the a11y report's test-artifacts/ output location is documented as
#          intentional (ADR-119 grouping) rather than left surprising.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SK="$PLUGIN_ROOT/skills/gaia-validate-design-a11y/SKILL.md"
}

teardown() { common_teardown; }

@test "F-012: a11y gate auto-detects UI presence from ux-design.md when ui_present unset" {
  grep -qF 'Guard for actionability + UX auto-detect' "$SK"
  grep -qF 'UI presence inferred from ux-design.md' "$SK"
}

@test "F-012: a11y skip message is actionable (names /gaia-config-compliance + re-run)" {
  grep -qF '/gaia-config-compliance to set compliance.ui_present: true' "$SK"
  grep -qF 're-run /gaia-validate-design-a11y' "$SK"
}

@test "F-012: explicit false still skips (does not run a11y on a non-UI project)" {
  # The false / no-evidence branch must still exit early — gate not weakened.
  grep -qF 'explicitly `false`, OR unset with no UX evidence' "$SK"
}

@test "F-013: a11y report test-artifacts location documented as intentional" {
  grep -qF 'Output-location note.' "$SK"
  grep -qF 'grouped with the other test artifacts' "$SK"
}
