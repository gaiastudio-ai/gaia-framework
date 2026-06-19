#!/usr/bin/env bats
# e39-s4-extract-findings.bats — coverage for the per-story Findings extractor
# and the sprint-scoped triage default.
#
# TC-STCL-1..3: sprint-scoped default scans only committed stories; --all
# restores the full sweep; the extractor emits frontmatter + Findings only,
# never the story body.

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  EXTRACT="$PLUGIN/skills/gaia-triage-findings/scripts/extract-findings.sh"
  TMP="$BATS_TEST_TMPDIR/work"
  mkdir -p "$TMP"
}

# Build a story file with a unique body sentinel so we can prove the body is
# never emitted by the extractor.
_make_story() {
  local path="$1" key="$2" sprint="$3" findings_body="$4"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
---
key: "$key"
status: "done"
sprint_id: "$sprint"
---

# Story: $key

## User Story

BODY_SENTINEL_DO_NOT_LEAK — this line is story body and must never appear in extractor output.

## Tasks

- [ ] do a thing (ANOTHER_BODY_SENTINEL)

## Findings

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|------------------|
$findings_body
EOF
}

# TC-STCL-3 — extractor emits ONLY frontmatter + Findings, never the body.
@test "extractor emits frontmatter + Findings only, never the story body" {
  local f="$TMP/E39-S99-x/story.md"
  _make_story "$f" "E39-S99" "sprint-99" \
    "| 1 | tech-debt | medium | refactor the widget | create story |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  # The finding row is present...
  [[ "$output" == *"refactor the widget"* ]]
  [[ "$output" == *"E39-S99"* ]]
  # ...but no story-body sentinel ever leaks.
  [[ "$output" != *"BODY_SENTINEL_DO_NOT_LEAK"* ]]
  [[ "$output" != *"ANOTHER_BODY_SENTINEL"* ]]
}

# Extractor: a story with no ## Findings section emits no finding rows (clean).
@test "extractor handles a story with no Findings section" {
  local f="$TMP/E39-S98-y/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'EOF'
---
key: "E39-S98"
status: "done"
sprint_id: "sprint-98"
---

# Story: E39-S98

## User Story

NO_FINDINGS_BODY_SENTINEL
EOF
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NO_FINDINGS_BODY_SENTINEL"* ]]
}

# Extractor resolves the story key from the per-story directory name when the
# basename is story.md (new canonical layout).
@test "extractor resolves key from per-story dir when basename is story.md" {
  local f="$TMP/E39-S97-from-dir/story.md"
  _make_story "$f" "" "sprint-97" \
    "| 1 | tech-debt | low | tidy imports | dismiss |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E39-S97"* ]]   # key derived from the directory name
}

# Missing-file guard: a non-existent path errors cleanly (non-zero), no crash.
@test "extractor errors cleanly on a missing file" {
  run "$EXTRACT" --story-file "$TMP/does-not-exist.md"
  [ "$status" -ne 0 ]
}

# ---------- Marker-exclusion idempotency tests ----------

# A tech-debt finding marked [TRIAGED] must not be emitted.
@test "triaged tech-debt finding is excluded from output" {
  local f="$TMP/E39-S80-triaged-td/story.md"
  _make_story "$f" "E39-S80" "sprint-80" \
    "| 1 | tech-debt | medium | refactor the widget [TRIAGED] | create story |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"refactor the widget"* ]]
}

# A tech-debt finding marked [DISMISSED] must not be emitted.
@test "dismissed tech-debt finding is excluded from output" {
  local f="$TMP/E39-S81-dismissed-td/story.md"
  _make_story "$f" "E39-S81" "sprint-81" \
    "| 1 | tech-debt | low | dead code path [DISMISSED] | dismiss |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"dead code path"* ]]
}

# Regression guard: a bug finding marked [TRIAGED] is still excluded (existing behaviour).
@test "triaged bug finding is excluded from output" {
  local f="$TMP/E39-S82-triaged-bug/story.md"
  _make_story "$f" "E39-S82" "sprint-82" \
    "| 1 | bug | medium | null pointer on empty input [TRIAGED] | fix |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"null pointer on empty input"* ]]
}

# An unmarked tech-debt finding must still be emitted normally.
@test "unmarked tech-debt finding is emitted" {
  local f="$TMP/E39-S83-unmarked-td/story.md"
  _make_story "$f" "E39-S83" "sprint-83" \
    "| 1 | tech-debt | medium | consolidate helper functions | create story |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"consolidate helper functions"* ]]
}

# Idempotency: running the extractor twice on the same file produces identical output.
@test "double run on file with marked rows yields identical output" {
  local f="$TMP/E39-S84-idempotent/story.md"
  _make_story "$f" "E39-S84" "sprint-84" \
    "| 1 | tech-debt | medium | stale import [TRIAGED] | create story |
| 2 | tech-debt | low | unused variable | create story |
| 3 | bug | medium | off-by-one [DISMISSED] | fix |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  local first="$output"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "$first" = "$output" ]
}
