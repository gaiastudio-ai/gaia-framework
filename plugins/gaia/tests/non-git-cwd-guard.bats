#!/usr/bin/env bats
# non-git-cwd-guard.bats — coverage for the non-git CWD skip-with-warning guard
# applied to the seven dev-story git-dependent scripts (E53-S234, AC2 + AC5).
#
# Story: E53-S234 — Document non-git docs/ workspace + degrade git ops gracefully
# Anchor ADRs: ADR-070, ADR-072
#
# Each guarded script, when invoked from a CWD that is NOT inside a git work
# tree, MUST exit 0 and emit a "skipped (non-git CWD)" warning to stderr. This
# allows /gaia-dev-story Steps 10-13 to run from project-root (no .git) without
# halting the workflow.
#
# Scripts under test (per AC2):
#   - skills/gaia-dev-story/scripts/promotion-chain-guard.sh
#   - skills/gaia-dev-story/scripts/git-branch.sh
#   - scripts/git-push.sh
#   - skills/gaia-dev-story/scripts/pr-create.sh
#   - skills/gaia-dev-story/scripts/ci-wait.sh
#   - skills/gaia-dev-story/scripts/merge.sh
#   - skills/gaia-dev-story/scripts/verify-pr-merged.sh

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  DEVSTORY_SCRIPTS="$PLUGIN_ROOT/skills/gaia-dev-story/scripts"
  SHARED_SCRIPTS="$PLUGIN_ROOT/scripts"
  # Build a non-git fixture CWD: ensure it is NOT inside any git work tree.
  NONGIT_CWD="$TEST_TMP/non-git-fixture"
  mkdir -p "$NONGIT_CWD"
  # Defensive: assert the fixture is genuinely outside a work tree by reading
  # the git verdict from inside it.
  ( cd "$NONGIT_CWD" && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) \
    || skip "fixture CWD unexpectedly inside a git work tree"
}

teardown() { common_teardown; }

