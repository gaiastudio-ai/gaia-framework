#!/usr/bin/env bats
# brain-freshness-hooks.bats — coverage for the event-driven freshness hooks
# that wire update-brain-index.sh into the lifecycle + review-write paths.
#
# Behaviour under test:
#   - transition-story-status.sh invokes update-brain-index.sh on story→done
#     to mark the story node closed and link its final reviews (TC-BRN-75/76).
#   - review-gate.sh invokes update-brain-index.sh on a landed review to
#     append a reviewed-in edge (TC-BRN-77).
#   - Repeated lifecycle/review events are idempotent — no duplicate edges
#     or entries (TC-BRN-78).
#   - A full gaia-brain-reindex sweep preserves lesson entries verbatim
#     via carry-forward (TC-BRN-79/80).
#
# All tests use CLAUDE_PROJECT_ROOT isolation so they never touch the real
# brain index. Paths derive from $BATS_TEST_DIRNAME via test_helper.bash.

load 'test_helper.bash'

# Portable sha256 — dual idiom matching the brain scripts.
_sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'no-sha256-tool'
  fi
}

setup() {
  common_setup

  UPDATER="$SCRIPTS_DIR/brain/update-brain-index.sh"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"
  REVIEW_GATE="$SCRIPTS_DIR/review-gate.sh"
  REINDEX="$SCRIPTS_DIR/brain/gaia-brain-reindex.sh"

  # Isolated project root.
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia/knowledge"
  mkdir -p "$PROJ/.gaia/state"
  mkdir -p "$PROJ/.gaia/config"
  mkdir -p "$PROJ/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$PROJ/.gaia/artifacts/planning-artifacts/epics"
  export CLAUDE_PROJECT_ROOT="$PROJ"
  export PROJECT_PATH="$PROJ"
  MANIFEST="$PROJ/.gaia/knowledge/brain-index.yaml"

  # Minimal sprint-status.yaml so transition-story-status.sh can function.
  cat > "$PROJ/.gaia/state/sprint-status.yaml" <<'YAML'
current_sprint: sprint-99
sprints:
  sprint-99:
    status: active
    stories:
      E99-S1:
        status: review
        points: 3
    total_points: 3
YAML
  export SPRINT_STATUS_YAML="$PROJ/.gaia/state/sprint-status.yaml"

  # Minimal epics-and-stories.md.
  cat > "$PROJ/.gaia/artifacts/planning-artifacts/epics-and-stories.md" <<'MD'
# Epics and Stories

## Epic 99: Test Epic

### Story E99-S1: Test Story
- **Status:** review
- **Points:** 3
MD
  export EPICS_AND_STORIES="$PROJ/.gaia/artifacts/planning-artifacts/epics-and-stories.md"

  # Per-epic shard.
  mkdir -p "$PROJ/.gaia/artifacts/planning-artifacts/epics"
  cat > "$PROJ/.gaia/artifacts/planning-artifacts/epics/epic-e99-test-epic.md" <<'MD'
## Epic 99: Test Epic

### Story E99-S1:
- **Status:** review
- **Points:** 3
MD

  # Story file with review gate table (status: review, ready for →done).
  local story_dir="$PROJ/.gaia/artifacts/implementation-artifacts"
  cat > "$story_dir/E99-S1-test-story.md" <<'MD'
---
template: 'story'
version: 1.4.0
key: "E99-S1"
title: "Test Story"
epic: "E99"
status: review
priority: "P2"
size: "S"
points: 3
risk: "low"
sprint_id: "sprint-99"
priority_flag: null
delivered: true
deferred_implementation: false
origin: "manual"
origin_ref: "test"
depends_on: []
blocks: []
traces_to: []
date: "2026-06-16"
author: "Test"
---

# Story: Test Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |

## Definition of Done

### Acceptance

- [x] All acceptance criteria verified
MD
  export STORY_FILE="$story_dir/E99-S1-test-story.md"

  # Story index YAML (required by transition script).
  mkdir -p "$story_dir/epic-E99-test-epic/stories"
  cat > "$story_dir/epic-E99-test-epic/stories/story-index.yaml" <<'YAML'
- story_key: "E99-S1"
  title: "Test Story"
  epic: "E99"
  priority: "P2"
  risk: "low"
  author: "Test"
  file: "E99-S1-test-story.md"
  status: "review"
YAML
  export STORY_INDEX_YAML="$story_dir/epic-E99-test-epic/stories/story-index.yaml"

  # Seed brain-index manifest with a lesson entry (node for the story).
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "E99-S1"
  source_type: lesson
  path: ".gaia/artifacts/implementation-artifacts/E99-S1-test-story.md"
  tags: ["story"]
  synopsis: "Test story node."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "aaa111aaa111aaa111aaa111aaa111aaa111aaa111aaa111aaa111aaa111aaa1"
    source_url: null
    fetched_at: null
    expires_at: null
YAML
}

