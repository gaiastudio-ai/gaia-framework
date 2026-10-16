#!/usr/bin/env bats
# tick-story-checkbox.bats — unit and integration tests for the sanctioned
# checkbox writer that ticks task, subtask, and AC checkboxes in story files.

# bats file_tags=tick-story-checkbox

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

TICK_SCRIPT=""

setup() {
  common_setup
  TICK_SCRIPT="$SCRIPTS_DIR/tick-story-checkbox.sh"
  export CLAUDE_PLUGIN_ROOT="$SCRIPTS_DIR/.."

  # Build a fixture story file with known structure.
  FIXTURE="$TEST_TMP/story.md"
  _write_fixture
}

teardown() {
  common_teardown
}

_write_fixture() {
  cat > "$FIXTURE" << 'STORY_EOF'
---
key: "E900-S1"
status: in-progress
points: 5
---

# Story: Test fixture for checkbox ticking

## Acceptance Criteria

- [ ] **AC1:** First acceptance criterion with evidence
- [ ] **AC2:** Second acceptance criterion
- [ ] AC-EC1: Edge case criterion

## Tasks / Subtasks

- [ ] Task 1 -- Implement the core feature
  - [ ] Subtask 1.1: Write the parser
  - [ ] Subtask 1.2: Wire up the `output` with |pipes| and [brackets]
  - [ ] Subtask 1.3: Add error handling
- [ ] Task 2 -- Write tests
  - [ ] Subtask 2.1: Unit tests
- [x] Task 3 -- Already completed task
- [ ] Task 10 -- A double-digit task

```
- [ ] Task 99 -- This is inside a fenced code block
  - [ ] Subtask 99.1: Also fenced
```

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
STORY_EOF
}

# ---------------------------------------------------------------------------
# AC2 / Scenario 1: Single task tick
# ---------------------------------------------------------------------------
@test "ticks a single task checkbox" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1
  [ "$status" -eq 0 ]
  # Task 1 should now be ticked.
  run grep '^- \[x\] Task 1 ' "$FIXTURE"
  [ "$status" -eq 0 ]
  # Task 2 should remain unticked.
  run grep '^- \[ \] Task 2 ' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 / Scenario 2: Subtask tick
# ---------------------------------------------------------------------------
@test "ticks a specific subtask without affecting siblings" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 2
  [ "$status" -eq 0 ]
  # Subtask 1.2 should be ticked.
  run grep '^\  - \[x\] Subtask 1\.2' "$FIXTURE"
  [ "$status" -eq 0 ]
  # Subtask 1.1 and 1.3 should remain unticked.
  run grep '^\  - \[ \] Subtask 1\.1' "$FIXTURE"
  [ "$status" -eq 0 ]
  run grep '^\  - \[ \] Subtask 1\.3' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 / Scenario 3: Idempotent tick (already-ticked line)
