#!/usr/bin/env bats
# sprint-state-key-alignment.bats — tests for sprint-status.yaml key alignment.
#
# Verifies that sprint-state.sh init/inject and all reader sites use the
# canonical `stories:` key (not the legacy `items:` key), and that legacy
# files with `items:` are handled gracefully.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SPRINT_STATE="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
RESOLVE_SPRINT_STORIES="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"

setup() {
  common_setup
  # Create a minimal project layout in TEST_TMP so sprint-state.sh can resolve
  # paths without touching the real plugin tree.
  mkdir -p "$TEST_TMP/project/.gaia/state"
  mkdir -p "$TEST_TMP/project/.gaia/config"
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$TEST_TMP/project/.gaia/memory"

  # Minimal project config so sprint-state.sh doesn't bail on missing config.
  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" <<'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
YAML

  export PROJECT_ROOT="$TEST_TMP/project"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP/project"
  export PROJECT_PATH="$TEST_TMP/project"
  export SPRINT_STATUS_YAML="$TEST_TMP/project/.gaia/state/sprint-status.yaml"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — sprint-state.sh init seeds `stories:` not `items:`
# ---------------------------------------------------------------------------
@test "init seeds stories key, not items key" {
  run bash "$SPRINT_STATE" init --sprint-id sprint-999
  [ "$status" -eq 0 ]
  # The created file must contain `stories:` and must NOT contain `items:`
  grep -q '^stories:' "$SPRINT_STATUS_YAML"
  run grep -q '^items:' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
  # Structural validation: sprint_id, status, total_points, goals present
  grep -q '^sprint_id:' "$SPRINT_STATUS_YAML"
  grep -q '^status: planned' "$SPRINT_STATUS_YAML"
  grep -q '^total_points: 0' "$SPRINT_STATUS_YAML"
  grep -q '^goals:' "$SPRINT_STATUS_YAML"
}

# ---------------------------------------------------------------------------
# AC2 — all writer/reader sites use the `stories:` key consistently
# ---------------------------------------------------------------------------
@test "no writer site in sprint-state.sh seeds or appends to items key" {
  local script="$SPRINT_STATE"
  [ -f "$script" ]

  # Init writer sites: the printf lines that seed the story-list key.
  # These lines appear in the concurrent-mode and single-sprint init paths.
  # They must all say 'stories' not 'items'.
  local init_seeds
  init_seeds=$(grep -c "printf.*'items: \[\]" "$script" || true)
  [ "$init_seeds" -eq 0 ]
}

@test "sprint-state.sh readers all reference stories key" {
  local script="$SPRINT_STATE"
  [ -f "$script" ]

  # Every awk reader block marker must use stories:, not items:.
  # Sprint-state.sh should have zero items: references in code
  # (comments mentioning legacy migration are acceptable).
  local items_in_code
  items_in_code=$(grep -n 'items:' "$script" | grep -v '^[[:space:]]*#' || true)
  [ -z "$items_in_code" ]
}

@test "resolve-sprint-stories.sh reader uses stories key with items fallback" {
  local script="$RESOLVE_SPRINT_STORIES"
  [ -f "$script" ]
  # The awk block in this script reads the stories: key as primary
  grep -q 'stories' "$script"
  grep -q 'in_stories' "$script"
  # It also has a fallback for legacy items: key
  grep -q 'in_items' "$script"
  # The END block prefers stories: over items:
  grep -q 'saw_stories' "$script"
}

@test "covered sites include init, inject, done-check, dep-lint, reconcile, triage reader" {
  local script="$SPRINT_STATE"
  [ -f "$script" ]

  # Init: stories: [] seed
  grep -q "printf.*'stories: \[\]" "$script"
  # Inject/append: the awk writer references stories:
  grep -q 'stories:.*\[\]' "$script"
  # Done-check: _yaml_all_stories_done references stories:
  grep -q '_yaml_all_stories_done' "$script"
  # Dep-lint: .stories[] yq selector
  grep -q '\.stories\[\]' "$script"
  # Reconcile structural check: grep for stories:
  grep -qE "grep.*stories:" "$script"
  # Triage reader: resolve-sprint-stories.sh references stories:
  grep -q 'stories' "$RESOLVE_SPRINT_STORIES"
}

# ---------------------------------------------------------------------------
# AC3 — legacy items: file migration
# ---------------------------------------------------------------------------
@test "reader handles legacy items-only file without data loss" {
  # Create a legacy sprint-status.yaml with items: key and no stories: key
  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-legacy"
status: active
total_points: 5
goals: []
items:
  - key: "E900-S1"
    title: 'Legacy story one'
    status: "in-progress"
    points: 3
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
  - key: "E900-S2"
    title: 'Legacy story two'
    status: "ready-for-dev"
    points: 2
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML

  # Create story files so resolver can find them
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S1-legacy-story-one"
  printf -- '---\nkey: "E900-S1"\nstatus: "in-progress"\n---\n# Story\n' > \
    "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S1-legacy-story-one/story.md"
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S2-legacy-story-two"
  printf -- '---\nkey: "E900-S2"\nstatus: "ready-for-dev"\n---\n# Story\n' > \
    "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S2-legacy-story-two/story.md"

  # Run the triage reader
  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"

  [ "$status" -eq 0 ]
  # Both stories must be found
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S2"* ]]
  # Count: exactly 2 lines of output
  local count
  count=$(printf '%s\n' "$output" | grep -c 'E900-S' || true)
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC4 — freshly initialized sprint with 20 stories, triage finds all 20
# ---------------------------------------------------------------------------
@test "triage finds all 20 stories after init and inject" {
  # Initialize a fresh sprint
  run bash "$SPRINT_STATE" init --sprint-id sprint-test
  [ "$status" -eq 0 ]

  # Create story files with proper frontmatter and inject 20 stories
  local i key
  for i in $(seq 1 20); do
    key="E99-S${i}"
    mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E99/${key}-test-story-${i}"
    cat > "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E99/${key}-test-story-${i}/story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "test story ${i}"
status: "ready-for-dev"
sprint_id: "sprint-test"
points: 2
risk: "medium"
epic: "E99"
---
# Story
EOF
    run bash "$SPRINT_STATE" inject --story "$key"
    [ "$status" -eq 0 ]
  done

  # Transition sprint to active so the scoped reader works
  run bash "$SPRINT_STATE" transition --sprint sprint-test --to active
  [ "$status" -eq 0 ]

  # Run the triage reader
  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]

  # Must find exactly 20 story files
  local count
  count=$(printf '%s\n' "$output" | grep -c '.' || true)
  [ "$count" -eq 20 ]

  # Every key must appear
  for i in $(seq 1 20); do
    [[ "$output" == *"E99-S${i}"* ]]
  done
}

# ---------------------------------------------------------------------------
# AC5a — fresh init creates stories: not items:
# ---------------------------------------------------------------------------
@test "fresh init creates stories key (AC5a)" {
  run bash "$SPRINT_STATE" init --sprint-id sprint-fresh
  [ "$status" -eq 0 ]
  grep -q '^stories: \[\]' "$SPRINT_STATUS_YAML"
  run grep -q '^items:' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC5b — legacy items-only file, reader finds the story
# ---------------------------------------------------------------------------
@test "reader finds story in legacy items-only file (AC5b)" {
  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-legacy-5b"
status: active
total_points: 2
goals: []
items:
  - key: "E900-S1"
    title: 'Legacy story'
    status: "ready-for-dev"
    points: 2
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S1-legacy-story"
  printf -- '---\nkey: "E900-S1"\nstatus: "ready-for-dev"\n---\n# Story\n' > \
    "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S1-legacy-story/story.md"

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]]
}

