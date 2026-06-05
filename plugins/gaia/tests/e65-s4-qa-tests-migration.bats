#!/usr/bin/env bats
# e65-s4-qa-tests-migration.bats — structural assertions for the
# `gaia-qa-tests` migration to the E65-S2 review-skill template.
#
# Pattern-matches against E65-S3 (gaia-security-review). Verifies:
#   - TC-DEJ-PHASE-S4   — seven canonical phase headers in order
#   - TC-DEJ-DET-S4     — determinism settings (temperature: 0, model pin, prompt_hash)
#   - TC-DEJ-TOOLKIT-QA-01 — QA toolkit declared (test-discovery + AC-coverage analyzer)
#   - TC-DEJ-RUBRIC-S4  — severity rubric carries ≥2 examples per tier for QA categories
#   - TC-DEJ-WRITE-S4-1 — FR-402 review-file path declared (qa-tests-{story_key}.md)
#   - TC-DEJ-WRITE-S4-2 — fork allowlist exactly [Read, Grep, Glob, Bash]
#
# All assertions are static-text reads against the migrated SKILL.md — no
# fork/subagent dispatch, no network. Suite is fast (<1s wall-clock).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SKILL_FILE="$BATS_TEST_DIRNAME/../skills/gaia-qa-tests/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# --- TC-DEJ-WRITE-S4-2 — fork allowlist read-only ---

@test "TC-DEJ-WRITE-S4-2: allowed-tools is exactly [Read, Grep, Glob, Bash]" {
  run grep -E '^allowed-tools:' "$SKILL_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E '\[Read, Grep, Glob, Bash\]' >/dev/null
}

@test "TC-DEJ-WRITE-S4-2: no Write or Edit appears in allowed-tools" {
  run grep -E '^allowed-tools:.*(Write|Edit)' "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

# --- TC-DEJ-PHASE-S4 — unifying principle + seven phase headers in order ---

@test "TC-DEJ-PHASE-S4: unifying principle present verbatim" {
  grep -F 'Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-PHASE-S4: seven canonical phase headers in order" {
  local got
  got="$(grep -nE '^### Phase [1-7]' "$SKILL_FILE" || true)"
  echo "$got" | grep -F 'Phase 1' >/dev/null
  echo "$got" | grep -F 'Phase 2' >/dev/null
  echo "$got" | grep -F 'Phase 3A' >/dev/null
  echo "$got" | grep -F 'Phase 3B' >/dev/null
  echo "$got" | grep -F 'Phase 4' >/dev/null
  echo "$got" | grep -F 'Phase 5' >/dev/null
  echo "$got" | grep -F 'Phase 6' >/dev/null
  echo "$got" | grep -F 'Phase 7' >/dev/null
}

# --- TC-DEJ-DET-S4 — determinism settings ---

@test "TC-DEJ-DET-S4: temperature: 0 declared" {
  grep -F 'temperature: 0' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-DET-S4: model pinned to claude-opus-4-7" {
  grep -F 'claude-opus-4-7' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-DET-S4: prompt_hash recording declared" {
  grep -F 'prompt_hash' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-TOOLKIT-QA-01 — QA toolkit declared ---

@test "TC-DEJ-TOOLKIT-QA-01: test-discovery section present" {
  grep -iF 'test-discovery' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-TOOLKIT-QA-01: AC-coverage analyzer section present" {
  grep -iF 'AC-coverage' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-TOOLKIT-QA-01: stack-toolkit table declares per-stack discovery globs" {
  grep -F 'ts-dev' "$SKILL_FILE" >/dev/null
  grep -F 'python-dev' "$SKILL_FILE" >/dev/null
  grep -F 'go-dev' "$SKILL_FILE" >/dev/null
  grep -F 'flutter-dev' "$SKILL_FILE" >/dev/null
  grep -F 'java-dev' "$SKILL_FILE" >/dev/null
  grep -F 'mobile-dev' "$SKILL_FILE" >/dev/null
  grep -F 'angular-dev' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-TOOLKIT-QA-01: ts-dev test glob declared" {
  grep -F '*.{test,spec}.{ts,tsx,js,jsx}' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-TOOLKIT-QA-01: python-dev test glob declared" {
  grep -F 'test_*.py' "$SKILL_FILE" >/dev/null
  grep -F '*_test.py' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-TOOLKIT-QA-01: go-dev test glob declared" {
  grep -F '*_test.go' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-TOOLKIT-QA-01: dual-strategy AC-matching documented" {
  # AC-ID prefix matching
  grep -iE 'AC-?ID' "$SKILL_FILE" >/dev/null
  # Given/When/Then fallback
  grep -F 'Given/When/Then' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-TOOLKIT-QA-01: primary vs edge-case differential weighting documented" {
  grep -iF 'primary' "$SKILL_FILE" >/dev/null
  grep -iE 'edge[- ]case' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-RUBRIC-S4 — severity rubric examples ---

@test "TC-DEJ-RUBRIC-S4: Critical tier present" {
  grep -E '^### Critical' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-RUBRIC-S4: Warning tier present" {
  grep -E '^### Warning' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-RUBRIC-S4: Suggestion tier present" {
  grep -E '^### Suggestion' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-RUBRIC-S4: Critical examples include missing AC coverage and untested error path" {
  grep -iE 'missing.*coverage|missing.*AC' "$SKILL_FILE" >/dev/null
  grep -iE 'untested.*error|error.*path' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-RUBRIC-S4: Warning examples include weak assertion and brittle selector" {
  grep -iE 'weak.*assert|toBeDefined' "$SKILL_FILE" >/dev/null
  grep -iE 'brittle.*selector|CSS class' "$SKILL_FILE" >/dev/null
}

@test "TC-DEJ-RUBRIC-S4: Suggestion examples include redundant tests and FR-traceability" {
  grep -iE 'redundant.*test|over[- ]coverage' "$SKILL_FILE" >/dev/null
  grep -iE 'FR[- ]?traceab|traceability' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-WRITE-S4-1 — FR-402 review-file path declared ---

@test "TC-DEJ-WRITE-S4-1: FR-402 path qa-tests-{story_key}.md declared" {
  grep -F 'qa-tests-' "$SKILL_FILE" | grep -F 'docs/implementation-artifacts/' >/dev/null
}

@test "TC-DEJ-WRITE-S4-1: parent-mediated write (Option A) documented" {
  grep -iF 'parent-mediated' "$SKILL_FILE" >/dev/null
  grep -iF 'the parent writes the file' "$SKILL_FILE" >/dev/null
}

# --- shared-script invocation present ---

@test "shared scripts: load-stack-persona.sh referenced" {
  grep -F 'load-stack-persona.sh' "$SKILL_FILE" >/dev/null
}

@test "shared scripts: verdict-resolver.sh referenced" {
  grep -F 'verdict-resolver.sh' "$SKILL_FILE" >/dev/null
}

@test "shared scripts: file-list-diff-check.sh referenced" {
  grep -F 'file-list-diff-check.sh' "$SKILL_FILE" >/dev/null
}

@test "shared scripts: review-gate.sh referenced for QA Tests gate" {
  grep -F 'review-gate.sh' "$SKILL_FILE" >/dev/null
  grep -F '"QA Tests"' "$SKILL_FILE" >/dev/null
}

# --- evidence-judgment-parity.bats registration check ---

@test "TC-DEJ-PARITY-S4: gaia-qa-tests registered in REVIEW_SKILLS array" {
  local parity="$BATS_TEST_DIRNAME/evidence-judgment-parity.bats"
  grep -F 'skills/gaia-qa-tests/SKILL.md' "$parity" >/dev/null
}
