#!/usr/bin/env bats
# af-2026-05-27-4-e105-consumer-migration.bats
#
# AF-2026-05-27-4 / Test05 F-031, F-032, F-050, F-054.
#
# E105-S1 / ADR-127 introduced the per-story nested layout
#   epic-{slug}/{key}-{slug}/story.md
# (basename `story.md`; the per-story directory carries the key). The WRITERS
# (materialize-sprint-stories.sh) and the shared resolver (resolve-story-file.sh)
# already understood it, but several CONSUMERS still globbed only the legacy
# flat / `epic-*/stories/` layouts, so they could not find new-layout stories:
#   - sprint-state.sh         locate_story_file() (via `get`) + reconcile
#   - review-gate.sh          story locator (via `status`)
#   - check-deps.sh           dependency story locator
#   - validate-frontmatter.sh canonical-filename arm (false-positive CRITICAL)
#   - transition-story-status.sh  story-index.yaml path + file: pointer
#   - check-status-discipline.sh  path classifier
#
# These tests assert the consumers now recognise the NEW layout while still
# honouring the legacy layouts (read-compat). All run against an
# IMPLEMENTATION_ARTIFACTS-overridden TEMP root — they NEVER touch live .gaia.
#
# Invocation idioms (sprint-state.sh / transition-story-status.sh /
# check-status-discipline.sh run main-on-load and are NOT sourceable): locators
# are exercised through their CLI subcommands; pure helper functions are
# extracted by `sed` range and sourced into a minimal harness (the canonical
# idiom from sprint-state.bats::_run_helper).

load 'test_helper.bash'

setup() {
  common_setup
  SS="$SCRIPTS_DIR/sprint-state.sh"
  RG="$SCRIPTS_DIR/review-gate.sh"
  TSS="$SCRIPTS_DIR/transition-story-status.sh"
  CSD="$SCRIPTS_DIR/check-status-discipline.sh"
  VFM="$SCRIPTS_DIR/../skills/gaia-create-story/scripts/validate-frontmatter.sh"
  CDEP="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/check-deps.sh"
  IA="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IA"
  export IMPLEMENTATION_ARTIFACTS="$IA"
  export PROJECT_PATH="$TEST_TMP"
}
teardown() { common_teardown; }

# Write a story file with enough frontmatter for the locator/template filter
# (template: 'story' + key/status). Locators only need template+key+status.
_write_story() { # $1 = path ; $2 = key ; $3 = status
  local path="$1" key="$2" status="${3:-backlog}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
---
template: 'story'
key: "$key"
title: "Sample Story"
status: $status
epic: "${key%%-*}"
---

# Story: Sample

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
EOF
}

# Write a story with the COMPLETE 15-field frontmatter so validate-frontmatter's
# required-field checks pass and execution reaches the canonical-filename arm.
# title "Sample Story" slugifies to "sample-story".
_write_full_story() { # $1 = path ; $2 = key
  local path="$1" key="$2"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
---
template: 'story'
key: "$key"
title: "Sample Story"
epic: "${key%%-*}"
status: backlog
priority: P2
size: M
points: 3
risk: medium
sprint_id: null
priority_flag: null
depends_on: []
blocks: []
traces_to: []
date: "2026-05-27"
author: "test"
delivered: true
deferred_implementation: false
---

# Story: Sample

## Acceptance Criteria

- AC1: Given a context, when an action, then a result.

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
EOF
}

# Extract one or more function definitions (by name) from a script and source
# them into a minimal harness that stubs err()/die()/resolve_epic_slug().
# $1 = script path ; $2 = call to run ; remaining = function names to extract.
_extract_run() {
  local script="$1" call="$2"; shift 2
  local fn sed_prog="" extracted
  for fn in "$@"; do
    sed_prog="${sed_prog}/^${fn}() {/,/^}/p;"
  done
  extracted=$(sed -n "$sed_prog" "$script")
  [ -n "$extracted" ] || { echo "extraction failed for [$*] in $script"; return 1; }
  # resolve_story_index_path requires the epics file to exist (exit 5 otherwise);
  # seed an empty one so the resolver reaches the layout logic under test.
  mkdir -p "$IA/../planning-artifacts"
  : > "$IA/../planning-artifacts/epics-and-stories.md"
  cat <<HARNESS
#!/usr/bin/env bash
set -uo pipefail
err()  { printf '%s\n' "\$*" >&2; }
die()  { printf '%s\n' "\$*" >&2; exit 1; }
resolve_epic_slug() { printf '%s' "\$RES_EPIC_SLUG"; }
IMPLEMENTATION_ARTIFACTS="$IA"
EPICS_AND_STORIES="$IA/../planning-artifacts/epics-and-stories.md"
STORY_INDEX_YAML=""
$extracted
$call
HARNESS
}

# ---------------------------------------------------------------------------
# sprint-state.sh locate_story_file() via `get` — NEW layout (F-031)
# ---------------------------------------------------------------------------

@test "F-031: sprint-state get resolves a NEW per-story layout story (story.md)" {
  _write_story "$IA/epic-E1-core/E1-S1-foo/story.md" "E1-S1" in-progress
  run "$SS" get --story E1-S1
  [ "$status" -eq 0 ]
  [ "$output" = "in-progress" ]
}

