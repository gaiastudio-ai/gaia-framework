#!/usr/bin/env bash
# issue-1405-epic-key-normalization.bats
#
# transition-story-status.sh read the `epic:` frontmatter field and used it
# VERBATIM as the epic key passed to resolve_epic_slug (which derives the
# per-epic story-index.yaml path). When `epic:` held the FULL epic title
# (e.g. `epic: "E14 — GAIA Sync Agent ..."`) — a broad historical convention —
# resolve_epic_slug's `epic_num="${epic_key#E}"` expanded to the whole title
# and the `^## Epic <num>:` grep never matched, aborting the transition/reconcile.
#
# Fix: the caller derives the bare `E<digits>` key from the `epic:` field (or
# prefers an `epic_key:` frontmatter field) before handing it to the resolver,
# so both the legacy full-title form and the modern bare-key form resolve.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPTS_DIR_LOCAL="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  TRANSITION="$SCRIPTS_DIR_LOCAL/transition-story-status.sh"

  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/docs/implementation-artifacts" "$PROJ/docs/planning-artifacts" "$PROJ/_memory"

  # A story whose epic: frontmatter is the FULL TITLE, not the bare key.
  STORY="$PROJ/docs/implementation-artifacts/E14-S11-fixture.md"
  cat > "$STORY" <<'EOF'
---
template: 'story'
key: "E14-S11"
title: "Sync agent client binary"
epic: "E14 — GAIA Sync Agent (Client-Side Go Binary)"
status: backlog
sprint_id: null
priority: "P2"
size: "S"
points: 1
risk: "low"
---

# Story: Sync agent
EOF

  cat > "$PROJ/docs/planning-artifacts/epics-and-stories.md" <<'EOF'
# Epics and Stories

## Epic 14: GAIA Sync Agent (Client-Side Go Binary)

### Story E14-S11: Sync agent client binary

- **Epic:** E14
- **Status:** backlog
EOF

  export PROJECT_PATH="$PROJ"
  export IMPLEMENTATION_ARTIFACTS="$PROJ/docs/implementation-artifacts"
  export PLANNING_ARTIFACTS="$PROJ/docs/planning-artifacts"
  export MEMORY_PATH="$PROJ/_memory"
  export EPICS_AND_STORIES="$PROJ/docs/planning-artifacts/epics-and-stories.md"
  export STORY_STATUS_LOCK="$PROJ/_memory/.story-status.lock"
  # IMPORTANT: do NOT set STORY_INDEX_YAML — that override bypasses the
  # per-epic resolver this test must exercise.
}
teardown() { common_teardown; }

@test "issue-1405: --reconcile-only succeeds when epic: holds the full title" {
  run "$TRANSITION" E14-S11 --reconcile-only
  [ "$status" -eq 0 ] || { echo "exit=$status output=$output"; false; }
  ! printf '%s\n' "$output" | grep -q 'resolve_epic_slug failed'
}

@test "issue-1405: the per-epic story-index.yaml is created under the resolved epic slug" {
  run "$TRANSITION" E14-S11 --reconcile-only
  [ "$status" -eq 0 ]
  # The writer should have created a per-epic index somewhere under epic-E14-*.
  run bash -c 'find "'"$PROJ"'/docs/implementation-artifacts" -name story-index.yaml -path "*epic-*14*"'
  [ -n "$output" ] || { echo "no per-epic story-index.yaml created"; find "$PROJ" -name story-index.yaml; false; }
}

@test "issue-1405: a bare-key epic: still resolves (no regression)" {
  # Rewrite the story to the modern bare-key form and confirm it still works.
  sed -i.bak 's/^epic: .*/epic: "E14"/' "$STORY" && rm -f "$STORY.bak"
  run "$TRANSITION" E14-S11 --reconcile-only
  [ "$status" -eq 0 ] || { echo "bare-key regressed: $output"; false; }
}

@test "issue-1405: an explicit --epic override still wins" {
  run "$TRANSITION" E14-S11 --reconcile-only --epic E14
  [ "$status" -eq 0 ]
}
