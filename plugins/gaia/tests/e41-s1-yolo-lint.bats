#!/usr/bin/env bats
# e41-s1-yolo-lint.bats — regression suite for plugins/gaia/scripts/yolo-lint.sh
#
# Story: E41-S1 (YOLO Mode Contract + Helper)
# Architecture: §10.30.3 (six hard-gate categories) + §10.30.8 (anti-patterns)
# ADR: ADR-057 (YOLO Mode Contract for V2 Phase 4 Commands)
#
# Coverage:
#   TC-YOLO-13 — Lint rejects yolo_steps: covering a hard-gate step
#   ECI-498    — yolo_steps: [] empty array is a no-op (no lint output)
#   ECI-499    — yolo_steps: pointing to a non-existent step number => WARNING
#
# Lint contract (FR-YOLO-2 a..f):
#   FAIL hard if yolo_steps: covers any of:
#     (a) Pre-start quality gate steps
#     (b) Status guards (HALT unless status == X)
#     (c) Allowlist rejections
#     (d) Destructive-write approvals
#     (e) Validation-failure cap (3-attempt cap)
#     (f) Memory-save prompts
#   WARN (non-blocking) on out-of-range step numbers (ECI-499).
#   Empty yolo_steps: [] is a no-op (ECI-498).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/yolo-lint.sh"
}

teardown() { common_teardown; }

# Helper — build a minimal SKILL.md fixture under TEST_TMP/skills/<id>/SKILL.md
write_skill() {
  local id="$1"
  local body="$2"
  mkdir -p "$TEST_TMP/skills/$id"
  printf '%s\n' "$body" > "$TEST_TMP/skills/$id/SKILL.md"
  echo "$TEST_TMP/skills/$id/SKILL.md"
}

# --- Existence + invocation contract ---------------------------------------

@test "yolo-lint.sh: file exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "yolo-lint.sh: defines public lint_yolo_steps function" {
  # NFR-052 public-function coverage: the function name MUST be parseable
  # by run-with-coverage.sh's grep ('^[a-z_][a-z0-9_]*\(\) {').
  grep -qE '^lint_yolo_steps\(\)[[:space:]]*\{' "$SCRIPT"
}

@test "yolo-lint.sh: --help exits 0 with usage banner" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"yolo-lint"* ]]
}

# --- TC-YOLO-13: hard-gate violations FAIL ---------------------------------

@test "b): yolo_steps:[1] on a status-guard step FAILS" {
  write_skill demo-status-guard "$(cat <<'YAML'
---
name: demo-status-guard
yolo_steps: [1]
---

## Step 1: Status Guard

HALT unless status == backlog.

## Step 2: Elaborate
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hard-gate"* ]] || [[ "$output" == *"HARD-GATE"* ]]
  [[ "$output" == *"demo-status-guard"* ]]
}

@test "a): yolo_steps:[1] on a pre-start gate step FAILS" {
  write_skill demo-pre-start "$(cat <<'YAML'
---
name: demo-pre-start
yolo_steps: [1]
quality_gates:
  pre_start:
    - check: prd_exists
---

## Step 1: Pre-start Gate Check

## Step 2: Plan
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo-pre-start"* ]]
}

@test "c): yolo_steps:[2] on an allowlist-rejection step FAILS" {
  write_skill demo-allowlist "$(cat <<'YAML'
---
name: demo-allowlist
yolo_steps: [2]
---

## Step 1: Load

## Step 2: Allowlist Rejection Check

Reject path-traversal writes.
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo-allowlist"* ]]
}

@test "d): yolo_steps:[2] on a destructive-write approval step FAILS" {
  write_skill demo-destructive "$(cat <<'YAML'
---
name: demo-destructive
yolo_steps: [2]
---

## Step 1: Load

## Step 2: Destructive Write Approval

Confirm before writing to plugins/gaia/skills/.
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo-destructive"* ]]
}

@test "e): yolo_steps:[3] on the attempt-cap step FAILS" {
  write_skill demo-attempt-cap "$(cat <<'YAML'
---
name: demo-attempt-cap
yolo_steps: [3]
---

## Step 1: Validate

## Step 2: Fix

## Step 3: Attempt Cap (3 attempts) — HALT

After 3 unresolved attempts, prompt user.
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo-attempt-cap"* ]]
}

@test "f): yolo_steps:[2] on a memory-save prompt step FAILS" {
  write_skill demo-memory-save "$(cat <<'YAML'
---
name: demo-memory-save
yolo_steps: [2]
---

## Step 1: Work

## Step 2: Memory Save Prompt

Prompt user [y]/[n]/[e] before sidecar write.
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo-memory-save"* ]]
}

# --- TC-YOLO-13 happy path: legal yolo_steps PASS --------------------------

@test "happy: yolo_steps:[3] on a non-hard-gate Elaborate step PASSES" {
  write_skill demo-elaborate "$(cat <<'YAML'
---
name: demo-elaborate
yolo_steps: [3]
---

## Step 1: Status Guard

## Step 2: Load Inputs

## Step 3: Elaborate Story

Generate the elaborated story content.

## Step 4: Memory Save Prompt
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -eq 0 ]
}

# --- ECI-498: empty yolo_steps:[] is a no-op -------------------------------

@test "yolo_steps: (empty) emits no lint output and PASSES" {
  write_skill demo-empty "$(cat <<'YAML'
---
name: demo-empty
yolo_steps: []
---

## Step 1: Status Guard

## Step 2: Elaborate
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -eq 0 ]
  # Should produce no FAIL or WARNING lines for this skill.
  ! [[ "$output" == *"demo-empty"*"FAIL"* ]]
  ! [[ "$output" == *"demo-empty"*"WARN"* ]]
}

@test "missing yolo_steps key behaves identically to (no lint output)" {
  write_skill demo-missing "$(cat <<'YAML'
---
name: demo-missing
---

## Step 1: Status Guard
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"demo-missing"*"FAIL"* ]]
  ! [[ "$output" == *"demo-missing"*"WARN"* ]]
}

# --- ECI-499: out-of-range step number => WARNING (non-blocking) -----------

@test "yolo_steps:[99] when skill has 3 steps emits WARNING (exit 0)" {
  write_skill demo-oor "$(cat <<'YAML'
---
name: demo-oor
yolo_steps: [99]
---

## Step 1: Load

## Step 2: Plan

## Step 3: Elaborate
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]] || [[ "$output" == *"warning"* ]] || [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"demo-oor"* ]]
  [[ "$output" == *"99"* ]]
}

# --- Multiple skills: aggregate behavior -----------------------------------

@test "multi-skill: one violation in three skills FAILS with exact-skill identification" {
  write_skill clean-a "$(cat <<'YAML'
---
name: clean-a
yolo_steps: [3]
---

## Step 1: Status Guard

## Step 2: Plan

## Step 3: Elaborate
YAML
)"
  write_skill bad-b "$(cat <<'YAML'
---
name: bad-b
yolo_steps: [1]
---

## Step 1: Status Guard

HALT unless status == backlog.
YAML
)"
  write_skill clean-c "$(cat <<'YAML'
---
name: clean-c
---

## Step 1: Anything
YAML
)"
  run "$SCRIPT" --skills-root "$TEST_TMP/skills"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad-b"* ]]
  # The clean skills should not appear as FAIL items.
  ! [[ "$output" == *"clean-a"*"FAIL"* ]]
  ! [[ "$output" == *"clean-c"*"FAIL"* ]]
}
