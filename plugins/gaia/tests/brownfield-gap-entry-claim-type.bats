#!/usr/bin/env bats
# brownfield-gap-entry-claim-type.bats — schema-validation and prose-coverage
# tests for the brownfield gap-entry claim_type and evidence.line_range
# emission rules.
#
# Schema-validation tests (ajv/python3+jsonschema) skip gracefully when no
# backend is available. Prose-coverage tests run unconditionally — they grep
# the SKILL.md for the explicit emission rules that instruct scanners to
# anchor evidence.line_range to matched tokens and stamp claim_type for
# negative/absence findings.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA="$PLUGIN/schemas/brownfield-gap-entry.schema.json"
  SKILL="$PLUGIN/skills/gaia-brownfield/SKILL.md"
  VALIDATOR="$PLUGIN/scripts/lib/validate-artifact-schema.sh"
}

teardown() { common_teardown; }

# Detect whether a JSON-schema validator backend is available on this host.
# Mirrors the cascade inside validate-artifact-schema.sh: ajv first, then
# python3+jsonschema. The bare host has neither — validate assertions SKIP.
_has_backend() {
  if command -v ajv >/dev/null 2>&1; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ===========================================================================
# Schema validation: positive — negative-claim gap entry validates (AC1)
# ===========================================================================

@test "negative-claim gap entry with claim_type negative validates against schema (AC1)" {
  _has_backend || skip "no JSON-schema validator backend available"

  local fixture="$TEST_TMP/negative-claim.json"
  cat > "$fixture" <<'FIXTURE'
{
  "gap_id": "DC-001",
  "category": "doc-code-drift",
  "severity": "WARNING",
  "claim_type": "negative",
  "title": "No __main__ guard in cli.py",
  "evidence": {
    "file": "src/cli.py",
    "line_range": "42"
  }
}
FIXTURE

  source "$VALIDATOR"
  run validate_artifact_schema "$SCHEMA" "$fixture"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Schema validation: negative — out-of-enum claim_type rejected (AC2)
# ===========================================================================

@test "gap entry with out-of-enum claim_type is rejected by schema (AC2)" {
  _has_backend || skip "no JSON-schema validator backend available"

  local fixture="$TEST_TMP/bad-claim-type.json"
  cat > "$fixture" <<'FIXTURE'
{
  "gap_id": "DC-002",
  "category": "doc-code-drift",
  "severity": "WARNING",
  "claim_type": "unknown",
  "title": "Stale config reference",
  "evidence": {
    "file": "src/config.py",
    "line_range": "10"
  }
}
FIXTURE

  source "$VALIDATOR"
  run validate_artifact_schema "$SCHEMA" "$fixture"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# Schema validation: line_range patterns (AC3)
# ===========================================================================

@test "evidence.line_range single-line token-anchored value validates (AC3)" {
  _has_backend || skip "no JSON-schema validator backend available"

  local fixture="$TEST_TMP/single-line.json"
  cat > "$fixture" <<'FIXTURE'
{
  "gap_id": "HC-001",
  "category": "hardcoded-value",
  "severity": "INFO",
  "title": "Magic number on line 42",
  "evidence": {
    "file": "src/constants.py",
    "line_range": "42"
  }
}
FIXTURE

  source "$VALIDATOR"
  run validate_artifact_schema "$SCHEMA" "$fixture"
  [ "$status" -eq 0 ]
}

@test "evidence.line_range multi-line range validates (AC3)" {
  _has_backend || skip "no JSON-schema validator backend available"

  local fixture="$TEST_TMP/range-line.json"
  cat > "$fixture" <<'FIXTURE'
{
  "gap_id": "HC-002",
  "category": "hardcoded-value",
  "severity": "INFO",
  "title": "Hard-coded block spanning lines 42-58",
  "evidence": {
    "file": "src/constants.py",
    "line_range": "42-58"
  }
}
FIXTURE

  source "$VALIDATOR"
  run validate_artifact_schema "$SCHEMA" "$fixture"
  [ "$status" -eq 0 ]
}

@test "evidence.line_range non-numeric value is rejected by schema (AC3)" {
  _has_backend || skip "no JSON-schema validator backend available"

  local fixture="$TEST_TMP/bad-line-range.json"
  cat > "$fixture" <<'FIXTURE'
{
  "gap_id": "HC-003",
  "category": "hardcoded-value",
  "severity": "INFO",
  "title": "Bad line range",
  "evidence": {
    "file": "src/constants.py",
    "line_range": "near line 42"
  }
}
FIXTURE

  source "$VALIDATOR"
  run validate_artifact_schema "$SCHEMA" "$fixture"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# Prose-coverage: evidence_line anchoring rule present in SKILL.md (AC4)
# ===========================================================================

@test "SKILL.md gap-entry-schema-ref contains evidence line_range anchoring rule (AC4)" {
  # The emission prose must instruct scanners to anchor line_range to the
  # matched key/token itself, not a neighbouring line.
  grep -qi 'matched.*\(key\|token\)' "$SKILL"
  grep -qi 'anchor' "$SKILL"
  # Both terms must appear in proximity to "line_range" context.
  grep -qi 'line_range.*anchor\|anchor.*line_range\|line_range.*matched\|matched.*line_range' "$SKILL"
}

# ===========================================================================
# Prose-coverage: claim_type negative emission rule present in SKILL.md (AC5)
# ===========================================================================

@test "SKILL.md contains a standalone claim_type negative emission rule outside the enum comment (AC5)" {
  # The emission prose must instruct scanners to set claim_type: negative
  # for absence/missing findings. This rule must be a standalone paragraph
  # or bullet OUTSIDE the schema-ref enum-comment line. Filter out the
  # single enum-comment line to ensure we are testing for a substantive
  # emission rule, not just the pre-existing enum annotation.
  local filtered
  filtered="$(grep -i 'negative' "$SKILL" | grep -vi 'claim_type-enum:' | grep -vi 'non-negative')"
  printf '%s\n' "$filtered" | grep -qi 'absence\|missing'
  printf '%s\n' "$filtered" | grep -qi 'MUST.*claim_type\|claim_type.*MUST\|MUST.*negative\|negative.*MUST'
}

# ===========================================================================
# Prose-coverage: contradiction rule present in SKILL.md (AC5)
# ===========================================================================

@test "SKILL.md emission rules document contradiction claim_type outside the enum comment (AC5)" {
  # The standalone emission-rule prose (not just the schema-ref enum comment)
  # must document that two-sided doc/code contradictions set claim_type:
  # contradiction. Filter out the enum comment and the drift-description
  # paragraph to require a substantive rule.
  local filtered
  filtered="$(grep -i 'contradiction' "$SKILL" | grep -vi 'claim_type-enum:' | grep -vi 'config-contradiction' | grep -vi 'cross-scanner drift')"
  printf '%s\n' "$filtered" | grep -qi 'MUST.*contradiction\|contradiction.*MUST\|claim_type.*contradiction\|contradiction.*claim_type'
}
