#!/usr/bin/env bats
# yield-gate-regression-2026-05-08.bats — regression test for the
# 2026-05-08 incident where /gaia-meeting executed end-to-end with zero
# YIELD-STOP sentinels (E76-S9, AC5, TC-MTG-YGATE-4).
#
# Two fixtures:
#   - run-2026-05-08-no-yields.txt    (control, pre-fix): no sentinels.
#   - run-2026-05-08-with-yields.txt   (post-fix): canonical sentinels in order.
#
# The control test asserts that the CONTROL fixture has zero sentinels — that
# is the regression signal. The post-fix test asserts the post-fix fixture has
# all six canonical sentinels in canonical order.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CONTROL_FIXTURE="$BATS_TEST_DIRNAME/fixtures/run-2026-05-08-no-yields.txt"
  POSTFIX_FIXTURE="$BATS_TEST_DIRNAME/fixtures/run-2026-05-08-with-yields.txt"
}

@test "Pre-flight: control fixture exists" {
  [ -f "$CONTROL_FIXTURE" ]
}

@test "Pre-flight: post-fix fixture exists" {
  [ -f "$POSTFIX_FIXTURE" ]
}

@test "AC5: control fixture has ZERO YIELD-STOP sentinels (regression signal)" {
  count="$(grep -c '^<<YIELD-STOP ' "$CONTROL_FIXTURE" || true)"
  [ "$count" = "0" ]
}

@test "AC5: post-fix fixture has SIX YIELD-STOP sentinels in canonical order" {
  count="$(grep -c '^<<YIELD-STOP ' "$POSTFIX_FIXTURE" || true)"
  [ "$count" = "6" ]
  ordered_phases="$(grep -oE '<<YIELD-STOP phase=[a-z-]+' "$POSTFIX_FIXTURE" | sed 's/<<YIELD-STOP phase=//')"
  expected="post-charter
post-research
discuss-cadence
discuss-cadence
pre-close
pre-save"
  [ "$ordered_phases" = "$expected" ]
}

@test "AC5: control fixture would FAIL the sentinel-presence assertion (regression detected)" {
  # This test models what AC5 calls out: the control fixture, when fed through
  # the same sentinel-presence assertion as the post-fix fixture, MUST fail.
  count="$(grep -c '^<<YIELD-STOP ' "$CONTROL_FIXTURE" || true)"
  # The expectation for a passing run is at least one sentinel; control has 0,
  # so this comparison is intentionally a failure-equivalent: we assert the
  # presence-count is below the post-fix threshold.
  [ "$count" -lt 1 ]
}

@test "AC5: post-fix fixture passes the sentinel-presence assertion" {
  count="$(grep -c '^<<YIELD-STOP ' "$POSTFIX_FIXTURE" || true)"
  [ "$count" -ge 1 ]
}
