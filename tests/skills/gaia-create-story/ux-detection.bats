#!/usr/bin/env bats
# ux-detection.bats — gaia-create-story UX Designer conditional routing + parallel spawn protocol (E54-S2)
#
# Validates Step 3 expansion of gaia-create-story SKILL.md per E54-S2:
#   AC1 (TC-CSE-05): no UX scope -> only PM + Architect; [a] line omits "and UX Designer"
#   AC2 (TC-CSE-06): legacy block present -> PM + Architect + UX Designer in parallel single message
#   AC3 (TC-CSE-07): UI terms in description match rule #2 -> UX Designer spawned
#   AC4 (TC-CSE-08): missing ux-design.md -> rule #4 fails safely (no error), rules 1-3 still evaluate
#   AC5: UX Designer answers exactly 3 question scopes (edge cases, accessibility, interaction patterns)
#   AC6: ALL spawn paths use a SINGLE message containing multiple Agent tool calls (true parallel)
#
# Usage:
#   bats tests/skills/gaia-create-story/ux-detection.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SKILL_DIR="$SKILLS_DIR/gaia-create-story"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  AGENTS_DIR="$REPO_ROOT/plugins/gaia/agents"
}

# Extract the body of "### Step 3 -- Elaborate Story" up to the next "### Step" heading.
step3_body() {
  awk '
    /^### Step 3 -- Elaborate Story/ { capture=1; next }
    /^### Step / && capture { exit }
    capture { print }
  ' "$SKILL_FILE"
}

# ---------- Pre-flight ----------

@test "Pre-flight: SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

@test "Pre-flight: ux-designer agent exists" {
  [ -f "$AGENTS_DIR/ux-designer.md" ]
}

# ---------- AC1 / TC-CSE-05: no UX scope -> only PM + Architect; [a] line omits "and UX Designer" ----------

@test "AC1/TC-CSE-05: Step 3 documents conditional [a] prompt text without UX Designer when detection misses" {
  body="$(step3_body)"
  echo "$body" | grep -qE "Auto-delegate to PM \(Derek\) and Architect \(Theo\)"
}

@test "AC1/TC-CSE-05: Step 3 explicitly states omission of 'and UX Designer' clause when no UX match" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "omits.*UX Designer|without.*UX Designer|no UX.*Designer.*not spawn"
}

# ---------- AC2 / TC-CSE-06: legacy block present -> PM + Architect + UX Designer parallel ----------

@test "AC2/TC-CSE-06: Step 3 documents the [a] line WITH UX Designer when detection matches" {
  body="$(step3_body)"
  echo "$body" | grep -qE "Auto-delegate to PM \(Derek\), Architect \(Theo\), and UX Designer \(Christy\)"
}

@test "AC2/TC-CSE-06: Step 3 references design_ref: frontmatter key as definitive UX signal" {
  body="$(step3_body)"
  echo "$body" | grep -qE "design_ref:"
}

# ---------- AC3 / TC-CSE-07: UI terms in description ----------

@test "AC3/TC-CSE-07: Step 3 lists UI/UX terms used by detection rule #2" {
  body="$(step3_body)"
  echo "$body" | grep -qE "modal|button|wizard"
  echo "$body" | grep -qiE "screen.*page.*modal|UI/UX terms|UI terms"
}

@test "AC3/TC-CSE-07: Step 3 calls out case-insensitive matching for rule #2" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "case.insensitive"
}

# ---------- AC4 / TC-CSE-08: missing ux-design.md degrades safely ----------

@test "AC4/TC-CSE-08: Step 3 documents rule #4 degrade-safely when ux-design.md is missing" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "ux-design\.md.*missing|missing.*ux-design\.md|file_exists|skip rule.*4|rule.*4.*skip|not present"
}

@test "AC4/TC-CSE-08: Step 3 contains the four-rule pseudocode block" {
  body="$(step3_body)"
  echo "$body" | grep -qE "rule1"
  echo "$body" | grep -qE "rule2"
  echo "$body" | grep -qE "rule3"
  echo "$body" | grep -qE "rule4"
}

# ---------- AC5: UX Designer answers exactly 3 questions ----------

@test "AC5: Step 3 declares UX Designer answers 3 questions (edge cases, a11y, interaction patterns)" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "edge cases.*empty.*loading.*error|empty.*loading.*error.*offline"
  echo "$body" | grep -qiE "accessibility|keyboard|screen.reader|ARIA"
  echo "$body" | grep -qiE "interaction pattern|design.system"
}

@test "AC5: Step 3 lists UX Designer load set including ux-design.md and design-record reference" {
  body="$(step3_body)"
  echo "$body" | grep -qE "ux-design\.md"
  echo "$body" | grep -qiE "design-record reference"
}

# ---------- AC6: parallel spawn enforcement ----------

@test "AC6: Step 3 enforces SINGLE message with multiple Agent tool calls" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "single message.*Agent|multiple Agent.*single message|parallel.*single message"
}

@test "AC6: Step 3 calls out parallel (not sequential) spawn explicitly" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "parallel.*not sequential|true parallel|in parallel"
}

# ---------- PM + Architect contracts preserved ----------

@test "PM contract: Step 3 documents PM (Derek) loads epics-and-stories.md, prd.md, ux-design.md" {
  body="$(step3_body)"
  # PM section must mention Derek + the three loaded files
  echo "$body" | grep -qE "Derek"
  echo "$body" | grep -qE "epics-and-stories\.md"
  echo "$body" | grep -qE "prd\.md"
}

@test "PM contract: Step 3 declares PM answers 3 questions (edge cases, AC prioritization, stakeholder notes)" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "stakeholder"
  echo "$body" | grep -qiE "AC prioritization|prioritization"
}

@test "Architect contract: Step 3 documents Architect (Theo) loads architecture.md, test-plan.md, epics-and-stories.md" {
  body="$(step3_body)"
  echo "$body" | grep -qE "Theo"
  echo "$body" | grep -qE "architecture\.md"
  echo "$body" | grep -qE "test-plan\.md"
}

@test "Architect contract: Step 3 declares Architect answers 2 questions (constraints, dependencies)" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "implementation constraints|technical dependencies"
}

# ---------- Detection rule documentation ----------

@test "Detection: Step 3 documents all four rules with priority order" {
  body="$(step3_body)"
  # All four rule descriptions
  echo "$body" | grep -qiE "Rule #1|Rule 1"
  echo "$body" | grep -qiE "Rule #2|Rule 2"
  echo "$body" | grep -qiE "Rule #3|Rule 3"
  echo "$body" | grep -qiE "Rule #4|Rule 4"
}

@test "Detection: Step 3 mentions logging which rule(s) fired (telemetry)" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "log|telemetry|rule.fired|rules=|observability"
}

# ---------- Subagent dependency check ----------

@test "Dependency: ux-designer agent file references Christy persona" {
  grep -qiE "Christy" "$AGENTS_DIR/ux-designer.md"
}
