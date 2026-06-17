#!/usr/bin/env bats
# ci-wait.bats — bats coverage for E55-S13 D1 (TC-DSF-1).
#
# Verifies that ci-wait.sh polls the gh CLI with the correct JSON field
# names. The gh CLI's `pr checks` subcommand only exposes these JSON
# fields: bucket, completedAt, description, event, link, name, startedAt,
# state, workflow. The legacy `--json status,conclusion` request is rejected
# with "Unknown JSON field: \"status\"".
#
# Story: E55-S13 — dev-story workflow friction bundle.
# Defect: D1 — ci-wait.sh queried `--json status,conclusion` against
#              gh 2.88.x, producing 5 transient polling failures and a HALT.

load 'test_helper.bash'

CI_WAIT_REL="../skills/gaia-dev-story/scripts/ci-wait.sh"

setup() {
  common_setup
  CI_WAIT="$(cd "$BATS_TEST_DIRNAME/$(dirname "$CI_WAIT_REL")" && pwd)/$(basename "$CI_WAIT_REL")"
}

teardown() { common_teardown; }

# TC-DSF-1 — ci-wait.sh MUST not request the deprecated `status` / `conclusion`
# fields from `gh pr checks`. The fix renames the field path to `state` /
# `bucket` (the canonical fields exposed by gh 2.88.x).
@test "ci-wait.sh references only canonical gh pr-checks JSON fields" {
  # Negative: no request for the deprecated `status` field path.
  run grep -c -- '--json[^"]*status' "$CI_WAIT"
  [ "$status" -eq 0 ] || [ "$output" = "0" ]

  # Positive: requests the canonical `state` field (sufficient for state-based
  # gating) OR `bucket` (the one-word summary).
  run grep -E -- '--json[[:space:]]*[^"]*\b(state|bucket)\b' "$CI_WAIT"
  [ "$status" -eq 0 ]
}

# TC-DSF-1b — Pending / failure detection MUST use the new field path.
# The legacy implementation grepped for `"status":"IN_PROGRESS"` and
# `"conclusion":"FAILURE"`. The fix uses `bucket` (pass/fail/pending/skipping).
@test "ci-wait.sh detection uses the new field path (bucket)" {
  # The legacy patterns must be gone.
  run grep -E '"status":"(IN_PROGRESS|QUEUED|PENDING)"' "$CI_WAIT"
  [ "$status" -ne 0 ]

  run grep -E '"conclusion":"(FAILURE|CANCELLED|TIMED_OUT)"' "$CI_WAIT"
  [ "$status" -ne 0 ]

  # The new bucket-based detection MUST be present.
  run grep -E '"bucket":"(pending|fail)"' "$CI_WAIT"
  [ "$status" -eq 0 ]
}
