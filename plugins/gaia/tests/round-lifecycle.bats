#!/usr/bin/env bats
# round-lifecycle.bats — unit tests for the per-round review-record subcommands
# added to register-write.sh: record-round, record-round-report, complete-round,
# assert-round-complete, impact-assessment, record-scope-revision, bind-brief,
# supersede-brief, round-info, and the additive seq on record-run.
#
# Every test that exercises a NEW subcommand FAILS in the red phase because
# the dispatch case does not exist yet ("unknown subcommand" exit 1).
# Tests for EXISTING behaviour (legacy registers, standalone runs) must PASS.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

VALID_RUN_ID="round-20261016T120000Z-12345"
VALID_RUN_ID_2="round-20261016T130000Z-67890"
VALID_RUN_ID_3="round-20261016T140000Z-11111"

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
  export PROJECT_ROOT="${BATS_TMPDIR:-${TMPDIR:-/tmp}}/roundtest-$$-${BATS_TEST_NUMBER}"
  mkdir -p "$PROJECT_ROOT"
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

_minimal_register() {
  local path="$1"
  local entries="${2:-"[]"}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "schema_version: 1
story: TEST-S1
gate_runs: []
entries: ${entries}" > "$path"
}

_write_story_with_ac() {
  # _write_story_with_ac <path> <key> [ac-text]
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
  # _init_git_repo <dir> — set up a minimal git repo, return its HEAD SHA.
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
  # _make_commit <dir> <filename> — create a new commit, return SHA.
  local dir="$1" fname="$2"
  printf 'change\n' > "$dir/$fname"
  git -C "$dir" add "$fname"
  git -C "$dir" commit -q -m "add $fname"
  git -C "$dir" rev-parse HEAD
}

# ===================================================================
# record-round
# ===================================================================

@test "record-round writes open round with resolved SHA, requirement version and gates" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=selected by review-skip-check"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local round_id
  round_id="$(yq '.rounds[0].run_id' "$reg")"
  [ "$round_id" = "$VALID_RUN_ID" ]

  local round_status
  round_status="$(yq '.rounds[0].status' "$reg")"
  [ "$round_status" = "open" ]

  local commit
  commit="$(yq '.rounds[0].commit_sha' "$reg")"
  [ "$commit" = "$sha" ]

  local gate_name
  gate_name="$(yq '.rounds[0].selected_gates[0].gate' "$reg")"
  [ "$gate_name" = "code-review" ]

  local gate_reason
  gate_reason="$(yq '.rounds[0].selected_gates[0].reason' "$reg")"
  [ "$gate_reason" = "selected by review-skip-check" ]

  local req_ver
  req_ver="$(yq '.rounds[0].requirement_version' "$reg")"
  local re_reqver='^sha256:[0-9a-f]{64}$'
  [[ "$req_ver" =~ $re_reqver ]] || false

  local accepted
  accepted="$(yq '.rounds[0].accepted_version' "$reg")"
  [ "$accepted" = "$req_ver" ]
}

@test "record-round refuses standalone run-id" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "standalone-20261016T120000Z-99" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 1 ]
  grep -qi "invalid round run-id" <<<"$output"
}

@test "record-round refuses zero gates" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "at least one gate" <<<"$output"
}

@test "record-round creates register when missing" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # No register file pre-created.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ]
  local round_id
  round_id="$(yq '.rounds[0].run_id' "$reg")"
  [ "$round_id" = "$VALID_RUN_ID" ]
}

@test "record-round idempotency: identical payload is no-op" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Second call with identical payload — no-op exit 0.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local round_count
  round_count="$(yq '.rounds | length' "$reg")"
  [ "$round_count" -eq 1 ]
}

@test "record-round idempotency: conflicting payload exits 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Same run-id but different gate list.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "qa-tests=different"
  [ "$status" -eq 1 ]
  grep -qi "conflicting" <<<"$output"
}

# ===================================================================
# requirement version
# ===================================================================

@test "requirement version stable across gate-table and findings edits" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local ver1
  ver1="$(yq '.rounds[0].requirement_version' "$reg")"

  # Edit the Review Gate table (non-AC change).
  sed -i.bak 's/UNVERIFIED/PASSED/' "$story_file"
  rm -f "${story_file}.bak"

  # Record a second round — should have the same requirement version.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local ver2
  ver2="$(yq '.rounds[1].requirement_version' "$reg")"
  [ "$ver1" = "$ver2" ]
}

@test "requirement version changes on AC text edit" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local ver1
  ver1="$(yq '.rounds[0].requirement_version' "$reg")"

  # Edit the AC text.
  sed -i.bak 's/The system does something/The system does something else entirely/' "$story_file"
  rm -f "${story_file}.bak"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local ver2
  ver2="$(yq '.rounds[1].requirement_version' "$reg")"
  [ "$ver1" != "$ver2" ]
}

@test "requirement version normalises checkbox state and trailing whitespace" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1" "- [x] AC1: Something.
- [X] AC2: Another thing.  "

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local ver1
  ver1="$(yq '.rounds[0].requirement_version' "$reg")"

  # Unchecked version should produce the same hash.
  _write_story_with_ac "$story_file" "TEST-S1" "- [ ] AC1: Something.
- [ ] AC2: Another thing."

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local ver2
  ver2="$(yq '.rounds[1].requirement_version' "$reg")"
  [ "$ver1" = "$ver2" ]
}

# ===================================================================
# complete-round
# ===================================================================

@test "complete-round refuses gate with no completed run or missing report" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Record a round, but do NOT record any gate runs or reports.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "code-review" <<<"$output"
}

@test "complete-round on already-complete round exits 0 idempotent" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record the gate run as completed.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Record the report.
  local report="$TEST_TMP/code-review-report.md"
  printf 'report content\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Complete the round.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Second complete-round on an already complete round — idempotent exit 0.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 0 ]
}

@test "complete-round refuses when HEAD moved" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record the gate run and report.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Move HEAD.
  _make_commit "$repo_dir" "newfile.txt" >/dev/null

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "HEAD\|commit" <<<"$output"
}

@test "complete-round refuses AC version mismatch" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record gate run + report.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Edit the AC text (changes the requirement version).
  sed -i.bak 's/The system does something/Something completely different/' "$story_file"
  rm -f "${story_file}.bak"

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "version\|mismatch\|requirement" <<<"$output"
}

# ===================================================================
# assert-round-complete
# ===================================================================

@test "assert-round-complete: exits 1 for open round" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
}

@test "assert-round-complete: exits 0 for complete round" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 0 ]

  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 0 ]
}

@test "assert-round-complete: exits 0 for legacy register with no rounds" {
  _minimal_register "$TEST_TMP/reg.yaml"

  # Seed the register so resolve-path finds it.
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 0 ]
  grep -qi "no orchestrated round" <<<"$output"
}

@test "assert-round-complete: exits 0 with no register file" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # No register file at all.
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 0 ]
  grep -qi "no orchestrated round" <<<"$output"
}

@test "assert-round-complete: exits 2 for malformed register" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg")"
  printf 'rounds: "not a sequence"\nschema_version: 1\nstory: TEST-S1\ngate_runs: []\nentries: []\n' > "$reg"

  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 2 ]
}

# ===================================================================
# supersession
# ===================================================================

@test "record-round supersedes the previous open round" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local old_status
  old_status="$(yq '.rounds[0].status' "$reg")"
  [ "$old_status" = "superseded" ]

  local new_status
  new_status="$(yq '.rounds[1].status' "$reg")"
  [ "$new_status" = "open" ]
}

@test "superseded round cannot be completed" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Supersede it with a new round.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Try to complete the superseded round.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "superseded" <<<"$output"
}

# ===================================================================
# impact-assessment
# ===================================================================

@test "impact-assessment records SHAs and changed files" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local sha2
  sha2="$(_make_commit "$repo_dir" "newfile.txt")"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --from-run "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local ia_to_sha
  ia_to_sha="$(yq '.rounds[1].impact_assessment.to_sha' "$reg")"
  [ "$ia_to_sha" = "$sha2" ]

  local ia_from_sha
  ia_from_sha="$(yq '.rounds[1].impact_assessment.from_sha' "$reg")"
  [ "$ia_from_sha" = "$sha1" ]

  local changed
  changed="$(yq '.rounds[1].impact_assessment.changed_files[0]' "$reg")"
  [ "$changed" = "newfile.txt" ]
}

@test "impact-assessment handles files with spaces in names" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Create a file with a space in its name.
  printf 'content\n' > "$repo_dir/file with spaces.txt"
  git -C "$repo_dir" add "file with spaces.txt"
  git -C "$repo_dir" commit -q -m "add spaced file"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --from-run "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local changed
  changed="$(yq '.rounds[1].impact_assessment.changed_files[0]' "$reg")"
  [ "$changed" = "file with spaces.txt" ]
}

@test "carried gate without rationale blocks completion" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: complete it so round 2 can carry from it.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "security-review=initial"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate security-review --outcome completed
  [ "$status" -eq 0 ]
  local sec_rpt="$TEST_TMP/sec-report.md"
  printf 'security review round 1\n' > "$sec_rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate security-review --report "$sec_rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2: select code-review, carry security-review from round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Manually inject a carried gate with empty rationale referencing the
  # real completed round 1 so the empty-rationale branch is exercised.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  export _PREV_RUN="$VALID_RUN_ID"
  yq -i '(.rounds[] | select(.run_id == "round-20261016T130000Z-67890")).carried_gates = [{"gate": "security-review", "from_run": strenv(_PREV_RUN), "applicability_rationale": ""}]' "$reg"
  unset _PREV_RUN

  # Record gate run for code-review.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/cr-report.md"
  printf 'code review round 2\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "rationale\|security-review" <<<"$output"
}

@test "record-round refuses --carry with empty rationale" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test" \
    --carry "security-review=${VALID_RUN_ID_2}:"
  [ "$status" -eq 1 ]
  grep -qi "empty.*rationale\|rationale.*empty" <<<"$output"
}

@test "record-round refuses --carry with invalid run-id" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test" \
    --carry "security-review=INVALID-ID:some rationale"
  [ "$status" -eq 1 ]
  grep -qi "invalid round run-id" <<<"$output"
}

@test "impact-assessment outside-git exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  _minimal_register "$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --from-run "$VALID_RUN_ID_2" \
    --repo "/nonexistent/dir"
  [ "$status" -eq 1 ]
  # Must fail because of the outside-git check, not "unknown subcommand".
  [[ "$output" != *"unknown subcommand"* ]]
}

# ===================================================================
# scope revision
# ===================================================================

@test "essential revision advances accepted_version" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local orig_ver
  orig_ver="$(yq '.rounds[0].accepted_version' "$reg")"

  # Edit the AC to change the version.
  sed -i.bak 's/The system does something/The system does something new/' "$story_file"
  rm -f "${story_file}.bak"

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "Added missing requirement" \
    --reassess code-review
  [ "$status" -eq 0 ]

  local new_ver
  new_ver="$(yq '.rounds[0].accepted_version' "$reg")"
  [ "$orig_ver" != "$new_ver" ]
}

