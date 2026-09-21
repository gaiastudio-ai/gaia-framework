#!/usr/bin/env bats
# no-fabricated-user-invitee.bats — gaia-meeting invitee-token WARNING + drop
# (E76-S8, AC4, TC-MTG-NOFAB-3, FR-MTG-10 / NFR-MTG-1)
#
# resolve-invitees.sh must detect when an `--invitees` token is the literal
# `me`, the literal `user`, or a token equal to the resolved user name (per
# `scripts/resolve-user-name.sh`), emit a single-line WARNING with the
# canonical wording, and DROP the offending token from the resolved CSV while
# preserving the original ordering of the remaining tokens.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RESOLVER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/resolve-invitees.sh"
  RESOLVE_USER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/resolve-user-name.sh"
  TMPDIR_T="$(mktemp -d)"
  INDEX="$TMPDIR_T/installed.txt"
  export LC_ALL=C

  if USER_NAME="$("$RESOLVE_USER" 2>/dev/null)"; then
    export USER_NAME
  else
    USER_NAME=""
  fi
}

teardown() {
  rm -rf "$TMPDIR_T"
}

write_index() {
  : > "$INDEX"
  for name in "$@"; do echo "$name" >> "$INDEX"; done
}

# canonical WARNING wording per AC4 — kept in one place to detect drift.
warn_for() {
  local tok="$1"
  echo "[gaia-meeting] WARNING: invitee token \"${tok}\" resolves to the user — the user is not an agent and is not auto-included; user authoring uses --charter / [i]nterject only"
}

@test "the literal token 'me' produces the canonical WARNING and is dropped" {
  write_index alice bob
  run "$RESOLVER" --mode explore --invitees "alice,me,bob" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^resolved=alice,bob$'
  expected="$(warn_for me)"
  [[ "$output" == *"$expected"* ]]
}

@test "the literal token 'user' produces the canonical WARNING and is dropped" {
  write_index alice bob
  run "$RESOLVER" --mode explore --invitees "alice,user,bob" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^resolved=alice,bob$'
  expected="$(warn_for user)"
  [[ "$output" == *"$expected"* ]]
}

@test "a user-name token produces the canonical WARNING and is dropped" {
  # The resolver reads a configured user name and falls back to the git
  # identity. A CI runner has neither, so there is no name to feed the
  # case and nothing to assert — skip rather than fail on the absence of
  # ambient configuration the case does not control.
  [ -n "$USER_NAME" ] || skip "no user name resolvable in this environment"
  write_index alice bob
  run "$RESOLVER" --mode explore --invitees "alice,${USER_NAME},bob" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^resolved=alice,bob$'
  expected="$(warn_for "$USER_NAME")"
  [[ "$output" == *"$expected"* ]]
}

@test "'me' is matched case-insensitively (uppercase ME also drops)" {
  write_index alice bob
  run "$RESOLVER" --mode explore --invitees "alice,ME,bob" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^resolved=alice,bob$'
  # The literal token is preserved in the WARNING line so assertions that
  # grep for the offending input keep working.
  expected="$(warn_for ME)"
  [[ "$output" == *"$expected"* ]]
}

@test "ordering of remaining tokens is preserved when a user token is dropped" {
  write_index z y x w
  run "$RESOLVER" --mode explore --invitees "z,me,y,x,w" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^resolved=z,y,x,w$'
}

@test "input with no offending tokens emits no user-WARNING (clean path)" {
  write_index alice bob
  run "$RESOLVER" --mode explore --invitees "alice,bob" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^resolved=alice,bob$'
  ! [[ "$output" == *"resolves to the user"* ]]
}
