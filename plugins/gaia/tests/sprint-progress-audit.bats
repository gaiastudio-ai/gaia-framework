#!/usr/bin/env bats
# sprint-progress-audit.bats — merge-not-done checkpoint for multi-story sprints
#
# Tests the sprint-progress-audit.sh helper, which detects stories whose PR
# is merged on the promotion target but whose status has not reached done
# with a COMPLETE Review Gate. The script composes verify-pr-merged.sh (merge
# detection) and review-gate.sh review-gate-check (gate completeness) rather
# than building a parallel scanner.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-progress-audit.sh"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# write_sprint_status PATH <key:status> [<key:status> ...]
write_sprint_status() {
  local path="$1"; shift
  cat > "$path" <<'HEADER'
sprint_id: "sprint-test"
status: active
start_date: "2026-06-01"
end_date: "2026-06-14"
total_points: 10
goals: []
items: []
HEADER
  echo "stories:" >> "$path"
  for row in "$@"; do
    cat >> "$path" <<EOF
  - key: "$(echo "$row" | cut -d: -f1)"
    title: "test story"
    status: "$(echo "$row" | cut -d: -f2)"
    points: 1
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-06-01"
EOF
  done
}

# write_story_file PATH <fm_status> <code> <qa> <sec> <ta> <tr> <perf>
write_story_file() {
  local path="$1" story_status="$2" code="$3" qa="$4" sec="$5" ta="$6" tr="$7" pr="$8"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
---
key: "$(basename "$(dirname "$path")" | sed 's/-[a-z].*$//')"
status: $story_status
---

# Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $code | — |
| QA Tests | $qa | — |
| Security Review | $sec | — |
| Test Automation | $ta | — |
| Test Review | $tr | — |
| Performance Review | $pr | — |
EOF
}

# ---------------------------------------------------------------------------
# ---------- Existence and help ----------
# ---------------------------------------------------------------------------

@test "script exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "help flag exits 0 with usage information" {
  run --separate-stderr "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-progress-audit"* ]]
  [[ "$output" == *"sprint-status"* ]]
}

# ---------------------------------------------------------------------------
# ---------- Merged-but-not-done detection ----------
# ---------------------------------------------------------------------------

@test "merged-but-in-progress story produces warning and non-zero exit" {
  # Set up a fixture: sprint-status with one in-progress story.
  local yaml="$TEST_TMP/sprint-status.yaml"
  write_sprint_status "$yaml" "EX-S1:in-progress"

  # Create the implementation directory with the story file.
  local impl="$TEST_TMP/impl/epic-example/EX-S1-test-story"
  write_story_file "$impl/story.md" in-progress UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED

  # Create a fake git repo where the merge commit exists on the target branch.
  local repo="$TEST_TMP/repo"
  mkdir -p "$repo"
  git -C "$repo" init -b staging >/dev/null 2>&1
  git -C "$repo" config user.email "test@gaia.local" >/dev/null 2>&1
  git -C "$repo" config user.name "gaia-test" >/dev/null 2>&1
  git -C "$repo" commit --allow-empty -m "feat(EX-S1): initial commit" >/dev/null 2>&1

  run --separate-stderr env \
    PROJECT_PATH="$repo" \
    IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
    "$SCRIPT" --sprint-status "$yaml" --target-branch staging

  [ "$status" -ne 0 ]
  [[ "$output" == *"EX-S1"* ]]
  [[ "$output" == *"WARNING"* ]] || [[ "$output" == *"merged"* ]]
}

# ---------------------------------------------------------------------------
# ---------- Clean sprint (no offenders) ----------
# ---------------------------------------------------------------------------

@test "all-done sprint with all gates passed exits 0 clean" {
  local yaml="$TEST_TMP/sprint-status.yaml"
  write_sprint_status "$yaml" "EX-S1:done" "EX-S2:done"

  run --separate-stderr env \
    "$SCRIPT" --sprint-status "$yaml" --target-branch staging

  [ "$status" -eq 0 ]
}