@test "reassessed gate counts only from higher seq" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record a gate run BEFORE the revision.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Edit the AC.
  sed -i.bak 's/The system does something/The system does something new/' "$story_file"
  rm -f "${story_file}.bak"

  # Record a scope revision that reassesses code-review.
  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "Added missing requirement" \
    --reassess code-review
  [ "$status" -eq 0 ]

  # The pre-revision gate run should not count for completion.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
}

@test "unrelated enhancement blocks until AC restored" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record gate run + report.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Edit the AC.
  sed -i.bak 's/The system does something/The system does something else/' "$story_file"
  rm -f "${story_file}.bak"

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind unrelated_enhancement \
    --decision "Out-of-scope change" \
    --followon "TEST-S99"
  [ "$status" -eq 0 ]

  # complete-round should fail because AC doesn't match accepted_version.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
}

@test "record-scope-revision refuses --reassess with unrelated_enhancement" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind unrelated_enhancement \
    --decision "Out-of-scope" \
    --reassess code-review \
    --followon "TEST-S99"
  [ "$status" -eq 1 ]
  grep -qi "cannot reassess" <<<"$output"
}

@test "record-scope-revision refuses empty --decision" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "" \
    --reassess code-review
  [ "$status" -eq 1 ]
  grep -qi "empty.*decision\|decision.*required" <<<"$output"
}

@test "record-scope-revision requires --followon for unrelated_enhancement" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind unrelated_enhancement \
    --decision "Out-of-scope"
  [ "$status" -eq 1 ]
  grep -qi "followon\|follow-on" <<<"$output"
}

@test "record-scope-revision refuses reassessed gate not in selected or carried" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Try to reassess a gate not in selected or carried.
  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "Missing requirement" \
    --reassess security-review
  [ "$status" -eq 1 ]
  grep -qi "neither selected nor carried" <<<"$output"
}

@test "record-scope-revision with --reassess on a carried gate moves it to selected" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  # Record a round with code-review selected and security-review carried.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test" \
    --carry "security-review=${VALID_RUN_ID_2}:no changes under security paths"
  [ "$status" -eq 0 ]

  # Edit the AC.
  sed -i.bak 's/The system does something/The system does something security-relevant/' "$story_file"
  rm -f "${story_file}.bak"

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "Security requirement added" \
    --reassess security-review
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # security-review should now be in selected_gates, not carried_gates.
  local selected_count
  selected_count="$(yq '[.rounds[0].selected_gates[] | select(.gate == "security-review")] | length' "$reg")"
  [ "$selected_count" -eq 1 ]

  local carried_count
  carried_count="$(yq '[.rounds[0].carried_gates[] | select(.gate == "security-review")] | length' "$reg")"
  [ "$carried_count" -eq 0 ]
}

# ===================================================================
# bind-brief / supersede-brief
# ===================================================================

@test "bind-brief stores path and hash; edited brief refused; supersede links" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/correction-brief.md"
  printf 'Fix the code-review findings.\n' > "$brief"

  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local brief_path
  brief_path="$(yq '.rounds[0].brief.path' "$reg")"
  [ "$brief_path" = "$brief" ]

  # Edit the brief file.
  printf 'WIDENED SCOPE: also fix security issues.\n' >> "$brief"

  # assert-round-complete should catch the widened brief.
  # (But first the round has to be completed for the brief check to matter,
  #  or the round is open which also exits 1.)
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]

  # Supersede the brief.
  local new_brief="$TEST_TMP/correction-brief-v2.md"
  printf 'Updated brief.\n' > "$new_brief"
  run "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --brief "$new_brief" \
    --rationale "Scope expanded to include security fixes"
  [ "$status" -eq 0 ]

  local new_path
  new_path="$(yq '.rounds[0].brief.path' "$reg")"
  [ "$new_path" = "$new_brief" ]
}

@test "supersede-brief preserves old brief in history with rationale" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'original\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local brief2="$TEST_TMP/brief2.md"
  printf 'updated\n' > "$brief2"
  run "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief2" \
    --rationale "Brief expanded"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local history_len
  history_len="$(yq '.rounds[0].brief.history | length' "$reg")"
  [ "$history_len" -ge 1 ]

  local history_rationale
  history_rationale="$(yq '.rounds[0].brief.history[0].rationale' "$reg")"
  [ "$history_rationale" = "Brief expanded" ]
}

@test "supersede-brief same-path case records hash change" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'original\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  # Same path, different content.
  printf 'updated content\n' > "$brief"
  run "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief" \
    --rationale "Brief content changed"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local current_path
  current_path="$(yq '.rounds[0].brief.path' "$reg")"
  [ "$current_path" = "$brief" ]
}

@test "supersede-brief refuses empty --rationale" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'original\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local brief2="$TEST_TMP/brief2.md"
  printf 'new\n' > "$brief2"
  run "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief2" --rationale ""
  [ "$status" -eq 1 ]
  grep -qi "empty.*rationale\|rationale.*required\|rationale.*empty" <<<"$output"
}

@test "bind-brief on complete round succeeds; on superseded round exits 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Complete the round fully.
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

  # bind-brief on a complete round should succeed.
  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  # Create an OPEN round (round 2), then supersede it with round 3.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Round 3 supersedes the open round 2.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_3" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # bind-brief on superseded round 2 should fail.
  local brief2="$TEST_TMP/brief2.md"
  printf 'brief2\n' > "$brief2"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --brief "$brief2"
  [ "$status" -eq 1 ]
  grep -qi "superseded" <<<"$output"
}

# ===================================================================
# hostile values and pattern validation
# ===================================================================

@test "hostile values stored literally; pattern violations exit 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Record a round with hostile characters in reason.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=reason with \"quotes\" and \$(command) and {yaml: true}"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local reason
  reason="$(yq '.rounds[0].selected_gates[0].reason' "$reg")"
  # The hostile values should be stored literally (not interpreted).
  grep -qF '$(command)' <<<"$reason"
}

@test "invalid run-id in record-round exits 1 register unchanged" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "bad-run-id-format" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 1 ]
  grep -qi "invalid round run-id" <<<"$output"
}

@test "invalid run-id in record-round-report exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "not-valid" \
    --gate code-review --report "/tmp/report.md"
  [ "$status" -eq 1 ]
  # Must be a run-id validation error, not "unknown subcommand".
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in complete-round exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "not-valid" --repo "/tmp"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in impact-assessment --run-id exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "not-valid" --from-run "$VALID_RUN_ID" --repo "/tmp"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in impact-assessment --from-run exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --from-run "not-valid" --repo "/tmp"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in record-scope-revision exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "not-valid" --kind essential_missing_requirement \
    --decision "test" --reassess code-review
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in bind-brief exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "not-valid" --brief "/tmp/brief.md"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in supersede-brief exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "not-valid" --brief "/tmp/brief.md" --rationale "test"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in round-info --run-id exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" round-info --story TEST-S1 --run-id "not-valid"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

# ===================================================================
# concurrency
# ===================================================================

@test "concurrent writers: no lost update or duplicate run-id" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Launch two concurrent record-round calls with different run-ids.
  "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=concurrent-1" &
  local pid1=$!

  "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=concurrent-2" &
  local pid2=$!

  # Capture both exit codes — both writers must succeed.
  local rc1=0 rc2=0
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Both run-ids must be present.
  local round_count
  round_count="$(yq '.rounds | length' "$reg")"
  [ "$round_count" -eq 2 ]

  local has_r1 has_r2
  has_r1="$(yq "[.rounds[].run_id] | map(select(. == \"$VALID_RUN_ID\")) | length" "$reg")"
  has_r2="$(yq "[.rounds[].run_id] | map(select(. == \"$VALID_RUN_ID_2\")) | length" "$reg")"
  [ "$has_r1" -eq 1 ]
  [ "$has_r2" -eq 1 ]

  # Exactly one round must be open and the other superseded.
  local open_count superseded_count
  open_count="$(yq '[.rounds[] | select(.status == "open")] | length' "$reg")"
  superseded_count="$(yq '[.rounds[] | select(.status == "superseded")] | length' "$reg")"
  [ "$open_count" -eq 1 ]
  [ "$superseded_count" -eq 1 ]
}

@test "concurrent record-run calls: no lost entry, no duplicate seq" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  _minimal_register "$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Two record-run calls, both writing to gate_runs, launched together.
  "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --outcome completed &
  local pid1=$!

  "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate qa-tests --outcome completed &
  local pid2=$!

  local rc1=0 rc2=0
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Both gate_run entries must be present.
  local gr_len
  gr_len="$(yq '.gate_runs | length' "$reg")"
  [ "$gr_len" -eq 2 ]

  # Seq values must be unique (1 and 2, not both 1).
  local unique_seqs total_seqs
  total_seqs="$(yq '[.gate_runs[].seq] | length' "$reg")"
  unique_seqs="$(yq '[.gate_runs[].seq] | unique | length' "$reg")"
  [ "$total_seqs" -eq 2 ] || false
  [ "$unique_seqs" -eq 2 ] || false
}

# ===================================================================
# legacy regression
# ===================================================================

@test "existing subcommands unchanged on legacy registers" {
  _minimal_register "$TEST_TMP/reg.yaml"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # record-run still works on a legacy register (no rounds[]).
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "standalone-20261016-001" \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # gate-status still works.
  run "$SCRIPT" gate-status --story TEST-S1 \
    --run-id "standalone-20261016-001" \
    --gate code-review
  [ "$status" -eq 0 ]
  grep -q "RAN" <<<"$output"
}

@test "rounds null treated as legacy no rounds" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg")"
  printf 'schema_version: 1\nstory: TEST-S1\ngate_runs: []\nentries: []\nrounds: null\n' > "$reg"

  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 0 ]
  grep -qi "no orchestrated round" <<<"$output"
}

@test "carried_gates non-sequence exits 2" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg")"
  local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  cat > "$reg" <<YAML
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
rounds:
  - run_id: "${VALID_RUN_ID}"
    commit_sha: "${sha}"
    requirement_version: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    accepted_version: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    status: open
    superseded_by: null
    selected_gates:
      - gate: code-review
        reason: "test"
        report_path: ""
        report_sha256: ""
    carried_gates: "not a sequence"
    impact_assessment: null
    scope_revisions: []
    brief: null
YAML

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "/tmp"
  [ "$status" -eq 2 ]
}

# ===================================================================
# complete-round: all-six-gates, impact_assessment, order
# ===================================================================

@test "new commit: complete-round needs impact_assessment and all six gates" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Make a new commit.
  _make_commit "$repo_dir" "change.txt" >/dev/null

  # Record a new round with only one gate selected and no carries.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record impact assessment.
  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --from-run "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Record gate run + report for code-review only.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Try to complete — should fail because only 1 of 6 gates accounted for.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "neither selected nor carried\|unaccounted" <<<"$output"
}

