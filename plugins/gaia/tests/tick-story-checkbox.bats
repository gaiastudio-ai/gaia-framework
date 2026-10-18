#!/usr/bin/env bats
# tick-story-checkbox.bats — unit and integration tests for the sanctioned
# checkbox writer that ticks task, subtask, and AC checkboxes in story files.
# Covers all format variants observed in production story files.

# bats file_tags=tick-story-checkbox

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

TICK_SCRIPT=""

setup() {
  common_setup
  TICK_SCRIPT="$SCRIPTS_DIR/tick-story-checkbox.sh"
  export CLAUDE_PLUGIN_ROOT="$SCRIPTS_DIR/.."

  FIXTURE="$TEST_TMP/story.md"
  _write_fixture
}

teardown() {
  common_teardown
}

# Fixture with every format variant observed in production.
_write_fixture() {
  cat > "$FIXTURE" << 'STORY_EOF'
---
key: "E900-S1"
status: in-progress
points: 5
---

# Story: Test fixture for checkbox ticking

## Acceptance Criteria

- [ ] **AC1:** First acceptance criterion
- [ ] **AC2:** Second acceptance criterion
- [ ] AC-EC1: Edge case criterion

## Tasks / Subtasks

- [ ] Task 1 -- Plain format
  - [ ] Subtask 1.1: Explicit subtask label
  - [ ] Subtask 1.2: With `backticks` and |pipes| and [brackets]
  - [ ] Subtask 1.3: Third subtask
- [ ] **Task 2:** Bold with colon
  - [ ] 2.1: Bare number subtask
  - [ ] 2.2 Another bare (no colon)
- [ ] **T3** -- Shorthand bold
  - [ ] **3.1:** Bold bare number
  - [ ] 3.2: Plain bare number
- [x] Task 4 -- Already completed
- [ ] Task 10 -- Double-digit task
  - [ ] 10.1: Double-digit subtask
  - [ ] 1.10: Must NOT match 1.1

```
- [ ] Task 99 -- Inside fenced code block
  - [ ] 99.1: Also fenced
```

## Some Other Section

- [ ] Task 1 -- Outside the Tasks section (must never be ticked)

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | --- |
STORY_EOF
}

# ---------------------------------------------------------------------------
# Format: plain "Task N"
# ---------------------------------------------------------------------------
@test "ticks plain 'Task N' format" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1
  [ "$status" -eq 0 ]
  run grep '^- \[x\] Task 1 ' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Format: bold "**Task N:**"
# ---------------------------------------------------------------------------
@test "ticks bold '**Task N:**' format" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 2
  [ "$status" -eq 0 ]
  run grep '^- \[x\] \*\*Task 2:\*\*' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Format: shorthand bold "**TN**"
# ---------------------------------------------------------------------------
@test "ticks shorthand bold '**TN**' format" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 3
  [ "$status" -eq 0 ]
  run grep '^- \[x\] \*\*T3\*\*' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Format: explicit "Subtask N.M"
# ---------------------------------------------------------------------------
@test "ticks explicit 'Subtask N.M' format" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 1
  [ "$status" -eq 0 ]
  run grep 'Subtask 1\.1' "$FIXTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[x]"* ]]
}

# ---------------------------------------------------------------------------
# Format: bare "N.M:" subtask
# ---------------------------------------------------------------------------
@test "ticks bare 'N.M:' subtask format" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 2 --subtask 1
  [ "$status" -eq 0 ]
  run grep '2\.1' "$FIXTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[x]"* ]]
}

# ---------------------------------------------------------------------------
# Format: bare "N.M" subtask without colon
# ---------------------------------------------------------------------------
@test "ticks bare 'N.M' subtask without colon" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 2 --subtask 2
  [ "$status" -eq 0 ]
  run grep '2\.2' "$FIXTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[x]"* ]]
}

