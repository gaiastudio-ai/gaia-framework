#!/usr/bin/env bats
# Tests that planning-class test docs write to planning-artifacts/ and
# execution outputs stay under test-artifacts/.

setup() {
  SKILLS_DIR="${BATS_TEST_DIRNAME}/../skills"
}

# -- Planning-class docs: canonical write goes to planning-artifacts/ --

@test "test-strategy SKILL.md writes to planning-artifacts (AC1)" {
  grep -q 'planning-artifacts/.*test-strategy' \
    "$SKILLS_DIR/gaia-test-strategy/SKILL.md"
}

@test "test-strategy SKILL.md does not specify test-artifacts as write target (AC2)" {
  # References to test-artifacts should only be read-only/legacy fallback
  if grep -q 'Write.*test-artifacts.*test-strategy\|Output.*test-artifacts.*test-strategy' \
    "$SKILLS_DIR/gaia-test-strategy/SKILL.md" 2>/dev/null; then
    # If the word "legacy" or "read-only" or "fallback" is nearby, that is fine
    local offending
    offending="$(grep 'Write.*test-artifacts.*test-strategy\|Output.*test-artifacts.*test-strategy' \
      "$SKILLS_DIR/gaia-test-strategy/SKILL.md" || true)"
    if printf '%s' "$offending" | grep -qiE 'legacy|read.only|fallback|pre-migration'; then
      return 0
    fi
    fail "test-strategy specifies test-artifacts as a primary write target"
  fi
}

@test "nfr-assessment SKILL.md writes to planning-artifacts (AC3)" {
  grep -q 'planning-artifacts/.*nfr-assessment' \
    "$SKILLS_DIR/gaia-nfr/SKILL.md"
}

@test "performance-test-plan SKILL.md writes to planning-artifacts (AC4)" {
  grep -q 'planning-artifacts/.*performance-test-plan' \
    "$SKILLS_DIR/gaia-perf-testing/SKILL.md"
}

@test "traceability-matrix SKILL.md writes to planning-artifacts (AC5)" {
  grep -q 'planning-artifacts/.*traceability-matrix' \
    "$SKILLS_DIR/gaia-trace/SKILL.md"
}

# -- Legacy read fallback is documented --

@test "test-strategy documents legacy test-artifacts read fallback (AC6)" {
  grep -qiE 'legacy.*test-artifacts|test-artifacts.*read.only|test-artifacts.*fallback' \
    "$SKILLS_DIR/gaia-test-strategy/SKILL.md"
}

@test "traceability-matrix documents legacy test-artifacts read fallback (AC7)" {
  grep -qiE 'legacy.*test-artifacts|test-artifacts.*read|test-artifacts.*fallback|pre-migration.*test-artifacts' \
    "$SKILLS_DIR/gaia-trace/SKILL.md"
}

# -- Execution outputs stay under test-artifacts/ --

@test "atdd execution artifacts reference test-artifacts (AC8)" {
  # ATDD is an execution artifact, not a planning doc — it stays in test-artifacts
  grep -q 'test-artifacts/.*atdd' "$SKILLS_DIR/gaia-trace/SKILL.md"
}

# -- Migration script exists --

@test "migrate-planning-vs-test.sh exists (AC9)" {
  [ -f "${BATS_TEST_DIRNAME}/../scripts/migrate-planning-vs-test.sh" ]
}

@test "migration script covers all five planning-class doc types (AC10)" {
  local script="${BATS_TEST_DIRNAME}/../scripts/migrate-planning-vs-test.sh"
  grep -q 'test-plan' "$script"
  grep -q 'test-strategy' "$script"
  grep -q 'traceability-matrix' "$script"
  grep -q 'nfr-assessment' "$script"
  grep -q 'performance-test-plan' "$script"
}