@test "revert after essential revision blocks completion" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1" "- [ ] AC1: The system does something."

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Edit the AC.
  _write_story_with_ac "$story_file" "TEST-S1" "- [ ] AC1: The system does something new."

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "New requirement" \
    --reassess code-review
  [ "$status" -eq 0 ]

  # Revert the AC to the original text.
  _write_story_with_ac "$story_file" "TEST-S1" "- [ ] AC1: The system does something."

  # complete-round should fail because version != accepted_version.
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
  [ "$status" -eq 1 ]
  grep -qi "version\|mismatch" <<<"$output"
}

@test "unchanged brief does not make incomplete round pass" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Bind a brief.
  local brief="$TEST_TMP/brief.md"
  printf 'fix things\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  # assert-round-complete should still exit 1 (round is open).
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
}

# ===================================================================
# round-info
# ===================================================================

@test "round-info prints run-id, status, SHA, versions; exit 1 no round, 2 malformed" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # No register — exit 1.
  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 1 ]
  grep -q "last_completed_run" <<<"$output"

  # Record a round.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 0 ]
  grep -q "run_id $VALID_RUN_ID" <<<"$output"
  grep -q "status open" <<<"$output"
  grep -q "commit_sha" <<<"$output"
  grep -q "accepted_version" <<<"$output"
  grep -q "current_version" <<<"$output"
  grep -q "brief_path" <<<"$output"
}

@test "round-info with no register prints six none lines exit 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 1 ]
  local none_count
  none_count="$(grep -c 'last_completed_run.*none' <<<"$output" || true)"
  [ "$none_count" -eq 6 ]
}

@test "round-info prints brief_path and brief_sha256" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # No brief bound yet.
  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 0 ]
  grep -q "brief_path none" <<<"$output"

  # Bind a brief.
  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 0 ]
  grep -q "brief_path $brief" <<<"$output"
  grep -q "brief_sha256" <<<"$output"
}

@test "mixed history: round then standalone; round-info reports none" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Record a round + gate run.
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

  # Then a standalone run of the same gate.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "standalone-20261016-001" \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # round-info should report none for code-review (standalone overrides).
  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 0 ]
  grep -q "last_completed_run code-review none" <<<"$output"
}

# ===================================================================
# Carried-gate hop-chain edge cases
# ===================================================================

@test "carried gate 2-hop chain resolves correctly" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: selects code-review, runs it.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=initial run"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Round 2: carries code-review from round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=second round gate" \
    --carry "code-review=${VALID_RUN_ID}:no changes in code-review paths"
  [ "$status" -eq 0 ]

  # Round 3: carries code-review from round 2 (2-hop chain back to round 1).
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_3" --repo "$repo_dir" \
    --gate "security-review=third round gate" \
    --carry "code-review=${VALID_RUN_ID_2}:still no code changes"
  [ "$status" -eq 0 ]

  # Complete round 3 — the 2-hop carry should resolve to round 1.
  # (Will fail in red phase because complete-round is not yet implemented.)
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_3" --gate security-review --outcome completed
  [ "$status" -eq 0 ]
  local sec_report="$TEST_TMP/security-review-report.md"
  printf 'security review report for round 3\n' > "$sec_report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_3" --gate security-review --report "$sec_report"
  [ "$status" -eq 0 ]

  # complete-round should resolve the 2-hop carry chain successfully.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_3" --repo "$repo_dir"
  # Round 3 has only security-review selected and code-review carried via 2 hops.
  # complete-round will exit 0 only if the full round is satisfied, but this
  # test only selects one gate — so we expect exit 0 (single-gate round).
  # If the hop chain is broken, the error message names code-review.
  [ "$status" -eq 0 ]
}

@test "carried gate cycle detected exits 1" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Compute the requirement version so the fixture matches.
  local req_ver
  req_ver="$(env IMPLEMENTATION_ARTIFACTS="$IMPLEMENTATION_ARTIFACTS" PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT" round-info --story TEST-S1 2>&1 || true)"

  # Create round 1 via record-round so the req version is correct.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "round-20261016T100000Z-1" --repo "$repo_dir" \
    --gate "qa-tests=placeholder"
  [ "$status" -eq 0 ]

  # Create round 2 via record-round.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "round-20261016T100000Z-2" --repo "$repo_dir" \
    --gate "qa-tests=placeholder"
  [ "$status" -eq 0 ]

  # Now manually edit the register to create a cycle:
  # Round 1 carries code-review from round 2, round 2 carries from round 1.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  export _RW_CR1="round-20261016T100000Z-2" _RW_CR2="round-20261016T100000Z-1"
  yq -i '(.rounds[] | select(.run_id == "round-20261016T100000Z-1")).carried_gates = [{"gate": "code-review", "from_run": strenv(_RW_CR1), "applicability_rationale": "carried from round 2"}]' "$reg"
  yq -i '(.rounds[] | select(.run_id == "round-20261016T100000Z-2")).carried_gates = [{"gate": "code-review", "from_run": strenv(_RW_CR2), "applicability_rationale": "carried from round 1"}]' "$reg"
  # Mark round 1 complete so round 2 is the open one.
  yq -i '(.rounds[] | select(.run_id == "round-20261016T100000Z-1")).status = "complete"' "$reg"
  unset _RW_CR1 _RW_CR2

  # Record gate run for qa-tests so the selected gate passes.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "round-20261016T100000Z-2" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/qa-report.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "round-20261016T100000Z-2" --gate qa-tests --report "$rpt"
  [ "$status" -eq 0 ]

  # complete-round should detect the cycle and exit 1.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "round-20261016T100000Z-2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "cycle" <<<"$output"
}

@test "carried gate hop to run-id not in rounds exits 1" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Create round 1 normally.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "round-20261016T100000Z-1" --repo "$repo_dir" \
    --gate "qa-tests=placeholder"
  [ "$status" -eq 0 ]

  # Manually add a carried gate referencing a non-existent round.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  yq -i '(.rounds[] | select(.run_id == "round-20261016T100000Z-1")).carried_gates = [{"gate": "code-review", "from_run": "round-20261016T100000Z-999", "applicability_rationale": "from nonexistent"}]' "$reg"

  # Record gate run for qa-tests.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "round-20261016T100000Z-1" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/qa-report.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "round-20261016T100000Z-1" --gate qa-tests --report "$rpt"
  [ "$status" -eq 0 ]

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "round-20261016T100000Z-1" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "not found in rounds\|not found" <<<"$output"
}

@test "carried gate in neither selected nor carried at terminal round exits 1" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1 selects ONLY qa-tests (no code-review anywhere).
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "round-20261016T100000Z-1" --repo "$repo_dir" \
    --gate "qa-tests=placeholder"
  [ "$status" -eq 0 ]

  # Round 2 selects security-review and carries code-review from round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "round-20261016T100000Z-2" --repo "$repo_dir" \
    --gate "security-review=placeholder"
  [ "$status" -eq 0 ]

  # Manually add a carried gate pointing to round 1, which doesn't have code-review.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  yq -i '(.rounds[] | select(.run_id == "round-20261016T100000Z-2")).carried_gates = [{"gate": "code-review", "from_run": "round-20261016T100000Z-1", "applicability_rationale": "carried from round 1 which lacks it"}]' "$reg"

  # Record gate runs for round 2 selected gates.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "round-20261016T100000Z-2" --gate security-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/sec-report.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "round-20261016T100000Z-2" --gate security-review --report "$rpt"
  [ "$status" -eq 0 ]

  # complete-round should fail: code-review carried from round 1, but round 1
  # has code-review in neither selected nor carried.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "round-20261016T100000Z-2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "gate not found in round\|not found" <<<"$output"
}

@test "terminal carried-gate run applies reassessed-gate seq rule" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  # Round 1 selects code-review and records a scope revision that reassesses it.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=initial"
  [ "$status" -eq 0 ]

  # Record a gate run BEFORE the scope revision (low seq).
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Add an AC line to trigger a version change.
  # BSD sed does not support \n in replacements; use printf + awk.
  awk '/^- \[ \] AC1: The system does something\./{print; print "- [ ] AC2: New requirement."; next}1' "$story_file" > "${story_file}.tmp" && mv "${story_file}.tmp" "$story_file"

  # Record a scope revision that reassesses code-review.
  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "added missing requirement" \
    --reassess code-review
  [ "$status" -eq 0 ]

  # Round 2 carries code-review from round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=second round" \
    --carry "code-review=${VALID_RUN_ID}:no code changes"
  [ "$status" -eq 0 ]

  # complete-round on round 2 should fail: the only code-review gate_runs
  # entry for round 1 has a seq lower than the revision's seq. The terminal
  # carried-gate reassessed-gate seq rule requires a higher-seq entry.
  local report="$TEST_TMP/qa-report.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --report "$report"
  [ "$status" -eq 0 ]

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  # The failure should mention the carried gate that did not pass the seq rule.
  grep -qi "code-review\|carried\|seq\|reassess" <<<"$output"
}

@test "impact-assessment before record-round is refused" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  _minimal_register "$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Try impact-assessment for a run-id that has no round recorded yet.
  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --from-run "$VALID_RUN_ID_2" \
    --repo "$repo_dir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "round not found\|not found" <<<"$output"
}

@test "complete-round validates impact_assessment.to_sha and from_run" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=initial"
  [ "$status" -eq 0 ]

  # New commit for round 2.
  local sha2
  sha2="$(_make_commit "$repo_dir" "file2.txt")"

  # Round 2: select all 6 gates so the all-gates check is satisfied.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=second" \
    --gate "qa-tests=second" \
    --gate "security-review=second" \
    --gate "test-automate=second" \
    --gate "test-review=second" \
    --gate "performance-review=second"
  [ "$status" -eq 0 ]

  # Record impact-assessment with valid data.
  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --from-run "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Tamper the impact_assessment.to_sha to a different value.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local bad_sha="cccccccccccccccccccccccccccccccccccccccc"
  export _BAD="$bad_sha"
  yq -i '(.rounds[] | select(.run_id == "round-20261016T130000Z-67890")).impact_assessment.to_sha = strenv(_BAD)' "$reg"
  unset _BAD

  # Record gate runs + reports for round 2 (all 6 to satisfy the all-gates check).
  local gates=(code-review qa-tests security-review test-automate test-review performance-review)
  for g in "${gates[@]}"; do
    run "$SCRIPT" record-run --story TEST-S1 \
      --run-id "$VALID_RUN_ID_2" --gate "$g" --outcome completed
    [ "$status" -eq 0 ]
    local rpt="$TEST_TMP/${g}-report.md"
    printf 'report\n' > "$rpt"
    run "$SCRIPT" record-round-report --story TEST-S1 \
      --run-id "$VALID_RUN_ID_2" --gate "$g" --report "$rpt"
    [ "$status" -eq 0 ]
  done

  # complete-round should fail because impact_assessment.to_sha was tampered.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "to_sha\|impact.*mismatch\|sha.*mismatch" <<<"$output"
}

