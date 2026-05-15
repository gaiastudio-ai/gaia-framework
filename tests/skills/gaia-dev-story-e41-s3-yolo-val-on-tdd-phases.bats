#!/usr/bin/env bats
# gaia-dev-story-e41-s3-yolo-val-on-tdd-phases.bats — E41-S3 declarative wire-up
#
# Validates the declarative surface and pause-free TDD preservation for
# /gaia-dev-story YOLO: Val on TDD phases (GR-DS-1).
#
# AC1: yolo_steps frontmatter declares 5, 6, 7 (extends E41-S4's [15])
# AC5 (TC-YOLO-14 dev-story partial): Steps 5/6/7 bodies remain pause-free
#      — sister to gaia-dev-story-step7b-val.bats #23/24/25 (E55-S4 / ADR-073).
# AC9: Steps 5, 6, 7 each carry a > [!yolo] body marker per §10.30.2.
#
# AC2/AC3/AC4/AC6/AC7/AC8 are satisfied by the existing Step 7b cumulative-diff
# Val-in-TDD pass (E55-S4 / ADR-073) and verified by step7b-val.bats — this
# story does NOT add per-phase Val dispatches inside Step 5/6/7 bodies because
# that would re-introduce pauses inside the TDD loop and violate the pause-free
# invariant. The declarative `yolo_steps:` surface registers TDD coverage; the
# actual dispatch is the post-Refactor single-pass Val per Step 7b.
#
# Usage: bats tests/skills/gaia-dev-story-e41-s3-yolo-val-on-tdd-phases.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
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

# ---------- AC1: declarative yolo_steps frontmatter ----------

@test "AC1: yolo_steps declares step 5" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b5\b[^]]*\]'
}

@test "AC1: yolo_steps declares step 6" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b6\b[^]]*\]'
}

@test "AC1: yolo_steps declares step 7" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b7\b[^]]*\]'
}

@test "AC1: yolo_steps preserves step 15 (E41-S4 coordination)" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b15\b[^]]*\]'
}

@test "AC1: yolo_steps does NOT declare step 14 (FR-YOLO-2(b) hard gate)" {
  ! frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b14\b[^]]*\]'
}

# ---------- AC5: pause-free TDD invariant (E55-S4 / ADR-073 / TC-DSH-12) ----------

@test "AC5: Step 5 body contains NO AskUserQuestion invocation" {
  ! step_body "Step 5" | grep -qE 'AskUserQuestion'
}

@test "AC5: Step 6 body contains NO AskUserQuestion invocation" {
  ! step_body "Step 6" | grep -qE 'AskUserQuestion'
}

@test "AC5: Step 7 body contains NO AskUserQuestion invocation" {
  ! step_body "Step 7" | grep -qE 'AskUserQuestion'
}

@test "AC5: Step 5/6/7 bodies contain NO HALT directives (pause-free TDD)" {
  # Match HALT case-sensitively to avoid false-firing on prose words like
  # "halted" lower-case. The pause-free contract uses uppercase HALT.
  ! step_body "Step 5" | grep -qE '\bHALT\b'
  ! step_body "Step 6" | grep -qE '\bHALT\b'
  ! step_body "Step 7" | grep -qE '\bHALT\b'
}

# ---------- AC9: > [!yolo] body markers at Steps 5, 6, 7 ----------

@test "AC9: Step 5 body declares a > [!yolo] body marker" {
  step_body "Step 5" | grep -qE '^>[[:space:]]*\[!yolo\]'
}

@test "AC9: Step 6 body declares a > [!yolo] body marker" {
  step_body "Step 6" | grep -qE '^>[[:space:]]*\[!yolo\]'
}

@test "AC9: Step 7 body declares a > [!yolo] body marker" {
  step_body "Step 7" | grep -qE '^>[[:space:]]*\[!yolo\]'
}

@test "AC9: Step 5/6/7 markers reference Step 7b cumulative-diff dispatch" {
  # The markers must explain that AC2/3/4/6/7/8 are satisfied by the
  # cumulative-diff post-Refactor pass at Step 7b (E55-S4), not by a per-phase
  # dispatch inserted into the TDD body.
  step_body "Step 5" | grep -qE 'Step 7b|cumulative'
  step_body "Step 6" | grep -qE 'Step 7b|cumulative'
  step_body "Step 7" | grep -qE 'Step 7b|cumulative'
}

# ---------- Step 7b machinery preserved (E55-S4 / ADR-073) ----------

@test "Step 7b machinery: post-Refactor Val pass is still wired" {
  grep -qE '^### Step 7b' "$SKILL_FILE"
  step_body "Step 7b" | grep -qE 'gaia-val-validate|Val.*validate'
}

@test "Step 7b machinery: 3-iteration cap is documented" {
  step_body "Step 7b" | grep -qE 'iteration[[:space:]]*<[[:space:]]*3|3-iteration cap'
}