# Helper: assert the captured run was a "skipped (non-git CWD)" success.
assert_skipped_non_git() {
  [ "$status" -eq 0 ] || {
    printf 'expected exit 0, got %s. stderr: %s\n' "$status" "$stderr" >&2
    return 1
  }
  [[ "$stderr" == *"skipped (non-git CWD)"* ]] || {
    printf 'stderr missing skip warning: %s\n' "$stderr" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC2 + AC5: each of the seven scripts skip-with-warning on non-git CWD
# ---------------------------------------------------------------------------

@test "non-git CWD: promotion-chain-guard.sh skips with warning" {
  cd "$NONGIT_CWD"
  PROJECT_CONFIG="$NONGIT_CWD/missing.yaml" \
    run --separate-stderr "$DEVSTORY_SCRIPTS/promotion-chain-guard.sh"
  assert_skipped_non_git
}

@test "non-git CWD: git-branch.sh skips with warning" {
  cd "$NONGIT_CWD"
  PROJECT_PATH="$NONGIT_CWD" \
    run --separate-stderr "$DEVSTORY_SCRIPTS/git-branch.sh" E53-S234 sample-slug
  assert_skipped_non_git
}

@test "non-git CWD: git-push.sh skips with warning" {
  cd "$NONGIT_CWD"
  GAIA_GIT_PUSH_BACKOFF=0 \
    run --separate-stderr "$SHARED_SCRIPTS/git-push.sh"
  assert_skipped_non_git
}

@test "non-git CWD: pr-create.sh skips with warning" {
  cd "$NONGIT_CWD"
  PROJECT_PATH="$NONGIT_CWD" \
    run --separate-stderr "$DEVSTORY_SCRIPTS/pr-create.sh" E53-S234 "sample title"
  assert_skipped_non_git
}

@test "non-git CWD: ci-wait.sh skips with warning" {
  cd "$NONGIT_CWD"
  PROJECT_PATH="$NONGIT_CWD" \
    run --separate-stderr "$DEVSTORY_SCRIPTS/ci-wait.sh" 1234 --timeout 1
  assert_skipped_non_git
}

@test "non-git CWD: merge.sh skips with warning" {
  cd "$NONGIT_CWD"
  PROJECT_PATH="$NONGIT_CWD" \
    run --separate-stderr "$DEVSTORY_SCRIPTS/merge.sh" 1234 E53-S234
  assert_skipped_non_git
}

@test "non-git CWD: verify-pr-merged.sh skips with warning" {
  cd "$NONGIT_CWD"
  PROJECT_PATH="$NONGIT_CWD" \
    run --separate-stderr "$DEVSTORY_SCRIPTS/verify-pr-merged.sh" E53-S234 staging
  assert_skipped_non_git
}

# ---------------------------------------------------------------------------
# Consistency check: all seven scripts emit the same canonical phrase. This
# protects against drift where one script invents a different warning text.
# ---------------------------------------------------------------------------

@test "non-git CWD: canonical 'skipped (non-git CWD)' phrase used by all 7 scripts" {
  cd "$NONGIT_CWD"

  local script
  for script in \
      "$DEVSTORY_SCRIPTS/promotion-chain-guard.sh" \
      "$DEVSTORY_SCRIPTS/git-branch.sh:E53-S234:sample-slug" \
      "$SHARED_SCRIPTS/git-push.sh" \
      "$DEVSTORY_SCRIPTS/pr-create.sh:E53-S234:sample title" \
      "$DEVSTORY_SCRIPTS/ci-wait.sh:1234:--timeout:1" \
      "$DEVSTORY_SCRIPTS/merge.sh:1234:E53-S234" \
      "$DEVSTORY_SCRIPTS/verify-pr-merged.sh:E53-S234:staging" ; do
    # Split path:arg1:arg2:... on the first colon-segment that is not a path.
    local IFS=':'
    # shellcheck disable=SC2206
    local parts=( $script )
    unset IFS
    local path="${parts[0]}"
    # Avoid `${args[@]}` under `set -u` when the slice is empty (bash 3.2 quirk).
    local -a args=()
    if [ "${#parts[@]}" -gt 1 ]; then
      args=( "${parts[@]:1}" )
    fi
    PROJECT_PATH="$NONGIT_CWD" PROJECT_CONFIG="$NONGIT_CWD/missing.yaml" \
      GAIA_GIT_PUSH_BACKOFF=0 \
      run --separate-stderr "$path" ${args[@]+"${args[@]}"}
    [ "$status" -eq 0 ] || {
      printf 'script %s exited %s. stderr: %s\n' "$path" "$status" "$stderr" >&2
      return 1
    }
    [[ "$stderr" == *"skipped (non-git CWD)"* ]] || {
      printf 'script %s missing canonical skip phrase. stderr: %s\n' \
        "$path" "$stderr" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Negative control: inside a real git work tree, the guard does NOT skip.
# This protects against the trivial "always skip" implementation passing.
# We use the plugin's own work tree as the in-tree fixture.
# ---------------------------------------------------------------------------

@test "in-git CWD: promotion-chain-guard.sh does NOT emit non-git skip warning" {
  cd "$PLUGIN_ROOT"
  # Force the ABSENT path so the script's normal exit semantics don't depend
  # on local config files, then assert the non-git skip phrase is absent.
  PROJECT_CONFIG="$TEST_TMP/missing.yaml" \
    run --separate-stderr "$DEVSTORY_SCRIPTS/promotion-chain-guard.sh"
  # Expected non-git path: ABSENT (exit 1) from plugin root since no
  # ci_cd.promotion_chain in $TEST_TMP/missing.yaml.
  [[ "$stderr" != *"skipped (non-git CWD)"* ]] || {
    printf 'in-git CWD unexpectedly emitted non-git skip phrase: %s\n' "$stderr" >&2
    return 1
  }
}
