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
@test "TC-STCL-3: extractor emits frontmatter + Findings only, never the story body" {
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
@test "TC-STCL-3b: extractor handles a story with no Findings section" {
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
@test "TC-STCL-3c: extractor resolves key from per-story dir when basename is story.md" {
  local f="$TMP/E39-S97-from-dir/story.md"
  _make_story "$f" "" "sprint-97" \
    "| 1 | tech-debt | low | tidy imports | dismiss |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E39-S97"* ]]   # key derived from the directory name
}

# Missing-file guard: a non-existent path errors cleanly (non-zero), no crash.
@test "TC-STCL-3d: extractor errors cleanly on a missing file" {
  run "$EXTRACT" --story-file "$TMP/does-not-exist.md"
  [ "$status" -ne 0 ]
}
