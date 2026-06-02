#!/usr/bin/env bats
# resolve-config-cwd-independence.bats — AF-2026-05-17-2 regression guard
#
# Asserts that resolve-config.bats's setup() cd's into TEST_TMP so the
# subject script's L5 $PWD discovery step finds no project-config.yaml
# at $PWD and falls through to the CLAUDE_SKILL_DIR fixture path.
#
# Without this guard, running bats from a directory whose CWD (or an
# ancestor, via the walk-up step at L4b) contains config/project-config.yaml
# silently substitutes the real project config for the fixture and breaks
# all fixture-based assertions — 16 of 76 tests fail when bats runs from
# the project root instead of from gaia-framework/.
#
# This regression test does NOT modify the script's documented precedence
# ladder ($PWD > CLAUDE_SKILL_DIR per L5/L6); it only verifies that the
# resolve-config.bats setup() compensates by cd'ing into a clean directory
# so the fixture path can be exercised.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  BATS_FILE="$REPO_ROOT/plugins/gaia/tests/resolve-config.bats"
  export LC_ALL=C
}

@test "resolve-config.bats exists" {
  [ -f "$BATS_FILE" ]
}

@test "resolve-config.bats setup() cd's into TEST_TMP (AF-2026-05-17-2)" {
  # The setup function must contain a 'cd "$TEST_TMP"' line so the L5
  # $PWD-discovery step misses and falls through to CLAUDE_SKILL_DIR.
  run grep -E 'cd "\$TEST_TMP"' "$BATS_FILE"
  [ "$status" -eq 0 ]
}

@test "resolve-config.bats setup() references AF-2026-05-17-2 lineage" {
  run grep -E 'AF-2026-05-17-2' "$BATS_FILE"
  [ "$status" -eq 0 ]
}

@test "resolve-config.bats runs green from a parent-of-gaia-framework CWD" {
  # The whole point of AF-2026-05-17-2 — bats invocation from project root
  # (one dir up from gaia-framework/) must succeed end-to-end.
  cd "$REPO_ROOT/.."
  run bats "$BATS_FILE"
  [ "$status" -eq 0 ]
  # Expect the standard plan line for the suite
  [[ "$output" == *"1.."* ]]
}