# ---------------------------------------------------------------------------
# AC5c — file with both items: and stories: keys, stories: preferred
# ---------------------------------------------------------------------------
@test "reader prefers stories key when both keys present (AC5c)" {
  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-both-keys"
status: active
total_points: 4
goals: []
items:
  - key: "E900-S1"
    title: 'Items story'
    status: "in-progress"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
stories:
  - key: "E900-S2"
    title: 'Stories story'
    status: "ready-for-dev"
    points: 2
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S2-stories-story"
  printf -- '---\nkey: "E900-S2"\nstatus: "ready-for-dev"\n---\n# Story\n' > \
    "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S2-stories-story/story.md"

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  # stories: key is preferred, so E900-S2 should be found
  [[ "$output" == *"E900-S2"* ]]
  # items: key entries should NOT appear when stories: is present
  [[ "$output" != *"E900-S1"* ]]
}

# ---------------------------------------------------------------------------
# AC5d — empty stories list, reader returns zero stories gracefully
# ---------------------------------------------------------------------------
@test "reader returns zero stories from empty list without error (AC5d)" {
  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-empty"
status: active
total_points: 0
goals: []
stories: []
YAML

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  # Output should be empty (no stories)
  [ -z "$output" ]
}

@test "reader returns zero stories from empty legacy items list without error (AC5d legacy)" {
  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-empty-legacy"
status: active
total_points: 0
goals: []
items: []
YAML

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC6 — bash version compatibility (structural check)
# ---------------------------------------------------------------------------
@test "no bash 4+ syntax in sprint-state.sh changed code" {
  local script="$SPRINT_STATE"
  [ -f "$script" ]
  # Check for bash 4+ features that break on macOS /bin/bash 3.2
  local violations
  violations=$(grep -nE 'local -A |declare -A |\$\{[a-zA-Z_]+,,\}|\$\{[a-zA-Z_]+\^\^\}|readarray |mapfile |\|\&' "$script" || true)
  [ -z "$violations" ]
}

# ---------------------------------------------------------------------------
# AC7 — no leaked identifiers in plugin tree changes
# ---------------------------------------------------------------------------
@test "no leaked internal identifiers in sprint-state.sh" {
  local script="$SPRINT_STATE"
  [ -f "$script" ]
  # Scan for internal traceability IDs (excluding regex-literal contexts
  # and synthetic test IDs like E99-S1 or E900-S1)
  # Check for FR-nnn, NFR-nnn, SR-nnn, ADR-nnn, TC-nnn patterns
  local leaks
  leaks=$(grep -nE '\b(FR|NFR|SR|ADR|TC)-[0-9]{2,}' "$script" | grep -v 'E\[0-9\]' | grep -v '#.*test' || true)
  [ -z "$leaks" ]
}

@test "no leaked internal identifiers in resolve-sprint-stories.sh" {
  local script="$RESOLVE_SPRINT_STORIES"
  [ -f "$script" ]
  local leaks
  leaks=$(grep -nE '\b(FR|NFR|SR|ADR|TC)-[0-9]{2,}' "$script" | grep -v 'E\[0-9\]' | grep -v '#.*test' || true)
  [ -z "$leaks" ]
}

# ---------------------------------------------------------------------------
# AC8 — fixtures use temp dirs only
# ---------------------------------------------------------------------------
@test "this test suite uses only temp dirs for fixtures" {
  # Verify our setup creates files under TEST_TMP, not the real plugin tree
  [ -d "$TEST_TMP" ]
  [ -d "$TEST_TMP/project/.gaia/state" ]
  # Our SPRINT_STATUS_YAML points to the temp dir, not the real project
  [[ "$SPRINT_STATUS_YAML" == "$TEST_TMP"* ]]
}
