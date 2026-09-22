#!/usr/bin/env bats
# e41-s2-yolo-wire-up.bats — E41-S2 declarative yolo_steps:[3] wire-up
#
# Validates the four ACs of /gaia-create-story YOLO wire-up (GR-CS-6):
#   AC1 (TC-YOLO-5):  yolo_steps: [3] declared in SKILL.md frontmatter; Step 3
#                      consults yolo-mode.sh is_yolo as the canonical signal.
#   AC2 (TC-YOLO-6):  Step 1 non-backlog status HALT preserved unconditionally.
#                      YOLO does NOT bypass the hard gate (FR-YOLO-2(b)).
#   AC3 (TC-YOLO-14): Non-YOLO routing-prompt wording is byte-identical to
#                      the pre-E41 baseline — the [u]/[a] menu text is preserved.
#   AC4 (ECI-506):    CRITICAL-finding HALT note present in the Step 3 YOLO
#                      branch.
#
# Usage: bats tests/skills/gaia-create-story/e41-s2-yolo-wire-up.bats
# Dependencies: bats-core 1.10+, awk, grep

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-create-story/SKILL.md"
  HELPER_FILE="$REPO_ROOT/plugins/gaia/scripts/yolo-mode.sh"
}

# Extract the YAML frontmatter block (between the first two `---` lines).
frontmatter() {
  awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2) exit; next} n==1' "$SKILL_FILE"
}

# Extract the body of Step 3 (stops at the next ### Step heading).
step3_body() {
  awk '
    /^### Step 3 -- Elaborate Story/ { capture=1; next }
    /^### Step / && capture { exit }
    capture { print }
  ' "$SKILL_FILE"
}

# Extract the body of Step 1 (stops at the next ### Step heading).
step1_body() {
  awk '
    /^### Step 1 -- Select Story/ { capture=1; next }
    /^### Step / && capture { exit }
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

# ---------- AC1: declarative yolo_steps + helper-call contract ----------

@test "frontmatter declares the elaboration step as the only yolo-automatable step" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[[:space:]]*3[[:space:]]*\]'
}

@test "the elaboration step consults the yolo-mode helper" {
  step3_body | grep -qE 'yolo-mode\.sh.*is_yolo'
}

@test "the elaboration step documents auto-selecting the delegate option under yolo" {
  step3_body | grep -qiE 'auto[- ]select.*\[a\]'
}

@test "the elaboration step declares the yolo body marker by convention" {
  step3_body | grep -qE '^>[[:space:]]*\[!yolo\]'
}

# ---------- AC2: Step 1 hard-gate preservation (FR-YOLO-2(b)) ----------

@test "the story-selection step still halts on a story that is not in backlog" {
  step1_body | grep -qiE 'HALT.*--.*"Story \{?key\}? is in'
}

@test "the story-selection step keeps its note that yolo must not bypass the hard guard" {
  step1_body | grep -qE 'YOLO MUST NOT bypass|YOLO hard guard'
}

@test "frontmatter leaves the story-selection step out of the yolo-automatable set" {
  ! frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b1\b[^]]*\]'
}

# ---------- AC3: non-YOLO regression guard (TC-YOLO-14) ----------

@test "the interactive routing menu keeps its canonical answer-myself and delegate wording" {
  step3_body | grep -qE "^\[u\] I'll answer the elaboration questions myself"
  step3_body | grep -qE "^\[a\] Auto-delegate to PM \(Derek\), Architect \(Theo\)"
}

@test "the interactive answer-myself path still documents its four-question flow" {
  step3_body | grep -qE '4-question flow|4 questions'
}

# ---------- AC4: CRITICAL-finding HALT (ECI-506) ----------

@test "the elaboration step halts on a critical finding even under yolo" {
  step3_body | grep -qiE 'CRITICAL.*HALT|HALT.*CRITICAL'
}

# ---------- Anti-pattern guard (§10.30.8) ----------

@test "the elaboration step routes yolo detection through the helper rather than parsing the environment inline" {
  # The §10.30.8 antipattern is `if [[ -n "$YOLO" ]]; then …` without yolo_steps.
  # Since we now have yolo_steps declared, even if the body references YOLO_MODE,
  # we ensure the helper-call surface is the primary contract.
  step3_body | grep -qE 'yolo-mode\.sh|is_yolo'
}
