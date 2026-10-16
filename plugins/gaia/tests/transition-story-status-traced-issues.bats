#!/usr/bin/env bats
# transition-story-status-traced-issues.bats — traced-issue closure on done.
#
# Verifies the post-transition hook that closes or comments on GitHub issues
# listed in a story's `traces_to` frontmatter when the story reaches done.
#
# Public-function coverage:
#   - _close_traced_issues        — post-transition hook entry point
#   - _parse_traces_to            — extracts GitHub issue numbers from frontmatter
#   - _find_merged_pr_number      — resolves the story's merged PR via gh
#   - _is_issue_fully_addressed   — checks if other non-done stories trace the same issue
#   - _gh_with_timeout            — portable time-bounded gh wrapper
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
  # Timeout for gh calls in tests (short for speed)
  export GAIA_GH_TIMEOUT=5
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

# Helper: write a PR-returning gh stub
_write_pr_stub() {
  local pr_num="${1:-123}"
  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    if [ "\$2" = "list" ]; then
      printf '%s\n' "$pr_num"
      exit 0
    fi ;;
  issue)
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ── AC1: fully-addressed issue is closed with comment ───────────────────────

@test "traced issue is closed with story key and PR ref" {
  _write_pr_stub 123

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Verify gh issue close called with issue number
  grep -q 'issue close 100' "$GH_CALL_LOG"
  # Comment includes the story key
  grep 'issue close 100' "$GH_CALL_LOG" | grep -q "$STORY_KEY"
  # Comment includes PR ref
  grep 'issue close 100' "$GH_CALL_LOG" | grep -q 'PR #123'
}

# ── AC2: partially-addressed issue names remaining story keys ───────────────

@test "partial comment names the remaining non-done story keys" {
  local second_key="E900-S2"
  _write_story_file "$second_key" in-progress '["GitHub #200"]'
  _write_story_file "$STORY_KEY" review '["GitHub #200"]'
  _write_pr_stub 456

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]
  local saved_output="$output"

  # comment (not close) was called
  grep -q 'issue comment 200' "$GH_CALL_LOG"
  # close was NOT called
  run grep -q 'issue close 200' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
  # Comment includes this story key
  grep 'issue comment 200' "$GH_CALL_LOG" | grep -q "$STORY_KEY"
  # Comment includes PR ref
  grep 'issue comment 200' "$GH_CALL_LOG" | grep -q 'PR #456'
  # Comment names the remaining non-done story key
  grep 'issue comment 200' "$GH_CALL_LOG" | grep -q "$second_key"
  # WARNING emitted
  [[ "$saved_output" == *"WARNING"* ]]
}

# ── Blocker 1: exact issue-number match, not substring ──────────────────────

@test "issue #20 does not match a story tracing #200" {
  # Primary story traces to #20
  _write_story_file "$STORY_KEY" review '["GitHub #20"]'
  # Another story traces to #200 (not #20) and is in-progress
  _write_story_file "E900-S2" in-progress '["GitHub #200"]'
  _write_pr_stub 111

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Issue #20 is fully addressed (the other story traces #200, not #20)
  grep -q 'issue close 20 ' "$GH_CALL_LOG"
  # Must NOT have issued a comment (which would mean partial)
  run grep -q 'issue comment 20' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "body-text mention of GitHub #N does not count as a tracer" {
  # Primary story traces to #50
  _write_story_file "$STORY_KEY" review '["GitHub #50"]'
  # Another story does NOT trace to #50 but mentions it in body text
  local other_key="E900-S3"
  local other_file="$TEST_TMP/docs/implementation-artifacts/${other_key}-traced-issue-fixture.md"
  cat > "$other_file" <<EOF
---
template: 'story'
key: "${other_key}"
title: "Unrelated fixture"
epic: "E900"
status: in-progress
sprint_id: "fixture-sprint"
priority: "P1"
size: "S"
points: 1
risk: "low"
traces_to: []
---

# Story: Unrelated fixture

This story references GitHub #50 in the body but does not trace to it.
EOF
  _write_pr_stub 222

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Issue #50 is fully addressed (body-text mention is not a tracer)
  grep -q 'issue close 50 ' "$GH_CALL_LOG"
  run grep -q 'issue comment 50' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

# ── Blocker 2: self-skip must be exact key match ────────────────────────────

@test "E900-S1 does not skip E900-S10 during other-tracer scan" {
  # Primary story traces to #300
  _write_story_file "$STORY_KEY" review '["GitHub #300"]'
  # E900-S10 also traces to #300, in-progress — must be detected
  _write_story_file "E900-S10" in-progress '["GitHub #300"]'
  _write_pr_stub 333

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Issue #300 is partially addressed (E900-S10 is not done)
  grep -q 'issue comment 300' "$GH_CALL_LOG"
  grep 'issue comment 300' "$GH_CALL_LOG" | grep -q 'E900-S10'
  run grep -q 'issue close 300' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

# ── AC3: empty traces_to is a no-op ────────────────────────────────────────

@test "empty traces_to triggers no gh calls" {
  _write_story_file "$STORY_KEY" review '[]'

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  run grep -q 'issue' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "absent traces_to field triggers no gh calls" {
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

  run grep -q 'issue' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

# ── AC4: gh unavailable — WARNING emitted, transition succeeds ──────────────

@test "gh unavailable emits WARNING and completes transition" {
  PATH="/usr/bin:/bin" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"gh"* ]]
  grep -q 'status: done' "$STORY_FILE"
}

@test "gh API failure emits WARNING with issue number and completes transition" {
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

  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"100"* ]]
  grep -q 'status: done' "$STORY_FILE"
}

# ── Blocker 4: gh call timeout — transition still completes ─────────────────

@test "gh call that hangs is killed after timeout and transition completes" {
  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    if [ "\$2" = "list" ]; then
      printf '555\n'
      exit 0
    fi ;;
  issue)
    # Simulate a hang
    sleep 60
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"

  # Short timeout so test finishes quickly
  GAIA_GH_TIMEOUT=2 PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # WARNING about timeout emitted
  [[ "$output" == *"WARNING"* ]]
  # Transition still completed
  grep -q 'status: done' "$STORY_FILE"
}

# ── AC5: existing tests unaffected ──────────────────────────────────────────

@test "non-done transition does not invoke traced-issue handler" {
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

  run grep -q 'issue' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

# ── Multiple traced issues ──────────────────────────────────────────────────

@test "multiple traced issues are each processed" {
  _write_story_file "$STORY_KEY" review '["GitHub #100", "GitHub #200"]'
  _write_pr_stub 999

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  grep -q 'issue close 100' "$GH_CALL_LOG"
  grep -q 'issue close 200' "$GH_CALL_LOG"
}

# ── Blocker 5: no PR ref when no merged PR found ───────────────────────────

@test "close comment omits PR ref when no merged PR found" {
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

  # Issue close was attempted
  grep -q 'issue close 100' "$GH_CALL_LOG"
  # Story key is in the comment
  grep 'issue close 100' "$GH_CALL_LOG" | grep -q "$STORY_KEY"
  # No "PR #" in the comment (no PR found)
  run bash -c "grep 'issue close 100' '$GH_CALL_LOG' | grep -q 'PR #'"
  [ "$status" -ne 0 ]
}
