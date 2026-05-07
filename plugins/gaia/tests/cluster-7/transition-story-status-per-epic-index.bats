#!/usr/bin/env bats
# transition-story-status-per-epic-index.bats — E79-S3
#
# Verifies that transition-story-status.sh writes the per-epic
# story-index.yaml resolved via lib/resolve-epic-slug.sh, never the
# legacy flat docs/implementation-artifacts/story-index.yaml. The flat
# index is read-only-fallback only.
#
# Test scenarios trace back to the story's Test Scenarios table:
#   TC-CSP-6        — Per-epic story-index write (AC1, AC2, AC4)
#   TC-CSP-8        — Flat read-only fallback (AC3)
#   TC-CSP-edge-1   — Idempotent re-run produces byte-identical index
#   TC-CSP-edge-2   — Missing flat post-migration emits no warning (AC5)
#   no-write guard  — grep over the script: zero writes to flat path (AC4)

load 'test_helper.bash'

setup() {
  common_setup

  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"
  RESOLVER="$SCRIPTS_DIR/lib/resolve-epic-slug.sh"

  STORY_KEY="E99-S1"
  EPIC_KEY="E99"
  EPIC_SLUG="epic-E99-canonical-layout-fixture"

  IMPL_DIR="$TEST_TMP/docs/implementation-artifacts"
  PLAN_DIR="$TEST_TMP/docs/planning-artifacts"
  MEM_DIR="$TEST_TMP/_memory"
  STORIES_DIR="$IMPL_DIR/$EPIC_SLUG/stories"
  STORY_FILE="$STORIES_DIR/${STORY_KEY}-fixture.md"
  PER_EPIC_INDEX="$STORIES_DIR/story-index.yaml"
  FLAT_INDEX="$IMPL_DIR/story-index.yaml"
  SPRINT_YAML="$IMPL_DIR/sprint-status.yaml"
  EPICS_MD="$PLAN_DIR/epics-and-stories.md"
  LOCK_FILE="$MEM_DIR/.story-status.lock"

  mkdir -p "$STORIES_DIR" "$PLAN_DIR" "$MEM_DIR"

  cat >"$STORY_FILE" <<'EOF'
---
template: 'story'
key: "E99-S1"
title: "Per-epic story-index fixture"
epic: "E99"
status: backlog
sprint_id: "fixture-sprint"
priority: "P2"
size: "S"
points: 1
risk: "low"
author: "fixture-author"
---

# Story: Per-epic story-index fixture

> **Status:** backlog
EOF

  cat >"$SPRINT_YAML" <<'EOF'
sprint_id: "fixture-sprint"
stories:
  - key: E99-S1
    status: "backlog"
EOF

  cat >"$EPICS_MD" <<'EOF'
# Epics and Stories

## E99 — Canonical layout fixture

### Story E99-S1: Per-epic story-index fixture

- **Epic:** E99
- **Priority:** P2
- **Description:** Fixture story used by transition-story-status-per-epic-index.bats.
- **Status:** backlog
EOF

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export PLANNING_ARTIFACTS="$PLAN_DIR"
  export MEMORY_PATH="$MEM_DIR"
  export SPRINT_STATUS_YAML="$SPRINT_YAML"
  export EPICS_AND_STORIES="$EPICS_MD"
  export STORY_STATUS_LOCK="$LOCK_FILE"
  # NOTE: deliberately do NOT export STORY_INDEX_YAML — we want the script
  # to derive the per-epic path itself via the E79-S1 resolver.
  unset STORY_INDEX_YAML
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Preconditions — E79-S1 deliverables present.
# ---------------------------------------------------------------------------

@test "TC-CSP-6: resolver script is present and executable" {
  [ -x "$RESOLVER" ]
}

@test "TC-CSP-6: transition-story-status.sh is present and executable" {
  [ -x "$TRANSITION" ]
}

# ---------------------------------------------------------------------------
# TC-CSP-6 — Per-epic story-index write (AC1, AC4).
# ---------------------------------------------------------------------------

@test "TC-CSP-6: writes per-epic story-index.yaml, not the flat index (AC1, AC4)" {
  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev
  [ "$status" -eq 0 ]

  # Per-epic index MUST exist.
  [ -f "$PER_EPIC_INDEX" ]

  # Flat index MUST NOT have been created.
  [ ! -e "$FLAT_INDEX" ]

  # Per-epic entry contains the canonical metadata block.
  run grep -q "^  ${STORY_KEY}:" "$PER_EPIC_INDEX"
  [ "$status" -eq 0 ]
  run grep -q "status: \"ready-for-dev\"" "$PER_EPIC_INDEX"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-CSP-8 — `file:` pointer relative to per-epic stories/ dir (AC2).
# ---------------------------------------------------------------------------

@test "TC-CSP-8: file pointer is basename relative to per-epic stories/ dir (AC2)" {
  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev
  [ "$status" -eq 0 ]

  # The `file:` field MUST be the bare basename — not absolute, not
  # project-root-relative, not parent-relative.
  expected_basename="${STORY_KEY}-fixture.md"
  run grep -E "^[[:space:]]+file:[[:space:]]+\"${expected_basename}\"" "$PER_EPIC_INDEX"
  [ "$status" -eq 0 ]

  # No leading "/", "../", or "epic-*/stories/" prefix should appear in the
  # file: value for this entry.
  run grep -E "^[[:space:]]+file:[[:space:]]+\"(/|\\.\\./|epic-)" "$PER_EPIC_INDEX"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — Read-only legacy-flat fallback. The writer MUST NOT modify the flat
# file. We seed a flat index that already contains a different entry, run a
# transition, and assert (a) the per-epic index is written, (b) the flat
# index is byte-identical before/after.
# ---------------------------------------------------------------------------

@test "TC-CSP-8: legacy flat index is read-only — writer never mutates it (AC3)" {
  cat >"$FLAT_INDEX" <<'EOF'
# Auto-maintained by status-sync protocol. Do not edit manually.
last_updated: "2026-04-28T12:00:00Z"
stories:
  E99-S99:
    title: "Legacy flat-only entry"
    epic: "E99"
    status: "done"
    file: "E99-S99-legacy-flat-only-entry.md"
EOF

  before_sha=$(shasum -a 256 "$FLAT_INDEX" | awk '{print $1}')

  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev
  [ "$status" -eq 0 ]

  after_sha=$(shasum -a 256 "$FLAT_INDEX" | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]

  # Per-epic index must have been written separately.
  [ -f "$PER_EPIC_INDEX" ]
}

# ---------------------------------------------------------------------------
# Idempotency edge case — re-running the same transition twice MUST yield a
# byte-identical per-epic story-index.yaml after the first write.
# ---------------------------------------------------------------------------

@test "TC-CSP-edge-1: idempotent re-run produces byte-identical per-epic index" {
  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev
  [ "$status" -eq 0 ]

  first_sha=$(shasum -a 256 "$PER_EPIC_INDEX" | awk '{print $1}')

  # Re-run the same transition (will be a no-op against the story file but
  # the writer is still allowed to touch the index — the index must remain
  # byte-stable).
  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev
  [ "$status" -eq 0 ]

  second_sha=$(shasum -a 256 "$PER_EPIC_INDEX" | awk '{print $1}')
  [ "$first_sha" = "$second_sha" ]
}

# ---------------------------------------------------------------------------
# AC5 — Post-migration steady state: the flat file is absent. The script
# MUST NOT emit any error or warning about the missing flat fallback.
# ---------------------------------------------------------------------------

@test "TC-CSP-edge-2: missing flat index post-migration emits no warning (AC5)" {
  [ ! -e "$FLAT_INDEX" ]

  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev
  [ "$status" -eq 0 ]

  # No stderr line should reference the flat index path or the
  # legacy-flat-fallback tag when the flat file is absent.
  run bash -c '"$1" "$2" --to in-progress 2>&1 1>/dev/null' \
    _ "$TRANSITION" "$STORY_KEY"
  [ "$status" -eq 0 ]
  ! printf '%s' "$output" | grep -qE 'legacy-flat-fallback|story-index\.yaml.*missing'
}

# ---------------------------------------------------------------------------
# AC4 grep guard — verify the source script never writes to the flat path.
# This is a regression fence: any code path that resurrects a flat write
# (printf > "$FLAT_INDEX", mv ... > "$FLAT_INDEX", etc.) breaks this test.
# ---------------------------------------------------------------------------

@test "TC-CSP-edge-3: per-epic stories/ dir auto-created when story file lives at flat path" {
  # Move the seed story file to the flat path (mid-migration scenario):
  # the story file itself lives at `${IMPL_DIR}/${KEY}-fixture.md` while
  # the per-epic stories/ dir (and its story-index.yaml) does NOT yet
  # exist. The script must auto-create the per-epic dir.
  flat_story="$IMPL_DIR/${STORY_KEY}-fixture.md"
  mv "$STORY_FILE" "$flat_story"
  rm -rf "$IMPL_DIR/$EPIC_SLUG"

  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev
  [ "$status" -eq 0 ]

  # Per-epic dir + index were created on demand.
  [ -d "$IMPL_DIR/$EPIC_SLUG/stories" ]
  [ -f "$IMPL_DIR/$EPIC_SLUG/stories/story-index.yaml" ]

  # Flat index still untouched — writer never targets it.
  [ ! -e "$FLAT_INDEX" ]
}

@test "AC4 guard: transition-story-status.sh has zero writes to the flat story-index.yaml" {
  # Allow read-only references (legacy_flat_index_lookup) but no write
  # redirection (`>`, `>>`, `mv ... flat`, `cp ... flat`) targeting the flat
  # `docs/implementation-artifacts/story-index.yaml` literal.
  run bash -c '
    grep -nE "(>|>>|tee|mv|cp)[^\n]*docs/implementation-artifacts/story-index\\.yaml" "$1"
  ' _ "$TRANSITION"
  [ "$status" -ne 0 ]
}
