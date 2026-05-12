#!/usr/bin/env bats
# resolve-story-file-coverage-stub.bats — E79-S7 NFR-052 coverage stub
#
# The full E79-S7 test suite for the shared story-file resolver (TC-VSG-1..5
# unit cases + TC-VSG-6..8 integration cases) is planned at
# plugins/gaia/tests/resolve-story-file.bats and will exercise the canonical
# nested-vs-flat precedence rule end-to-end. That suite is part of E79-S7's
# acceptance criteria (DoD item: "bats suite at resolve-story-file.bats
# passes — 5 unit cases").
#
# The NFR-052 public-function coverage gate scans only top-level .bats files
# (run-with-coverage.sh uses `grep -rq "$f" "$TESTS_DIR"/*.bats`, which does
# NOT recurse). Until the full TC-VSG-* suite lands, this stub at the top
# level lists the public function name so the gate registers it as covered.
#
# Smoke coverage is exercised here so the file is not just textual: three
# minimal @test blocks invoke `resolve_story_file` against synthetic
# fixtures to confirm the helper is sourceable and routes the three primary
# return paths (single nested hit, zero matches, multi-nested ambiguity).
#
# Public functions covered (NFR-052):
#   resolve_story_file

load 'test_helper.bash'

setup() {
  HELPER="${BATS_TEST_DIRNAME}/../scripts/resolve-story-file.sh"
  STORY_TREE="${BATS_TEST_TMPDIR}/docs/implementation-artifacts"
  mkdir -p "$STORY_TREE"
  export IMPLEMENTATION_ARTIFACTS="$STORY_TREE"
}

@test "resolve_story_file: single nested hit returns the path, exit 0" {
  mkdir -p "$STORY_TREE/epic-Etest/stories"
  : > "$STORY_TREE/epic-Etest/stories/E1-S1-foo.md"
  # shellcheck disable=SC1090
  source "$HELPER"
  run resolve_story_file "E1-S1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-Etest/stories/E1-S1-foo.md" ]]
}

@test "resolve_story_file: zero matches exits 1 with actionable error" {
  # shellcheck disable=SC1090
  source "$HELPER"
  run resolve_story_file "E99-S99"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "story file not found for key E99-S99"
}

@test "resolve_story_file: multiple nested matches exits 2 (ambiguity)" {
  mkdir -p "$STORY_TREE/epic-Efoo/stories" "$STORY_TREE/epic-Ebar/stories"
  : > "$STORY_TREE/epic-Efoo/stories/E5-S1-a.md"
  : > "$STORY_TREE/epic-Ebar/stories/E5-S1-b.md"
  # shellcheck disable=SC1090
  source "$HELPER"
  run resolve_story_file "E5-S1"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "multiple nested story files matched key E5-S1"
}
