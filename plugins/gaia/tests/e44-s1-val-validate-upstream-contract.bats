#!/usr/bin/env bats
# e44-s1-val-validate-upstream-contract.bats
#
# VCP-VALV-02 — Script-verifiable coverage for the /gaia-val-validate
# Upstream Integration Contract (E44-S1 / FR-343 / FR-357 / ADR-058).
#
# Asserts the SKILL.md at plugins/gaia/skills/gaia-val-validate/SKILL.md
# contains the formal upstream-contract section anchors and field names so
# downstream skills (E44-S3..S6) can wire to a stable, documented shape.
#
# Covers:
#   AC1 — invocation method, required parameters (artifact_path,
#         artifact_type), response schema (severity, description, location)
#   AC4 — deprecation callout for `val_validate_output: true`, with
#         cross-references to ADR-058 and FR-357
#   AC5 — VCP-VALV-02 (this file). VCP-VALV-01 and VCP-VAL-03 are
#         LLM-checkable and outlined inside the SKILL.md, executed by the
#         broader VCP test orchestrator — not by bats.
#
# E44-S2 implements the iterative auto-fix loop that consumes this contract;
# this test only verifies the contract documentation itself.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-val-validate" && pwd)/SKILL.md"
  export SKILL
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — Section anchors present
# ---------------------------------------------------------------------------

@test "AC1: SKILL.md exists and is readable" {
  [ -f "$SKILL" ]
  [ -r "$SKILL" ]
}

@test "AC1: SKILL.md contains '## Upstream Integration Contract' anchor" {
  grep -q '^## Upstream Integration Contract' "$SKILL"
}

@test "AC1: SKILL.md documents Invocation Method subsection" {
  grep -q 'Invocation Method' "$SKILL"
}

@test "AC1: SKILL.md documents Required Parameters subsection" {
  grep -q 'Required Parameters' "$SKILL"
}

@test "AC1: SKILL.md documents Response Schema subsection" {
  grep -q 'Response Schema' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC1 — Required parameter names present
# ---------------------------------------------------------------------------

@test "AC1: SKILL.md mentions artifact_path parameter" {
  grep -q 'artifact_path' "$SKILL"
}

@test "AC1: SKILL.md mentions artifact_type parameter" {
  grep -q 'artifact_type' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC1 — Response schema fields present
# ---------------------------------------------------------------------------

@test "AC1: SKILL.md documents 'severity' response field" {
  grep -q 'severity' "$SKILL"
}

@test "AC1: SKILL.md documents 'description' response field" {
  grep -q 'description' "$SKILL"
}

@test "AC1: SKILL.md documents 'location' response field" {
  grep -q 'location' "$SKILL"
}

@test "AC1: SKILL.md lists CRITICAL, WARNING, INFO severity levels" {
  grep -q 'CRITICAL' "$SKILL"
  grep -q 'WARNING' "$SKILL"
  grep -q 'INFO' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC1 — Iterative re-invocation semantics documented
# ---------------------------------------------------------------------------

@test "AC1/AC2: SKILL.md documents iterative re-invocation semantics" {
  grep -q -E 'Iterative Re-?Invocation' "$SKILL"
}

@test "AC2: SKILL.md states Val re-reads artifact from disk per invocation" {
  grep -q -E -i 're-?read' "$SKILL"
}

@test "AC2: SKILL.md states Val MUST NOT cache findings across invocations" {
  grep -q -i 'cache' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC4 — Deprecation callout + cross-references present
# ---------------------------------------------------------------------------

@test "AC4: SKILL.md contains a Deprecated callout" {
  grep -q -E '^> \*\*Deprecated:?\*\*' "$SKILL"
}

@test "AC4: SKILL.md flags val_validate_output: true as deprecated" {
  grep -q 'val_validate_output' "$SKILL"
}

@test "AC4: SKILL.md cross-references ADR-058" {
  grep -q 'ADR-058' "$SKILL"
}

@test "AC4: SKILL.md documents that val_validate_output is superseded by direct-invocation" {
  grep -q 'superseded' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC1 — Canonical JSON example present (one per severity level)
# ---------------------------------------------------------------------------

@test "AC1: SKILL.md contains a JSON example of the response schema" {
  # Look for fenced json block plus a findings array marker
  grep -q '```json' "$SKILL"
  grep -q '"findings"' "$SKILL"
}
