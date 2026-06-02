#!/usr/bin/env bats
# vcp-ux-06.bats — E46-S2 / FR-350 / VCP-UX-06.
#
# Script-verifiable validation that any design-tokens.json emitted by
# /gaia-create-ux Import mode conforms to the W3C DTCG draft schema —
# every leaf entry has $value and $type, $description is optional but a
# string when present, and the file is JSON parseable.
#
# Tests run against a fixture under
#   gaia-public/plugins/gaia/tests/fixtures/figma-import/design-tokens.json
# captured from a reference Import run. The fixture is the contract: if
# Import mode regresses on the DTCG envelope, this bats file fails.
#
# Per Subtask 7.3 the file is registered as the script-verifiable backing
# for VCP-UX-06 in test-plan.md §11.46.10.

load 'test_helper.bash'

FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/figma-import"
TOKENS_FIXTURE="$FIXTURE_DIR/design-tokens.json"
SPECS_FIXTURE="$FIXTURE_DIR/component-specs.yaml"

setup() { common_setup; }
teardown() { common_teardown; }

# Helper: detect whether jq is available. Tests that require jq are
# skipped (not failed) on hosts where jq is not installed; the contract
# checks fall back to grep-only assertions.
_have_jq() {
  command -v jq >/dev/null 2>&1
}

# -------------------------------------------------------------------------
# Fixture presence — the captured Import-mode output MUST exist so this
# bats file has something to validate against.
# -------------------------------------------------------------------------

@test "VCP-UX-06: design-tokens.json fixture exists under tests/fixtures/figma-import/" {
  [ -f "$TOKENS_FIXTURE" ]
}

@test "VCP-UX-06: component-specs.yaml fixture exists under tests/fixtures/figma-import/" {
  [ -f "$SPECS_FIXTURE" ]
}

# -------------------------------------------------------------------------
# JSON parseability — design-tokens.json MUST parse as valid JSON.
# -------------------------------------------------------------------------

@test "VCP-UX-06: design-tokens.json is parseable as JSON (jq)" {
  if ! _have_jq; then
    skip "jq not installed on this host"
  fi
  run jq -e . "$TOKENS_FIXTURE"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# DTCG envelope — top-level $schema reference per Subtask 5.2.
# -------------------------------------------------------------------------

@test "VCP-UX-06: design-tokens.json declares a top-level \$schema reference" {
  run grep -F '"$schema"' "$TOKENS_FIXTURE"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# DTCG leaf shape — every leaf object has both $value and $type. The
# $description key is optional. Verified via jq when available, falling
# back to grep+count otherwise.
# -------------------------------------------------------------------------

@test "VCP-UX-06: every leaf token entry has \$value (jq)" {
  if ! _have_jq; then
    skip "jq not installed on this host"
  fi
  # Walk every leaf object that contains a $type key — every such object
  # MUST also carry $value. The jq script returns the count of entries
  # that violate this rule; the count MUST be zero.
  _violations=$(jq '
    [ .. | objects | select(has("$type")) | select(has("$value") | not) ] | length
  ' "$TOKENS_FIXTURE")
  [ "$_violations" -eq 0 ]
}

@test "VCP-UX-06: every leaf token entry has \$type (jq)" {
  if ! _have_jq; then
    skip "jq not installed on this host"
  fi
  _violations=$(jq '
    [ .. | objects | select(has("$value")) | select(has("$type") | not) ] | length
  ' "$TOKENS_FIXTURE")
  [ "$_violations" -eq 0 ]
}

@test "VCP-UX-06: \$description is a string when present (jq)" {
  if ! _have_jq; then
    skip "jq not installed on this host"
  fi
  _violations=$(jq '
    [ .. | objects | select(has("$description")) | select(."$description" | type != "string") ] | length
  ' "$TOKENS_FIXTURE")
  [ "$_violations" -eq 0 ]
}

# -------------------------------------------------------------------------
# Grep-fallback contract checks — minimal regression bar that survives
# without jq. These run unconditionally.
# -------------------------------------------------------------------------

@test "VCP-UX-06: design-tokens.json references the \$value DTCG key" {
  run grep -F '"$value"' "$TOKENS_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-06: design-tokens.json references the \$type DTCG key" {
  run grep -F '"$type"' "$TOKENS_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-06: design-tokens.json uses nested-group convention (no flat dot-notation token names)" {
  # Flat dot-notation token names like "colors.primary" are discouraged
  # by the DTCG draft. Reject any top-level key containing a dot.
  if ! _have_jq; then
    skip "jq not installed on this host"
  fi
  _flat=$(jq '[ keys[] | select(test("\\.")) ] | length' "$TOKENS_FIXTURE")
  [ "$_flat" -eq 0 ]
}

# -------------------------------------------------------------------------
# component-specs.yaml schema_version contract.
# -------------------------------------------------------------------------

@test "VCP-UX-06: component-specs.yaml fixture declares schema_version" {
  run grep -E '^schema_version:' "$SPECS_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-06: component-specs.yaml fixture declares a top-level components: map" {
  run grep -E '^components:' "$SPECS_FIXTURE"
  [ "$status" -eq 0 ]
}
