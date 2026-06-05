#!/usr/bin/env bats
# e44-s6-phase3-testing-val-auto-review-wire-in.bats
#
# Script-verifiable coverage for E44-S6 — wiring the Val auto-fix loop
# (E44-S2 / ADR-058) into the 3 Phase 3 Testing artifact-producing skills
# plus an additive note in /gaia-val-validate documenting that the skill
# does not self-invoke (Task 4 / AC5):
#
#   - gaia-readiness-check  -> docs/planning-artifacts/readiness-report.md
#                                                           (artifact_type=readiness)
#   - gaia-test-design      -> docs/test-artifacts/test-plan.md
#                                                           (artifact_type=test-plan)
#   - gaia-edit-test-plan   -> docs/test-artifacts/test-plan.md
#                                                           (artifact_type=test-plan)
#
# Story acceptance criteria covered (script-verifiable subset):
#   AC1 — readiness-check Val invocation after Step 10 artifact write
#   AC2 — test-design Val invocation after Step 7 artifact write; legacy
#         "val_validate_output: true flag preserved" Critical Rule bullet
#         removed verbatim
#   AC3 — edit-test-plan Val invocation after the Step 5 write-back
#   AC4 — auto-fix loop iteration counter / 3-cap markers present in each
#         of the 3 wire-in SKILL.md files
#   AC5 — /gaia-val-validate SKILL.md documents the no-self-invoke
#         invariant introduced by Task 4
#   AC6 — gating semantics (artifact-existence guard) embedded in each
#         wire-in (AC-EC3 mirror from E44-S3..S5)
#   AC7 — VCP-VAL-04 contributing rows: anchor presence + flag absence
#
# Edge-case mirrors of E44-S3 (PR #252), E44-S4 (PR #253), E44-S5 (PR #254):
#   AC-EC3 — artifact-existence guard ("if not exists ... exit")
#   AC-EC6 — Val-skill-availability guard ("Val auto-review unavailable")
#   AC-EC8 — YOLO hard-gate invariant referenced (no bypass branch)
#
# Mirrors the structure of e44-s3-phase1-val-auto-review-wire-in.bats,
# e44-s4-phase2-val-auto-review-wire-in.bats, and
# e44-s5-phase3-solutioning-val-auto-review-wire-in.bats.

load 'test_helper.bash'

setup() {
  common_setup
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export SKILLS_DIR
  PHASE3_TEST_SKILLS_LIST="gaia-readiness-check gaia-test-design gaia-edit-test-plan"
  export PHASE3_TEST_SKILLS_LIST
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Pre-flight — all 3 Phase 3 Testing SKILL.md files exist and are readable;
# /gaia-val-validate SKILL.md (target of Task 4) also exists.
# ---------------------------------------------------------------------------

@test "preflight: all 3 Phase 3 Testing SKILL.md files exist" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    [ -f "$SKILLS_DIR/$skill/SKILL.md" ]
    [ -r "$SKILLS_DIR/$skill/SKILL.md" ]
  done
}

@test "preflight: gaia-val-validate SKILL.md exists (Task 4 target)" {
  [ -f "$SKILLS_DIR/gaia-val-validate/SKILL.md" ]
  [ -r "$SKILLS_DIR/gaia-val-validate/SKILL.md" ]
}

# ---------------------------------------------------------------------------
# AC1/AC2/AC3 — Each SKILL.md embeds the Val Auto-Fix Loop step
# ---------------------------------------------------------------------------

@test "AC1: gaia-readiness-check SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-readiness-check/SKILL.md"
}

@test "AC2: gaia-test-design SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-test-design/SKILL.md"
}

@test "AC3: gaia-edit-test-plan SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-edit-test-plan/SKILL.md"
}

@test "AC1/AC2/AC3: each Phase 3 Testing skill invokes /gaia-val-validate with artifact_path and artifact_type" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -q '/gaia-val-validate' "$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'artifact_path' "$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'artifact_type' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC1/AC2/AC3 — Correct artifact_type per skill
# ---------------------------------------------------------------------------

@test "AC1: gaia-readiness-check uses artifact_type=readiness" {
  grep -qE 'artifact_type[[:space:]]*=[[:space:]]*readiness' "$SKILLS_DIR/gaia-readiness-check/SKILL.md"
}

