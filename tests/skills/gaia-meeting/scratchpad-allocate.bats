#!/usr/bin/env bats
# scratchpad-allocate.bats — gaia-meeting scratchpad allocator (E76-S4)
#
# Covers AC1 (monotonic SP-N), AC2 (latest-wins replace), AC3 (visibility
# render). Exercises TC-MTG-SP-1.
#
# The allocator is a tiny state-machine helper that operates on an in-memory
# state file (one record per line: SP-N|content|content_type|pinning_agent|
# intent|history_count). It exposes three subcommands:
#   pin   — append a new SP-N or update an existing one (latest-wins)
#   list  — emit the scratchpad records in SP-N order (latest-wins view)
#   render — emit the rendered scratchpad block to stdout

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/scratchpad-allocate.sh"
  TMPDIR_T="$(mktemp -d)"
  STATE="$TMPDIR_T/scratchpad.state"
  : > "$STATE"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "Pre-flight: scratchpad-allocate.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "three pins receive monotonically numbered slots SP-1, SP-2 and SP-3" {
  run "$HELPER" pin --state "$STATE" --content "first" --intent "first intent" --agent "alpha"
  [ "$status" -eq 0 ]
  [ "$output" = "SP-1" ]
  run "$HELPER" pin --state "$STATE" --content "second" --intent "second intent" --agent "beta"
  [ "$status" -eq 0 ]
  [ "$output" = "SP-2" ]
  run "$HELPER" pin --state "$STATE" --content "third" --intent "third intent" --agent "gamma"
  [ "$status" -eq 0 ]
  [ "$output" = "SP-3" ]
}

@test "pin order is preserved in the list output" {
  "$HELPER" pin --state "$STATE" --content "a" --intent "ai" --agent "alpha" >/dev/null
  "$HELPER" pin --state "$STATE" --content "b" --intent "bi" --agent "beta" >/dev/null
  "$HELPER" pin --state "$STATE" --content "c" --intent "ci" --agent "gamma" >/dev/null
  run "$HELPER" list --state "$STATE" --field id
  [ "$status" -eq 0 ]
  expected="SP-1
SP-2
SP-3"
  [ "$output" = "$expected" ]
}

@test "re-pinning a slot with new content applies latest-wins" {
  "$HELPER" pin --state "$STATE" --content "first"  --intent "i1" --agent "alpha" >/dev/null
  "$HELPER" pin --state "$STATE" --content "second" --intent "i2" --agent "beta"  >/dev/null
  "$HELPER" pin --state "$STATE" --content "third"  --intent "i3" --agent "gamma" >/dev/null

  run "$HELPER" pin --state "$STATE" --target SP-2 --content "second-updated" --intent "i2u" --agent "delta"
  [ "$status" -eq 0 ]
  [ "$output" = "SP-2" ]

  run "$HELPER" list --state "$STATE" --field content
  [ "$status" -eq 0 ]
  expected="first
second-updated
third"
  [ "$output" = "$expected" ]
}

@test "replacing a slot that does not exist exits non-zero" {
  "$HELPER" pin --state "$STATE" --content "only" --intent "i" --agent "alpha" >/dev/null
  run "$HELPER" pin --state "$STATE" --target SP-7 --content "ghost" --intent "i" --agent "beta"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the history count increments each time a slot is replaced" {
  "$HELPER" pin --state "$STATE" --content "v1" --intent "i" --agent "alpha" >/dev/null
  "$HELPER" pin --state "$STATE" --target SP-1 --content "v2" --intent "i" --agent "beta" >/dev/null
  "$HELPER" pin --state "$STATE" --target SP-1 --content "v3" --intent "i" --agent "gamma" >/dev/null
  run "$HELPER" list --state "$STATE" --field history_count
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "render emits one line per slot carrying its latest content" {
  "$HELPER" pin --state "$STATE" --content "alpha-content" --intent "ai" --agent "alpha" >/dev/null
  "$HELPER" pin --state "$STATE" --content "beta-content"  --intent "bi" --agent "beta"  >/dev/null
  run "$HELPER" render --state "$STATE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^SP-1: alpha-content'
  echo "$output" | grep -q '^SP-2: beta-content'
}

@test "render on an empty state file emits nothing and succeeds" {
  run "$HELPER" render --state "$STATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