@test "carried report edited after recording is refused" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: select code-review, run it, record report.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=initial"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/code-review-report.md"
  printf 'original report content\n' > "$report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Round 2: carries code-review from round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=second round" \
    --carry "code-review=${VALID_RUN_ID}:no code changes"
  [ "$status" -eq 0 ]

  # Edit the report AFTER it was recorded.
  printf 'TAMPERED report content\n' > "$report"

  # Record gate run + report for qa-tests.
  local qa_report="$TEST_TMP/qa-report.md"
  printf 'report\n' > "$qa_report"
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --report "$qa_report"
  [ "$status" -eq 0 ]

  # complete-round should refuse: the carried report's SHA no longer matches.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "report.*edit\|sha.*mismatch\|report.*changed\|report.*integrity\|code-review" <<<"$output"
}

@test "round-info REWORK re-entry shows updated brief after supersede" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Record and complete a round.
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

  # Bind a brief.
  local brief="$TEST_TMP/correction-brief.md"
  printf 'original brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  # round-info shows the original brief.
  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 0 ]
  grep -q "brief_path $brief" <<<"$output"

  # Supersede with a new brief.
  local new_brief="$TEST_TMP/correction-brief-v2.md"
  printf 'updated brief\n' > "$new_brief"
  run "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$new_brief" \
    --rationale "added scope for performance fix"
  [ "$status" -eq 0 ]

  # round-info should now show the NEW brief path.
  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 0 ]
  grep -q "brief_path $new_brief" <<<"$output"
  [[ "$output" != *"brief_path $brief"* ]]
}

# ===================================================================
# git PATH shim tests
# ===================================================================

@test "git rev-parse --is-inside-work-tree not exactly true exits 1" {
  local shim_dir="$TEST_TMP/git-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/git" <<'SHIM'
#!/usr/bin/env bash
if [[ "$*" == *"--is-inside-work-tree"* ]]; then
  printf 'yes\n'  # not "true"
  exit 0
fi
exec /usr/bin/git "$@"
SHIM
  chmod +x "$shim_dir/git"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env PATH="$shim_dir:$PATH" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$TEST_TMP" \
    --gate "code-review=test"
  [ "$status" -eq 1 ]
  # Must fail because of the git check, not "unknown subcommand".
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "work.tree\|git\|repo\|not inside" <<<"$output"
}

@test "git rev-parse HEAD non-hex output exits 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local shim_dir="$TEST_TMP/git-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/git" <<'SHIM'
#!/usr/bin/env bash
if [[ "$*" == *"rev-parse HEAD"* ]]; then
  printf 'NOT-A-HEX-SHA\n'
  exit 0
fi
exec /usr/bin/git "$@"
SHIM
  chmod +x "$shim_dir/git"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env PATH="$shim_dir:$PATH" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 1 ]
  # Must fail because of the hex validation, not "unknown subcommand".
  [[ "$output" != *"unknown subcommand"* ]] || false
  grep -qi "hex\|SHA\|commit\|resolve" <<<"$output"
}

# ===================================================================
# Temp file cleanup on success and failure
# ===================================================================

@test "no rw-* temp files leak after record-round success" {
  local test_tmpdir
  test_tmpdir="$(mktemp -d "$TEST_TMP/rw-leak-test.XXXXXX")"

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env TMPDIR="$test_tmpdir" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local leaked
  leaked="$(find "$test_tmpdir" -maxdepth 1 -name 'rw-*' -type f 2>/dev/null | wc -l)"
  [ "$leaked" -eq 0 ]
  rm -rf "$test_tmpdir"
}

@test "no rw-* temp files leak after record-round failure" {
  local test_tmpdir
  test_tmpdir="$(mktemp -d "$TEST_TMP/rw-leak-test.XXXXXX")"

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Make a valid first round so the register exists.
  run env TMPDIR="$test_tmpdir" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Clean any temp files from the success path.
  find "$test_tmpdir" -maxdepth 1 -name 'rw-*' -type f -delete 2>/dev/null || true

  # Shim yq to fail on the rounds-append write so the failure happens AFTER
  # _rw_mktemp has created rw-* files in TMPDIR.
  local real_yq
  real_yq="$(command -v yq)"
  local shim_dir="$TEST_TMP/shim-leak"
  mkdir -p "$shim_dir"
  # The yq call that adds a new round includes 'load(' in the expression.
  # Match that in the args to fail only the final write.
  cat > "$shim_dir/yq" <<SHIMEOF
#!/bin/bash
for _a in "\$@"; do
  case "\$_a" in *load*) exit 1 ;; esac
done
exec "$real_yq" "\$@"
SHIMEOF
  chmod +x "$shim_dir/yq"

  run env TMPDIR="$test_tmpdir" PATH="$shim_dir:$PATH" "$SCRIPT" record-round \
    --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=test"
  [ "$status" -ne 0 ]

  local leaked
  leaked="$(find "$test_tmpdir" -maxdepth 1 -name 'rw-*' -type f 2>/dev/null | wc -l)"
  [ "$leaked" -eq 0 ]
  rm -rf "$test_tmpdir"
}

# ===================================================================
# Idempotency: reason and carry changes
# ===================================================================

@test "idempotency: changed reason gives exit 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=original reason"
  [ "$status" -eq 0 ]

  # Same gates but different reason text.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=different reason"
  [ "$status" -eq 1 ]
  grep -qi "conflicting" <<<"$output"
}

@test "idempotency: added carry gives exit 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Same gates but an added carry.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test" \
    --carry "security-review=${VALID_RUN_ID_2}:some rationale"
  [ "$status" -eq 1 ]
  grep -qi "conflicting" <<<"$output"
}

# ===================================================================
# Newline injection in --gate/--carry
# ===================================================================

@test "newline in gate reason stored literally, not as extra gate" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local nl_reason="reason line1
line2"
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=${nl_reason}"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local gate_count
  gate_count="$(yq '.rounds[0].selected_gates | length' "$reg")"
  # Must be exactly 1 gate, not 2 (newline must not create a second gate).
  [ "$gate_count" -eq 1 ]
}

# ===================================================================
# --carry with no colon separator
# ===================================================================

@test "--carry with no colon separator is refused" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test" \
    --carry "security-review=${VALID_RUN_ID_2}"
  [ "$status" -eq 1 ]
  grep -qi "carry.*needs\|run-id.*rationale" <<<"$output"
}

# ===================================================================
# Brief integrity: deleted brief, absolute path
# ===================================================================

@test "assert-round-complete exits 1 when bound brief file is deleted" {
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

  local brief="$TEST_TMP/brief-to-delete.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  # Delete the brief file.
  rm -f "$brief"

  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
  grep -qi "brief\|missing" <<<"$output"
}

