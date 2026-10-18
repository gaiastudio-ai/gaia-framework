#!/usr/bin/env bats
# round-lifecycle-integration.bats — end-to-end integration tests for the
# per-round review-record lifecycle.  Drives record-round, gate runs,
# consolidation, complete-round and assert-round-complete in sequence.
#
# Dual-shell: runs on both bash 5 and macOS /bin/bash 3.2 via
# BASH_UNDER_TEST.  The 3.2 run prints $BASH_VERSION at the start.
#
# Every test that exercises a NEW subcommand FAILS in the red phase because
# the dispatch case does not exist yet ("unknown subcommand" exit 1).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BASH_UNDER_TEST="${BASH_UNDER_TEST:-bash}"
VALID_RUN_ID="round-20261016T120000Z-12345"
VALID_RUN_ID_2="round-20261016T130000Z-67890"
VALID_RUN_ID_3="round-20261016T140000Z-11111"

# Six canonical register gate names.
CANONICAL_GATES=(
  code-review
  qa-tests
  security-review
  test-automate
  test-review
  performance-review
)

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/register-write.sh"
  if [ ! -x "$SCRIPT" ]; then
    echo "register-write.sh not executable: $SCRIPT" >&2
    return 1
  fi
  REPORT_PATH="$SCRIPTS_DIR/resolve-review-report-path.sh"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP"
  export PROJECT_ROOT="${BATS_TMPDIR:-${TMPDIR:-/tmp}}/integ-$$-${BATS_TEST_NUMBER}"
  mkdir -p "$PROJECT_ROOT"

  echo "# Integration test running under: $("$BASH_UNDER_TEST" --version | head -1)" >&3
}

teardown() {
  # Clean up the per-test PROJECT_ROOT directory.
  if [ -n "$PROJECT_ROOT" ] && [ -d "$PROJECT_ROOT" ]; then
    rm -rf "$PROJECT_ROOT"
  fi
  common_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_write_story_with_ac() {
  local path="$1" key="$2"
  local ac_text="${3:-"- [ ] AC1: The system does something."}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<STORY
---
template: 'story'
key: "${key}"
title: "Test Story"
status: in-progress
epic: "${key%%-*}"
---
# Story: Test Story

## Acceptance Criteria

${ac_text}

## Tasks / Subtasks

- [ ] Task 1: Do something.

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |

## Findings

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| — | — | — | — | — |
STORY
}

_init_git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  printf 'init\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "init"
  git -C "$dir" rev-parse HEAD
}

_make_commit() {
  local dir="$1" fname="$2"
  printf 'change\n' > "$dir/$fname"
  git -C "$dir" add "$fname"
  git -C "$dir" commit -q -m "add $fname"
  git -C "$dir" rev-parse HEAD
}

# ===================================================================
# End-to-end round lifecycle
# ===================================================================

@test "end-to-end round: record, gate runs, consolidation, complete, assert" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # 1. Record a round with one gate.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=selected by run-all-reviews"
  [ "$status" -eq 0 ]

  # 2. Record a gate run (completed).
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # 3. Record the report.
  local report="$TEST_TMP/code-review-report.md"
  printf 'code review passed\n' > "$report"
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # 4. Complete the round.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # 5. Assert the round is complete.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 0 ]
}

@test "partial round rejected" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Record a round but do NOT record gate run or report.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # complete-round should fail.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 1 ]

  # assert should report incomplete.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
}

@test "stale-commit round rejected" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Gate run + report.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Move HEAD.
  _make_commit "$repo_dir" "newfile.txt" >/dev/null

  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 1 ]
}

@test "superseded round rejected" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Supersede with a new round.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Try to complete the old one.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 1 ]
}

@test "widened-brief round rejected" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Gate run + report.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Complete the round.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Bind a brief, then widen it.
  local brief="$TEST_TMP/brief.md"
  printf 'fix this\n' > "$brief"
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  printf 'fix this AND that\n' > "$brief"  # edit the file (widens)

  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
  grep -qi "widened\|brief" <<<"$output"
}

@test "brief bound to complete round then edited — assert-round-complete exits 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  # Edit the brief.
  printf 'expanded brief\n' > "$brief"

  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
}

@test "code-tree resolution binds to worktree HEAD not primary" {
  # Two repos: "primary" and "worktree". The round should bind to the
  # worktree HEAD, which is a different SHA.
  local primary="$TEST_TMP/primary"
  local primary_sha
  primary_sha="$(_init_git_repo "$primary")"

  local wt_dir="$TEST_TMP/worktree"
  local wt_sha
  wt_sha="$(_init_git_repo "$wt_dir")"
  _make_commit "$wt_dir" "wt-change.txt" >/dev/null
  wt_sha="$(git -C "$wt_dir" rev-parse HEAD)"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Record the round against the worktree (not primary).
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$wt_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local recorded_sha
  recorded_sha="$(yq '.rounds[0].commit_sha' "$reg")"
  [ "$recorded_sha" = "$wt_sha" ]
  [ "$recorded_sha" != "$primary_sha" ]
}

@test "first orchestrated round on standalone-history story" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Create a register with only standalone gate_runs (no rounds[]).
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg")"
  printf 'schema_version: 1\nstory: TEST-S1\ngate_runs:\n  - run_id: "standalone-20261015-001"\n    gate: code-review\n    at: "2026-10-15T00:00:00Z"\n    outcome: completed\nentries: []\n' > "$reg"

  # round-info should report none for all gates.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 1 ]
  grep -q "last_completed_run code-review none" <<<"$output"

  # Record the first orchestrated round — should succeed.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=no carryable evidence"
  [ "$status" -eq 0 ]

  # Gate run + report.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Complete — should succeed (no predecessor with a different SHA).
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # assert-round-complete — should pass.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 0 ]
}

@test "skip-list gate with no carryable evidence moves to selected and runs" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # round-info with no register — all gates none.
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 1 ]
  grep -q "last_completed_run code-review none" <<<"$output"
  grep -q "last_completed_run qa-tests none" <<<"$output"

  # Record a round selecting both code-review and qa-tests (promoted from skip).
  run env LC_ALL=C "$BASH_UNDER_TEST" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=selected by run-all-reviews" \
    --gate "qa-tests=no carryable evidence"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local gate_count
  gate_count="$(yq '.rounds[0].selected_gates | length' "$reg")"
  [ "$gate_count" -eq 2 ]
}