@test "AC2: gaia-test-design uses artifact_type=test-plan" {
  grep -qE 'artifact_type[[:space:]]*=[[:space:]]*test-plan' "$SKILLS_DIR/gaia-test-design/SKILL.md"
}

@test "AC3: gaia-edit-test-plan uses artifact_type=test-plan" {
  grep -qE 'artifact_type[[:space:]]*=[[:space:]]*test-plan' "$SKILLS_DIR/gaia-edit-test-plan/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC1/AC2/AC3 — Correct artifact_path per skill
# ---------------------------------------------------------------------------

@test "AC1: gaia-readiness-check references readiness-report.md (canonical post-AF-21-X)" {
  # Future AF will canonicalize this path. Accept canonical or legacy.
  grep -qE '(docs/planning-artifacts|\.gaia/artifacts/planning-artifacts)/readiness-report\.md' "$SKILLS_DIR/gaia-readiness-check/SKILL.md"
}

@test "AC2: gaia-test-design references test-plan.md (canonical post-AF-21-X)" {
  grep -qE '(docs/test-artifacts|\.gaia/artifacts/test-artifacts)/test-plan\.md' "$SKILLS_DIR/gaia-test-design/SKILL.md"
}

@test "AC3: gaia-edit-test-plan references test-plan.md (canonical post-AF-21-X)" {
  grep -qE '(docs/test-artifacts|\.gaia/artifacts/test-artifacts)/test-plan\.md' "$SKILLS_DIR/gaia-edit-test-plan/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC8 surrogate (per story Tasks 1.4/2.2/3.2): no Phase 3 Testing wire-in
# SKILL.md introduces the deprecated val_validate_output flag. For
# gaia-test-design, the prose Critical Rule bullet referencing the flag
# (line 33 in pre-wire-in snapshot) is also removed.
# ---------------------------------------------------------------------------

@test "AC2/AC3: no Phase 3 Testing SKILL.md mentions val_validate_output (frontmatter or prose)" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    ! grep -q 'val_validate_output' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC4 — Provenance and 3-iteration cap referenced in each wire-in
# ---------------------------------------------------------------------------

@test "AC4: each Phase 3 Testing skill references the canonical pattern (pattern provenance)" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -q 'Reuses the canonical pattern' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC4: each Phase 3 Testing skill defers to the canonical spec rather than duplicating it (decision provenance)" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -q 'cite this anchor' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC4: each Phase 3 Testing skill documents iteration counter (iteration = 1)" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -qE 'iteration[[:space:]]*=[[:space:]]*1' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC4: each Phase 3 Testing skill documents the 3-iteration cap" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -qE 'iteration[[:space:]]*<=[[:space:]]*3' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC4: each Phase 3 Testing skill cites the canonical Auto-Fix Loop Pattern anchor" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -q 'Auto-Fix Loop Pattern' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC6 / AC-EC3 — Artifact-existence guard
# ---------------------------------------------------------------------------

@test "AC-EC3 (AC6): each Phase 3 Testing skill includes an artifact-existence guard" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -qE 'if[[:space:]]+not[[:space:]]+exists' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC6 — Val-skill-availability guard with documented warning text
# ---------------------------------------------------------------------------

@test "AC-EC6: each Phase 3 Testing skill emits the canonical missing-Val warning" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -q 'Val auto-review unavailable' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC8 — YOLO hard-gate invariant; no bypass branch introduced
# ---------------------------------------------------------------------------

@test "AC-EC8: each Phase 3 Testing skill references the YOLO hard-gate invariant" {
  for skill in $PHASE3_TEST_SKILLS_LIST; do
    grep -qE 'YOLO' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# Loop placement — wire-in step appears AFTER the artifact-write step
#   AC1: gaia-readiness-check Val loop runs after Step 10 (Generate Gate
#        Report) and BEFORE Step 12 (Adversarial Review), preserving the
#        post-adversarial step order (renumbered 11 -> 12, 12 -> 13).
#   AC2: gaia-test-design Val loop runs after Step 7 (Generate Output) and
#        BEFORE Step 9 (Optional: Scaffold Test Framework, renumbered from 8).
#   AC3: gaia-edit-test-plan Val loop runs after Step 5 (Add Version Note
#        and Save) and BEFORE Step 7 (Next Steps, renumbered from 6).
# ---------------------------------------------------------------------------

@test "AC1 placement: gaia-readiness-check Val loop step appears after Step 10 (Generate Gate Report) and before Adversarial Review" {
  local skill="$SKILLS_DIR/gaia-readiness-check/SKILL.md"
  local write_line val_line adv_line
  write_line="$(grep -n '^### Step 10 — Generate Gate Report' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  adv_line="$(grep -n 'Adversarial Review' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ -n "$adv_line" ]
  [ "$val_line" -gt "$write_line" ]
  [ "$val_line" -lt "$adv_line" ]
}

@test "AC2 placement: gaia-test-design Val loop step appears after Step 7 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-test-design/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 7 -- Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "AC3 placement: gaia-edit-test-plan Val loop step appears after Step 5 (Add Version Note and Save)" {
  local skill="$SKILLS_DIR/gaia-edit-test-plan/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 5 — Add Version Note and Save' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

# ---------------------------------------------------------------------------
# Step renumbering invariants — keep vcp-cpt expectations and step counts
# in sync with the wire-in.
#   gaia-readiness-check: 12 -> 13 (Val inserted at Step 11; old 11/12 -> 12/13)
#   gaia-test-design:      8 ->  9 (Val inserted at Step 8;  old 8     -> 9)
#   gaia-edit-test-plan:   6 ->  7 (Val inserted at Step 6;  old 6     -> 7)
# ---------------------------------------------------------------------------

@test "step-count: gaia-readiness-check has 13 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-readiness-check/SKILL.md")
  [ "$count" = "13" ]
}

@test "step-count: gaia-test-design has 9 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ (--|—)' "$SKILLS_DIR/gaia-test-design/SKILL.md")
  [ "$count" = "9" ]
}

