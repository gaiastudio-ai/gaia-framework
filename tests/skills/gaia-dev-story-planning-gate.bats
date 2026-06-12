#!/usr/bin/env bats
# gaia-dev-story-planning-gate.bats — TC-DSH-01 regression guard for E55-S1
#
# Story: E55-S1 (Planning gate hard halt via AskUserQuestion)
# ADR: ADR-073 (/gaia-dev-story Planning-Gate Halt + Val Auto-Validation Loop)
#
# Validates the Step 4 planning gate region in
# `plugins/gaia/skills/gaia-dev-story/SKILL.md`:
#
#   AC1/AC2 — Test 1: AskUserQuestion instruction present in gate region.
#   AC1/AC2 — Test 2: conversational prompt ("wait for user...") absent.
#   AC1/AC2 — Test 3: no Edit/Write to test/impl file before user response.
#   AC3    — Test 4: yolo-mode.sh is_yolo invocation present (ADR-057/ADR-073
#                    single-source-of-truth — no inline detection).
#   AC3    — Test 5: extension-point placeholder markers present for E55-S2,
#                    E55-S3, E55-S5.
#
# The gate region is the contiguous block bounded by the literal markers:
#   <!-- planning gate begin -->
#   <!-- planning gate end -->
#
# Usage:
#   bats tests/skills/gaia-dev-story-planning-gate.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  SKILL_FILE="$SKILLS_DIR/gaia-dev-story/SKILL.md"

  GATE_BEGIN='<!-- planning gate begin -->'
  GATE_END='<!-- planning gate end -->'
}

# Extract the gate region (inclusive of markers) from SKILL.md to stdout.
# If either marker is missing, prints nothing — the @test predicate will then
# fail naturally on the substring assertion.
extract_gate_region() {
  awk -v b="$GATE_BEGIN" -v e="$GATE_END" '
    index($0, b) { in_region = 1 }
    in_region    { print }
    index($0, e) { in_region = 0 }
  ' "$SKILL_FILE"
}

# ---------- Preconditions ----------

@test "SKILL.md exists at gaia-dev-story skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "Gate region begin marker is present" {
  grep -qF "$GATE_BEGIN" "$SKILL_FILE"
}

@test "Gate region end marker is present" {
  grep -qF "$GATE_END" "$SKILL_FILE"
}

# ---------- Test 1: AskUserQuestion present (AC1, AC2) ----------

@test "Test 1: gate region contains the literal token AskUserQuestion" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  echo "$region" | grep -qF "AskUserQuestion"
}

# ---------- Test 2: conversational prompt absent (AC1, AC2) ----------

@test "Test 2: gate region does NOT contain 'wait for user confirmation'" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  ! echo "$region" | grep -qiF "wait for user confirmation"
}

@test "Test 2 (variant): gate region does NOT contain any 'wait for user' phrasing" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  ! echo "$region" | grep -qiE "wait for user"
}

# ---------- Test 3: no Edit/Write between plan render and gate (AC1, AC2) ----------
#
# The non-YOLO branch of the gate region MUST NOT instruct the agent to invoke
# Edit or Write against a test or implementation file before the user responds.
# We assert that the gate region does not contain instruction strings that
# would cause such a tool call. The Edit/Write tokens MAY appear elsewhere in
# SKILL.md (e.g., the PostToolUse matcher in the frontmatter, or Steps 5-7) —
# only the gate region itself is constrained.

@test "Test 3: gate region does NOT instruct Edit of a test or implementation file before gate" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  # Reject any prose instruction like "use Edit to ...", "invoke Edit on ...",
  # "Edit the test file", "Write the implementation", etc., inside the gate.
  ! echo "$region" | grep -qiE "(invoke|call|use|run|issue) +(the +)?Edit\b"
  ! echo "$region" | grep -qiE "(invoke|call|use|run|issue) +(the +)?Write\b"
  ! echo "$region" | grep -qiE "Edit +(the +)?(test|impl|implementation|source) +file"
  ! echo "$region" | grep -qiE "Write +(the +)?(test|impl|implementation|source) +file"
}

# ---------- Test 4: is_yolo gate present (AC3 — ADR-057/ADR-073) ----------

@test "Test 4: gate region invokes yolo-mode.sh is_yolo (no inline detection)" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE "yolo-mode\.sh.*is_yolo|is_yolo.*yolo-mode\.sh"
}

@test "Test 4 (helper exists): yolo-mode.sh is shipped with the plugin" {
  [ -x "$SCRIPTS_DIR/yolo-mode.sh" ]
}

# ---------- Test 5: extension-point placeholder markers present (AC3) ----------

@test "Test 5a: E55-S2 YOLO branch placeholder marker present in gate region" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  echo "$region" | grep -qF "YOLO Val auto-validation loop"
}

@test "Test 5b: E55-S3 three-option prompt placeholder marker present in gate region" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  echo "$region" | grep -qF "three-option prompt body"
}

@test "Test 5c: E55-S5 plan-structure validator placeholder marker present in gate region" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  echo "$region" | grep -qF "plan-structure validator"
}

# ---------- NFR-DSH-5: single-line gate log emission instruction ----------

@test "NFR-DSH-5: gate region instructs emission of single-line gate log" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  echo "$region" | grep -qF "step4_gate"
}