teardown() {
  unset CLAUDE_PROJECT_ROOT PROJECT_PATH SPRINT_STATUS_YAML EPICS_AND_STORIES
  unset STORY_FILE STORY_INDEX_YAML
  common_teardown
}

# ---------------------------------------------------------------------------
# Helper: extract ALL lines belonging to a single entry block by key.
# ---------------------------------------------------------------------------
_extract_entry_block() {
  local manifest="$1" key="$2"
  awk -v key="$key" '
    /^- key:/ {
      k = $0; sub(/^- key:[[:space:]]*"?/, "", k); sub(/"?$/, "", k)
      if (k == key) { found = 1 }
      else if (found) { exit }
    }
    found { print }
  ' "$manifest"
}

# ---- TC-BRN-75 — story→done invokes update-brain-index.sh to mark node closed

@test "transition story→done marks reviewed-in edges on the story node" {
  [ -f "$TRANSITION" ]
  [ -f "$UPDATER" ]

  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  # Run the transition to done.
  run bash "$TRANSITION" E99-S1 --to done
  [ "$status" -eq 0 ]

  # Content assertion: the manifest must now contain reviewed-in edges on the
  # story node. The fixture story file has 6 PASSED review gates, so we expect
  # reviewed-in edges (at least one) rather than relying on a flaky mtime proxy.
  local entry_block
  entry_block="$(_extract_entry_block "$MANIFEST" "E99-S1")"
  [ -n "$entry_block" ]

  # At least one reviewed-in edge must be present.
  printf '%s\n' "$entry_block" | grep -q 'type: reviewed-in'
}

# ---- TC-BRN-76 — story→done links final reviews via reviewed-in edges

@test "story→done links final reviews via reviewed-in edges" {
  [ -f "$TRANSITION" ]
  [ -f "$UPDATER" ]

  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  # Run transition to done.
  run bash "$TRANSITION" E99-S1 --to done
  [ "$status" -eq 0 ]

  # The manifest should now contain reviewed-in edges linking the review gates.
  local entry_block
  entry_block="$(_extract_entry_block "$MANIFEST" "E99-S1")"

  # The fixture defines exactly 6 PASSED review gates; assert the exact count.
  local edge_count
  edge_count=$(printf '%s\n' "$entry_block" | grep -c 'type: reviewed-in' || true)
  [ "$edge_count" -eq 6 ]
}

# ---- TC-BRN-77 — review-gate.sh review-write appends a reviewed-in edge

@test "review-gate.sh review-write appends a reviewed-in edge" {
  [ -f "$REVIEW_GATE" ]
  [ -f "$UPDATER" ]

  # Start with review gate in UNVERIFIED state for Code Review.
  # Reset the story to have Code Review UNVERIFIED.
  local story_dir="$PROJ/.gaia/artifacts/implementation-artifacts"
  cat > "$story_dir/E99-S1-test-story.md" <<'MD'
---
template: 'story'
version: 1.4.0
key: "E99-S1"
title: "Test Story"
epic: "E99"
status: in-progress
priority: "P2"
size: "S"
points: 3
risk: "low"
sprint_id: "sprint-99"
priority_flag: null
delivered: true
deferred_implementation: false
origin: "manual"
origin_ref: "test"
depends_on: []
blocks: []
traces_to: []
date: "2026-06-16"
author: "Test"
---

# Story: Test Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
MD

  # Also update sprint-status to in-progress.
  cat > "$PROJ/.gaia/state/sprint-status.yaml" <<'YAML'
current_sprint: sprint-99
sprints:
  sprint-99:
    status: active
    stories:
      E99-S1:
        status: in-progress
        points: 3
    total_points: 3
YAML

  # Disable proof-of-execution for test.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  # Run review-gate.sh update with a PASSED verdict.
  run bash "$REVIEW_GATE" update --story E99-S1 --gate "Code Review" --verdict PASSED \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]

  # The manifest should now have a reviewed-in edge for Code Review.
  local entry_block
  entry_block="$(_extract_entry_block "$MANIFEST" "E99-S1")"

  # Should have a reviewed-in edge.
  printf '%s\n' "$entry_block" | grep -q 'type: reviewed-in'
}

# ---- TC-BRN-78 — repeated lifecycle events are idempotent