@test "step-count: gaia-edit-test-plan has 7 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ (--|—)' "$SKILLS_DIR/gaia-edit-test-plan/SKILL.md")
  [ "$count" = "7" ]
}

# ---------------------------------------------------------------------------
# Checkpoint emission — each new Val-loop step emits one
# write-checkpoint.sh invocation (E43-S2 wire-in convention) with
# stage=val-auto-review.
# ---------------------------------------------------------------------------

@test "checkpoint: gaia-readiness-check Val loop step emits one write-checkpoint.sh invocation at step 11" {
  grep -qE '^> `!(\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh gaia-readiness-check 11 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-readiness-check/SKILL.md"
}

@test "checkpoint: gaia-test-design Val loop step emits one write-checkpoint.sh invocation at step 8" {
  grep -qE '^> `!(\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh gaia-test-design 8 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-test-design/SKILL.md"
}

@test "checkpoint: gaia-edit-test-plan Val loop step emits one write-checkpoint.sh invocation at step 6" {
  grep -qE '^> `!(\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh gaia-edit-test-plan 6 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-edit-test-plan/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC5 (Task 4) — /gaia-val-validate SKILL.md documents the no-self-invoke
# invariant. This story does NOT alter the existing Iterative Re-Invocation
# subsection (E44-S1 owns that contract) — it only appends an explicit
# "/gaia-val-validate does NOT self-invoke" callout so downstream wire-ins
# cannot accidentally introduce recursion (AC5 / Task 4.3).
# ---------------------------------------------------------------------------

@test "AC5: gaia-val-validate SKILL.md retains the Iterative Re-Invocation subsection" {
  grep -qE '^### Iterative Re-Invocation' "$SKILLS_DIR/gaia-val-validate/SKILL.md"
}

@test "AC5: gaia-val-validate SKILL.md documents the no-self-invoke invariant (Task 4)" {
  # Phrasing: "does NOT self-invoke" — case-sensitive on the NOT to match the
  # canonical invariant text from sibling wire-in stories (E44-S3..S5) and
  # this story's Task 4.3.
  grep -q 'does NOT self-invoke' "$SKILLS_DIR/gaia-val-validate/SKILL.md"
}