# ---------------------------------------------------------------------------
# Format: bold bare "**N.M:**" subtask
# ---------------------------------------------------------------------------
@test "ticks bold bare '**N.M:**' subtask format" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 3 --subtask 1
  [ "$status" -eq 0 ]
  run grep '3\.1' "$FIXTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[x]"* ]]
}

# ---------------------------------------------------------------------------
# Idempotent: already-ticked task
# ---------------------------------------------------------------------------
@test "idempotent: ticking an already-ticked task is exit 0 no-op" {
  local before
  before="$(cat "$FIXTURE")"
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 4
  [ "$status" -eq 0 ]
  local after
  after="$(cat "$FIXTURE")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Mixed ticked/unticked: only the target changes
# ---------------------------------------------------------------------------
@test "mixed state: only the targeted subtask changes" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 1
  [ "$status" -eq 0 ]
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 3
  [ "$status" -eq 0 ]
  # 1.1 and 1.3 ticked; 1.2 unticked.
  grep 'Subtask 1\.1' "$FIXTURE" | grep -q '\[x\]'
  grep 'Subtask 1\.2' "$FIXTURE" | grep -q '\[ \]'
  grep 'Subtask 1\.3' "$FIXTURE" | grep -q '\[x\]'
}

# ---------------------------------------------------------------------------
# Special characters preserved
# ---------------------------------------------------------------------------
@test "special characters in task line preserved byte-for-byte" {
  local content_before
  content_before="$(grep 'Subtask 1\.2' "$FIXTURE" | sed 's/^[[:space:]]*- \[.\] //')"
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 2
  [ "$status" -eq 0 ]
  local content_after
  content_after="$(grep 'Subtask 1\.2' "$FIXTURE" | sed 's/^[[:space:]]*- \[.\] //')"
  [ "$content_before" = "$content_after" ]
}

# ---------------------------------------------------------------------------
# Empty tasks section
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
# Fenced code block protection
# ---------------------------------------------------------------------------
@test "does not tick checkboxes inside fenced code blocks" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 99
  [ "$status" -eq 1 ]
  grep 'Task 99' "$FIXTURE" | grep -q '\[ \]'
}

# ---------------------------------------------------------------------------
# Boundary: Task 1 does NOT match Task 10
# ---------------------------------------------------------------------------
@test "Task 1 tick does not affect Task 10" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1
  [ "$status" -eq 0 ]
  grep '^- \[ \] Task 10 ' "$FIXTURE"
}

# ---------------------------------------------------------------------------
# Boundary: only Task 10 exists, --task 1 exits 1 changes nothing
# ---------------------------------------------------------------------------
@test "boundary: --task 1 exits 1 when only Task 10 exists" {
  local boundary="$TEST_TMP/boundary.md"
  cat > "$boundary" << 'EOF'
---
key: "E900-S9"
---

## Tasks / Subtasks

- [ ] Task 10 -- Only double-digit task
  - [ ] 10.1: Only double-digit subtask

## Review Gate
EOF
  local before
  before="$(cat "$boundary")"
  run bash "$TICK_SCRIPT" --file "$boundary" --task 1
  [ "$status" -eq 1 ]
  local after
  after="$(cat "$boundary")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Boundary: subtask 1.1 does NOT match 1.10
# ---------------------------------------------------------------------------
@test "boundary: subtask 1.1 does not match 1.10" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1 --subtask 1
  [ "$status" -eq 0 ]
  grep '1\.10' "$FIXTURE" | grep -q '\[ \]'
}

