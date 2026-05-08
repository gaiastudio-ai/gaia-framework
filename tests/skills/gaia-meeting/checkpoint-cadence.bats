#!/usr/bin/env bats
# checkpoint-cadence.bats — gaia-meeting checkpoint-cadence loader (E76-S7, AC9, TS11)
#
# AC9: meeting.checkpoint_every_n_turns clamp-and-warn.
#   - default (unset): 4
#   - in [1,10]: honored verbatim
#   - 0 / -1: clamped to 1, single-line WARNING
#   - 11+: clamped to 10, single-line WARNING

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/checkpoint-cadence.sh"
  TMP="$(mktemp -d)"
  SETTINGS="$TMP/settings.json"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: checkpoint-cadence.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC9: unset setting -> default 4" {
  echo '{}' > "$SETTINGS"
  run "$HELPER" --settings "$SETTINGS"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "AC9: missing settings file -> default 4" {
  run "$HELPER" --settings "$TMP/no-such-file.json"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "AC9: in-range value 7 honored verbatim" {
  printf '{"meeting":{"checkpoint_every_n_turns":7}}\n' > "$SETTINGS"
  run "$HELPER" --settings "$SETTINGS"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "AC9: zero clamps to 1 with WARNING" {
  printf '{"meeting":{"checkpoint_every_n_turns":0}}\n' > "$SETTINGS"
  run --separate-stderr "$HELPER" --settings "$SETTINGS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [[ "$stderr" == *"WARNING"* ]]
}

@test "AC9: negative clamps to 1 with WARNING" {
  printf '{"meeting":{"checkpoint_every_n_turns":-1}}\n' > "$SETTINGS"
  run --separate-stderr "$HELPER" --settings "$SETTINGS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "AC9: above-range 11 clamps to 10 with WARNING" {
  printf '{"meeting":{"checkpoint_every_n_turns":11}}\n' > "$SETTINGS"
  run --separate-stderr "$HELPER" --settings "$SETTINGS"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

@test "AC9: WARNING goes to stderr, value goes to stdout" {
  printf '{"meeting":{"checkpoint_every_n_turns":99}}\n' > "$SETTINGS"
  run --separate-stderr "$HELPER" --settings "$SETTINGS"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
  [[ "$stderr" == *"WARNING"* ]]
  # Single-line WARNING — exactly one newline-terminated line.
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = "1" ]
}
