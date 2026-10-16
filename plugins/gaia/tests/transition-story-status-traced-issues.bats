#!/usr/bin/env bats
# transition-story-status-traced-issues.bats — traced-issue closure on done.
#
# Verifies the post-transition hook that closes or comments on GitHub issues
# listed in a story's `traces_to` frontmatter when the story reaches done.
#
# Public-function coverage:
#   - _close_traced_issues   — post-transition hook entry point
#   - _parse_traces_to       — extracts GitHub issue numbers from frontmatter
#   - _find_merged_pr_number — resolves the story's merged PR via gh
#
# All gh calls are stubbed via PATH override — no real GitHub API calls.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/tss-traced-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$TEST_TMP/docs/planning-artifacts"
  mkdir -p "$TEST_TMP/_memory"
  mkdir -p "$TEST_TMP/.git"

  STORY_KEY="E900-S1"
  STORY_FILE="$TEST_TMP/docs/implementation-artifacts/${STORY_KEY}-traced-issue-fixture.md"
  SPRINT_YAML="$TEST_TMP/docs/implementation-artifacts/sprint-status.yaml"
  EPICS_MD="$TEST_TMP/docs/planning-artifacts/epics-and-stories.md"
  INDEX_YAML="$TEST_TMP/docs/implementation-artifacts/story-index.yaml"
  LOCK_FILE="$TEST_TMP/_memory/.story-status.lock"

  # Stub directory for gh binary stubs
  GH_STUB_DIR="$TEST_TMP/gh-stubs"
  mkdir -p "$GH_STUB_DIR"

  # Default gh stub that records calls to a log file
  GH_CALL_LOG="$TEST_TMP/gh-calls.log"
  : > "$GH_CALL_LOG"

  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
# Default: succeed silently
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"

  # Story fixture in review state (about to transition to done)
  _write_story_file "$STORY_KEY" review '["GitHub #100"]'

  cat > "$SPRINT_YAML" <<EOF
sprint_id: "fixture-sprint"
stories:
  - key: $STORY_KEY
    status: "review"
EOF

  cat > "$EPICS_MD" <<EOF
# Epics and Stories

## Epic E900 — Traced-issue test epic

### Story ${STORY_KEY}: Traced-issue fixture

- **Epic:** E900
- **Priority:** P1
- **Status:** review
EOF

  cat > "$INDEX_YAML" <<EOF
# Auto-maintained
last_updated: "2026-10-16T00:00:00Z"
stories:
  ${STORY_KEY}:
    story_key: "${STORY_KEY}"
    title: "Traced-issue fixture"
    epic: "E900"
    priority: "P1"
    risk: "low"
    author: "Test"
    file: "${STORY_KEY}-traced-issue-fixture.md"
    status: "review"
EOF

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
  export PLANNING_ARTIFACTS="$TEST_TMP/docs/planning-artifacts"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export SPRINT_STATUS_YAML="$SPRINT_YAML"
  export EPICS_AND_STORIES="$EPICS_MD"
  export STORY_INDEX_YAML="$INDEX_YAML"
  export STORY_STATUS_LOCK="$LOCK_FILE"
  # Skip the review-gate composite check for these tests
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=1
  # Skip orphan sweep (no epics dir in test fixtures)
  export GAIA_SKIP_ORPHAN_SWEEP=1
}

# Helper: write a story file with given status and traces_to
_write_story_file() {
  local key="$1" status="$2" traces_to="${3:-[]}"
  local file="$TEST_TMP/docs/implementation-artifacts/${key}-traced-issue-fixture.md"
  cat > "$file" <<EOF
---
template: 'story'
key: "${key}"
title: "Traced-issue fixture"
epic: "E900"
status: ${status}
sprint_id: "fixture-sprint"
priority: "P1"
size: "S"
points: 1
risk: "low"
traces_to: ${traces_to}
---

# Story: Traced-issue fixture

> **Status:** ${status}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |
EOF
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ── AC1: fully-addressed issue is closed with comment ───────────────────────

@test "traced issue is closed with comment when story reaches done" {
  # gh stub: pr list returns a PR number, issue close succeeds
  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    if [ "\$2" = "list" ]; then
      printf '123\n'
      exit 0
    fi ;;
  issue)
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Verify gh issue close was called with the issue number
  grep -q 'issue close 100' "$GH_CALL_LOG"
  # Verify the comment mentions the PR and story key
  grep 'issue close 100' "$GH_CALL_LOG" | grep -q 'PR #123'
}