# ---------------------------------------------------------------------------
# Boundary: --subtask 1 exits 1 when only 10.1 exists
# ---------------------------------------------------------------------------
@test "boundary: --task 1 --subtask 1 exits 1 when only 10.1 exists" {
  local boundary="$TEST_TMP/boundary-sub.md"
  cat > "$boundary" << 'EOF'
---
key: "E900-S9"
---

## Tasks / Subtasks

- [ ] Task 10 -- Only double-digit task
  - [ ] 10.1: Only double-digit subtask

## Review Gate
EOF
  local before
  before="$(cat "$boundary")"
  run bash "$TICK_SCRIPT" --file "$boundary" --task 1 --subtask 1
  [ "$status" -eq 1 ]
  local after
  after="$(cat "$boundary")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Section scoping: Task 1 outside ## Tasks / Subtasks is never ticked
# ---------------------------------------------------------------------------
@test "section scoping: Task line outside Tasks section is never ticked" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1
  [ "$status" -eq 0 ]
  # The fixture has a "Task 1" line under "## Some Other Section".
  # That line must remain unticked ([ ]).
  local outside
  outside="$(awk '/^## Some Other Section/,0' "$FIXTURE" | grep 'Task 1')"
  [[ "$outside" == *"[ ]"* ]]
}

# ---------------------------------------------------------------------------
# AC tick
# ---------------------------------------------------------------------------
@test "ticks a bold AC checkbox" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --ac 1
  [ "$status" -eq 0 ]
  grep 'AC1' "$FIXTURE" | grep -q '\[x\]'
  grep 'AC2' "$FIXTURE" | grep -q '\[ \]'
}

