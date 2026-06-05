#!/usr/bin/env bats
# gaia-dev-story-step7b-val.bats — TC-DSH-11/TC-DSH-12 regression guard for E55-S4
#
# Story: E55-S4 (Val-in-TDD single post-Refactor pass — Step 7b)
# ADR:   ADR-073 (/gaia-dev-story Planning-Gate Halt + Val Auto-Validation Loop)
# Sibling: E55-S2 (planning-gate YOLO Val auto-validation loop — same loop semantics)
#
# Validates the Step 7b region in
# `plugins/gaia/skills/gaia-dev-story/SKILL.md`:
#
#   AC1 (TC-DSH-11) — Step 7b invokes Val ONCE on the diff, with up to 3 auto-fix
#                     iterations; CRITICAL+WARNING gate, INFO-only breaks.
#   AC2 (TC-DSH-11) — On exhaustion the skill HALTs with an actionable message
#                     naming the remaining findings.
#   AC3 (TC-DSH-12) — Steps 5 (TDD Red), 6 (TDD Green), and 7 (Refactor) contain
#                     NO new `AskUserQuestion` invocations (pause-free TDD body).
#
# Step 7b region bounds (this story):
#   <!-- E55-S4: step 7b begin -->
#   <!-- E55-S4: step 7b end -->
#
# Usage:
#   bats tests/skills/gaia-dev-story-step7b-val.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SKILL_FILE="$SKILLS_DIR/gaia-dev-story/SKILL.md"

  STEP7B_BEGIN='<!-- E55-S4: step 7b begin -->'
  STEP7B_END='<!-- E55-S4: step 7b end -->'
}

# Extract the Step 7b region (inclusive of markers) from SKILL.md to stdout.
extract_step7b_region() {
  awk -v b="$STEP7B_BEGIN" -v e="$STEP7B_END" '
    index($0, b) { in_region = 1 }
    in_region    { print }
    index($0, e) { in_region = 0 }
  ' "$SKILL_FILE"
}

# Extract a step body — from the "### Step N --" heading (inclusive) up to
# the next "### Step" heading (exclusive). Used to inspect Steps 5/6/7
# bodies for forbidden new pause invocations.
extract_step_body() {
  local heading="$1"
  awk -v h="$heading" '
    /^### Step / {
      if (in_region) { in_region = 0 }
      if (index($0, h) == 1) { in_region = 1 }
    }
    in_region { print }
  ' "$SKILL_FILE"
}

# ---------- Pre-flight ----------

@test "Pre-flight: SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

@test "Pre-flight: Step 7b begin marker present" {
  grep -qF "$STEP7B_BEGIN" "$SKILL_FILE"
}

@test "Pre-flight: Step 7b end marker present" {
  grep -qF "$STEP7B_END" "$SKILL_FILE"
}

@test "Pre-flight: Step 7b sits between Step 7 and Step 8" {
  step7_line=$(grep -n '^### Step 7 ' "$SKILL_FILE" | head -1 | cut -d: -f1)
  begin_line=$(grep -nF "$STEP7B_BEGIN" "$SKILL_FILE" | head -1 | cut -d: -f1)
  end_line=$(grep -nF "$STEP7B_END" "$SKILL_FILE" | head -1 | cut -d: -f1)
  step8_line=$(grep -n '^### Step 8 ' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$step7_line" ] && [ -n "$begin_line" ] && [ -n "$end_line" ] && [ -n "$step8_line" ]
  [ "$step7_line" -lt "$begin_line" ]
  [ "$begin_line" -lt "$end_line" ]
  [ "$end_line" -lt "$step8_line" ]
}

# ---------- AC1 (TC-DSH-11): Val invocation + 3-iteration cap ----------

@test "AC1: Step 7b region invokes gaia-val-validate (Val skill)" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE "gaia-val-validate"
}

@test "AC1: Step 7b region declares the 3-iteration cap" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE "(3 iteration|max_iter ?= ?3|iteration *< *3|3-iter)"
}

@test "AC1: Step 7b region runs Val on the diff (Steps 5-7 artifacts)" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "diff"
}

@test "AC1: Step 7b region dispatches Val via the main-turn Agent tool" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "main-turn Agent|assert_agent_envelope"
}

@test "AC1: Step 7b region treats CRITICAL+WARNING as gating" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE "CRITICAL"
  echo "$region" | grep -qE "WARNING"
}