@test "F-031: sprint-state get still resolves a legacy flat-layout story" {
  _write_story "$IA/E2-S1-bar.md" "E2-S1" backlog
  run "$SS" get --story E2-S1
  [ "$status" -eq 0 ]
  [ "$output" = "backlog" ]
}

@test "F-031: sprint-state get still resolves a legacy epic-*/stories/ story" {
  _write_story "$IA/epic-E3-x/stories/E3-S1-baz.md" "E3-S1" review
  run "$SS" get --story E3-S1
  [ "$status" -eq 0 ]
  [ "$output" = "review" ]
}

@test "F-031: prefix boundary — get E1-S2 does not resolve the E1-S21 dir" {
  _write_story "$IA/epic-E1-core/E1-S21-twentyone/story.md" "E1-S21" backlog
  run "$SS" get --story E1-S2
  [ "$status" -ne 0 ]
  [[ "$output" == *"no story file found"* ]]
}

@test "F-031: a stories/ evidence-dir story.md is NOT resolved as the canonical story" {
  mkdir -p "$IA/epic-E4-y/stories/E4-S1-evidence"
  cat > "$IA/epic-E4-y/stories/E4-S1-evidence/story.md" <<EOF
---
template: 'story'
key: "E4-S1"
title: "Evidence"
status: backlog
EOF
  run "$SS" get --story E4-S1
  # No canonical story file exists for E4-S1 — the evidence dir must not satisfy it.
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# review-gate.sh story locator via `status` — NEW layout (F-031)
# ---------------------------------------------------------------------------

@test "F-031: review-gate status resolves a story in the NEW per-story layout" {
  _write_story "$IA/epic-E6-a/E6-S1-foo/story.md" "E6-S1" backlog
  run env IMPLEMENTATION_ARTIFACTS="$IA" PROJECT_PATH="$TEST_TMP" bash "$RG" status --story E6-S1
  [[ "$output" != *"no story file found"* ]]
}

# ---------------------------------------------------------------------------
# validate-frontmatter.sh canonical-filename arm — NEW layout (F-032)
# ---------------------------------------------------------------------------

@test "F-032: validate-frontmatter accepts story.md when parent dir encodes key+slug" {
  # title "Sample Story" slugifies to "sample-story" → dir = E7-S1-sample-story
  _write_full_story "$IA/epic-E7-b/E7-S1-sample-story/story.md" "E7-S1"
  run bash "$VFM" --file "$IA/epic-E7-b/E7-S1-sample-story/story.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"filename"* ]]
}

@test "F-032: validate-frontmatter flags a per-story dir whose name mismatches key+slug" {
  _write_full_story "$IA/epic-E7-b/E7-S1-wrong-slug/story.md" "E7-S1"
  run bash "$VFM" --file "$IA/epic-E7-b/E7-S1-wrong-slug/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"filename"* ]]
}

# ---------------------------------------------------------------------------
# transition-story-status.sh story-index path + pointer — NEW layout (F-050)
# ---------------------------------------------------------------------------

@test "F-050: story-index path is at the epic ROOT for the NEW per-story layout" {
  run bash -c "RES_EPIC_SLUG=epic-E8-c; $(_extract_run "$TSS" "resolve_story_index_path '$IA/epic-E8-c/E8-S1-foo/story.md' 'E8'" resolve_story_index_path)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/epic-E8-c/story-index.yaml" ]]
  [[ "$output" != *"/epic-E8-c/stories/story-index.yaml" ]]
}

@test "F-050: story-index path stays under stories/ for the legacy nested layout" {
  run bash -c "RES_EPIC_SLUG=epic-E9-d; $(_extract_run "$TSS" "resolve_story_index_path '$IA/epic-E9-d/stories/E9-S1-foo.md' 'E9'" resolve_story_index_path)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/epic-E9-d/stories/story-index.yaml" ]]
}

@test "F-050: story-index file: pointer includes per-story dir for NEW layout" {
  run bash -c "$(_extract_run "$TSS" "compute_story_index_file_pointer '$IA/epic-E8-c/E8-S1-foo/story.md'" compute_story_index_file_pointer)"
  [ "$status" -eq 0 ]
  [ "$output" = "E8-S1-foo/story.md" ]
}

@test "F-050: story-index file: pointer is the bare basename for legacy nested" {
  run bash -c "$(_extract_run "$TSS" "compute_story_index_file_pointer '$IA/epic-E9-d/stories/E9-S1-foo.md'" compute_story_index_file_pointer)"
  [ "$status" -eq 0 ]
  [ "$output" = "E9-S1-foo.md" ]
}

# ---------------------------------------------------------------------------
# check-status-discipline.sh path classifier — NEW layout (F-054 hygiene)
# ---------------------------------------------------------------------------

@test "F-054: check-status-discipline classifies NEW-layout story path as story_frontmatter" {
  run bash -c "$(_extract_run "$CSD" "classify_path '.gaia/artifacts/implementation-artifacts/epic-E1-core/E1-S1-foo/story.md'" classify_path)"
  [ "$status" -eq 0 ]
  [ "$output" = "story_frontmatter" ]
}

@test "F-054: check-status-discipline still classifies legacy nested story path" {
  run bash -c "$(_extract_run "$CSD" "classify_path '.gaia/artifacts/implementation-artifacts/epic-E1-core/stories/E1-S1-foo.md'" classify_path)"
  [ "$status" -eq 0 ]
  [ "$output" = "story_frontmatter" ]
}