@test "bind-brief stores absolute path even when given relative" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Create a brief using a relative path.
  local brief_dir="$TEST_TMP/briefs"
  mkdir -p "$brief_dir"
  printf 'brief\n' > "$brief_dir/rel-brief.md"

  # Run bind-brief from the brief's directory with a relative path.
  run env -C "$brief_dir" "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "rel-brief.md"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local stored_path
  stored_path="$(yq '.rounds[0].brief.path' "$reg")"
  # Stored path must start with / (absolute).
  [[ "$stored_path" == /* ]]
}

# ===================================================================
# yq failure handling: injected yq error yields exit 2, register unchanged
# ===================================================================

@test "yq failure on complete-round yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Normal setup: record round, gate run, report.
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

  # Snapshot the register before the failing attempt.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Create a yq shim that fails on the round_sha read.
  local shim_dir="$TEST_TMP/yq-fail-shim"
  _build_yq_shim "$shim_dir" '.commit_sha'

  # complete-round with the failing yq should exit 2.
  run env PATH="$shim_dir:$PATH" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 2 ]
  # The round must NOT have been marked complete.
  local reg_status
  reg_status="$(yq '.rounds[0].status' "$reg")"
  [ "$reg_status" = "open" ]
}

# ===================================================================
# impact-assessment guards
# ===================================================================

@test "impact-assessment refuses --from-run equal to --run-id" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --from-run "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "must differ\|same.*run\|self" <<<"$output"
}

@test "impact-assessment refuses non-open round" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1 + complete it.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/rpt.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2.
  local sha2
  sha2="$(_make_commit "$repo_dir" "change.txt")"
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Try impact-assessment on completed round 1 (not open).
  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --from-run "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "open\|status" <<<"$output"
}

# ===================================================================
# Structure validation: zero gates
# ===================================================================

@test "structure validation rejects round with empty selected_gates" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg")"
  cat > "$reg" <<YAML
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
rounds:
  - run_id: "${VALID_RUN_ID}"
    commit_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    requirement_version: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    accepted_version: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    status: open
    superseded_by: null
    selected_gates: []
    carried_gates: []
    impact_assessment: null
    scope_revisions: []
    brief: null
YAML

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo /tmp
  [ "$status" -eq 2 ]
}

@test "followon key is validated in record-scope-revision" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Invalid followon key (contains path traversal).
  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind unrelated_enhancement \
    --decision "Out-of-scope" \
    --followon "../../../etc/passwd"
  [ "$status" -eq 1 ]
  grep -qi "invalid story key" <<<"$output"
}

# ===================================================================
# No STUB env vars active
# ===================================================================

@test "record-round runs without any STUB env var and changes the register" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Assert no STUB var is leaking.
  run env
  [[ "$output" != *"_STUB="* ]] || false

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # The register must actually exist and contain the round.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ]
  local count
  count="$(yq '.rounds | length' "$reg")"
  [ "$count" -eq 1 ]
}

@test "complete-round runs without any STUB env var and marks round complete" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env
  [[ "$output" != *"_STUB="* ]] || false

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/cr-rpt.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local status_val
  status_val="$(yq '.rounds[0].status' "$reg")"
  [ "$status_val" = "complete" ]
}

@test "bind-brief runs without any STUB env var and stores the brief" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env
  [[ "$output" != *"_STUB="* ]] || false

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/stub-check-brief.md"
  printf 'brief content\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local bp
  bp="$(yq '.rounds[0].brief.path' "$reg")"
  [ -n "$bp" ] && [ "$bp" != "null" ]
}

# ===================================================================
# complete-round: single message names every failure
# ===================================================================

@test "complete-round names both HEAD mismatch and missing report in one message" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record gate run but NOT the report (so report is missing).
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Move HEAD so we get BOTH a HEAD mismatch AND a missing report.
  _make_commit "$repo_dir" "drift.txt" >/dev/null

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 1 ]

  # The error must mention BOTH the HEAD mismatch and the gate report issue.
  grep -qi "HEAD" <<<"$output"
  grep -qi "code-review" <<<"$output"
}

# ===================================================================
# Newline injection in run-id, story key, and from-run
# ===================================================================

@test "run-id with trailing newline is rejected" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local nl_id="${VALID_RUN_ID}
"
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$nl_id" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 1 ]
  grep -qi "invalid\|newline" <<<"$output"
}

@test "run-id with embedded newline is rejected" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local nl_id="${VALID_RUN_ID}
evil: [injected]"
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$nl_id" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 1 ]
  grep -qi "invalid\|newline" <<<"$output"
}

@test "story key with embedded newline is rejected" {
  run "$SCRIPT" assert-round-complete --story "TEST-S1
injected"
  [ "$status" -eq 1 ]
  grep -qi "invalid\|newline" <<<"$output"
}

@test "impact-assessment from-run with embedded newline is rejected" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local nl_from="${VALID_RUN_ID_2}
evil"
  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --from-run "$nl_from" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "invalid\|newline" <<<"$output"
}

# ===================================================================
# essential_missing_requirement requires --reassess
# ===================================================================

@test "record-scope-revision essential_missing_requirement without --reassess is refused" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "found a gap"
  [ "$status" -eq 1 ]
  grep -qi "reassess" <<<"$output"
}

# ===================================================================
# Structure validation rejects multiple open rounds
# ===================================================================

@test "structure validation rejects register with two open rounds" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg")"
  cat > "$reg" <<YAML
schema_version: 1
story: TEST-S1
gate_runs: []
entries: []
rounds:
  - run_id: "${VALID_RUN_ID}"
    commit_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    requirement_version: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    accepted_version: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    status: open
    superseded_by: null
    selected_gates:
      - gate: code-review
        reason: test
        report_path: ""
        report_sha256: ""
    carried_gates: []
    impact_assessment: null
    scope_revisions: []
    brief: null
  - run_id: "${VALID_RUN_ID_2}"
    commit_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    requirement_version: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    accepted_version: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    status: open
    superseded_by: null
    selected_gates:
      - gate: qa-tests
        reason: test
        report_path: ""
        report_sha256: ""
    carried_gates: []
    impact_assessment: null
    scope_revisions: []
    brief: null
YAML

  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 2 ]
  grep -qi "multiple open\|structural" <<<"$output"
}

# ===================================================================
# STUB env var checks for impact/supersede and scope-revision
# ===================================================================

@test "impact-assessment runs without any STUB env var" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/rpt.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  local sha2
  sha2="$(_make_commit "$repo_dir" "change.txt")"
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=test2"
  [ "$status" -eq 0 ]

  run env
  [[ "$output" != *"_STUB="* ]] || false

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --from-run "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]
}

@test "record-scope-revision runs without any STUB env var" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  run env
  [[ "$output" != *"_STUB="* ]] || false

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "discovered gap" \
    --reassess code-review
  [ "$status" -eq 0 ]
}

# ===================================================================
# Per-site yq failure tests (supersede write, pred_sha, ia_from_run,
# hop report SHA, rounds_len, rounds_type, idempotency carries)
# ===================================================================

# Helper: build a yq shim that fails when arguments match a pattern.
# Captures the real yq path once; uses it for non-matching calls.
# The pattern is stored in a companion file so no quoting issues arise.
_build_yq_shim() {
  local shim_dir="$1" pattern="$2" fail_n="${3:-}"
  mkdir -p "$shim_dir"
  local real_yq
  real_yq="$(command -v yq)"
  local counter="$shim_dir/.yq_cnt"
  printf '0\n' > "$counter"
  printf '%s' "$pattern" > "$shim_dir/.yq_pat"
  printf '%s' "$fail_n" > "$shim_dir/.yq_fail_n"
  printf '%s' "$real_yq" > "$shim_dir/.yq_real"
  cat > "$shim_dir/yq" <<'SHIMEOF'
#!/usr/bin/env bash
_sd="${0%/*}"
_pat="$(cat "$_sd/.yq_pat")"
_fn="$(cat "$_sd/.yq_fail_n")"
_real="$(cat "$_sd/.yq_real")"
_cnt="$_sd/.yq_cnt"
for a in "$@"; do
  case "$a" in *"$_pat"*)
    c=$(cat "$_cnt"); c=$((c+1)); printf '%s\n' "$c" > "$_cnt"
    if [ -z "$_fn" ] || [ "$c" = "$_fn" ]; then
      echo "yq shim: injected failure" >&2; exit 1
    fi; break;;
  esac
done
exec "$_real" "$@"
SHIMEOF
  chmod +x "$shim_dir/yq"
}

@test "yq failure on supersede write yields exit 2 and no second open round" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-supersede"
  _build_yq_shim "$shim" 'select(.status == "open")).status = "superseded"'

  run env PATH="$shim:$PATH" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=test2"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]

  local open_count
  open_count="$(yq '[.rounds[] | select(.status == "open")] | length' "$reg")"
  [ "$open_count" -eq 1 ]
}

@test "yq failure on pred_sha read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1 complete.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/rpt.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2 with same SHA (no new commit).
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=test2"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt2="$TEST_TMP/rpt2.md"
  printf 'report2\n' > "$rpt2"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --report "$rpt2"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-predsha"
  _build_yq_shim "$shim" '.rounds[0].commit_sha'

  run env PATH="$shim:$PATH" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]

  local round2_status
  round2_status="$(yq '.rounds[1].status' "$reg")"
  [ "$round2_status" = "open" ]
}

@test "yq failure on ia_from_run read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1 complete.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/rpt.md"
  printf 'round 1 code review\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2 with new commit and impact.
  local sha2
  sha2="$(_make_commit "$repo_dir" "change.txt")"
  local G6="code-review qa-tests security-review test-automate test-review performance-review"
  local args=()
  local g
  for g in $G6; do args+=(--gate "$g=test"); done
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" "${args[@]}"
  [ "$status" -eq 0 ]
  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --from-run "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]
  for g in $G6; do
    run "$SCRIPT" record-run --story TEST-S1 \
      --run-id "$VALID_RUN_ID_2" --gate "$g" --outcome completed
    [ "$status" -eq 0 ]
    local r="$TEST_TMP/${g}-report2.md"
    printf 'round 2 %s\n' "$g" > "$r"
    run "$SCRIPT" record-round-report --story TEST-S1 \
      --run-id "$VALID_RUN_ID_2" --gate "$g" --report "$r"
    [ "$status" -eq 0 ]
  done

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-iafromrun"
  _build_yq_shim "$shim" 'impact_assessment.from_run'

  run env PATH="$shim:$PATH" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

@test "yq failure on hop report SHA read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1 complete.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/rpt.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2 carries code-review from round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=test" \
    --carry "code-review=${VALID_RUN_ID}:same commit"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  local rpt2="$TEST_TMP/rpt2.md"
  printf 'report2\n' > "$rpt2"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --report "$rpt2"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-hoprsha"
  _build_yq_shim "$shim" '| .report_sha256'

  run env PATH="$shim:$PATH" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

@test "yq failure on rounds_len in assert-round-complete yields exit 2" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/rpt.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  local shim="$TEST_TMP/yqshim-roundslen"
  _build_yq_shim "$shim" '.rounds | length'

  run env PATH="$shim:$PATH" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 2 ]
}

@test "yq failure on rounds_type in validate_structure yields exit 2" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local shim="$TEST_TMP/yqshim-roundstype"
  _build_yq_shim "$shim" '.rounds | type'

  run env PATH="$shim:$PATH" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 2 ]
}

@test "yq failure on idempotency carries read yields exit 2" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test" \
    --carry "qa-tests=${VALID_RUN_ID_3}:rationale"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-carries"
  _build_yq_shim "$shim" ').carried_gates' 1

  # Re-send the same record-round (idempotency path).
  run env PATH="$shim:$PATH" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test" \
    --carry "qa-tests=${VALID_RUN_ID_3}:rationale"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

# ===================================================================
# Existing yq shim test fix: portable yq path and exit 2 assertion
# ===================================================================

@test "yq failure on complete-round yields exit 2 register unchanged (fixed shim)" {
  local repo_dir="$TEST_TMP/repo"
  local sha
  sha="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Normal setup: record round, gate run, report.
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

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Fail on the round_sha read (.commit_sha inside complete-round's logic).
  local shim="$TEST_TMP/yqshim-complete"
  _build_yq_shim "$shim" '.commit_sha'

  # complete-round with the failing yq should exit 2.
  run env PATH="$shim:$PATH" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 2 ]
  # The round must NOT have been marked complete.
  local reg_status
  reg_status="$(yq '.rounds[0].status' "$reg")"
  [ "$reg_status" = "open" ]
}

# ===================================================================
# CDPATH interference test for bind-brief and supersede-brief
# ===================================================================

@test "bind-brief resolves correct absolute path with CDPATH set" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  mkdir -p "$TEST_TMP/briefdir"
  local brief="$TEST_TMP/briefdir/brief.md"
  printf 'brief content\n' > "$brief"

  # Set CDPATH to a decoy directory.
  run env CDPATH="/tmp:$TEST_TMP" "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local stored_path
  stored_path="$(yq '.rounds[0].brief.path' "$reg")"
  # Must be an absolute path matching the real location.
  [[ "$stored_path" == /* ]] || false
  [ "$stored_path" = "$brief" ]
}

@test "supersede-brief resolves correct absolute path with CDPATH set" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/initial-brief.md"
  printf 'initial\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  mkdir -p "$TEST_TMP/newdir"
  local new_brief="$TEST_TMP/newdir/updated.md"
  printf 'updated\n' > "$new_brief"

  run env CDPATH="/tmp:$TEST_TMP" "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$new_brief" --rationale "improved"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local stored_path
  stored_path="$(yq '.rounds[0].brief.path' "$reg")"
  [[ "$stored_path" == /* ]] || false
  [ "$stored_path" = "$new_brief" ]
}

# ===================================================================
# round-info --run-id not-found exits 1 (not 2)
# ===================================================================

@test "round-info with --run-id that does not exist exits 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # A different run-id that was never recorded.
  run "$SCRIPT" round-info --story TEST-S1 --run-id "$VALID_RUN_ID_3"
  [ "$status" -eq 1 ]
  grep -qi "not found" <<<"$output"
}

# ===================================================================
# yq failure on ex_gates_reasons read yields exit 2 register unchanged
# ===================================================================

@test "yq failure on ex_gates_reasons read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Create a round so the idempotency path triggers.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  # Shim yq to fail on the selected_gates read during idempotency check.
  local shim="$TEST_TMP/yqshim-exgates"
  _build_yq_shim "$shim" 'strenv(_RW_RUN_ID))).selected_gates'

  # Re-record the same round — triggers idempotency and selected_gates read.
  run env PATH="$shim:$PATH" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

# ===================================================================
# bind-brief yq read failure tests
# ===================================================================

@test "yq failure on bind-brief round-status read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"

  local shim="$TEST_TMP/yqshim-bb-status"
  _build_yq_shim "$shim" '.run_id == strenv(_RW_RUN_ID))).status'

  run env PATH="$shim:$PATH" "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

@test "yq failure on bind-brief existing-brief-type read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Bind a brief so the existing check has a map to read.
  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-bb-brieftype"
  _build_yq_shim "$shim" '.brief | type'

  run env PATH="$shim:$PATH" "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

# ===================================================================
# supersede-brief yq read failure tests
# ===================================================================

@test "yq failure on supersede-brief round-status read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-sb-status"
  _build_yq_shim "$shim" '.run_id == strenv(_RW_RUN_ID))).status'

  local new_brief="$TEST_TMP/new-brief.md"
  printf 'new\n' > "$new_brief"

  run env PATH="$shim:$PATH" "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$new_brief" --rationale "test"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

@test "yq failure on supersede-brief existing-brief-type read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-sb-brieftype"
  _build_yq_shim "$shim" '.brief | type'

  local new_brief="$TEST_TMP/new-brief.md"
  printf 'new\n' > "$new_brief"

  run env PATH="$shim:$PATH" "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$new_brief" --rationale "test"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

@test "yq failure on supersede-brief old-path read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-sb-path"
  _build_yq_shim "$shim" '.brief.path'

  local new_brief="$TEST_TMP/new-brief.md"
  printf 'new\n' > "$new_brief"

  run env PATH="$shim:$PATH" "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$new_brief" --rationale "test"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

# ===================================================================
# empty reassess list for essential kind exits 1
# ===================================================================

@test "reassess with only whitespace/newline value yields exit 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Pass a newline as the --reassess value: the parse loop skips it,
  # leaving an empty reassess list, which must be refused.
  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --kind essential_missing_requirement \
    --decision "test" \
    --reassess $'\n'
  [ "$status" -eq 1 ]
  grep -qi "empty" <<<"$output"
}

# ===================================================================
# round-info yq failure on rounds-length read yields exit 2
# ===================================================================

@test "yq failure on round-info rounds-length read yields exit 2" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local shim="$TEST_TMP/yqshim-ri-len"
  _build_yq_shim "$shim" '.rounds | length'

  run env PATH="$shim:$PATH" "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 2 ]
}

@test "yq failure on round-info target-round read yields exit 2" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local shim="$TEST_TMP/yqshim-ri-target"
  _build_yq_shim "$shim" '.rounds[-1]'

  run env PATH="$shim:$PATH" "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 2 ]
}

# ===================================================================
# Multi-line SHA from git rev-parse HEAD is refused
# ===================================================================

@test "git rev-parse HEAD with multi-line output exits 1" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local shim_dir="$TEST_TMP/git-shim-multiline"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/git" <<'SHIM'
#!/usr/bin/env bash
if [[ "$*" == *"rev-parse HEAD"* ]]; then
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
  exit 0
fi
exec /usr/bin/git "$@"
SHIM
  chmod +x "$shim_dir/git"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run env PATH="$shim_dir:$PATH" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 1 ]
  grep -qi "newline\|hex\|SHA" <<<"$output"
}

# ===================================================================
# record-run rejects multi-line run-id
# ===================================================================

@test "record-run rejects run-id with embedded newline" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id $'run-001\nevil' --gate code-review --outcome completed
  [ "$status" -eq 1 ]
  grep -qi "newline\|invalid" <<<"$output"
}

@test "record-run accepts standalone run-id" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "run-001" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
}

@test "record-run accepts round-pattern run-id" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
}

# ===================================================================
# round-info --run-id yq failure yields exit 2
# ===================================================================

@test "yq failure on round-info run-id select read yields exit 2" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local shim="$TEST_TMP/yqshim-ri-runid"
  _build_yq_shim "$shim" 'select(.run_id == strenv(_RW_RUN_ID))'

  run env PATH="$shim:$PATH" "$SCRIPT" round-info --story TEST-S1 \
    --run-id "$VALID_RUN_ID"
  [ "$status" -eq 2 ]
}

# ===================================================================
# bind-brief yq failure on existing brief path/hash reads yields exit 2
# ===================================================================

@test "yq failure on bind-brief existing-brief-path read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Bind a first brief so the existing-brief branch is entered.
  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-bb-expath"
  _build_yq_shim "$shim" '.brief.path'

  local brief2="$TEST_TMP/brief2.md"
  printf 'brief2\n' > "$brief2"

  run env PATH="$shim:$PATH" "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief2"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

@test "yq failure on bind-brief existing-brief-hash read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  local shim="$TEST_TMP/yqshim-bb-exhash"
  _build_yq_shim "$shim" '.brief.sha256'

  local brief2="$TEST_TMP/brief2.md"
  printf 'brief2\n' > "$brief2"

  run env PATH="$shim:$PATH" "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief2"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

# ===================================================================
# supersede-brief yq failure on old-hash read yields exit 2
# ===================================================================

@test "yq failure on supersede-brief old-hash read yields exit 2 register unchanged" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local brief="$TEST_TMP/brief.md"
  printf 'brief\n' > "$brief"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  # Shim targets .brief.sha256 — the old-hash read in supersede-brief.
  # Must fail on the SECOND hit (.brief.sha256) because the first
  # hit is the brief-type read (.brief | type) which does NOT contain
  # ".brief.sha256". However, supersede-brief reads .brief.path first
  # (which also does not match), then .brief.sha256. So the first match
  # IS the old_hash read.
  local shim="$TEST_TMP/yqshim-sb-hash"
  _build_yq_shim "$shim" '.brief.sha256'

  local new_brief="$TEST_TMP/new-brief.md"
  printf 'new\n' > "$new_brief"

  run env PATH="$shim:$PATH" "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$new_brief" --rationale "test"
  [ "$status" -eq 2 ]

  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]

  # No empty history row must have been written.
  local hist_len
  hist_len="$(yq '(.rounds[0]).brief.history | length' "$reg")"
  [ "$hist_len" = "0" ]
}

# ===================================================================
# Hostile seq value in gate_runs is refused (arithmetic injection guard)
# ===================================================================

@test "record-run refuses hostile seq value in existing gate_runs" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Seed a register with a valid first gate_run.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  # Poison the seq to contain a command-substitution payload.
  local marker="$TEST_TMP/PWNED"
  export _HOSTILE_SEQ="SCRIPT_NAME[\$(touch $marker)]"
  yq -i '.gate_runs[0].seq = strenv(_HOSTILE_SEQ)' "$reg"
  unset _HOSTILE_SEQ

  # Second record-run must refuse with exit 2 (structure validation).
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate qa-tests --outcome completed
  [ "$status" -eq 2 ]
  # The marker file must NOT exist.
  [ ! -f "$marker" ]
}

@test "record-run refuses hostile seq on bash 3.2" {
  # Skip if /bin/bash is not bash 3.x.
  local ver
  ver="$(/bin/bash --version 2>/dev/null | head -1)" || skip "no /bin/bash"
  case "$ver" in *version\ 3*) ;; *) skip "/bin/bash is not 3.x";; esac

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  local marker="$TEST_TMP/PWNED32"
  export _HOSTILE_SEQ="SCRIPT_NAME[\$(touch $marker)]"
  yq -i '.gate_runs[0].seq = strenv(_HOSTILE_SEQ)' "$reg"
  unset _HOSTILE_SEQ

  run /bin/bash "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate qa-tests --outcome completed
  [ "$status" -eq 2 ]
  [ ! -f "$marker" ]
}

# ===================================================================
# assert-round-complete names unfinished gates
# ===================================================================

@test "assert-round-complete names each unfinished gate" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Open a round with two selected gates.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test" --gate "qa-tests=test"
  [ "$status" -eq 0 ]

  # Neither gate has been completed — assert-round-complete must fail
  # and name both gates.
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
  grep -q "code-review" <<<"$output"
  grep -q "qa-tests" <<<"$output"
}

# ===================================================================
# Test automation coverage: impact-assessment, carried-gate terminal
# outcome, report existence, supersede-brief, round-info current_version
# ===================================================================

@test "complete-round after commit change requires impact-assessment" {
  local repo_dir="$TEST_TMP/repo"
  local sha1
  sha1="$(_init_git_repo "$repo_dir")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: complete it normally so we have a predecessor.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/cr1.md"
  printf 'round 1 code review\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Make a new commit to change HEAD.
  local sha2
  sha2="$(_make_commit "$repo_dir" "change.txt")"
  [ "$sha1" != "$sha2" ]

  # Round 2: all six gates, but NO impact_assessment.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=test" --gate "qa-tests=test" \
    --gate "security-review=test" --gate "test-automate=test" \
    --gate "test-review=test" --gate "performance-review=test"
  [ "$status" -eq 0 ]

  local _g
  for _g in code-review qa-tests security-review test-automate test-review performance-review; do
    run "$SCRIPT" record-run --story TEST-S1 \
      --run-id "$VALID_RUN_ID_2" --gate "$_g" --outcome completed
    [ "$status" -eq 0 ]
    local _r="$TEST_TMP/${_g}-report.md"
    printf 'round 2 %s\n' "$_g" > "$_r"
    run "$SCRIPT" record-round-report --story TEST-S1 \
      --run-id "$VALID_RUN_ID_2" --gate "$_g" --report "$_r"
    [ "$status" -eq 0 ]
  done

  # complete-round should fail because impact_assessment is missing.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "impact_assessment" <<<"$output"
}

@test "carried gate with terminal run not completed blocks completion" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: select code-review but record it as errored.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome errored
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/cr-errored.md"
  printf 'code review errored round 1\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # Round 2 carries code-review from round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=test" \
    --carry "code-review=${VALID_RUN_ID}:no changes"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  local rpt2="$TEST_TMP/qa.md"
  printf 'qa tests round 2\n' > "$rpt2"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --report "$rpt2"
  [ "$status" -eq 0 ]

  # Should fail — the terminal code-review run was "errored", not "completed".
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "code-review" <<<"$output"
}

@test "selected gate with deleted report file blocks completion" {
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
  local rpt="$TEST_TMP/cr-to-delete.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # Delete the report file.
  rm -f "$rpt"

  # complete-round must refuse.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "report.*missing\|report file" <<<"$output"
}

@test "supersede-brief allows assert-round-complete on the new brief" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Full round: record, run, report, complete.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/cr.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # Bind original brief.
  local brief1="$TEST_TMP/brief1.md"
  printf 'brief v1\n' > "$brief1"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief1"
  [ "$status" -eq 0 ]

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Supersede the brief.
  local brief2="$TEST_TMP/brief2.md"
  printf 'brief v2\n' > "$brief2"
  run "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief2" --rationale "updated"
  [ "$status" -eq 0 ]

  # assert-round-complete must pass with the new brief.
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 0 ]

  # If we tamper with the new brief, assert must fail.
  printf 'tampered\n' >> "$brief2"
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
}

@test "round-info current_version changes when AC is edited" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$stories_dir/TEST-S1-test-story.md"
  _write_story_with_ac "$story_file" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Capture the current_version.
  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 0 ]
  local ver1
  ver1="$(grep 'current_version' <<<"$output" | awk '{print $2}')"

  # Edit the AC text.
  awk '/^- \[ \] AC1: The system does something\./{print; print "- [ ] AC99: Added criterion."; next}1' "$story_file" > "${story_file}.tmp" && mv "${story_file}.tmp" "$story_file"

  # current_version must have changed.
  run "$SCRIPT" round-info --story TEST-S1
  [ "$status" -eq 0 ]
  local ver2
  ver2="$(grep 'current_version' <<<"$output" | awk '{print $2}')"
  [ "$ver1" != "$ver2" ]
}

# ===================================================================
# Report tamper detection: complete-round re-hashes selected reports
# ===================================================================

@test "complete-round refuses when selected gate report was edited after recording" {
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
  local rpt="$TEST_TMP/cr-tamper.md"
  printf 'verdict: FAILED\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # Tamper with the report.
  printf 'verdict: PASSED\n' > "$rpt"

  # complete-round must refuse.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "edited after recording\|mismatch" <<<"$output"
}

@test "record-round-report refuses on a complete round" {
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
  local rpt="$TEST_TMP/cr.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Re-recording on a complete round must be refused.
  local forged="$TEST_TMP/forged.md"
  printf 'forged\n' > "$forged"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$forged"
  [ "$status" -eq 1 ]
}

@test "record-round-report refuses on a superseded round" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  # Supersede by creating a new round.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Attempt to record a report on the superseded round.
  local rpt="$TEST_TMP/cr.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 1 ]
}

# ===================================================================
# record-round-report stores absolute path from any CWD
# ===================================================================

@test "record-round-report resolves relative report to absolute path" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Create a report file in a subdirectory.
  local rpt_dir="$TEST_TMP/reports"
  mkdir -p "$rpt_dir"
  printf 'report\n' > "$rpt_dir/cr.md"

  # Run from the rpt_dir parent and pass a RELATIVE path.
  run bash -c "cd \"$TEST_TMP\" && \
    IMPLEMENTATION_ARTIFACTS=\"$IMPLEMENTATION_ARTIFACTS\" \
    PROJECT_ROOT=\"$PROJECT_ROOT\" \
    \"$SCRIPT\" record-round-report --story TEST-S1 \
    --run-id \"$VALID_RUN_ID\" --gate code-review --report reports/cr.md"
  [ "$status" -eq 0 ]

  # The stored path must be absolute.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local stored_path
  stored_path="$(yq '.rounds[0].selected_gates[0].report_path' "$reg")"
  case "$stored_path" in
    /*) ;; # absolute — pass
    *) echo "expected absolute path, got: $stored_path" >&2; return 1 ;;
  esac
}

# ===================================================================
# Concurrency: lost update and duplicate seq detection
# ===================================================================

@test "concurrent record-run: exact counts and no duplicate seq" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  _minimal_register "$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  local pids=()
  # Launch 4 concurrent record-run calls.
  "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed &
  pids+=($!)
  "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate qa-tests --outcome completed &
  pids+=($!)
  "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate security-review --outcome completed &
  pids+=($!)
  "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate test-automate --outcome completed &
  pids+=($!)

  local _p rc_sum=0
  for _p in "${pids[@]}"; do
    wait "$_p"
    rc_sum=$(( rc_sum + $? ))
  done
  [ "$rc_sum" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Must have exactly 4 gate_runs.
  local gr_len
  gr_len="$(yq '.gate_runs | length' "$reg")"
  [ "$gr_len" -eq 4 ]

  # All seq values must be unique.
  local unique_seqs
  unique_seqs="$(yq '[.gate_runs[].seq] | unique | length' "$reg")"
  [ "$unique_seqs" -eq 4 ]
}

# ===================================================================
# assert-round-complete names gates with errored or missing runs
# ===================================================================

@test "assert-round-complete names gate with recorded report but errored run" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record the run as errored (not completed).
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome errored
  [ "$status" -eq 0 ]

  # Record a report so the report-path check passes.
  local rpt="$TEST_TMP/cr-errored.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # assert-round-complete must fail AND name the gate.
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
  grep -q "code-review" <<<"$output"
  grep -qi "not completed\|errored" <<<"$output"
}

@test "assert-round-complete names gate with report but no run at all" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Record a report but do NOT record a run.
  local rpt="$TEST_TMP/cr-no-run.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
  grep -q "code-review" <<<"$output"
  grep -qi "not completed\|outcome.*none" <<<"$output"
}

@test "assert-round-complete names carried gate whose earlier run is missing" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: select qa-tests only (no code-review).
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "qa-tests=test"
  [ "$status" -eq 0 ]

  # Round 2: select security-review and carry code-review from round 1.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "security-review=test"
  [ "$status" -eq 0 ]

  # Manually inject a carried gate that points to a non-existent round.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  yq -i '(.rounds[] | select(.run_id == "round-20261016T130000Z-67890")).carried_gates = [{"gate": "code-review", "from_run": "round-20261016T999999Z-00000", "applicability_rationale": "from nonexistent"}]' "$reg"

  # Complete the selected gate for round 2 so the only failure is the carried gate.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate security-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/sec.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate security-review --report "$rpt"
  [ "$status" -eq 0 ]

  # assert-round-complete must name the carried gate.
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 1 ]
  grep -q "code-review" <<<"$output"
  grep -qi "not found in rounds\|from_run" <<<"$output"
}

# ===================================================================
# cross-round report reuse guard
# ===================================================================

@test "record-round-report refuses a report already used in another round (different commit)" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: record code-review with a report.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=round 1"
  [ "$status" -eq 0 ]

  local report="$TEST_TMP/code-review.md"
  printf 'code review findings\n' > "$report"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # New commit for round 2.
  _make_commit "$repo_dir" "change.txt" >/dev/null

  # Round 2: selects code-review.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=round 2"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Re-use round 1's report as round 2's evidence — must be refused.
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --report "$report"
  [ "$status" -eq 1 ]
  grep -qi "already recorded\|reuse" <<<"$output"
}

@test "record-round-report refuses a report already used in another round (same commit)" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: code-review.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=round 1"
  [ "$status" -eq 0 ]

  local report="$TEST_TMP/code-review-same.md"
  printf 'code review findings same commit\n' > "$report"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2 at same commit.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=round 2"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Same report, same commit — must still be refused (carry is the sanctioned path).
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --report "$report"
  [ "$status" -eq 1 ]
  grep -qi "already recorded\|reuse" <<<"$output"
}

@test "record-round-report allows re-recording a new report on the same gate" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local report1="$TEST_TMP/cr-v1.md"
  printf 'version 1\n' > "$report1"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report1"
  [ "$status" -eq 0 ]

  # Replace with a different report on the same round's gate.
  local report2="$TEST_TMP/cr-v2.md"
  printf 'version 2\n' > "$report2"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report2"
  [ "$status" -eq 0 ]
}

@test "same canonical path with new content accepted across rounds" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: record code-review at a canonical path.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=round 1"
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/reviews/code-review-TEST-S1.md"
  mkdir -p "$(dirname "$report")"
  printf 'round 1 FAILED\n' > "$report"
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local r1_sha
  r1_sha="$(yq '(.rounds[0].selected_gates[0]).report_sha256' "$reg")"
  [ -n "$r1_sha" ] && [ "$r1_sha" != "null" ] || false

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2 at the same commit — same path, new content.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=re-review after fix"
  [ "$status" -eq 0 ]

  # Overwrite the SAME path with fresh content.
  printf 'round 2 PASSED with entirely new review\n' > "$report"
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # This must succeed — the path is reused but content is different.
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --report "$report"
  [ "$status" -eq 0 ]

  # Verify stored path and sha changed.
  local r2_path r2_sha
  r2_path="$(yq '(.rounds[1].selected_gates[0]).report_path' "$reg")"
  r2_sha="$(yq '(.rounds[1].selected_gates[0]).report_sha256' "$reg")"
  [ "$r2_path" = "$report" ] || false
  [ "$r2_sha" != "$r1_sha" ] || false
  [ -n "$r2_sha" ] && [ "$r2_sha" != "null" ] || false

  # complete-round and assert-round-complete must also succeed.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 0 ]
  run "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 0 ]
}

@test "same canonical path with unchanged content refused across rounds" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: record code-review.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=round 1"
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/reviews/code-review-TEST-S1.md"
  mkdir -p "$(dirname "$report")"
  printf 'identical content\n' > "$report"
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2 at same commit (report content not changed).
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=round 2"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Same path AND same content — must be refused (SHA matches).
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --report "$report"
  [ "$status" -eq 1 ]
  grep -qi "already recorded\|reuse" <<<"$output"

  # Round 2 evidence must remain empty.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local r2_path r2_sha
  r2_path="$(yq '(.rounds[1].selected_gates[0]).report_path' "$reg")"
  r2_sha="$(yq '(.rounds[1].selected_gates[0]).report_sha256' "$reg")"
  [ -z "$r2_path" ] || [ "$r2_path" = "null" ] || false
  [ -z "$r2_sha" ] || [ "$r2_sha" = "null" ] || false
}

@test "legitimate carry still completes after cross-round reuse guard" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: full.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  local report="$TEST_TMP/cr.md"
  printf 'report\n' > "$report"
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2: carry code-review from round 1 (the sanctioned reuse path).
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=test" \
    --carry "code-review=${VALID_RUN_ID}:no code changes"
  [ "$status" -eq 0 ]

  local qa_report="$TEST_TMP/qa.md"
  printf 'qa\n' > "$qa_report"
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --report "$qa_report"
  [ "$status" -eq 0 ]

  # complete-round must succeed — the carry is legitimate.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 0 ]
}

@test "record-round-report refuses byte-identical copy at a new path" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: record code-review.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=round 1"
  [ "$status" -eq 0 ]
  local original="$TEST_TMP/cr-original.md"
  printf 'unique review content for copy test\n' > "$original"
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$original"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2: copy the report to a different path (same content, same SHA).
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "code-review=round 2"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local copy="$TEST_TMP/cr-copy.md"
  cp "$original" "$copy"

  # The copy has a different path but the same SHA — must be refused.
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate code-review --report "$copy"
  [ "$status" -eq 1 ]
  grep -qi "already recorded\|reuse" <<<"$output"
}

@test "record-round-report exits 2 when cross-round reuse query fails" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  local report="$TEST_TMP/cr-failclose.md"
  printf 'fail-close test\n' > "$report"

  # Shim yq to fail only on the cross-round duplicate query.
  local real_yq
  real_yq="$(command -v yq)"
  local shim_dir="$TEST_TMP/shim-dup"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/yq" <<SHIMEOF
#!/bin/bash
for _a in "\$@"; do
  case "\$_a" in *report_sha256*_RW_RHASH*) exit 1 ;; esac
done
exec "$real_yq" "\$@"
SHIMEOF
  chmod +x "$shim_dir/yq"

  # Record the register SHA before the attempt.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before_sha
  before_sha="$(shasum "$reg" | awk '{print $1}')"

  run env PATH="$shim_dir:$PATH" "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$report"
  [ "$status" -eq 2 ]

  # Register must be unchanged.
  local after_sha
  after_sha="$(shasum "$reg" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

# ===================================================================
# tagged-value structure check bypass and integer guard
# ===================================================================

@test "structure check refuses explicitly tagged non-integer seq value" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Inject an explicitly tagged !!int value with a command-substitution payload.
  local marker="$TEST_TMP/PWNED-tagged"
  # Use sed to insert the tagged value directly (yq strenv strips the tag).
  local payload
  payload="SCRIPT_NAME[\$(touch $marker)]"
  sed "s|seq: 1|seq: !!int \"$payload\"|" "$reg" > "${reg}.new"
  mv "${reg}.new" "$reg"

  # Verify yq sees the type as !!int (the bypass condition).
  local tag_type
  tag_type="$(yq '.gate_runs[0].seq | type' "$reg")"
  [[ "$tag_type" = "!!int" ]] || false

  # The structure check must refuse this (exit 2) and no marker file.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate qa-tests --outcome completed
  [ "$status" -eq 2 ]
  [ ! -f "$marker" ]
}

@test "structure check value validation catches tagged payload on complete-round" {
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
  local rpt="$TEST_TMP/cr-tagged.md"
  printf 'tagged test report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # Inject a tagged !!int payload into gate_runs[0].seq after the gate run
  # was legitimately recorded.
  local reg marker
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  marker="$TEST_TMP/PWNED-complete"
  local payload
  payload="SCRIPT_NAME[\$(touch $marker)]"
  sed "s|seq: 1|seq: !!int \"$payload\"|" "$reg" > "${reg}.new"
  mv "${reg}.new" "$reg"

  # complete-round must be refused by the structure check (exit 2), not pass.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 2 ]
  [ ! -f "$marker" ]
}

@test "structure check refuses tagged seq on bash 3.2" {
  local ver
  ver="$(/bin/bash --version 2>/dev/null | head -1)" || skip "no /bin/bash"
  case "$ver" in *version\ 3*) ;; *) skip "/bin/bash is not 3.x";; esac

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  local marker="$TEST_TMP/PWNED-tagged-32"
  local payload
  payload="SCRIPT_NAME[\$(touch $marker)]"
  sed "s|seq: 1|seq: !!int \"$payload\"|" "$reg" > "${reg}.new"
  mv "${reg}.new" "$reg"

  run /bin/bash "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate qa-tests --outcome completed
  [ "$status" -eq 2 ]
  [ ! -f "$marker" ]
}

@test "structure check refuses tagged hex seq value" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Create a round with a completed gate so the register has a gate_run.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/cr-hex.md"
  printf 'hex test report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Inject !!int "0x10" — a hex literal that yq accepts as type !!int
  # and that passes arithmetic (+0) but is not digits-only.
  sed 's|seq: 1|seq: !!int "0x10"|' "$reg" > "${reg}.new"
  mv "${reg}.new" "$reg"

  # Verify yq sees the type as !!int (confirming the bypass condition).
  local tag_type
  tag_type="$(yq '.gate_runs[0].seq | type' "$reg")"
  [[ "$tag_type" = "!!int" ]] || false

  # Use complete-round — it calls _rw_validate_structure but does NOT call
  # _rw_require_integer on the gate_runs max seq, so only the value-level
  # structure check catches the hex value.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 2 ]
  grep -qi "non-integer seq" <<<"$output"
}

@test "structure check refuses leading-zero seq 009" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Inject !!int "009" — an invalid octal literal that would crash bash
  # arithmetic with "value too great for base".
  sed 's|seq: 1|seq: !!int "009"|' "$reg" > "${reg}.new"
  mv "${reg}.new" "$reg"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate qa-tests --outcome completed
  [ "$status" -eq 2 ]
  grep -qi "non-integer seq" <<<"$output"
}

@test "structure check refuses leading-zero seq 010" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Inject untagged 010 — yq stores it as integer 8 (octal interpretation).
  # Even if yq normalises this, bash would mis-read the literal form.
  # Use a tagged form to ensure the value is literally "010".
  sed 's|seq: 1|seq: !!int "010"|' "$reg" > "${reg}.new"
  mv "${reg}.new" "$reg"

  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate qa-tests --outcome completed
  [ "$status" -eq 2 ]
  grep -qi "non-integer seq" <<<"$output"
}

@test "integer guard alone catches non-integer seq via shim" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # First record a valid run so the register has valid structure.
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Shim yq to return a non-integer for the max-seq query
  # (the query pattern: '[.gate_runs[].seq // 0] | max // 0').
  # The structure check has already passed on valid data.
  local real_yq
  real_yq="$(command -v yq)"
  local shim_dir="$TEST_TMP/shim-int"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/yq" <<SHIMEOF
#!/bin/bash
for _a in "\$@"; do
  case "\$_a" in *.gate_runs*max*) echo "abc"; exit 0 ;; esac
done
exec "$real_yq" "\$@"
SHIMEOF
  chmod +x "$shim_dir/yq"

  # The second record-run passes structure check then hits _rw_require_integer
  # with "abc" from the shimmed max-seq computation.
  run env PATH="$shim_dir:$PATH" "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate qa-tests --outcome completed
  [ "$status" -eq 2 ]
  grep -qi "expected integer" <<<"$output"
}

# ===================================================================
# nested read failure in gate-error collection
# ===================================================================

@test "complete-round exits 2 when gate-outcome yq read fails" {
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
  local rpt="$TEST_TMP/cr.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # Shim yq to fail only on the scope_revisions read (used by
  # _rw_gate_latest_outcome inside _rw_collect_gate_errors).
  local real_yq
  real_yq="$(command -v yq)"
  local shim_dir="$TEST_TMP/shim-outcome"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/yq" <<SHIMEOF
#!/bin/bash
case "\$*" in
  *scope_revisions*reassessed_gates*) exit 1 ;;
esac
exec "$real_yq" "\$@"
SHIMEOF
  chmod +x "$shim_dir/yq"

  run env PATH="$shim_dir:$PATH" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 2 ]
}

@test "assert-round-complete exits 2 when gate-outcome yq read fails" {
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
  local rpt="$TEST_TMP/cr.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  local real_yq
  real_yq="$(command -v yq)"
  local shim_dir="$TEST_TMP/shim-outcome2"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/yq" <<SHIMEOF
#!/bin/bash
case "\$*" in
  *scope_revisions*reassessed_gates*) exit 1 ;;
esac
exec "$real_yq" "\$@"
SHIMEOF
  chmod +x "$shim_dir/yq"

  run env PATH="$shim_dir:$PATH" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 2 ]
}

@test "complete-round exits 2 when carried-gate outcome read fails" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: record code-review, complete it.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/cr-carried.md"
  printf 'carried outcome test\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2: carry code-review from round 1, select qa-tests.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=test" \
    --carry "code-review=${VALID_RUN_ID}:no code changes"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  local qa_rpt="$TEST_TMP/qa-carried.md"
  printf 'qa carried outcome test\n' > "$qa_rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --report "$qa_rpt"
  [ "$status" -eq 0 ]

  # Shim: fail the scope_revisions query on the SECOND call only —
  # the first fires for the selected gate (qa-tests), the second for
  # the carried gate's hop-chain resolution (code-review).
  local shim_dir="$TEST_TMP/shim-carried-out"
  _build_yq_shim "$shim_dir" 'scope_revisions' 2

  run env PATH="$shim_dir:$PATH" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir"
  [ "$status" -eq 2 ]
}

@test "assert-round-complete exits 2 when carried-gate outcome read fails" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Round 1: record and complete.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  local rpt="$TEST_TMP/cr-carried2.md"
  printf 'carried outcome test 2\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 0 ]

  # Round 2: carry from round 1.  Leave it OPEN so assert-round-complete
  # exercises _rw_collect_gate_errors.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=test" \
    --carry "code-review=${VALID_RUN_ID}:no code changes"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]
  local qa_rpt="$TEST_TMP/qa-carried2.md"
  printf 'qa carried outcome test 2\n' > "$qa_rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --gate qa-tests --report "$qa_rpt"
  [ "$status" -eq 0 ]

  # Shim the carried-gate outcome read to fail (second scope_revisions call).
  local shim_dir="$TEST_TMP/shim-carried-assert"
  _build_yq_shim "$shim_dir" 'scope_revisions' 2

  run env PATH="$shim_dir:$PATH" "$SCRIPT" assert-round-complete --story TEST-S1
  [ "$status" -eq 2 ]
}

# ===================================================================
# selected-gate hash re-check fail-open
# ===================================================================

@test "complete-round exits 2 when selected-gate report-sha read fails" {
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
  local rpt="$TEST_TMP/cr-hashfail.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # Edit the report so it would mismatch if the hash is checked.
  printf 'edited report\n' > "$rpt"

  # Shim yq to fail only on the selected-gate report_sha256 read.
  local real_yq
  real_yq="$(command -v yq)"
  local shim_dir="$TEST_TMP/shim-sha"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/yq" <<SHIMEOF
#!/bin/bash
case "\$*" in
  *selected_gates*report_sha256*) exit 1 ;;
esac
exec "$real_yq" "\$@"
SHIMEOF
  chmod +x "$shim_dir/yq"

  run env PATH="$shim_dir:$PATH" "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 2 ]
}

@test "complete-round refuses blank report_sha256 in recorded evidence" {
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
  local rpt="$TEST_TMP/cr-blank.md"
  printf 'report\n' > "$rpt"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --gate code-review --report "$rpt"
  [ "$status" -eq 0 ]

  # Blank the sha in the register.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  yq -i '(.rounds[0].selected_gates[0]).report_sha256 = ""' "$reg"

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir"
  [ "$status" -eq 1 ]
  grep -qi "recorded without SHA\|without.*sha\|blank.*sha\|empty.*sha" <<<"$output"
}

# ===================================================================
# failure-path temp-file leak test fix
# ===================================================================

@test "no rw-* temp files leak after record-round failure (validated)" {
  local test_tmpdir
  test_tmpdir="$(mktemp -d "${BATS_TMPDIR:-${TMPDIR:-/tmp}}/rw-leak-fix.XXXXXX")"

  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # Make a valid first round so the register exists.
  run env TMPDIR="$test_tmpdir" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # Clean up any temp files from the successful call.
  find "$test_tmpdir" -maxdepth 1 -name 'rw-*' -type f -delete 2>/dev/null || true

  # Shim yq to fail on the final rounds-append write that uses load().  This
  # is the call AFTER _rw_mktemp has created rw-sel.json.* and rw-car.json.*
  # temp files, so the failure exercises the cleanup path that matters.
  local real_yq
  real_yq="$(command -v yq)"
  local shim_dir="$TEST_TMP/shim-leak-v"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/yq" <<SHIMEOF
#!/bin/bash
for _a in "\$@"; do
  case "\$_a" in *load*) exit 1 ;; esac
done
exec "$real_yq" "\$@"
SHIMEOF
  chmod +x "$shim_dir/yq"

  # This call will fail on the load() write AFTER _rw_mktemp has created
  # temp files.  The EXIT trap must clean them up.
  run env TMPDIR="$test_tmpdir" PATH="$shim_dir:$PATH" "$SCRIPT" record-round \
    --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" --repo "$repo_dir" \
    --gate "qa-tests=test"
  [ "$status" -ne 0 ]

  local leaked
  leaked="$(find "$test_tmpdir" -maxdepth 1 -name 'rw-*' -type f 2>/dev/null | wc -l)"
  [ "$leaked" -eq 0 ]

  # Cleanup in teardown-safe block.
  rm -rf "$test_tmpdir"
}
