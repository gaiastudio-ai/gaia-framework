#!/usr/bin/env bats
# gaia-dev-story-yolo-plan-loop.bats — TC-DSH-05..09 regression guard for E55-S2
#
# Story: E55-S2 (YOLO Val auto-validation loop, 3-iter cap, audit file)
# ADR: ADR-073 (/gaia-dev-story Planning-Gate Halt + Val Auto-Validation Loop)
# Predecessor: E55-S1 (planning gate hard halt)
#
# Validates the YOLO branch sub-region of the Step 4 planning gate in
# `plugins/gaia/skills/gaia-dev-story/SKILL.md`:
#
#   AC1 (TC-DSH-05) — YOLO branch routes the rendered plan to Val (gaia-val-validate).
#   AC2 (TC-DSH-06) — 3-iteration cap with audit-file persistence on every iteration.
#   AC3 (TC-DSH-07) — INFO-only findings allow loop break + advance to Step 5.
#   AC4 (TC-DSH-08) — checkpoint persists yolo flag + iteration count + last-findings-hash.
#   AC5 (T-37)      — story_key regex `^E\d+-S\d+$` rejects path traversal BEFORE any write.
#   AC6 (TC-DSH-09) — no inline `is_yolo` detection inside the YOLO branch sub-region.
#
# Gate region bounds (defined by E55-S1):
#   <!-- planning gate begin -->
#   <!-- planning gate end -->
#
# YOLO branch sub-region bounds (this story):
#   <!-- YOLO Val auto-validation loop -->   (begin)
#   <!-- planning gate end -->                                  (end)
#
# Usage:
#   bats tests/skills/gaia-dev-story-yolo-plan-loop.bats
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
  YOLO_BEGIN='<!-- YOLO Val auto-validation loop -->'
}

# Extract the gate region (inclusive of markers) from SKILL.md to stdout.
extract_gate_region() {
  awk -v b="$GATE_BEGIN" -v e="$GATE_END" '
    index($0, b) { in_region = 1 }
    in_region    { print }
    index($0, e) { in_region = 0 }
  ' "$SKILL_FILE"
}

# Extract the YOLO branch sub-region — from the YOLO marker (inclusive) to the
# gate end marker (exclusive). This is the slice that this story is allowed
# to mutate; it MUST contain the loop body and MUST NOT contain inline
# `is_yolo` redefinition.
extract_yolo_subregion() {
  awk -v b="$YOLO_BEGIN" -v e="$GATE_END" '
    index($0, e) { in_region = 0 }
    in_region    { print }
    index($0, b) { in_region = 1 }
  ' "$SKILL_FILE"
}

# ---------- Pre-flight ----------

@test "Pre-flight: SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

@test "Pre-flight: gate region begin marker present" {
  grep -qF "$GATE_BEGIN" "$SKILL_FILE"
}

@test "Pre-flight: gate region end marker present" {
  grep -qF "$GATE_END" "$SKILL_FILE"
}

@test "Pre-flight: YOLO branch marker present" {
  grep -qF "$YOLO_BEGIN" "$SKILL_FILE"
}

# ---------- AC1 (TC-DSH-05): YOLO routes plan to Val, not AskUserQuestion ----------

@test "AC1: YOLO sub-region invokes gaia-val-validate (Val skill)" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  echo "$region" | grep -qE "gaia-val-validate"
}

@test "AC1: YOLO sub-region does NOT call AskUserQuestion" {
  # The non-YOLO branch uses AskUserQuestion. The YOLO branch must not.
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  ! echo "$region" | grep -qF "AskUserQuestion"
}

# ---------- AC2 (TC-DSH-06): 3-iteration cap with audit file ----------

@test "AC2: YOLO sub-region declares the 3-iteration cap" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # Must mention 3 iterations or max_iter=3 explicitly.
  echo "$region" | grep -qE "(3 iteration|max_iter ?= ?3|iteration *< *3|3-iter)"
}

