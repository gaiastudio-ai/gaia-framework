#!/usr/bin/env bats
# e41-s4-yolo-auto-run-reviews.bats — E41-S4 /gaia-dev-story YOLO Step-15/16 wire-up
#
# Validates the five ACs of /gaia-dev-story YOLO auto-run-reviews (GR-DS-2):
#   AC1 (TC-YOLO-9):  Under YOLO, /gaia-run-all-reviews dispatched after Step 15.
#                      The dispatch lives at Step 16 per E55-S8 prior split.
#   AC2 (TC-YOLO-14): Non-YOLO regression preserved — Step 15 unchanged; Step 16
#                      explicitly SKIPs when is_yolo returns non-zero.
#   AC3 (ECI-503):    Final summary surfaces ALL FAILED verdicts via a
#                      ## Review Summary block. FAILED token UPPERCASE.
#                      Composite BLOCKED surfaced prominently on any FAILED.
#   AC4:              Dispatch-failure error path documented; user gets the
#                      manual-fallback message and Review Gate stays UNVERIFIED.
#   AC5:              `yolo_steps: [15]` declared; Step 14 NOT in yolo_steps
#                      (FR-YOLO-2(b) hard-gate preservation).
#
# Usage: bats tests/skills/gaia-dev-story/e41-s4-yolo-auto-run-reviews.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/SKILL.md"
  HELPER_FILE="$REPO_ROOT/plugins/gaia/scripts/yolo-mode.sh"
}

frontmatter() {
  awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2) exit; next} n==1' "$SKILL_FILE"
}

step_body() {
  local header="$1"
  awk -v hdr="$header" '
    $0 ~ "^### " hdr "($|[^A-Za-z0-9])" { capture=1; next }
    /^### Step / && capture { exit }
    /^## [^#]/ && capture { exit }
    capture { print }
  ' "$SKILL_FILE"
}

# ---------- Pre-flight ----------

@test "Pre-flight: SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

@test "Pre-flight: yolo-mode.sh helper exists (E41-S1)" {
  [ -f "$HELPER_FILE" ]
  grep -q '^is_yolo()' "$HELPER_FILE"
}

# ---------- AC5: declarative yolo_steps frontmatter ----------

@test "AC5: frontmatter declares yolo_steps with 15 included" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b15\b[^]]*\]'
}

@test "AC5: yolo_steps does NOT include 14 (FR-YOLO-2(b) hard gate)" {
  ! frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b14\b[^]]*\]'
}

# ---------- AC1: Step 16 dispatches /gaia-run-all-reviews under YOLO ----------

@test "AC1: Step 16 invokes yolo-mode.sh is_yolo as the single source of truth" {
  step_body "Step 16" | grep -qE 'yolo-mode\.sh.*is_yolo'
}

@test "AC1: Step 16 dispatches gaia-run-all-reviews on the YOLO branch" {
  step_body "Step 16" | grep -qiE 'gaia-run-all-reviews'
}

# ---------- AC2: non-YOLO regression preserved ----------

@test "AC2: Step 16 SKIPs entirely on non-YOLO (is_yolo non-zero branch)" {
  step_body "Step 16" | grep -qiE 'SKIP Step 16|skip.*step.*16|non-yolo branch.*skip'
}

@test "AC2: Step 15 body does NOT contain an unconditional aggregator dispatch" {
  # Step 15 body must NOT invoke /gaia-run-all-reviews unconditionally —
  # the dispatch lives behind Step 16's YOLO gate.
  ! step_body "Step 15" | grep -qE '^[[:space:]]*-[[:space:]]*Run.*gaia-run-all-reviews'
}

# ---------- AC3: FAILED-verdict surfacing (ECI-503) ----------

@test "AC3: Step 16 documents the ## Review Summary block" {
  step_body "Step 16" | grep -qE 'Review Summary'
}

@test "AC3: Step 16 documents FAILED-token surfacing (uppercase grep-friendly)" {
  step_body "Step 16" | grep -qE 'FAILED'
}

@test "AC3: Step 16 references the composite BLOCKED verdict" {
  step_body "Step 16" | grep -qiE 'BLOCKED|composite.*verdict|review-gate-check'
}

# ---------- AC4: dispatch-failure error path ----------

@test "AC4: Step 16 documents the dispatch-failure error path" {
  # AC4 contract requires an explicit failure / error phrase that surfaces a
  # manual-fallback instruction. The existing 'Non-YOLO runs MUST NOT auto-fire
  # reviews — the user manually invokes' wording is the SKIP path, not the
  # YOLO-dispatch-failure path. Require the canonical error phrase.
  step_body "Step 16" | grep -qiE 'dispatch fail(ed|ure)?|aggregator (failed|unreachable|did not return)|YOLO.*dispatch.*fail'
}

# ---------- Step 14 hard-gate preservation (FR-YOLO-2(b)) ----------

@test "AC5: Step 14 Post-Completion Gate remains in the SKILL.md (hard gate)" {
  step_body "Step 14" | grep -qE 'verify-pr-merged|Post-Completion Gate|merge commit'
}

# ---------- > [!yolo] body marker (§10.30.2 declarative convention) ----------

@test "AC1/§10.30.2: Step 15 or Step 16 declares a > [!yolo] body marker" {
  # Either step may carry the marker; the convention says it lives in the body
  # where YOLO behavior is documented.
  {
    step_body "Step 15" | grep -qE '^>[[:space:]]*\[!yolo\]'
  } || {
    step_body "Step 16" | grep -qE '^>[[:space:]]*\[!yolo\]'
  }
}
