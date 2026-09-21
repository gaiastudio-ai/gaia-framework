#!/usr/bin/env bats
# checkpoint-cadence-byte-identity.bats — byte-identity guard.
#
# checkpoint-cadence.sh is consumed by yield-gate.sh via stdin/argv but MUST
# remain byte-identical to its recorded baseline. This test pins the file's
# sha256; any unintended modification trips the guard.
#
# Re-recording this hash is only legitimate after confirming the new output is
# correct. The hash below was re-recorded once the only change since the prior
# baseline was verified to be a single comment line with no executable
# difference, and the resolver was re-checked against its documented contract
# (default 4, values in [1,10] honoured verbatim, <=0 clamps to 1, >10 to 10).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/checkpoint-cadence.sh"
}

# Updating this hash MUST be a deliberate act, justified by verifying the new
# file is correct — never a reflex to make this case go green again.
BASELINE_SHA256="612cc94a3489fa4579db95144b236d6ae41fb6ef6c037e312b920acbfeb44fd2"

@test "checkpoint-cadence.sh exists" {
  [ -x "$HELPER" ]
}

@test "checkpoint-cadence.sh sha256 matches the recorded baseline (byte-identical)" {
  actual_sha="$(shasum -a 256 "$HELPER" | awk '{print $1}')"
  [ "$actual_sha" = "$BASELINE_SHA256" ]
}
