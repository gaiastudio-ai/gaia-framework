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

# --------------- Gate-integrity regression tests (sharded architecture) ---------------
# These tests parse the workflow YAML with yq and assert the structural
# invariants that keep the bats-tests gate job from silently passing when
# a shard fails.  Each test has a per-mutant proof below.

@test "gate-integrity: bats-tests needs includes bats-shard" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  needs="$(yq '.jobs.bats-tests.needs[]' "$WORKFLOW" 2>/dev/null)"
  grep -qF 'bats-shard' <<< "$needs"
}

@test "gate-integrity: bats-tests has if: always() so it runs when shards fail" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  if_val="$(yq '.jobs.bats-tests.if' "$WORKFLOW" 2>/dev/null)"
  grep -qF 'always()' <<< "$if_val"
}

@test "gate-integrity: bats-tests first step checks shard result and fails on non-success" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  # The first step must have an if-condition that checks the shard result
  # AND a run block that exits non-zero.
  first_if="$(yq '.jobs.bats-tests.steps[0].if' "$WORKFLOW" 2>/dev/null)"
  first_run="$(yq '.jobs.bats-tests.steps[0].run' "$WORKFLOW" 2>/dev/null)"
  grep -qF 'needs.bats-shard.result' <<< "$first_if"
  grep -qF 'success' <<< "$first_if"
  grep -qF 'exit 1' <<< "$first_run"
}

@test "gate-integrity: bats-shard matrix has fail-fast: false" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  ff="$(yq '.jobs.bats-shard.strategy.fail-fast' "$WORKFLOW" 2>/dev/null)"
  [ "$ff" = "false" ]
}

@test "gate-integrity: shard-assignment validator has no continue-on-error or || true" {
  # Extract the validate step from the shard job and assert it has no
  # error-suppression patterns.
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  validate_step="$(yq '.jobs.bats-shard.steps[] | select(.name == "Validate shard assignments*")' "$WORKFLOW" 2>/dev/null)"
  [ -n "$validate_step" ]
  # No continue-on-error
  coe="$(yq '.jobs.bats-shard.steps[] | select(.name == "Validate shard assignments*") | .continue-on-error' "$WORKFLOW" 2>/dev/null)"
  [ "$coe" = "null" ] || [ -z "$coe" ]
  # No || true in the run command
  run_cmd="$(yq '.jobs.bats-shard.steps[] | select(.name == "Validate shard assignments*") | .run' "$WORKFLOW" 2>/dev/null)"
  ! grep -qF '|| true' <<< "$run_cmd"
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
  grep -qF 'parallel' <<< "$shard_job"
  grep -qF 'BATS_JOBS' <<< "$shard_job"
}
