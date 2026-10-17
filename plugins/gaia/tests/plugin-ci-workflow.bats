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

@test "plugin-ci.yml: shard apt install lines do NOT install kcov" {
  # The bats-shard jobs run apt-get install for their dependencies.  kcov
  # must not appear as a package token (it is unavailable on Ubuntu 24.04
  # noble and would break the install step).
  #
  # Scope to the bats-shard job (the sharded runner that replaced the old
  # monolithic bats-tests job) by reading from `  bats-shard:` up to the
  # next top-level job (`^  [a-z]` two-space indent).
  shard_job="$(awk '
    /^  bats-shard:/ { in_job=1; print; next }
    in_job && /^  [a-z][a-z0-9_-]*:/ { in_job=0 }
    in_job { print }
  ' "$WORKFLOW")"

  # The bats-shard job block must exist.
  [ -n "$shard_job" ]

  # Find any apt-get install line in the shard job and assert it does
  # not include the kcov package token.
  apt_lines="$(printf '%s\n' "$shard_job" | grep -E 'apt-get +install' || true)"
  [ -n "$apt_lines" ]

  if grep -Eq '(^|[[:space:]])kcov([[:space:]]|$)' <<<"$apt_lines"; then
    echo "apt install line still references kcov: $apt_lines" >&2
    return 1
  fi
}

@test "plugin-ci.yml: bats-tests gate runs public-function coverage check" {
  run grep -F 'check-public-function-coverage.sh' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "plugin-ci.yml: shard jobs use parallel for concurrent file execution" {
  # Each shard runs bats --jobs N with GNU parallel for concurrent file
  # execution (same approach as the old monolithic job).  Verify the
  # parallel package is installed and BATS_JOBS is configured.
  shard_job="$(awk '
    /^  bats-shard:/ { in_job=1; print; next }
    in_job && /^  [a-z][a-z0-9_-]*:/ { in_job=0 }
    in_job { print }
  ' "$WORKFLOW")"
  echo "$shard_job" | grep -qF 'parallel'
  echo "$shard_job" | grep -qF 'BATS_JOBS'
}
