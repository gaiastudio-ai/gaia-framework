#!/usr/bin/env bats
# AF-21-27: third (final) batch of Class-1 script-side canonical-first
# migrations. 3 remaining executable bare-legacy hits found in final audit.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "tdd-review-gate.sh IMPLEMENTATION_ARTIFACTS canonical-first" {
  grep -qF '.gaia/artifacts/implementation-artifacts' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/tdd-review-gate.sh"
}

@test "auto-detect-stack.sh SPEC_PATH canonical-first" {
  grep -qF '.gaia/artifacts/implementation-artifacts/quick-spec-' "$PLUGIN_ROOT/skills/gaia-quick-dev/scripts/auto-detect-stack.sh"
}

@test "test/runners/review-gate.sh artifact dir canonical-first" {
  grep -qF '.gaia/artifacts/implementation-artifacts' "$PLUGIN_ROOT/test/runners/review-gate.sh"
}
