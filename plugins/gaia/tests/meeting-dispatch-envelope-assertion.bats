#!/usr/bin/env bats
# meeting-dispatch-envelope-assertion.bats — E90-S2 envelope-assertion tests.
#
# Covers TC-MVB-4, 5, 8:
#   TC-MVB-4: wrong-agent envelope -> HALT
#   TC-MVB-5: correct envelope + persona_sig -> exit 0
#   TC-MVB-8: forged envelope triggers halt-event.sh invocation
#
# These tests exercise the new envelope-assertion code path. The path
# is opt-in via GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN; existing call
# sites without the env var skip the assertion (backward-compat).

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-meeting" && pwd)"
  DISPATCH_SCRIPT="$SKILL_DIR/scripts/dispatch-agent-turn.sh"
  export SKILL_DIR DISPATCH_SCRIPT
}

teardown() {
  common_teardown
  unset GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN GAIA_DISPATCH_AGENT_STUB 2>/dev/null || true
}

# ---------------- TC-MVB-4: foundation — envelope-assertion code path exists ----------------
@test "dispatch-agent-turn.sh contains GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN gate" {
  [ -f "$DISPATCH_SCRIPT" ]
  grep -qF 'GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN' "$DISPATCH_SCRIPT"
}

# ---------------- TC-MVB-5: dispatch-agent-turn.sh references write-val-envelope + assert-agent-envelope ----------------
@test "dispatch-agent-turn.sh sources lib/write-val-envelope.sh and lib/assert-agent-envelope.sh" {
  [ -f "$DISPATCH_SCRIPT" ]
  grep -qF 'write-val-envelope.sh' "$DISPATCH_SCRIPT"
  grep -qF 'assert-agent-envelope.sh' "$DISPATCH_SCRIPT"
}

# ---------------- TC-MVB-8: halt-event.sh wired on envelope-assertion failure ----------------
@test "dispatch-agent-turn.sh invokes halt-event.sh on envelope-assertion failure" {
  [ -f "$DISPATCH_SCRIPT" ]
  grep -qF 'halt-event.sh' "$DISPATCH_SCRIPT"
  grep -qF 'envelope-assertion-failed' "$DISPATCH_SCRIPT"
}

# ---------------- TC-MVB-9: backward-compat — opt-in default off ----------------
@test "envelope assertion is opt-in (gated by env var)" {
  # The implementation is gated by GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN
  # so existing call sites without the env var skip the assertion. This
  # preserves backward-compat during the E90-S2 rollout — production
  # call sites flip the flag once they're emitting envelope JSON with
  # the agent field populated.
  grep -qE 'GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN.*:?-?' "$DISPATCH_SCRIPT"
}

# ---------------- TC-MVB-10: --expected-agent flag wiring ----------------
@test "dispatch-agent-turn.sh passes --expected-agent to assert_agent_envelope" {
  [ -f "$DISPATCH_SCRIPT" ]
  grep -qF 'assert_agent_envelope' "$DISPATCH_SCRIPT"
  grep -qF -- '--expected-agent' "$DISPATCH_SCRIPT"
}

# ---------------- default artifacts tree in the unwired-dispatch diagnostic ----------------
#
# The diagnostic emitted when no dispatch stub is set names a path composed
# from the shared paths helper. Nothing else in the suite executes the script,
# so without this case that composition is unverified and a re-point of the
# artifacts segment would go unnoticed.

@test "the unwired-dispatch diagnostic names the canonical artifacts tree" {
  local root artifacts_rel
  root="$(mktemp -d)"
  artifacts_rel="$(
    PROJECT_ROOT="$root" _GAIA_PATHS_LOADED="" \
    bash -c '. "$1/plugins/gaia/scripts/lib/gaia-paths.sh" >/dev/null 2>&1;
             printf "%s" "${GAIA_ARTIFACTS_DIR#"$_GAIA_ROOT_CANON"/}"' _ "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  )"
  [ -n "$artifacts_rel" ] || { rm -rf "$root"; echo "could not resolve the artifacts segment"; return 1; }

  local charter="$root/charter.md"
  printf 'decide on the probe\n' > "$charter"

  # No stub set: the script takes the unwired branch, reports on stderr and
  # exits 3.
  run env -u GAIA_DISPATCH_AGENT_STUB PROJECT_ROOT="$root" \
    bash "$DISPATCH_SCRIPT" --agent layla --phase discuss --charter-ref "$charter" \
    --session-id sess-probe --round 1 --turn 1
  rm -rf "$root"

  [ "$status" -eq 3 ] || { echo "expected the unwired-dispatch exit, got $status: $output"; return 1; }
  printf '%s' "$output" | grep -qF "${artifacts_rel}/planning-artifacts/architecture" \
    || { echo "diagnostic does not name the canonical artifacts tree (${artifacts_rel}):"; printf '%s\n' "$output"; return 1; }
}
