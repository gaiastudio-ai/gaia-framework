#!/usr/bin/env bats
# bash-dev-wiring.bats — bash-dev agent (Shay) canonical-stack wiring tests
#
# Covers AC1-AC5 for the bash-dev persona and stack wiring.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  AGENTS_DIR="$(cd "$BATS_TEST_DIRNAME/../agents" && pwd)"
  KNOWLEDGE_DIR="$(cd "$BATS_TEST_DIRNAME/../knowledge" && pwd)"
  OVERLAY_SCRIPT="$SCRIPTS_DIR/review-common/agent-overlay.sh"
  PERSONA_SCRIPT="$SCRIPTS_DIR/load-stack-persona.sh"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — bash-dev.md persona file exists with valid structure
# ---------------------------------------------------------------------------

@test "agents/bash-dev.md exists (AC1)" {
  [ -f "$AGENTS_DIR/bash-dev.md" ]
}

@test "bash-dev.md frontmatter contains name: bash-dev (AC1)" {
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "name: bash-dev"
}

@test "bash-dev.md frontmatter contains context: main (AC1)" {
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "context: main"
}

@test "bash-dev.md frontmatter contains allowed-tools with Read, Write, Edit, Bash (AC1)" {
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "allowed-tools:"
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "Read"
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "Write"
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "Edit"
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "Bash"
}

@test "bash-dev.md inherits shared dev persona from _base-dev.md (AC1)" {
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "Inherit all shared dev persona, mission, and protocols from"
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "_base-dev.md"
}

@test "bash-dev.md identity is Shay (AC1)" {
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "Shay"
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "Bash Developer"
}

@test "bash-dev.md has Stack: bash in Expertise section (AC1)" {
  assert_file_contains "$AGENTS_DIR/bash-dev.md" "Stack:** bash"
}

# ---------------------------------------------------------------------------
# AC2 — agent-overlay.sh accepts bash-dev as canonical stack
# ---------------------------------------------------------------------------

@test "is_canonical_stack accepts bash-dev (agent-overlay resolves bash-dev) (AC2)" {
  run "$OVERLAY_SCRIPT" --skill gaia-review-code --stack bash-dev
  [ "$status" -eq 0 ]
}

@test "agent-overlay returns bash-dev agent_id for --stack bash-dev (AC2)" {
  run "$OVERLAY_SCRIPT" --skill gaia-review-code --stack bash-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent_id":"bash-dev"'* ]]
  [[ "$output" == *'"sidecar_path":"_memory/bash-dev-sidecar.md"'* ]]
}

# ---------------------------------------------------------------------------
# AC3 — bash is explicit-only (no auto-detect); explicit --stack resolves
# ---------------------------------------------------------------------------

@test "detect_stack_from_files does NOT auto-detect bash from .sh files (AC3)" {
  cd "$TEST_TMP"
  # Create a directory with only shell scripts — no other stack markers.
  echo '#!/bin/bash' > script.sh
  echo '#!/bin/bash' > deploy.sh
  mkdir -p tests
  echo '#!/bin/bash' > tests/test_foo.sh
  # load-stack-persona with file heuristics should NOT detect bash-dev.
  run "$PERSONA_SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 2 ]
}

@test "detect_stack_from_files does NOT auto-detect bash from .bats files (AC3)" {
  cd "$TEST_TMP"
  echo '#!/usr/bin/env bats' > test.bats
  run "$PERSONA_SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 2 ]
}

@test "explicit --stack bash-dev resolves persona via load-stack-persona.sh (AC3)" {
  run "$PERSONA_SCRIPT" --stack bash-dev --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack='bash-dev'"* ]] || [[ "$output" == *"stack=bash-dev"* ]]
  [[ "$output" == *"bash-dev.md"* ]]
}

@test "load-stack-persona.sh exclusion comment documents bash deliberate omission (AC3)" {
  grep -q "no bash auto-detect" "$PERSONA_SCRIPT"
}

@test "detect-signals.sh exclusion comment documents bash deliberate omission (AC3)" {
  grep -q "no bash auto-detect" "$SCRIPTS_DIR/detect-signals.sh"
}

# ---------------------------------------------------------------------------
# AC4 — agent-manifest.csv contains bash-dev row
# ---------------------------------------------------------------------------

@test "agent-manifest.csv contains bash-dev row with Shay display name (AC4)" {
  grep -q '"bash-dev"' "$KNOWLEDGE_DIR/agent-manifest.csv"
  grep -q '"Shay"' "$KNOWLEDGE_DIR/agent-manifest.csv"
}

@test "bash-dev manifest row has dev module (AC4)" {
  local row
  row="$(grep '"bash-dev"' "$KNOWLEDGE_DIR/agent-manifest.csv")"
  [[ "$row" == *'"dev"'* ]]
}

# ---------------------------------------------------------------------------
# AC5 — init-project.sh roster + display-name case
# ---------------------------------------------------------------------------

@test "init-project.sh source contains bash-dev in agents roster (AC5)" {
  # The Tier 3 agents list is rendered as a YAML array in a heredoc.
  grep -q 'bash-dev' "$SCRIPTS_DIR/init-project.sh"
}

@test "init-project.sh display-name case maps bash-dev (AC5)" {
  # The display_name_for function should have a bash-dev case arm.
  grep -qE 'bash-dev\)' "$SCRIPTS_DIR/init-project.sh"
}