@test "no merged stories (all in-progress, no PR) exits 0 clean" {
  # Sprint has in-progress stories but none have been merged.
  local yaml="$TEST_TMP/sprint-status.yaml"
  write_sprint_status "$yaml" "EX-S1:in-progress" "EX-S2:in-progress"

  # Create story files.
  local impl="$TEST_TMP/impl/epic-example"
  write_story_file "$impl/EX-S1-story-a/story.md" in-progress UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED
  write_story_file "$impl/EX-S2-story-b/story.md" in-progress UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED

  # Git repo with NO matching commits.
  local repo="$TEST_TMP/repo"
  mkdir -p "$repo"
  git -C "$repo" init -b staging >/dev/null 2>&1
  git -C "$repo" config user.email "test@gaia.local" >/dev/null 2>&1
  git -C "$repo" config user.name "gaia-test" >/dev/null 2>&1
  git -C "$repo" commit --allow-empty -m "unrelated: scaffold" >/dev/null 2>&1

  run --separate-stderr env \
    PROJECT_PATH="$repo" \
    IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
    "$SCRIPT" --sprint-status "$yaml" --target-branch staging

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# ---------- Composition verification (reuses existing scripts) ----------
# ---------------------------------------------------------------------------

@test "implementation references verify-pr-merged or its merge-detection logic" {
  # The script must source or call verify-pr-merged.sh or safe_grep_log
  # (the merge-detection function from shell-idioms used by verify-pr-merged).
  grep -qE 'verify-pr-merged\.sh|safe_grep_log' "$SCRIPT"
}

@test "implementation references review-gate or gating-flip-guard for gate checking" {
  # The script must source or call review-gate.sh or gating-flip-guard.sh.
  grep -qE 'review-gate\.sh|gating-flip-guard\.sh' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "mixed sprint: only non-done merged stories are flagged" {
  local yaml="$TEST_TMP/sprint-status.yaml"
  write_sprint_status "$yaml" "EX-S1:done" "EX-S2:in-progress" "EX-S3:done"

  # Story file for the in-progress one only.
  local impl="$TEST_TMP/impl/epic-example"
  write_story_file "$impl/EX-S2-story-b/story.md" in-progress UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED

  # Git repo where EX-S2 is merged.
  local repo="$TEST_TMP/repo"
  mkdir -p "$repo"
  git -C "$repo" init -b staging >/dev/null 2>&1
  git -C "$repo" config user.email "test@gaia.local" >/dev/null 2>&1
  git -C "$repo" config user.name "gaia-test" >/dev/null 2>&1
  git -C "$repo" commit --allow-empty -m "feat(EX-S2): implement the feature" >/dev/null 2>&1

  run --separate-stderr env \
    PROJECT_PATH="$repo" \
    IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
    "$SCRIPT" --sprint-status "$yaml" --target-branch staging

  [ "$status" -ne 0 ]
  [[ "$output" == *"EX-S2"* ]]
  # Done stories should NOT appear in the warnings.
  [[ "$output" != *"EX-S1"* ]]
  [[ "$output" != *"EX-S3"* ]]
}

@test "non-git CWD degrades gracefully with exit 0" {
  local yaml="$TEST_TMP/sprint-status.yaml"
  write_sprint_status "$yaml" "EX-S1:in-progress"

  local impl="$TEST_TMP/impl/epic-example"
  write_story_file "$impl/EX-S1-story-a/story.md" in-progress UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED

  # Use a non-git directory as PROJECT_PATH.
  local nongit="$TEST_TMP/nongit"
  mkdir -p "$nongit"

  run --separate-stderr env \
    PROJECT_PATH="$nongit" \
    IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
    "$SCRIPT" --sprint-status "$yaml" --target-branch staging

  [ "$status" -eq 0 ]
}

@test "missing --sprint-status flag exits non-zero" {
  run --separate-stderr "$SCRIPT" --target-branch staging
  [ "$status" -ne 0 ]
}
