#!/usr/bin/env bats
# E75-S4-readme-rsv2-updates.bats — covers AC1..AC5 for the README updates per
# FR-RSV2-48 (and the FR-RSV2-23 rename map cross-reference).
#
# Story: docs/implementation-artifacts/epic-E75-gaia-review-system-v2-polish/
# stories/E75-S4-framework-readme-updates-...md
#
# Eight test scenarios from the story's Test Scenarios table:
#   1. /gaia-test-automate classified as action skill (AC1)
#   2. Review Gate count documented as up to seven (AC2)
#   3. Renamed command /gaia-config-ci present (AC3)
#   4. Renamed command /gaia-test-strategy present (AC3)
#   5. New command /gaia-review-all documented (AC4)
#   6. New command /gaia-review-mobile documented (AC4)
#   7. Deployment-phase commands present (AC4)
#   8. No stale six-gate references remain (AC2)
# Plus AC5: deprecated alias rows present with replacement pointers.

bats_require_minimum_version 1.5.0

README="$BATS_TEST_DIRNAME/../../../README.md"

@test "AC1 / scenario 1: README lists /gaia-test-automate under action-skill category (not review-skill)" {
  [ -f "$README" ]
  # The action-skills section must mention /gaia-test-automate by name with the
  # test-automation-expansion description.
  run grep -Ei '^\|.*`/gaia-test-automate`.*test.automation' "$README"
  [ "$status" -eq 0 ]
  # And it must NOT be listed as one of the review skills (review-skill rows
  # carry the canonical /gaia-review-* prefix; /gaia-test-automate must never
  # appear in a row that begins with `/gaia-review-`).
  run grep -E '^\|.*`/gaia-review-.*test-automate' "$README"
  [ "$status" -ne 0 ]
}

@test "AC2 / scenario 2: README documents the Review Gate as up to seven gates" {
  run grep -Ei 'up to seven (gates|rows)' "$README"
  [ "$status" -eq 0 ]
  # Five always-on gates named explicitly.
  run grep -F '/gaia-review-code' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-review-qa' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-review-security' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-review-test' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-review-perf' "$README"; [ "$status" -eq 0 ]
  # Two conditional gates named explicitly.
  run grep -F '/gaia-review-a11y' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-review-mobile' "$README"; [ "$status" -eq 0 ]
  # ADR-082 cited as the authority for the seven-gate count.
  run grep -F 'ADR-082' "$README"; [ "$status" -eq 0 ]
}

@test "AC3 / scenario 3: README lists /gaia-config-ci (renamed from /gaia-ci-setup)" {
  run grep -F '/gaia-config-ci' "$README"
  [ "$status" -eq 0 ]
}

@test "AC3 / scenario 4: README lists /gaia-test-strategy (collapses /gaia-test-design + /gaia-test-framework)" {
  run grep -F '/gaia-test-strategy' "$README"
  [ "$status" -eq 0 ]
}

@test "AC4 / scenario 5: README documents the new /gaia-review-all composite command" {
  run grep -F '/gaia-review-all' "$README"
  [ "$status" -eq 0 ]
  # Must mention its gating semantics (composite verdict / aggregator).
  run grep -Ei 'composite|aggregat' "$README"
  [ "$status" -eq 0 ]
}

@test "AC4 / scenario 6: README documents the new /gaia-review-mobile gate with Talia" {
  run grep -F '/gaia-review-mobile' "$README"
  [ "$status" -eq 0 ]
  run grep -F 'Talia' "$README"
  [ "$status" -eq 0 ]
}

@test "AC4 / scenario 7: README lists the deployment-phase test commands" {
  run grep -F '/gaia-test-e2e' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-test-perf' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-test-dast' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-test-a11y' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-test-device-matrix' "$README"; [ "$status" -eq 0 ]
  run grep -F '/gaia-deploy' "$README"; [ "$status" -eq 0 ]
}

@test "AC2 / scenario 8: README has no stale 'six-gate' or 'six gates' references in the Review Gate section" {
  # Stale-count guard: search for 'six' immediately followed by 'gate' or
  # 'gates' (case-insensitive, hyphen or whitespace separator). The canonical
  # post-RSV2 count is 'up to seven'.
  run grep -Ei 'six[ -]gate' "$README"
  [ "$status" -ne 0 ]
}

@test "AC5: README documents deprecated aliases with replacement pointers" {
  # Deprecation table must point /gaia-ci-setup at /gaia-config-ci.
  run grep -E '/gaia-ci-setup.*/gaia-config-ci' "$README"
  [ "$status" -eq 0 ]
  # And /gaia-test-design at /gaia-test-strategy.
  run grep -E '/gaia-test-design.*/gaia-test-strategy' "$README"
  [ "$status" -eq 0 ]
  # And /gaia-test-framework at /gaia-test-strategy.
  run grep -E '/gaia-test-framework.*/gaia-test-strategy' "$README"
  [ "$status" -eq 0 ]
}