@test "AC1: Step 7b region breaks on INFO-only findings" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE "INFO"
}

@test "AC1: Step 7b region applies fixes inline (no nested subagent spawn)" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  # NFR-046 single-spawn-level — auto-fix uses the skill's own Edit/Write tools.
  echo "$region" | grep -qiE "inline"
  echo "$region" | grep -qE "Edit"
}

# ---------- AC1 audit-file persistence ----------

@test "AC1: Step 7b region references the audit file path" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  # Audit file path: _memory/checkpoints/{story_key}-tdd-val-findings.md
  echo "$region" | grep -qF '{story_key}-tdd-val-findings.md'
}

@test "AC1: Step 7b region prescribes append-only audit-file persistence" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "append"
}

# ---------- T-37 path-traversal mitigation ----------

@test "T-37: Step 7b region validates story_key against ^E\\d+-S\\d+\$ regex" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE '\^E\\d\+-S\\d\+\$|\^E\[0-9\]\+-S\[0-9\]\+\$'
}

@test "T-37: Step 7b region aborts BEFORE any audit-file write on regex mismatch" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "(abort|reject).*before|before.*(write|path)"
}

# ---------- AC2 (TC-DSH-11): HALT on exhaustion ----------

@test "AC2: Step 7b region halts on 3-iteration exhaustion" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "HALT"
}

@test "AC2: Step 7b region halt message names remaining findings" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  # The halt message must reference 'remaining findings' so the user can act.
  echo "$region" | grep -qiE "remaining findings"
}

@test "AC2: Step 7b region halt message points to audit file" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  # On halt, the user is directed to the audit file for the full record.
  echo "$region" | grep -qF '{story_key}-tdd-val-findings.md'
}

# ---------- DoD: pseudocode comment matches ADR-073 ----------

@test "DoD: Step 7b region carries inline pseudocode comment matching ADR-073" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  # Anchor on the canonical loop pattern from ADR-073 pseudocode.
  echo "$region" | grep -qE "iteration *= *0"
  echo "$region" | grep -qE "while iteration *< *3"
  echo "$region" | grep -qE "filter.*severity.*CRITICAL"
}

# ---------- AC1 (TC-DSH-11): YOLO and non-YOLO both run Step 7b ----------

@test "AC1: Step 7b region is unconditional (no is_yolo gate)" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  # Test Scenario 7: Step 7b runs identically in YOLO and non-YOLO. The
  # body MUST NOT branch on is_yolo — that gate lives only at Step 4.
  ! echo "$region" | grep -qE "is_yolo"
}

# ---------- NFR-DSH-5: gate logging ----------

@test "NFR-DSH-5: Step 7b region emits a single-line gate log to stderr" {
  region="$(extract_step7b_region)"
  [ -n "$region" ]
  # Mirror the step4_gate convention from E55-S1/S2; new key is step7b_gate.
  echo "$region" | grep -qE "step7b_gate"
}

# ---------- AC3 (TC-DSH-12): pause-free TDD body invariant ----------

@test "AC3: Step 5 (TDD Red) body contains NO AskUserQuestion invocation" {
  body="$(extract_step_body '### Step 5 ')"
  [ -n "$body" ]
  ! echo "$body" | grep -qF "AskUserQuestion"
}

@test "AC3: Step 6 (TDD Green) body contains NO AskUserQuestion invocation" {
  body="$(extract_step_body '### Step 6 ')"
  [ -n "$body" ]
  ! echo "$body" | grep -qF "AskUserQuestion"
}

@test "AC3: Step 7 (TDD Refactor) body contains NO AskUserQuestion invocation" {
  body="$(extract_step_body '### Step 7 ')"
  [ -n "$body" ]
  ! echo "$body" | grep -qF "AskUserQuestion"
}

@test "AC3: Step 5/6/7 bodies contain NO HALT directives (pause-free TDD body)" {
  for heading in '### Step 5 ' '### Step 6 ' '### Step 7 '; do
    body="$(extract_step_body "$heading")"
    [ -n "$body" ]
    # Case-insensitive: HALT, halt, Halt all forbidden inside the TDD body.
    if echo "$body" | grep -qiE "\bhalt\b"; then
      printf 'unexpected HALT directive in step body: %s\n' "$heading" >&2
      return 1
    fi
  done
}
