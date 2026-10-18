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

  # Initialise a real git repo so _resolve_gh_repo can derive owner/repo.
  (cd "$TEST_TMP" && git init -q && git remote add origin https://github.com/testowner/testrepo.git) 2>/dev/null

  STORY_KEY="E900-S1"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts/epic-E900-traced-issue-test/${STORY_KEY}-traced-issue-fixture"
  STORY_FILE="$TEST_TMP/docs/implementation-artifacts/epic-E900-traced-issue-test/${STORY_KEY}-traced-issue-fixture/story.md"
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
    file: "${STORY_KEY}-traced-issue-fixture/story.md"
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

# Helper: write a story file with given status and traces_to.
# Uses per-story directory layout ({key}-slug/story.md) to match the
# canonical naming that _find_other_tracers scans for.
_write_story_file() {
  local key="$1" status="$2" traces_to="${3:-[]}"
  local dir="$TEST_TMP/docs/implementation-artifacts/epic-E900-traced-issue-test/${key}-traced-issue-fixture"
  mkdir -p "$dir"
  local file="$dir/story.md"
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

  # Verify --repo targeting and -- separator in the close call
  grep -qF -- '--repo testowner/testrepo' "$GH_CALL_LOG"
  grep -qF -- '-- 100' "$GH_CALL_LOG"
  # Exact comment wording per spec: Fixed by PR #M (story <key>)
  grep -qF 'Fixed by PR #123 (story E900-S1)' "$GH_CALL_LOG"
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

  # Partial comment: remaining keys wrapped in backtick code spans
  grep -qF -- '--repo testowner/testrepo' "$GH_CALL_LOG"
  grep -qF -- '-- 200' "$GH_CALL_LOG"
  grep -qF 'Partially addressed by PR #456 (story E900-S1)' "$GH_CALL_LOG"
  # Remaining key is backtick-wrapped for Markdown rendering
  grep -qF 'Remaining: `E900-S2`.' "$GH_CALL_LOG"
  # close was NOT called for this issue
  run grep -q 'issue close 200' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
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
  grep -qF 'Fixed by PR #111 (story E900-S1)' "$GH_CALL_LOG"
  grep -qF -- '-- 20' "$GH_CALL_LOG"
  # Must NOT have issued a comment (which would mean partial)
  run grep -q 'issue comment 20' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "body-text mention of GitHub #N does not count as a tracer" {
  # Primary story traces to #50
  _write_story_file "$STORY_KEY" review '["GitHub #50"]'
  # Another story does NOT trace to #50 but mentions it in body text
  local other_key="E900-S3"
  local other_dir="$TEST_TMP/docs/implementation-artifacts/epic-E900-traced-issue-test/${other_key}-traced-issue-fixture"
  mkdir -p "$other_dir"
  local other_file="$other_dir/story.md"
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
  grep -qF 'Fixed by PR #222 (story E900-S1)' "$GH_CALL_LOG"
  grep -qF -- '-- 50' "$GH_CALL_LOG"
  run grep -q 'issue comment 50' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

# ── Blocker 2: self-skip must be exact key match ────────────────────────────

@test "self-skip uses exact key match, not substring" {
  # Primary story traces to #300
  _write_story_file "$STORY_KEY" review '["GitHub #300"]'
  # E900-S10 also traces to #300, in-progress — must be detected
  _write_story_file "E900-S10" in-progress '["GitHub #300"]'
  _write_pr_stub 333

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Issue #300 is partially addressed (E900-S10 is not done)
  grep -qF 'Remaining: `E900-S10`.' "$GH_CALL_LOG"
  grep -qF -- '-- 300' "$GH_CALL_LOG"
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

@test "gh call that hangs is killed after timeout with timeout-specific WARNING" {
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

  # Timeout-specific WARNING must mention "timed out" (not just generic failure)
  [[ "$output" == *"timed out"* ]]
  [[ "$output" == *"WARNING"* ]]
  # Transition still completed
  grep -q 'status: done' "$STORY_FILE"
}

@test "background+kill fallback exercises when timeout/gtimeout absent" {
  # gh stub that hangs on issue calls
  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    if [ "\$2" = "list" ]; then
      printf '666\n'
      exit 0
    fi ;;
  issue)
    # Simulate a hang — trap SIGTERM to test SIGKILL escalation
    trap '' TERM
    sleep 60
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$GH_STUB_DIR/gh"

  # Build a PATH without timeout/gtimeout but with gh stub + essential tools
  local clean_path="$GH_STUB_DIR:/usr/bin:/bin"

  # Short timeout; the fallback path (background+kill) must handle this
  GAIA_GH_TIMEOUT=2 PATH="$clean_path" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Timeout WARNING fires
  [[ "$output" == *"timed out"* ]]
  # Transition completed
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

  grep -qF 'Fixed by PR #999 (story E900-S1)' "$GH_CALL_LOG"
  grep -qF -- '-- 100' "$GH_CALL_LOG"
  grep -qF -- '-- 200' "$GH_CALL_LOG"
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

  # Exact comment wording without PR: Fixed by story <key>
  grep -qF 'Fixed by story E900-S1' "$GH_CALL_LOG"
  grep -qF -- '-- 100' "$GH_CALL_LOG"
  # No "PR #" in the comment (no PR found)
  run bash -c "grep 'issue close 100' '$GH_CALL_LOG' | grep -q 'PR #'"
  [ "$status" -ne 0 ]
}

# ── block-style YAML traces_to ────────────────────────────────────────────

@test "block-style YAML traces_to parsed and issues closed" {
  # Write story with block-style (indented dash list) traces_to
  local dir="$TEST_TMP/docs/implementation-artifacts/epic-E900-traced-issue-test/${STORY_KEY}-traced-issue-fixture"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'STORY'
---
template: 'story'
key: "E900-S1"
title: "Block-style fixture"
epic: "E900"
status: review
sprint_id: "fixture-sprint"
priority: "P1"
size: "S"
points: 1
risk: "low"
traces_to:
  - "GitHub #400"
  - "GitHub #401"
---

# Story: Block-style fixture

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
STORY
  _write_pr_stub 777

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$STORY_KEY" --to done --from review
  [ "$status" -eq 0 ]

  # Both issues from the block-style list are closed
  grep -qF -- '-- 400' "$GH_CALL_LOG"
  grep -qF -- '-- 401' "$GH_CALL_LOG"
  grep -qF 'Fixed by PR #777 (story E900-S1)' "$GH_CALL_LOG"
}

# ── reverse-prefix self-skip ──────────────────────────────────────────────

@test "reverse prefix direction: longer key transitioning, shorter key is other tracer" {
  # E900-S10 transitions to done, E900-S1 is the other tracer (reverse direction).
  # The self-skip must use exact key comparison, not prefix matching.
  local long_key="E900-S10"
  _write_story_file "$long_key" review '["GitHub #500"]'
  _write_story_file "E900-S1" in-progress '["GitHub #500"]'

  # Set up sprint/epics/index for E900-S10
  cat > "$SPRINT_YAML" <<EOF
sprint_id: "fixture-sprint"
stories:
  - key: $long_key
    status: "review"
EOF
  cat > "$EPICS_MD" <<EOF
# Epics and Stories

## Epic E900 — Traced-issue test epic

### Story ${long_key}: Reverse-prefix fixture

- **Epic:** E900
- **Priority:** P1
- **Status:** review
EOF
  cat > "$INDEX_YAML" <<EOF
# Auto-maintained
last_updated: "2026-10-16T00:00:00Z"
stories:
  ${long_key}:
    story_key: "${long_key}"
    title: "Reverse-prefix fixture"
    epic: "E900"
    priority: "P1"
    risk: "low"
    author: "Test"
    file: "${long_key}-traced-issue-fixture/story.md"
    status: "review"
EOF
  _write_pr_stub 888

  PATH="$GH_STUB_DIR:$PATH" run bash "$TRANSITION" "$long_key" --to done --from review
  [ "$status" -eq 0 ]

  # Issue #500 is partially addressed (E900-S1 is still in-progress)
  grep -qF 'Remaining: `E900-S1`.' "$GH_CALL_LOG"
  # Must NOT have closed the issue (only commented)
  run grep -q 'issue close.*500' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}

# ── branch-name PR search ────────────────────────────────────────────────

@test "merged PR resolved by branch name, not free-text title" {
  # Create a local branch matching the story-key convention so the
  # branch-based search finds it before falling back to body search.
  # A commit is needed for the ref to be visible via for-each-ref.
  # Configure user identity for CI environments where it is unset.
  (cd "$TEST_TMP" && \
   git config user.email "test@test" && \
   git config user.name "test" && \
   git commit -q --allow-empty -m "init" && \
   git checkout -q -b feat/E900-S1-traced-issue-fixture 2>/dev/null) || true

  # gh stub that logs args and returns a PR number only for --head queries
  cat > "$GH_STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALL_LOG"
case "\$1" in
  pr)
    if [ "\$2" = "list" ]; then
      # Return PR number for any query
      printf '555\n'
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

  # The first PR search should use --head (branch-based), not --search with
  # a bare story key (free-text title match).
  grep -qF -- '--head feat/E900-S1-traced-issue-fixture' "$GH_CALL_LOG"
  # And the story key does NOT appear as a bare --search argument
  run grep -qE -- '--search E900-S1[^"]' "$GH_CALL_LOG"
  [ "$status" -ne 0 ]
}
