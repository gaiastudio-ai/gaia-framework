#!/usr/bin/env bats
# resolve-story-file.bats — full TC-VSG-1..5 unit suite for the shared
# story-file resolver helper.
#
# Story: E79-S7 — Shared resolve-story-file.sh helper + retrofit 3 consumers
# Refs:  FR-476, TC-VSG-1..5 (test plan §11.69), AF-2026-05-12-1
#
# This suite supersedes the temporary resolve-story-file-coverage-stub.bats
# which covered three of the five required cases as an NFR-052 placeholder.
# Once this file is in place the stub remains for backward compatibility
# but the canonical coverage is here.
#
# Public functions covered (NFR-052):
#   resolve_story_file

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

HELPER="${BATS_TEST_DIRNAME}/../scripts/resolve-story-file.sh"

setup() {
  common_setup
  STORY_TREE="${TEST_TMP}/docs/implementation-artifacts"
  mkdir -p "$STORY_TREE"
  export IMPLEMENTATION_ARTIFACTS="$STORY_TREE"
  # shellcheck disable=SC1090
  source "$HELPER"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# TC-VSG-1 — Nested-only positive: nested path returned, no WARNING
# ---------------------------------------------------------------------------
@test "TC-VSG-1: nested-only positive returns nested path, exit 0, no WARNING" {
  mkdir -p "$STORY_TREE/epic-Etest/stories"
  : > "$STORY_TREE/epic-Etest/stories/E1-S1-foo.md"

  run --separate-stderr resolve_story_file "E1-S1"

  [ "$status" -eq 0 ]
  [ "$output" = "$STORY_TREE/epic-Etest/stories/E1-S1-foo.md" ]
  # Nested-only path is the canonical case — stderr must be empty (no
  # legacy-flat WARNING, no shadow WARNING, no ambiguity error).
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# TC-VSG-2 — Flat-only legacy positive + WARNING
# ---------------------------------------------------------------------------
@test "TC-VSG-2: flat-only legacy returns flat path, exit 0, stderr WARNING" {
  : > "$STORY_TREE/E2-S1-bar.md"

  run --separate-stderr resolve_story_file "E2-S1"

  [ "$status" -eq 0 ]
  [ "$output" = "$STORY_TREE/E2-S1-bar.md" ]
  echo "$stderr" | grep -q "WARNING: legacy-flat path"
  echo "$stderr" | grep -q "$STORY_TREE/E2-S1-bar.md"
  echo "$stderr" | grep -q "migrate via E79-S6"
}

# ---------------------------------------------------------------------------
# TC-VSG-3 — Both-exist nested-wins shadow: nested returned, flat ignored
# ---------------------------------------------------------------------------
@test "TC-VSG-3: both-exist returns nested, stderr WARNING shadow ignored" {
  mkdir -p "$STORY_TREE/epic-Eshadow/stories"
  : > "$STORY_TREE/epic-Eshadow/stories/E3-S1-nested.md"
  : > "$STORY_TREE/E3-S1-flat.md"

  run --separate-stderr resolve_story_file "E3-S1"

  [ "$status" -eq 0 ]
  [ "$output" = "$STORY_TREE/epic-Eshadow/stories/E3-S1-nested.md" ]
  echo "$stderr" | grep -q "WARNING: legacy-flat shadow ignored"
  echo "$stderr" | grep -q "$STORY_TREE/E3-S1-flat.md"
  # The flat path MUST NOT appear as the resolved stdout output.
  [ "$output" != "$STORY_TREE/E3-S1-flat.md" ]
}

# ---------------------------------------------------------------------------
# TC-VSG-4 — Zero matches: exit 1, actionable stderr with searched paths
# ---------------------------------------------------------------------------
@test "TC-VSG-4: zero matches exits 1 with actionable error listing paths" {
  run --separate-stderr resolve_story_file "E4-S1"

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "story file not found for key E4-S1"
  echo "$stderr" | grep -q "epic-\*/stories/E4-S1-\*\.md"
  echo "$stderr" | grep -q "E4-S1-\*\.md"
}

# ---------------------------------------------------------------------------
# TC-VSG-5 — Multi-nested ambiguity: exit 2, both paths on stderr
# ---------------------------------------------------------------------------
@test "TC-VSG-5: multi-nested ambiguity exits 2 listing both paths" {
  mkdir -p "$STORY_TREE/epic-Efoo/stories" "$STORY_TREE/epic-Ebar/stories"
  : > "$STORY_TREE/epic-Efoo/stories/E5-S1-a.md"
  : > "$STORY_TREE/epic-Ebar/stories/E5-S1-b.md"

  run --separate-stderr resolve_story_file "E5-S1"

  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "multiple nested story files matched key E5-S1"
  echo "$stderr" | grep -q "$STORY_TREE/epic-Efoo/stories/E5-S1-a.md"
  echo "$stderr" | grep -q "$STORY_TREE/epic-Ebar/stories/E5-S1-b.md"
}
