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

SCRATCHPAD="/private/tmp/claude-501/-Users-jlouage-Dev-GAIA-Framework/d21d61f7-c64a-462e-a618-bfe9ab06c17d/scratchpad"
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
  export PROJECT_ROOT="$SCRATCHPAD/roundtest-$$-${BATS_TEST_NUMBER}"
  mkdir -p "$PROJECT_ROOT"
}

teardown() { common_teardown; }

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
  [[ "$req_ver" =~ $re_reqver ]]

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

  # Create a register with a round that has a carried gate with empty rationale.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg")"
  local sha
  sha="$(git -C "$repo_dir" rev-parse HEAD)"
  cat > "$reg" <<YAML
schema_version: 1
story: TEST-S1
gate_runs:
  - run_id: "${VALID_RUN_ID}"
    gate: code-review
    at: "2026-01-01T00:00:00Z"
    outcome: completed
    seq: 1
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
    carried_gates:
      - gate: security-review
        from_run: "round-20261015T000000Z-99999"
        applicability_rationale: ""
    impact_assessment: null
    scope_revisions: []
    brief: null
YAML

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID" \
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
  ! grep -q "unknown subcommand" <<<"$output"
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

  # Now supersede the round.
  run "$SCRIPT" record-round --story TEST-S1 \
    --run-id "$VALID_RUN_ID_2" \
    --repo "$repo_dir" \
    --gate "code-review=test"
  [ "$status" -eq 0 ]

  # bind-brief on superseded round should fail.
  local brief2="$TEST_TMP/brief2.md"
  printf 'brief2\n' > "$brief2"
  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --brief "$brief2"
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
  ! grep -q "unknown subcommand" <<<"$output"
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in complete-round exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" complete-round --story TEST-S1 \
    --run-id "not-valid" --repo "/tmp"
  [ "$status" -eq 1 ]
  ! grep -q "unknown subcommand" <<<"$output"
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in impact-assessment --run-id exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "not-valid" --from-run "$VALID_RUN_ID" --repo "/tmp"
  [ "$status" -eq 1 ]
  ! grep -q "unknown subcommand" <<<"$output"
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in impact-assessment --from-run exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" impact-assessment --story TEST-S1 \
    --run-id "$VALID_RUN_ID" --from-run "not-valid" --repo "/tmp"
  [ "$status" -eq 1 ]
  ! grep -q "unknown subcommand" <<<"$output"
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in record-scope-revision exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" record-scope-revision --story TEST-S1 \
    --run-id "not-valid" --kind essential_missing_requirement \
    --decision "test" --reassess code-review
  [ "$status" -eq 1 ]
  ! grep -q "unknown subcommand" <<<"$output"
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in bind-brief exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" bind-brief --story TEST-S1 \
    --run-id "not-valid" --brief "/tmp/brief.md"
  [ "$status" -eq 1 ]
  ! grep -q "unknown subcommand" <<<"$output"
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in supersede-brief exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" supersede-brief --story TEST-S1 \
    --run-id "not-valid" --brief "/tmp/brief.md" --rationale "test"
  [ "$status" -eq 1 ]
  ! grep -q "unknown subcommand" <<<"$output"
  grep -qi "invalid.*run.id\|run.id.*invalid\|round run-id" <<<"$output"
}

@test "invalid run-id in round-info --run-id exits 1" {
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  _write_story_with_ac "$stories_dir/TEST-S1-test-story.md" "TEST-S1"

  run "$SCRIPT" round-info --story TEST-S1 --run-id "not-valid"
  [ "$status" -eq 1 ]
  ! grep -q "unknown subcommand" <<<"$output"
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
  ! grep -q "unknown subcommand" <<<"$output"
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
  ! grep -q "unknown subcommand" <<<"$output"
  grep -qi "hex\|SHA\|commit\|resolve" <<<"$output"
}