# ---------------------------------------------------------------------------
@test "idempotent: ticking an already-ticked task is a no-op exit 0" {
  # Task 3 is already ticked in the fixture.
  local before
  before="$(cat "$FIXTURE")"
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 3
  [ "$status" -eq 0 ]
  local after
  after="$(cat "$FIXTURE")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# AC-EC1: Mixed ticked/unticked — only the target changes
# ---------------------------------------------------------------------------
@test "mixed ticked/unticked: only the targeted subtask changes" {
  # Tick subtask 1.1 first.
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 1
  [ "$status" -eq 0 ]
  # Now tick subtask 1.3.
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 3
  [ "$status" -eq 0 ]
  # 1.1 and 1.3 should be ticked; 1.2 should remain unticked.
  run grep '^\  - \[x\] Subtask 1\.1' "$FIXTURE"
  [ "$status" -eq 0 ]
  run grep '^\  - \[ \] Subtask 1\.2' "$FIXTURE"
  [ "$status" -eq 0 ]
  run grep '^\  - \[x\] Subtask 1\.3' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC-EC2: Special markdown characters preserved
# ---------------------------------------------------------------------------
@test "special characters in task line preserved byte-for-byte" {
  # Subtask 1.2 contains backticks, pipes, and brackets.
  local content_before
  content_before="$(grep 'Subtask 1\.2' "$FIXTURE" | sed 's/^  - \[.\] //')"
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 2
  [ "$status" -eq 0 ]
  local content_after
  content_after="$(grep 'Subtask 1\.2' "$FIXTURE" | sed 's/^  - \[.\] //')"
  [ "$content_before" = "$content_after" ]
}

# ---------------------------------------------------------------------------
# AC-EC3: Empty tasks section
# ---------------------------------------------------------------------------
@test "empty tasks section: exits 0 with no changes" {
  local empty="$TEST_TMP/empty.md"
  cat > "$empty" << 'EOF'
---
key: "E900-S2"
---

## Tasks / Subtasks

## Review Gate
EOF
  local before
  before="$(cat "$empty")"
  run bash "$TICK_SCRIPT" --file "$empty" --task 1
  [ "$status" -eq 0 ]
  local after
  after="$(cat "$empty")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# AC-EC5: Bash 3.2 compatibility
# ---------------------------------------------------------------------------
@test "runs identically under /bin/bash 3.2" {
  # Only meaningful on macOS where /bin/bash is 3.2.
  if ! /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.2'; then
    skip "/bin/bash is not 3.2 on this host"
  fi
  _write_fixture
  run /bin/bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1
  [ "$status" -eq 0 ]
  run grep '^- \[x\] Task 1 ' "$FIXTURE"
  [ "$status" -eq 0 ]
  # Task 2 untouched.
  run grep '^- \[ \] Task 2 ' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Fenced code block protection
# ---------------------------------------------------------------------------
@test "does not tick checkboxes inside fenced code blocks" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 99
  [ "$status" -eq 1 ]
  # Task 99 inside the fenced block should remain unticked.
  run grep '^\- \[ \] Task 99' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Double-digit task number boundary (Task 1 vs Task 10)
# ---------------------------------------------------------------------------
@test "Task 1 tick does not affect Task 10" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1
  [ "$status" -eq 0 ]
  # Task 10 should remain unticked.
  run grep '^- \[ \] Task 10 ' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC tick (--ac mode)
# ---------------------------------------------------------------------------
@test "ticks a bold AC checkbox" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --ac 1
  [ "$status" -eq 0 ]
  run grep '^- \[x\] \*\*AC1:\*\*' "$FIXTURE"
  [ "$status" -eq 0 ]
  # AC2 should remain unticked.
  run grep '^- \[ \] \*\*AC2:\*\*' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Error: missing file
# ---------------------------------------------------------------------------
@test "exits 1 on missing file" {
  run bash "$TICK_SCRIPT" --file "$TEST_TMP/nonexistent.md" --task 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"file not found"* ]]
}

# ---------------------------------------------------------------------------
# Error: no matching task
# ---------------------------------------------------------------------------
@test "exits 1 when task number not found in non-empty section" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 42
  [ "$status" -eq 1 ]
  [[ "$output" == *"no matching Task 42"* ]]
}

# ---------------------------------------------------------------------------
# Error: mutually exclusive flags
# ---------------------------------------------------------------------------
@test "exits 1 when --task and --ac are both given" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --ac 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

# ---------------------------------------------------------------------------
# AC4 integration: tick all tasks, verify dashboard would count correctly
# ---------------------------------------------------------------------------
@test "integration: ticking all tasks produces correct ticked count" {
  # Tick tasks 1, 2, 10 (task 3 is already ticked).
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1
  [ "$status" -eq 0 ]
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 2
  [ "$status" -eq 0 ]
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 10
  [ "$status" -eq 0 ]

  # Count ticked vs total top-level task lines in the Tasks section.
  # The snapshot script counts lines matching /^- \[/ inside ## Tasks / Subtasks.
  # Use awk to properly handle fenced code blocks.
  local counts
  counts="$(awk '
    /^## Tasks \/ Subtasks/ { s=1; next }
    /^## / && s { exit }
    /^```/ { f=!f; next }
    s && !f && /^- \[/ {
      total++
      if (substr($0,4,1)=="x" || substr($0,4,1)=="X") ticked++
    }
    END { print ticked, total }
  ' "$FIXTURE")"
  local ticked total
  ticked="${counts%% *}"
  total="${counts##* }"

  [ "$ticked" -eq "$total" ]
  [ "$total" -eq 4 ]
}