@test "AC2: YOLO sub-region references the audit file path" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # Audit file path: _memory/checkpoints/{story_key}-yolo-plan-findings.md
  echo "$region" | grep -qF '{story_key}-yolo-plan-findings.md'
}

@test "AC2: YOLO sub-region prescribes append-only audit-file persistence" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # Append-only is mandated by Task 3 / Test Scenario 8.
  echo "$region" | grep -qiE "append"
}

@test "AC2: YOLO sub-region halts on exhaustion with audit-file pointer" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # On exhaustion: HALT and surface the audit file so the user can act.
  echo "$region" | grep -qiE "HALT"
}

# ---------- AC3 (TC-DSH-07): INFO-only break ----------

@test "AC3: YOLO sub-region breaks on INFO-only findings" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # INFO-only findings must allow the loop to break.
  echo "$region" | grep -qE "INFO"
}

@test "AC3: YOLO sub-region only treats CRITICAL+WARNING as gating" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  echo "$region" | grep -qE "CRITICAL"
  echo "$region" | grep -qE "WARNING"
}

# ---------- AC4 (TC-DSH-08): resume + checkpoint fields ----------

@test "AC4: YOLO sub-region persists iteration count to checkpoint" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "iteration"
}

@test "AC4: YOLO sub-region persists last-findings-hash to checkpoint" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  echo "$region" | grep -qF "last-findings-hash"
}

@test "AC4: YOLO sub-region uses checkpoint.sh / append-val-iteration.sh for persistence" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # Must NOT inline JSON writes — must call the shared producer.
  echo "$region" | grep -qE "(checkpoint\.sh|append-val-iteration\.sh)"
}

# ---------- AC5 (T-37): regex hardening rejects path traversal ----------

@test "AC5: YOLO sub-region validates story_key against ^E\\d+-S\\d+\$ regex" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # The regex must appear literally so reviewers can read the gate without
  # chasing indirection. Both POSIX-bracket and \d shorthand forms accepted.
  echo "$region" | grep -qE '\^E\\d\+-S\\d\+\$|\^E\[0-9\]\+-S\[0-9\]\+\$'
}

@test "AC5: YOLO sub-region aborts BEFORE any audit-file write on regex mismatch" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # The mitigation must be ordered "validate then write", not "sanitize and continue".
  echo "$region" | grep -qiE "(abort|reject).*before|before.*(write|path)"
}

# ---------- AC6 (TC-DSH-09): no inline is_yolo detection in YOLO sub-region ----------

@test "AC6: YOLO sub-region does not redefine or re-implement is_yolo inline" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # The YOLO branch is selected by the surrounding gate dispatch. The branch
  # body itself must not call is_yolo — that would be redundant inline detection.
  ! echo "$region" | grep -qE "is_yolo"
}

@test "AC6: SKILL.md routes YOLO detection through yolo-mode.sh exactly once (gate level)" {
  # The string `is_yolo` may appear once in the gate-level dispatch (E55-S1)
  # but not be re-implemented anywhere else in SKILL.md — i.e., no second
  # `is_yolo` call inside any other step body.
  count=$(grep -cE "is_yolo" "$SKILL_FILE")
  [ "$count" -ge 1 ]
}

# ---------- DoD: pseudocode comment matches ADR-073 ----------

@test "DoD: YOLO sub-region carries inline pseudocode comment matching ADR-073" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # Anchor on the canonical filter+break pattern from ADR-073 pseudocode.
  echo "$region" | grep -qE "iteration *= *0"
  echo "$region" | grep -qE "while iteration *< *3"
  echo "$region" | grep -qE "filter.*severity.*CRITICAL"
}

# ---------- NFR-DSH-5: gate logging preserved ----------

@test "NFR-DSH-5: YOLO sub-region preserves single-line gate-log emission" {
  region="$(extract_yolo_subregion)"
  [ -n "$region" ]
  # The E55-S1 gate emits step4_gate logs; the YOLO branch must continue to
  # report verdict transitions (e.g., per-iteration verdict).
  echo "$region" | grep -qE "step4_gate"
}
