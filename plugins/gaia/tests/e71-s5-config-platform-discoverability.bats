#!/usr/bin/env bats
# e71-s5-config-platform-discoverability.bats — E71-S5
#
# AC1, AC2, AC3, AC4 — `/gaia-config-platform` SKILL.md discoverability prose:
# - AC1: no-arg `add` enumerates baseline + extensibility note (TC-RSV2-EDITOR-3)
# - AC2: no-subcommand prints usage including baseline menu (TC-RSV2-EDITOR-4)
# - AC3: current-state-first invariant (TC-RSV2-EDITOR-5)
# - AC4: helper script byte-identical (sha256 contract)

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILL="$PLUGIN_DIR/skills/gaia-config-platform/SKILL.md"
HELPER="$PLUGIN_DIR/scripts/gaia-config-platform-edit.sh"

setup() { common_setup; }
teardown() { common_teardown; }

# AC3 — current-state-first invariant ---------------------------------

@test "AC3 SKILL.md describes current-state preamble printing platforms[]" {
  [ -f "$SKILL" ]
  # The prose must instruct printing the current platforms[] state as the
  # first user-visible line, on every invocation.
  grep -qiE 'current state' "$SKILL"
  grep -qiE 'first user-visible line|first line of output' "$SKILL"
}

# AC1 — no-arg `add` enumerates baseline + kebab-case extensibility note

@test "AC1 SKILL.md enumerates baseline web | ios | android for no-arg add" {
  [ -f "$SKILL" ]
  # Verbatim baseline literal from ADR-081 §4.2.
  grep -qF 'web | ios | android' "$SKILL"
}

@test "AC1 SKILL.md prints kebab-case extensibility regex on no-arg add" {
  [ -f "$SKILL" ]
  # Verbatim regex from ADR-081 §4.2.
  grep -qF '^[a-z][a-z0-9-]*$' "$SKILL"
}

@test "AC1 SKILL.md instructs re-prompting on no-arg add (no exit non-zero)" {
  [ -f "$SKILL" ]
  grep -qiE 're-?prompt' "$SKILL"
}

# AC2 — no-subcommand prints usage including baseline menu ------------

@test "AC2 SKILL.md describes no-subcommand usage block" {
  [ -f "$SKILL" ]
  grep -qiE 'no[- ]subcommand|usage block|usage' "$SKILL"
  # Subcommand list must be enumerated.
  grep -qE 'add' "$SKILL"
  grep -qE 'remove' "$SKILL"
  grep -qE 'list' "$SKILL"
}

# AC4 — helper script byte-identical pre vs post ----------------------

@test "AC4 helper script sha256 matches the recorded pre-edit hash" {
  # The pinned hash documents the helper's contract surface. E71-S9 AC1
  # intentionally amended the helper (no-arg `add` is now discoverability
  # exit 0 instead of validation exit 1) per SKILL.md Step 2c. Update the
  # pin to track the amended contract.
  [ -f "$HELPER" ]
  expected="2dad385f897f0c531be4645c076dcd676d64a76f6f67316dc0977b23244a7ae2"
  actual="$(shasum -a 256 "$HELPER" | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}
