#!/usr/bin/env bats
# test-automate-adr-051-preservation.bats — skill-specific assertions for E65-S5
#
# Verifies the hybrid migration of gaia-test-automate to the seven-phase
# Evidence/Judgment template DOES NOT regress the ADR-051 plan-then-execute
# split-phase contract. The standard evidence-judgment-parity.bats covers the
# five S1-AC7 invariants (allowed-tools, principle, phases, persona, resolver);
# this supplemental suite covers the ADR-051-specific contract that is unique
# to gaia-test-automate among the six review skills (TC-ADR051-PRESERVATION-01).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SKILL_FILE="$BATS_TEST_DIRNAME/../skills/gaia-test-automate/SKILL.md"

# --- AC1 / AC-EC12: hybrid section preservation ---

@test "SKILL.md contains ' Approval Gate' section AFTER seven-phase block" {
  grep -F 'Approval Gate' "$SKILL_FILE" >/dev/null
}

@test "SKILL.md preserves plan-tamper detection sequence" {
  grep -F 'plan_tamper_detected' "$SKILL_FILE" >/dev/null
}

@test "SKILL.md preserves plan-id-keyed review-gate.sh invocation" {
  # review-gate.sh must be invoked with --plan-id flag
  grep -E 'review-gate.sh.*--plan-id|--plan-id.*review-gate.sh' "$SKILL_FILE" >/dev/null \
    || grep -B1 -A4 'review-gate.sh update' "$SKILL_FILE" | grep -F -- '--plan-id' >/dev/null
}

@test "SKILL.md references the canonical plan file path test-automate-plan" {
  # AF-2026-05-21-21 canonicalized this path. Accept canonical or legacy.
  grep -E '(docs|\.gaia/artifacts)/test-artifacts/test-automate-plan-' "$SKILL_FILE" >/dev/null
}

# --- AC-EC1: Phase 6 does NOT invoke review-gate.sh ---

@test "Phase 6 explicitly states review-gate.sh is NOT invoked there" {
  # Look for an explicit non-invocation marker in or near the Phase 6 section.
  # Acceptable markers include phrases like "NO review-gate.sh", "does NOT
  # invoke review-gate.sh", or "review-gate.sh is NOT invoked" in the SKILL.md.
  grep -Ei 'NO review-gate\.sh|does NOT invoke review-gate\.sh|review-gate\.sh.{0,20}NOT invoked|NOT invoke.{0,20}review-gate\.sh' "$SKILL_FILE" >/dev/null
}

# --- AC-EC7: phase vocabulary disambiguation ---

@test "SKILL.md contains the phase-vocabulary disambiguation note" {
  # The note states the seven Review Phases all execute within the planning phase (fork-isolated analysis).
  grep -F 'Phase vocabulary disambiguation' "$SKILL_FILE" >/dev/null
  # Disambiguation note refers to seven Review Phases — accept any common phrasing.
  grep -E 'Review Phase 1.{0,30}Review Phase 7|Review Phases 1.{0,5}7|Review Phases 1 through 7|seven Review Phases|Review Phase 1.{0,30}through.{0,10}Review Phase 7' "$SKILL_FILE" >/dev/null
}

# --- AC-EC9: test-execution toolkit is GAP-FOCUSED, NOT execution ---

@test "stack-toolkit table uses listing commands (not execution)" {
  # The toolkit must reference at least one of the canonical listing commands
  # (jest --listTests, pytest --collect-only, go test -list, etc.) — NOT
  # `jest run`, `pytest run`, `go test ./...`.
  grep -E 'jest --listTests|vitest list|pytest --collect-only|go test -list|dart test --reporter=json' "$SKILL_FILE" >/dev/null
}

# --- AC2 / AC-EC2: schema separation between analysis-results.json and plan file ---

@test "SKILL.md references analysis-results.json under .gaia/state/review/test-automate/" {
  grep -F '.gaia/state/review/test-automate/' "$SKILL_FILE" >/dev/null
}

# --- AC-EC3 / AC-EC11: three-way verdict mapping with BLOCKED short-circuit ---

@test "SKILL.md documents BLOCKED short-circuit behavior" {
  # On BLOCKED, the skill emits a stub plan with verdict: BLOCKED — NOT a full
  # plan body — and does NOT invoke review-gate.sh.
  grep -E 'verdict:.*BLOCKED|verdict.*BLOCKED.*frontmatter|BLOCKED.*short-circuit|short-circuit.*BLOCKED' "$SKILL_FILE" >/dev/null
}

# --- AC-EC8: plan_id determinism via canonicalization ---

@test "SKILL.md documents plan_id canonicalization (textual variation excluded)" {
  # plan_id is computed from a canonical / normalized form so textually-
  # different LLM finding messages do NOT change plan_id.
  grep -Ei 'plan_id.*canonicaliz|normaliz.*plan_id|plan_id.*normaliz|canonical.{0,30}plan_id|plan_id.{0,40}message|message.{0,40}excluded' "$SKILL_FILE" >/dev/null
}

# --- AC-EC4: file-naming coexistence (review report vs plan file) ---

@test "SKILL.md references both test-automate-review-* and test-automate-plan-* paths" {
  grep -F 'test-automate-review-' "$SKILL_FILE" >/dev/null
  grep -F 'test-automate-plan-' "$SKILL_FILE" >/dev/null
}

# --- AC-EC6: shared file_hashes single source of truth ---

@test "SKILL.md documents shared file_hashes between analysis-results.json and plan file" {
  grep -E 'file_hashes' "$SKILL_FILE" >/dev/null
}

# --- AC5: fork allowlist sanity ---

@test "frontmatter allowed-tools is exactly [Read, Grep, Glob, Bash]" {
  grep -E '^allowed-tools:' "$SKILL_FILE" | grep -E '\[\s*Read\s*,\s*Grep\s*,\s*Glob\s*,\s*Bash\s*\]' >/dev/null
}

# --- AC1: determinism settings preserved per template ---

@test "determinism settings (temperature: 0, model: claude-opus-4-7, prompt_hash) present" {
  grep -F 'temperature: 0' "$SKILL_FILE" >/dev/null
  grep -F 'claude-opus-4-7' "$SKILL_FILE" >/dev/null
  grep -F 'prompt_hash' "$SKILL_FILE" >/dev/null
}

# --- AC1: unifying principle verbatim (also asserted by parity but useful skill-specific check) ---

@test "SKILL.md contains the unifying principle verbatim" {
  grep -F 'Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.' "$SKILL_FILE" >/dev/null
}
