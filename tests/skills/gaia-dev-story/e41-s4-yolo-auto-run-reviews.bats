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

@test "Pre-flight: the yolo-mode helper exists and defines the yolo predicate" {
  [ -f "$HELPER_FILE" ]
  grep -q '^is_yolo()' "$HELPER_FILE"
}

# ---------- AC5: declarative yolo_steps frontmatter ----------

@test "frontmatter declares the review-recording step as yolo-automatable" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b15\b[^]]*\]'
}

@test "frontmatter leaves the post-completion gate step out of the yolo-automatable set" {
  ! frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b14\b[^]]*\]'
}

# ---------- AC1: Step 16 dispatches /gaia-run-all-reviews under YOLO ----------

@test "the review-dispatch step consults the yolo-mode helper as the single source of truth" {
  step_body "Step 16" | grep -qE 'yolo-mode\.sh.*is_yolo'
}

@test "the review-dispatch step fires the all-reviews aggregator on the yolo branch" {
  step_body "Step 16" | grep -qiE 'gaia-run-all-reviews'
}

# ---------- AC2: non-YOLO regression preserved ----------

@test "the review-dispatch step is skipped entirely outside yolo mode" {
  step_body "Step 16" | grep -qiE 'SKIP Step 16|skip.*step.*16|non-yolo branch.*skip'
}

@test "the review-recording step carries no unconditional aggregator dispatch" {
  # Step 15 body must NOT invoke /gaia-run-all-reviews unconditionally —
  # the dispatch lives behind Step 16's YOLO gate.
  ! step_body "Step 15" | grep -qE '^[[:space:]]*-[[:space:]]*Run.*gaia-run-all-reviews'
}

# ---------- AC3: FAILED-verdict surfacing (ECI-503) ----------

@test "the review-dispatch step documents the review summary block in the final output" {
  step_body "Step 16" | grep -qE 'Review Summary'
}

@test "the review-dispatch step surfaces failed verdicts as an uppercase token" {
  step_body "Step 16" | grep -qE 'FAILED'
}

@test "the review-dispatch step references the composite blocked verdict" {
  step_body "Step 16" | grep -qiE 'BLOCKED|composite.*verdict|review-gate-check'
}

# ---------- AC4: dispatch-failure error path ----------

@test "the review-dispatch step documents the dispatch-failure fallback path" {
  # AC4 contract requires an explicit failure / error phrase that surfaces a
  # manual-fallback instruction. The existing 'Non-YOLO runs MUST NOT auto-fire
  # reviews — the user manually invokes' wording is the SKIP path, not the
  # YOLO-dispatch-failure path. Require the canonical error phrase.
  step_body "Step 16" | grep -qiE 'dispatch fail(ed|ure)?|aggregator (failed|unreachable|did not return)|YOLO.*dispatch.*fail'
}

# ---------- Step 14 hard-gate preservation (FR-YOLO-2(b)) ----------

@test "the post-completion gate step remains documented as a hard gate" {
  step_body "Step 14" | grep -qE 'verify-pr-merged|Post-Completion Gate|merge commit'
}

# ---------- > [!yolo] body marker (§10.30.2 declarative convention) ----------

@test "either review step declares the yolo body marker by convention" {
  # Either step may carry the marker; the convention says it lives in the body
  # where YOLO behavior is documented.
  {
    step_body "Step 15" | grep -qE '^>[[:space:]]*\[!yolo\]'
  } || {
    step_body "Step 16" | grep -qE '^>[[:space:]]*\[!yolo\]'
  }
}