# ── AC2: partially-addressed issue gets a comment, not a close ──────────────

@test "partially-addressed issue gets a comment instead of close" {
  # Set up a second story that also traces to #200, still in-progress
  local second_key="E900-S2"
  _write_story_file "$second_key" in-progress '["GitHub #200"]'

  # Update the primary story to trace to #200
  _write_story_file "$STORY_KEY" review '["GitHub #200"]'

  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    if [ "\$2" = "list" ]; then
      printf '456\n'
      exit 0
    fi ;;
  issue)
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]
  local saved_output="$output"

  # Verify gh issue comment was called (not close)
  grep -q 'issue comment 200' "$GH_CALL_LOG"
  # Verify close was NOT called for this issue
  run grep -q 'issue close 200' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
  # Verify WARNING was emitted
  [[ "$saved_output" == *"WARNING"* ]]
}

# ── AC3: empty traces_to is a no-op ────────────────────────────────────────

@test "empty traces_to triggers no gh calls" {
  _write_story_file "$STORY_KEY" review '[]'

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # gh-calls.log should have no issue-related calls
  run grep -q 'issue' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "absent traces_to field triggers no gh calls" {
  # Write story without traces_to
  cat > "$STORY_FILE" <<'EOF'
---
template: 'story'
key: "E900-S1"
title: "Traced-issue fixture"
epic: "E900"
status: review
sprint_id: "fixture-sprint"
priority: "P1"
size: "S"
points: 1
risk: "low"
---

# Story: Traced-issue fixture

> **Status:** review

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |
EOF

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # No issue-related gh calls
  run grep -q 'issue' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

# ── AC4: gh unavailable — WARNING emitted, transition succeeds ──────────────

@test "gh unavailable emits WARNING and completes transition" {
  # Remove gh from PATH entirely
  PATH="/usr/bin:/bin" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # WARNING about gh unavailability
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"gh"* ]]

  # Transition still completed
  grep -q 'status: done' "$STORY_FILE"
}

@test "gh API failure emits WARNING with issue number and completes transition" {
  # gh stub that fails on issue operations
  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    if [ "\$2" = "list" ]; then
      printf '789\n'
      exit 0
    fi ;;
  issue)
    exit 1 ;;
esac
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # WARNING emitted with the issue number
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"100"* ]]

  # Transition still completed
  grep -q 'status: done' "$STORY_FILE"
}

# ── AC5: existing tests unaffected ──────────────────────────────────────────

@test "non-done transition does not invoke traced-issue handler" {
  # Story at backlog, transition to in-progress (not done)
  _write_story_file "$STORY_KEY" backlog '["GitHub #100"]'
  cat > "$SPRINT_YAML" <<EOF
sprint_id: "fixture-sprint"
stories:
  - key: $STORY_KEY
    status: "backlog"
EOF
  cat > "$EPICS_MD" <<EOF
# Epics and Stories

## Epic E900 — Traced-issue test epic

### Story ${STORY_KEY}: Traced-issue fixture

- **Epic:** E900
- **Priority:** P1
- **Status:** backlog
EOF

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to in-progress --from backlog
  [ "$status" -eq 0 ]

  # No gh issue calls for non-done transitions
  run grep -q 'issue' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

# ── Multiple traced issues ──────────────────────────────────────────────────

@test "multiple traced issues are each processed" {
  _write_story_file "$STORY_KEY" review '["GitHub #100", "GitHub #200"]'

  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    if [ "\$2" = "list" ]; then
      printf '999\n'
      exit 0
    fi ;;
  issue)
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Both issues processed
  grep -q 'issue close 100' "$GH_CALL_LOG"
  grep -q 'issue close 200' "$GH_CALL_LOG"
}

# ── PR number unavailable — close still attempted without PR ref ────────────

@test "traced issue closed without PR number when pr list fails" {
  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    exit 1 ;;
  issue)
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Issue close was still attempted
  grep -q 'issue close 100' "$GH_CALL_LOG"
}
