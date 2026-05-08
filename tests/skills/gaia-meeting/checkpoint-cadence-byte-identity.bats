#!/usr/bin/env bats
# checkpoint-cadence-byte-identity.bats — AC6 byte-identity guard for E76-S9.
#
# E76-S9 introduces yield-gate.sh and rewrites the SKILL.md Procedure section
# to invoke it at every yield boundary. checkpoint-cadence.sh is consumed by
# yield-gate.sh via stdin/argv but MUST remain byte-identical to its E76-S7
# baseline.
#
# This test pins the file's sha256 to the E76-S9 baseline. Any unintended
# modification to checkpoint-cadence.sh will trip this guard.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/checkpoint-cadence.sh"
}

# Baseline sha256 captured at E76-S9 land. Updating this hash MUST be a
# deliberate, separate story.
BASELINE_SHA256="3cf8afa58d5205d469ae24d94bc9a89986fd0c029c1cd9c00eba366e487cd5f9"

@test "AC6: checkpoint-cadence.sh exists" {
  [ -x "$HELPER" ]
}

@test "AC6: checkpoint-cadence.sh sha256 matches the E76-S7 baseline (byte-identical)" {
  actual_sha="$(shasum -a 256 "$HELPER" | awk '{print $1}')"
  [ "$actual_sha" = "$BASELINE_SHA256" ]
}