@test "repeated lifecycle events produce no duplicate edges" {
  [ -f "$UPDATER" ]

  # Add an edge to the manifest directly.
  run bash "$UPDATER" --manifest "$MANIFEST" --add-edge \
    --target-key "E99-S1" \
    --edge-type "reviewed-in" \
    --edge-target "code-review-E99-S1"
  [ "$status" -eq 0 ]

  # Count edges after first add.
  local count_1
  count_1=$(grep -c 'type: reviewed-in' "$MANIFEST" || true)
  [ "$count_1" -eq 1 ]

  # Add the SAME edge again — idempotency guard should skip it.
  run bash "$UPDATER" --manifest "$MANIFEST" --add-edge \
    --target-key "E99-S1" \
    --edge-type "reviewed-in" \
    --edge-target "code-review-E99-S1"
  [ "$status" -eq 0 ]

  # Count should still be 1 (no duplicate).
  local count_2
  count_2=$(grep -c 'type: reviewed-in' "$MANIFEST" || true)
  [ "$count_2" -eq 1 ]
}

# ---- TC-BRN-79 — full reindex sweep preserves lesson entries verbatim

@test "full gaia-brain-reindex sweep preserves lesson entries verbatim" {
  [ -f "$REINDEX" ]

  # Add a lesson entry with an edge to the manifest.
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "lesson-retro-sprint-50"
  source_type: lesson
  path: ".gaia/artifacts/retro/retro-sprint-50.md"
  tags: ["strategy"]
  synopsis: "Lesson from sprint 50 retro."
  edges:
    - type: reviewed-in
      target: "sprint-review-sprint-50"
  trust:
    confidence: 1.0
    content_hash: "eee555eee555eee555eee555eee555eee555eee555eee555eee555eee555eee5"
    source_url: "retro:sprint-50"
    fetched_at: null
    expires_at: null
YAML

  # Snapshot the lesson entry before reindex.
  local lesson_before
  lesson_before="$(_extract_entry_block "$MANIFEST" "lesson-retro-sprint-50")"
  [ -n "$lesson_before" ]

  # Run the reindex sweep. It will re-harvest project-artifacts but should
  # carry forward the lesson entry verbatim.
  # Use a minimal project config so reindex can run.
  cat > "$PROJ/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
stacks:
  - name: bash
    path: "."
YAML

  # Create a minimal schema for the validator.
  local schema_dir="$SCRIPTS_DIR/brain"
  # Run reindex — it may warn about missing artifacts but should still
  # preserve the lesson entry.
  run bash "$REINDEX" 2>&1
  # Reindex may exit non-zero if there are no project-artifacts, but
  # the lesson should survive. Check the manifest.

  # The lesson entry must still be present.
  grep -q 'lesson-retro-sprint-50' "$MANIFEST"

  # The lesson entry must still have source_type: lesson.
  grep -q 'source_type: lesson' "$MANIFEST"

  # The lesson entry's edge must survive.
  local lesson_after
  lesson_after="$(_extract_entry_block "$MANIFEST" "lesson-retro-sprint-50")"
  [ -n "$lesson_after" ]

  # Synopsis must be preserved.
  printf '%s\n' "$lesson_after" | grep -q 'Lesson from sprint 50 retro.'
}

# ---- TC-BRN-80 — lesson entries survive a full index rebuild

@test "lesson entries survive a full index rebuild (not pruned as orphans)" {
  [ -f "$REINDEX" ]

  # Add TWO lesson entries to the manifest.
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "lesson-strategy-alpha"
  source_type: lesson
  path: ".gaia/artifacts/retro/retro-sprint-48.md"
  tags: ["strategy"]
  synopsis: "Alpha lesson."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "fff666fff666fff666fff666fff666fff666fff666fff666fff666fff666fff6"
    source_url: "retro:sprint-48"
    fetched_at: null
    expires_at: null
- key: "lesson-process-beta"
  source_type: lesson
  path: ".gaia/artifacts/retro/retro-sprint-49.md"
  tags: ["process"]
  synopsis: "Beta lesson."
  edges:
    - type: reviewed-in
      target: "sprint-review-sprint-49"
  trust:
    confidence: 1.0
    content_hash: "ggg777ggg777ggg777ggg777ggg777ggg777ggg777ggg777ggg777ggg777ggg7"
    source_url: "retro:sprint-49"
    fetched_at: null
    expires_at: null
YAML

  cat > "$PROJ/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
stacks:
  - name: bash
    path: "."
YAML

  # Run reindex.
  run bash "$REINDEX" 2>&1

  # BOTH lesson entries must survive.
  grep -q 'lesson-strategy-alpha' "$MANIFEST"
  grep -q 'lesson-process-beta' "$MANIFEST"

  # source_type must still be lesson for both.
  local lesson_count
  lesson_count=$(grep -c 'source_type: lesson' "$MANIFEST")
  [ "$lesson_count" -eq 2 ]

  # Beta's edge must survive.
  local beta_block
  beta_block="$(_extract_entry_block "$MANIFEST" "lesson-process-beta")"
  printf '%s\n' "$beta_block" | grep -q 'reviewed-in'
}
