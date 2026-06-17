#!/usr/bin/env bash
# issue-1314-ux-template-components-heading.bats
#
# The shipped ux-design-template.md §8 heading was "Design System / Component
# Reuse", but the create-ux finalize SV-09 check calls
# heading_present(ARTIFACT, "Components") — and heading_present uses anchored
# stem matching, so "Component Reuse" does NOT satisfy "Components". The shipped
# template therefore fails its own producer's SV-09 gate. The fix aligns the
# template heading so SV-09 passes on the canonical template.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATE="$PLUGIN_ROOT/skills/gaia-create-ux/ux-design-template.md"
  HEADING_LIB="$PLUGIN_ROOT/scripts/lib/heading-present.sh"
}
teardown() { common_teardown; }

@test "issue-1314: the shipped ux-design template satisfies (Components heading)" {
  [ -f "$TEMPLATE" ]
  [ -f "$HEADING_LIB" ]
  # shellcheck disable=SC1090
  source "$HEADING_LIB"
  run heading_present "$TEMPLATE" "Components"
  # heading_present echoes pass|fail (exit 0 either way) — assert the verdict.
  [ "$output" = "pass" ]
}

@test "issue-1314: the §8 heading leads with the Components stem" {
  grep -qE '^## 8\.[[:space:]]+Components' "$TEMPLATE"
}
