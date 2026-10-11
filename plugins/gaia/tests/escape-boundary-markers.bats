#!/usr/bin/env bats
# escape-boundary-markers.bats — tests for the shared boundary-marker escape helper.
#
# The helper replaces every `<<` with `<~<` so that the output never
# contains `<<<`.  It exposes a sourceable function escape_boundary_markers
# that reads stdin and writes stdout.

fail() { printf '%s\n' "$1" >&2; return 1; }

setup() {
  ESCAPE_HELPER="$BATS_TEST_DIRNAME/../scripts/lib/escape-boundary-markers.sh"
}

@test "escape helper replaces every double angle bracket" {
  [ -f "$ESCAPE_HELPER" ] || fail "escape helper not found: $ESCAPE_HELPER"
  [ -r "$ESCAPE_HELPER" ] || fail "escape helper not readable: $ESCAPE_HELPER"

  source "$ESCAPE_HELPER"
  result="$(printf 'hello << world' | escape_boundary_markers)"
  [[ "$result" == *'<~<'* ]] || fail "expected <~< in output: $result"
  [[ "$result" != *'<<'* ]] || {
    # The output contains <~< which itself has no `<<` substring, so
    # check for a raw `<<` that is not part of `<~<`.
    cleaned="${result//<~</}"
    [[ "$cleaned" != *'<<'* ]] || fail "output still contains raw <<: $result"
  }
}

@test "escape helper output never contains triple angle bracket" {
  [ -f "$ESCAPE_HELPER" ] || fail "escape helper not found: $ESCAPE_HELPER"
  [ -r "$ESCAPE_HELPER" ] || fail "escape helper not readable: $ESCAPE_HELPER"

  source "$ESCAPE_HELPER"

  # Test runs of 1 to 11 `<` characters
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    local input=""
    local j
    for ((j = 0; j < i; j++)); do
      input="${input}<"
    done
    local out
    out="$(printf '%s' "$input" | escape_boundary_markers)"
    [[ "$out" != *'<<<'* ]] || \
      fail "run of $i angle brackets produced <<<: $out"
  done
}

@test "escape helper handles five-angle-bracket marker" {
  [ -f "$ESCAPE_HELPER" ] || fail "escape helper not found: $ESCAPE_HELPER"
  [ -r "$ESCAPE_HELPER" ] || fail "escape helper not readable: $ESCAPE_HELPER"

  source "$ESCAPE_HELPER"
  local input='<<<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>'
  local out
  out="$(printf '%s' "$input" | escape_boundary_markers)"
  [[ "$out" != *'<<<'* ]] || \
    fail "five-angle-bracket marker not defused: $out"
  # The original marker text must not survive intact
  [[ "$out" != *'<<<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>'* ]] || \
    fail "marker survived escaping unchanged: $out"
}

@test "escape helper passes through text without angle brackets" {
  [ -f "$ESCAPE_HELPER" ] || fail "escape helper not found: $ESCAPE_HELPER"
  [ -r "$ESCAPE_HELPER" ] || fail "escape helper not readable: $ESCAPE_HELPER"

  source "$ESCAPE_HELPER"
  local out
  out="$(printf 'hello world' | escape_boundary_markers)"
  [ "$out" = "hello world" ] || \
    fail "non-angle-bracket text changed: expected 'hello world', got '$out'"
}

@test "escape helper handles empty input" {
  [ -f "$ESCAPE_HELPER" ] || fail "escape helper not found: $ESCAPE_HELPER"
  [ -r "$ESCAPE_HELPER" ] || fail "escape helper not readable: $ESCAPE_HELPER"

  source "$ESCAPE_HELPER"
  local out
  out="$(printf '' | escape_boundary_markers)"
  [ -z "$out" ] || \
    fail "expected empty output for empty input, got: '$out'"
}
