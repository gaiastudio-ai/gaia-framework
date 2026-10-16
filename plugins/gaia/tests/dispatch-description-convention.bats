#!/usr/bin/env bats

# Per-site assertions that every Agent dispatch site in gaia-dev-story and
# gaia-run-sprint carries the description convention (story key as first
# token).  Removing the convention from any single site MUST fail a named
# test.  Each test anchors on a unique context string that identifies the
# dispatch site, then asserts the convention text appears in the same
# paragraph (within a narrow line range around the anchor).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  DS_SKILL="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  RS_SKILL="$PLUGIN_ROOT/skills/gaia-run-sprint/SKILL.md"
}

teardown() { common_teardown; }

# Helper: assert that within WINDOW lines of the anchor line in FILE,
# at least one line contains the convention text.
# Usage: assert_convention_near FILE ANCHOR_PATTERN
assert_convention_near() {
  local file="$1" anchor="$2" window="${3:-8}"
  [ -f "$file" ] || { echo "file not found: $file"; return 1; }
  local anchor_line
  anchor_line="$(grep -n "$anchor" "$file" | head -1 | cut -d: -f1)"
  [ -n "$anchor_line" ] || { echo "anchor not found: $anchor"; return 1; }
  local start=$((anchor_line > window ? anchor_line - window : 1))
  local end=$((anchor_line + window))
  # The convention text appears in two forms.  The long form may wrap across
  # lines so we match the fragment that stays on one line.
  #   long:  "include the story key as the first token in the description"
  #   short: "story-key-prefixed description"
  if sed -n "${start},${end}p" "$file" | grep -q 'story key as the first token'; then
    return 0
  fi
  if sed -n "${start},${end}p" "$file" | grep -q 'story-key-prefixed description'; then
    return 0
  fi
  echo "convention text missing near line $anchor_line (anchor: $anchor) in $file"
  return 1
}

# -- dev-story dispatch sites --

@test "dev-story: stack-developer contract carries the description convention" {
  assert_convention_near "$DS_SKILL" 'Stack-developer dispatch contract'
}

@test "dev-story: Val dispatch (non-YOLO step 4) carries the description convention" {
  assert_convention_near "$DS_SKILL" 'On .validate.: route the rendered plan to the .gaia-val-validate. skill'
}

@test "dev-story: Val dispatch (YOLO step 4) carries the description convention" {
  assert_convention_near "$DS_SKILL" 'The rendered plan auto-routes to Val for up to 3 iterations'
}

@test "dev-story: tdd-reviewer route-to-qa (step 5 red) carries the description convention" {
  # Anchor on the unique "Red-phase diff" wording in the step 5 route-to-qa paragraph.
  assert_convention_near "$DS_SKILL" 'Red-phase diff (include the story key'
}

@test "dev-story: tdd-reviewer QA_AUTO (step 5 red) carries the description convention" {
  # The step 5 QA_AUTO line is the only one mentioning both QA_AUTO and "phase=red".
  # Window 1: the convention sits on the anchor line itself.
  assert_convention_near "$DS_SKILL" 'step5_tdd_gate: phase=red verdict=qa_auto' 1
}

@test "dev-story: tdd-reviewer route-to-qa (step 6 green) carries the description convention" {
  assert_convention_near "$DS_SKILL" 'Green-phase diff (include the story key'
}

@test "dev-story: tdd-reviewer QA_AUTO (step 6 green) carries the description convention" {
  assert_convention_near "$DS_SKILL" 'step6_tdd_gate: phase=green verdict=qa_auto' 1
}

@test "dev-story: tdd-reviewer route-to-qa (step 7 refactor) carries the description convention" {
  assert_convention_near "$DS_SKILL" 'Refactor-phase diff (include the story key'
}

@test "dev-story: tdd-reviewer QA_AUTO (step 7 refactor) carries the description convention" {
  assert_convention_near "$DS_SKILL" 'step7_tdd_gate: phase=refactor verdict=qa_auto' 1
}

@test "dev-story: Val-in-TDD (step 7b) carries the description convention" {
  # The step 7b Val dispatch is the one mentioning "artifacts touched during Steps 5-7".
  assert_convention_near "$DS_SKILL" 'artifacts touched during Steps 5-7.*main-turn Agent tool'
}

# -- run-sprint dispatch site --

@test "run-sprint: parallel agent dispatch carries the description convention" {
  assert_convention_near "$RS_SKILL" 'spawn that persona'
}

# -- published-source hygiene --

@test "no internal identifiers leaked into this test file" {
  local self="$BATS_TEST_DIRNAME/dispatch-description-convention.bats"
  if LC_ALL=C grep -Eq '\b(FR|NFR|SR|ADR)-[0-9]+\b' "$self"; then
    echo "leaked requirement/decision identifier in test file"
    return 1
  fi
  # Real story keys (not synthetic E9xx) would be a leak.
  if LC_ALL=C grep -Eq '\bE[0-9]{1,2}-S[0-9]+\b' "$self" | grep -vq 'E9[0-9][0-9]'; then
    echo "leaked real story key in test file"
    return 1
  fi
}
