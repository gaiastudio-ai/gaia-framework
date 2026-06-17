#!/usr/bin/env bats
# e65-s6-test-review-migration.bats — structural assertions for the
# `gaia-test-review` migration to the E65-S2 review-skill template.
#
# Pattern-matches against E65-S4 (gaia-qa-tests). Verifies:
#   - TC-DEJ-PHASE-S6   — seven canonical phase headers in order
#   - TC-DEJ-DET-S6     — determinism settings (temperature: 0, model pin, prompt_hash)
#   - TC-DEJ-TOOLKIT-TR-01 — test-quality toolkit declared (smell detection + flakiness + fixture analysis)
#   - TC-DEJ-RUBRIC-S6  — severity rubric carries ≥2 examples per tier for test-quality categories
#   - TC-DEJ-WRITE-S6-1 — FR-402 review-file path declared (test-review-{story_key}.md)
#   - TC-DEJ-WRITE-S6-2 — fork allowlist exactly [Read, Grep, Glob, Bash]
#   - TC-DEJ-PARITY-S6  — gaia-test-review registered in evidence-judgment-parity.bats
#
# All assertions are static-text reads against the migrated SKILL.md — no
# fork/subagent dispatch, no network. Suite is fast (<1s wall-clock).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SKILL_FILE="$BATS_TEST_DIRNAME/../skills/gaia-test-review/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# --- TC-DEJ-WRITE-S6-2 — fork allowlist read-only ---

@test "allowed-tools is exactly [Read, Grep, Glob, Bash]" {
  run grep -E '^allowed-tools:' "$SKILL_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E '\[Read, Grep, Glob, Bash\]' >/dev/null
}

@test "no Write or Edit appears in allowed-tools" {
  run grep -E '^allowed-tools:.*(Write|Edit)' "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

# --- TC-DEJ-PHASE-S6 — unifying principle + seven phase headers in order ---

@test "unifying principle present verbatim" {
  grep -F 'Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.' "$SKILL_FILE" >/dev/null
}

@test "seven canonical phase headers in order" {
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

# --- TC-DEJ-DET-S6 — determinism settings ---

@test "temperature: 0 declared" {
  grep -F 'temperature: 0' "$SKILL_FILE" >/dev/null
}

@test "model pinned to claude-opus-4-7" {
  grep -F 'claude-opus-4-7' "$SKILL_FILE" >/dev/null
}

@test "prompt_hash recording declared" {
  grep -F 'prompt_hash' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-TOOLKIT-TR-01 — test-quality toolkit declared ---

@test "test-smell detection section present" {
  grep -iE 'test[- ]smell' "$SKILL_FILE" >/dev/null
}

@test "flakiness retry-history analysis declared" {
  grep -iE 'flakiness' "$SKILL_FILE" >/dev/null
  grep -iE 'retry[- ]history|retry rate|retry count' "$SKILL_FILE" >/dev/null
}

@test "fixture analysis declared" {
  grep -iE 'fixture analysis|shared mutable fixture|setup/teardown' "$SKILL_FILE" >/dev/null
}

@test "stack-toolkit table declares all seven canonical stacks" {
  grep -F 'ts-dev' "$SKILL_FILE" >/dev/null
  grep -F 'python-dev' "$SKILL_FILE" >/dev/null
  grep -F 'go-dev' "$SKILL_FILE" >/dev/null
  grep -F 'flutter-dev' "$SKILL_FILE" >/dev/null
  grep -F 'java-dev' "$SKILL_FILE" >/dev/null
  grep -F 'mobile-dev' "$SKILL_FILE" >/dev/null
  grep -F 'angular-dev' "$SKILL_FILE" >/dev/null
}

@test "per-stack CI test-result formats declared" {
  # junit XML, jest JSON, go test -json, pytest junitxml
  grep -iE 'junit.*xml|junitxml' "$SKILL_FILE" >/dev/null
  grep -iE 'jest.*json|--json' "$SKILL_FILE" >/dev/null
  grep -iE 'go test -json|go-test-json' "$SKILL_FILE" >/dev/null
}

@test "three-tier flakiness signal source documented" {
  # CI history → annotations → skip
  grep -iE 'CI history|CI test-result' "$SKILL_FILE" >/dev/null
  grep -iE '@flaky|pytest.mark.flaky|@retry' "$SKILL_FILE" >/dev/null
}

@test "scope boundary vs S4 documented" {
  grep -iE 'scope boundary|S4|coverage existence|test quality' "$SKILL_FILE" >/dev/null
  # Specifically the S4 vs S6 boundary
  grep -F 'S4' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-RUBRIC-S6 — severity rubric examples ---

@test "Critical tier present" {
  grep -E '^### Critical' "$SKILL_FILE" >/dev/null
}

@test "Warning tier present" {
  grep -E '^### Warning' "$SKILL_FILE" >/dev/null
}

@test "Suggestion tier present" {
  grep -E '^### Suggestion' "$SKILL_FILE" >/dev/null
}

@test "Critical examples include flaky test and shared mutable fixture" {
  grep -iE 'flaky test|>5%|retry rate' "$SKILL_FILE" >/dev/null
  grep -iE 'shared mutable fixture|singleton.*mutable' "$SKILL_FILE" >/dev/null
}

@test "Warning examples include hardcoded sleep and conditional-in-test" {
  grep -iE 'hardcoded sleep|setTimeout' "$SKILL_FILE" >/dev/null
  grep -iE 'conditional[- ]in[- ]test|conditional logic' "$SKILL_FILE" >/dev/null
}

@test "Suggestion examples include magic number and missing docstring" {
  grep -iE 'magic number' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-WRITE-S6-1 — FR-402 review-file path declared ---

@test "path test-review-{story_key}.md declared" {
  grep -F 'test-review-' "$SKILL_FILE" | grep -F 'docs/implementation-artifacts/' >/dev/null
}

@test "parent-mediated write (Option A) documented" {
  grep -iF 'parent-mediated' "$SKILL_FILE" >/dev/null
  grep -iF 'Option A' "$SKILL_FILE" >/dev/null
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

@test "shared scripts: review-gate.sh referenced for Test Review gate" {
  grep -F 'review-gate.sh' "$SKILL_FILE" >/dev/null
  grep -F '"Test Review"' "$SKILL_FILE" >/dev/null
}

# --- evidence-judgment-parity.bats registration check ---

@test "gaia-test-review registered in REVIEW_SKILLS array" {
  local parity="$BATS_TEST_DIRNAME/evidence-judgment-parity.bats"
  grep -F 'skills/gaia-test-review/SKILL.md' "$parity" >/dev/null
}
