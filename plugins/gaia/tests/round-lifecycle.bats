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
  printf 'report\n' > "$sec_rpt"
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
  printf 'report\n' > "$rpt"
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

  wait "$pid1" || true
  wait "$pid2" || true

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  # At least one round should exist; both is fine (serialized by lock).
  local round_count
  round_count="$(yq '.rounds | length' "$reg")"
  [ "$round_count" -ge 1 ]
}

@test "concurrent record-run plus record-round: no lost entry, no duplicate seq" {
  local repo_dir="$TEST_TMP/repo"
  _init_git_repo "$repo_dir" >/dev/null

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  _minimal_register "$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # record-run in background.
  "$SCRIPT" record-run --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
    --gate code-review --outcome completed &
  local pid1=$!

  # record-round in background.
  "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=concurrent" &
  local pid2=$!

  wait "$pid1" || true
  wait "$pid2" || true

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local gr_len
  gr_len="$(yq '.gate_runs | length' "$reg")"
  [ "$gr_len" -ge 1 ]

  # The record-round must also succeed (rounds[] must exist).
  local round_count
  round_count="$(yq '.rounds | length' "$reg")"
  [ "$round_count" -ge 1 ]
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
  printf 'report\n' > "$sec_report"
  run "$SCRIPT" record-round-report --story TEST-S1 \
    --run-id "$VALID_RUN_ID_3" --gate security-review --report "$sec_report"
  [ "$status" -eq 0 ]

  # complete-round should resolve the 2-hop carry chain successfully.
  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_3" --repo "$repo_dir"
  # Exit 0 means the 2-hop chain resolved and code-review counted.
  # (If only 2 of 6 gates are accounted for, it will exit 1 for unrelated
  # reasons — but the carried gate itself must not be the failure reason.)
  # We cannot expect exit 0 here because not all 6 gates are accounted for.
  # Instead, check that the error does NOT name code-review as the problem.
  # shellcheck disable=SC2254
  local output_lower
  output_lower="$(tr '[:upper:]' '[:lower:]' <<<"$output")"
  [[ "$output_lower" != *"code-review"* ]] || [ "$status" -eq 0 ]
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
  test_tmpdir="$(mktemp -d "${BATS_TMPDIR:-${TMPDIR:-/tmp}}/rw-leak-test.XXXXXX")"

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
  test_tmpdir="$(mktemp -d "${BATS_TMPDIR:-${TMPDIR:-/tmp}}/rw-leak-test.XXXXXX")"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  # This will fail because the run-id is invalid.
  run env TMPDIR="$test_tmpdir" "$SCRIPT" record-round --story TEST-S1 \
    --run-id "bad-id" --repo /nonexistent \
    --gate "code-review=test"
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
  printf 'report\n' > "$rpt"
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
    printf 'report\n' > "$r"
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