# ---------------------------------------------------------------------------
# Symlinked story path: writes through to the real file
# ---------------------------------------------------------------------------
@test "symlinked path: writes through to the real file" {
  local real="$TEST_TMP/real-story.md"
  local link="$TEST_TMP/link-story.md"
  cat > "$real" << 'EOF'
---
key: "E900-S3"
---

## Tasks / Subtasks

- [ ] Task 1 -- Behind a symlink

## Review Gate
EOF
  ln -sf "$real" "$link"
  run bash "$TICK_SCRIPT" --file "$link" --task 1
  [ "$status" -eq 0 ]
  [ -L "$link" ]
  grep 'Task 1' "$real" | grep -q '\[x\]'
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
@test "exits 1 when task number not found" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 42
  [ "$status" -eq 1 ]
  [[ "$output" == *"no matching task 42"* ]]
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
# Bash 3.2 compatibility
# ---------------------------------------------------------------------------
@test "runs identically under /bin/bash 3.2" {
  if ! /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.2'; then
    skip "/bin/bash is not 3.2 on this host"
  fi
  _write_fixture
  run /bin/bash "$TICK_SCRIPT" --file "$FIXTURE" --task 2
  [ "$status" -eq 0 ]
  grep 'Task 2' "$FIXTURE" | grep -q '\[x\]'
  run /bin/bash "$TICK_SCRIPT" --file "$FIXTURE" --task 2 --subtask 1
  [ "$status" -eq 0 ]
  grep '2\.1' "$FIXTURE" | grep -q '\[x\]'
}

# ---------------------------------------------------------------------------
# Integration: tick all tasks, verify count
# ---------------------------------------------------------------------------
@test "integration: ticking all tasks produces correct count" {
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 1
  [ "$status" -eq 0 ]
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 2
  [ "$status" -eq 0 ]
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 3
  [ "$status" -eq 0 ]
  run bash "$TICK_SCRIPT" --file "$FIXTURE" --task 10
  [ "$status" -eq 0 ]

  local counts
  counts="$(awk '
    /^## Tasks \/ Subtasks/ { s=1; next }
    /^## / && s { exit }
    /^```/ { f=!f; next }
    s && !f && /^- \[/ {
      total++
      if (substr($0,4,1)=="x" || substr($0,4,1)=="X") ticked++
    }
    END { print ticked+0, total+0 }
  ' "$FIXTURE")"
  local ticked total
  ticked="${counts%% *}"
  total="${counts##* }"

  [ "$ticked" -eq "$total" ]
  [ "$total" -eq 5 ]
}

# ---------------------------------------------------------------------------
# Integration: tick tasks and verify the real snapshot reports correct counts
# ---------------------------------------------------------------------------

# _write_snapshot_project — scaffold a minimal .gaia project around a story
# file so the real sprint-progress-snapshot.sh can parse it.
_write_snapshot_project() {
  local story_file="$1" story_key="$2"
  local proj="$TEST_TMP/snap-project"
  mkdir -p "$proj/.gaia/state" "$proj/.gaia/config"

  local impl="$proj/.gaia/artifacts/implementation-artifacts"
  local sdir="$impl/epic-test/${story_key}-snap-test"
  mkdir -p "$sdir"
  cp "$story_file" "$sdir/story.md"

  cat > "$proj/.gaia/state/sprint-status.yaml" <<YAML
sprint_id: "sprint-snap"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 5
velocity_capacity: 100
goals:
  - "test"
stories:
  - key: "${story_key}"
    title: "Story ${story_key}"
    status: "in-progress"
    points: 5
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
YAML

  printf '%s' "$proj"
}

@test "real snapshot reports correct task count after ticking" {
  # Build a clean fixture without fenced-code-block tasks so the snapshot's
  # parser and the tick script agree on the task inventory.
  local story="$TEST_TMP/snap-story.md"
  cat > "$story" << 'SNAP_FIXTURE'
---
key: "E900-S1"
status: in-progress
points: 5
---

# Story: Snapshot integration fixture

## Tasks / Subtasks

- [ ] Task 1 -- First task
- [ ] Task 2 -- Second task
- [ ] Task 3 -- Third task
- [x] Task 4 -- Already completed

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | --- |
SNAP_FIXTURE

  # Tick task 1 with the real writer.
  run bash "$TICK_SCRIPT" --file "$story" --task 1
  [ "$status" -eq 0 ]

  # Scaffold a project tree and run the real snapshot.
  local proj story_dir
  proj="$(_write_snapshot_project "$story" "E900-S1")"
  story_dir="$proj/.gaia/artifacts/implementation-artifacts/epic-test/E900-S1-snap-test"

  local snap_script
  snap_script="$(snapshot_script_under_test "$SCRIPTS_DIR/sprint-progress-snapshot.sh")"

  PROJECT_ROOT="$proj" run "$snap_script"
  [ "$status" -eq 0 ]

  local cache="$proj/.gaia/state/.sprint-progress-cache.json"
  [ -f "$cache" ]

  # 4 top-level tasks; task 4 was already ticked, task 1 just ticked = 2 done.
  local done_count total_count
  done_count="$(jq -r '.stories[0].tasks.done' "$cache")"
  total_count="$(jq -r '.stories[0].tasks.total' "$cache")"
  [ "$total_count" -eq 4 ]
  [ "$done_count" -eq 2 ]

  # Tick one more task in the project copy and re-run — count must increase.
  bash "$TICK_SCRIPT" --file "$story_dir/story.md" --task 2
  # Wipe incremental-refresh sidecars so the snapshot re-parses the story.
  rm -f "$proj/.gaia/state/.sprint-progress-parsed" \
        "$proj/.gaia/state/.sprint-progress-mtimes"
  PROJECT_ROOT="$proj" run "$snap_script"
  [ "$status" -eq 0 ]

  done_count="$(jq -r '.stories[0].tasks.done' "$cache")"
  [ "$done_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# SKILL.md integration: Step 6 contains the tick instruction
# ---------------------------------------------------------------------------
@test "SKILL.md Step 6 contains the tick-story-checkbox.sh instruction" {
  local skillmd="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/SKILL.md"
  [ -f "$skillmd" ]
  local step6_body
  step6_body="$(awk '/^### Step 6 --/,/^### Step 6a/' "$skillmd")"
  grep -q 'tick-story-checkbox.sh' <<< "$step6_body"
  grep -q '\-\-task' <<< "$step6_body"
  grep -q '\-\-subtask' <<< "$step6_body"
}
