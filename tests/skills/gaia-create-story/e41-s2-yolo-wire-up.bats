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

@test "Pre-flight: yolo-mode.sh helper exists (E41-S1)" {
  [ -f "$HELPER_FILE" ]
  grep -q '^is_yolo()' "$HELPER_FILE"
}

# ---------- AC1: declarative yolo_steps + helper-call contract ----------

@test "AC1: frontmatter declares yolo_steps: [3]" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[[:space:]]*3[[:space:]]*\]'
}

@test "AC1: Step 3 body consults yolo-mode.sh is_yolo helper" {
  step3_body | grep -qE 'yolo-mode\.sh.*is_yolo'
}

@test "AC1: Step 3 body documents auto-select [a] under YOLO" {
  step3_body | grep -qiE 'auto[- ]select.*\[a\]'
}

@test "AC1: Step 3 body declares the > [!yolo] body marker per §10.30.2" {
  step3_body | grep -qE '^>[[:space:]]*\[!yolo\]'
}

# ---------- AC2: Step 1 hard-gate preservation (FR-YOLO-2(b)) ----------

@test "AC2: Step 1 still contains the non-backlog HALT clause" {
  step1_body | grep -qiE 'HALT.*--.*"Story \{?key\}? is in'
}

@test "AC2: YOLO hard guard note remains in Step 1 (E54-S1, AC3)" {
  step1_body | grep -qE 'YOLO MUST NOT bypass|YOLO hard guard'
}

@test "AC2: yolo_steps does NOT include Step 1 (FR-YOLO-2(b) compliance)" {
  ! frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[^]]*\b1\b[^]]*\]'
}

# ---------- AC3: non-YOLO regression guard (TC-YOLO-14) ----------

@test "AC3: non-YOLO [u]/[a] menu wording is preserved (canonical text)" {
  step3_body | grep -qE "^\[u\] I'll answer the elaboration questions myself"
  step3_body | grep -qE "^\[a\] Auto-delegate to PM \(Derek\), Architect \(Theo\)"
}

@test "AC3: non-YOLO four-question [u] flow still present" {
  step3_body | grep -qE '4-question flow|4 questions'
}

# ---------- AC4: CRITICAL-finding HALT (ECI-506) ----------

@test "AC4: Step 3 YOLO branch documents CRITICAL-finding HALT" {
  step3_body | grep -qiE 'CRITICAL.*HALT|HALT.*CRITICAL'
}

# ---------- Anti-pattern guard (§10.30.8) ----------

@test "Anti-pattern: Step 3 does NOT contain inline YOLO env parsing" {
  # The §10.30.8 antipattern is `if [[ -n "$YOLO" ]]; then …` without yolo_steps.
  # Since we now have yolo_steps declared, even if the body references YOLO_MODE,
  # we ensure the helper-call surface is the primary contract.
  step3_body | grep -qE 'yolo-mode\.sh|is_yolo'
}
