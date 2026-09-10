#!/usr/bin/env bats
# sm-capacity-check-unchanged.bats — regression guard on the capacity check.
#
# The execution-phase helper is a DELIBERATE FORK of the dependency-depth
# traversal in sm-capacity-check.sh, not a refactor of it. The two scripts
# share an input contract and a recurrence but diverge on two points, and the
# divergence is the whole reason they are separate files:
#
#   * the capacity check reduces the graph to one scalar; the helper keeps the
#     per-story partition;
#   * the capacity check breaks a cycle DEFENSIVELY and still reports a number,
#     because a capacity advisory must never halt planning. The helper treats a
#     cycle as a hard error.
#
# Extracting a shared traversal would make the capacity check's
# advisory-never-halts contract depend on a flag passed by its caller — a
# fail-open shape. The duplication is the cheaper risk, and this suite is what
# keeps it honest: it asserts the ORIGINAL is untouched, by content and by
# behaviour.
#
# These tests are REGRESSION GUARDS, so they PASS from the moment they are
# written: the file is unchanged today, and the suite exists to fail loudly if
# a future contributor "helpfully" unifies the two scripts or makes the
# capacity check hard-fail on cycles to match the helper.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sm-capacity-check.sh"
  # sha256 of the capacity check as it stands. Paired with the behavioural and
  # source-line assertions below so that a re-pin alone cannot silently bless a
  # semantic change.
  EXPECTED_SHA256="a117056a34e417c6a6b0061b40766ed13136bcc20f2db36130b68e2da0b80d8f"
  export SCRIPT EXPECTED_SHA256
}
teardown() { common_teardown; }

# sha256_of <path> — portable across the macOS and Linux runners. Neither
# tool is assumed present; if both are missing the test fails rather than
# skipping, because a guard that can silently not run is not a guard.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'no-sha256-tool-available'
  fi
}

@test "the capacity check script is byte-unchanged (AC2)" {
  local actual
  actual="$(sha256_of "$SCRIPT")"
  [ "$actual" != "no-sha256-tool-available" ]
  [ "$actual" = "$EXPECTED_SHA256" ]
}

@test "the capacity check retains its defensive cycle guard (AC2)" {
  # The literal line that makes a cycle contribute a partial depth instead of
  # halting. Pinned separately from the hash so that re-pinning the hash after
  # an unrelated edit cannot quietly drop this behaviour.
  run grep -c 'if (k in onstack) return 1' "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "the capacity check still tolerates a cycle and exits 0 (AC2)" {
  # The behavioural half. A cycle must remain a non-event for the capacity
  # check: it reports a depth and exits 0, because flagging capacity is
  # advisory and must never halt sprint planning. If someone ever aligns this
  # script with the phase helper's hard-error contract, this reddens even if
  # the hash was re-pinned.
  local f="$TEST_TMP/cyclic.stories"
  printf 'K1|K2|1\nK2|K3|1\nK3|K1|1\n' > "$f"

  run "$SCRIPT" --stories-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"capacity:"* ]]
}
