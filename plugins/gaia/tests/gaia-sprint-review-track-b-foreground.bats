#!/usr/bin/env bats
# gaia-sprint-review-track-b-foreground.bats — TC-SGR-26 anti-pattern static grep
#
# Story: E93-S4. Traces to AC2, NFR-069, T-SGR-4.

setup() {
  RUNNER="${BATS_TEST_DIRNAME}/../skills/gaia-sprint-review/scripts/track-b-dispatch.sh"
}

@test ".1: runner does not contain --headed=false literal" {
  ! grep -Eq -- "--headed=false" "$RUNNER"
}

@test ".2: runner does not contain --headless flag" {
  ! grep -Eq -- "--headless" "$RUNNER"
}

@test ".3: runner does not contain --machine flag" {
  ! grep -Eq -- "--machine" "$RUNNER"
}

@test ".4: runner does not contain headless: true" {
  ! grep -Eq "headless:[[:space:]]*true" "$RUNNER"
}

@test ".5: runner does not contain playwright_headed: false" {
  ! grep -Eq "playwright_headed:[[:space:]]*false" "$RUNNER"
}

@test ".6: runner sources the foreground-enforcement primitives" {
  # Either explicit GAIA_HEADLESS check or [ -t 1 ] TTY check must appear
  grep -q "GAIA_HEADLESS" "$RUNNER"
}
