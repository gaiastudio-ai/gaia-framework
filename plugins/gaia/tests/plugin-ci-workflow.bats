#!/usr/bin/env bats
# plugin-ci-workflow.bats — E28-S175 regression guard for the plugin-ci.yml
# workflow shape.
#
# The `bats-tests` job previously ran `sudo apt-get install -y jq kcov` on
# Ubuntu 24.04 (noble), which fails with "E: Unable to locate package kcov"
# because kcov is not in noble's default apt repositories. This test locks in
# the shape of the fix so that a future edit cannot silently reintroduce the
# apt install of kcov and break CI on every PR again.
#
# AC mapping:
#   AC1 — bats-tests job must run to completion on noble → asserted indirectly
#         by AC2 below (if kcov is not in the apt install line, the install
#         step no longer fails).
#   AC2 — kcov must not appear in the apt install command for bats-tests.
#   AC3 — bats suite must still be invoked (run-with-coverage.sh).
#   AC4 — if kcov is dropped, the workflow yaml must carry a comment
#         explaining the decision so future maintainers understand the gap.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  export REPO_ROOT WORKFLOW
}
teardown() { common_teardown; }

@test "plugin-ci.yml: workflow file exists" {
  [ -f "$WORKFLOW" ]
}

@test "plugin-ci.yml: bats-tests job is defined" {
  run grep -E '^  bats-tests:' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "plugin-ci.yml: bats-tests apt install line does NOT install kcov" {
  # Extract the apt-get install line(s) inside the bats-tests job. The bug
  # was: `sudo apt-get install -y jq kcov`. After the fix, kcov must not
  # appear as an apt package token.
  #
  # We scope to the bats-tests job by reading from `  bats-tests:` up to the
  # next top-level job (`^  [a-z]` two-space indent).
  bats_job="$(awk '
    /^  bats-tests:/ { in_job=1; print; next }
    in_job && /^  [a-z][a-z0-9_-]*:/ { in_job=0 }
    in_job { print }
  ' "$WORKFLOW")"

  # The bats-tests job block must exist.
  [ -n "$bats_job" ]

  # Find any apt-get install line in the bats-tests job and assert it does
  # not include the kcov package token.
  apt_lines="$(printf '%s\n' "$bats_job" | grep -E 'apt-get +install' || true)"
  [ -n "$apt_lines" ]

  # `kcov` must not appear as a whitespace-delimited token in any apt-get
  # install line. A comment mentioning kcov elsewhere is fine — this check
  # targets the install command only.
  if printf '%s\n' "$apt_lines" | grep -Eq '(^|[[:space:]])kcov([[:space:]]|$)'; then
    echo "apt install line still references kcov: $apt_lines" >&2
    return 1
  fi
}

@test "plugin-ci.yml: bats-tests still invokes run-with-coverage.sh" {
  run grep -F 'plugins/gaia/tests/run-with-coverage.sh' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "plugin-ci.yml: carries an comment explaining the kcov decision" {
  # If kcov is dropped from apt install, the workflow yaml must carry a
  # comment referencing E28-S175 (or kcov) so the decision is discoverable
  # from the file itself.
  run grep -E '#.*(E28-S175|kcov)' "$WORKFLOW"
  [ "$status" -eq 0 ]
}
