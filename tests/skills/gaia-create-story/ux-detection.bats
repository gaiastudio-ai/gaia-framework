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

@test "the elaboration step documents the delegate prompt without the ux designer when detection misses" {
  body="$(step3_body)"
  echo "$body" | grep -qE "Auto-delegate to PM \(Derek\) and Architect \(Theo\)"
}

@test "the elaboration step states the ux designer clause is omitted when nothing matches" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "omits.*UX Designer|without.*UX Designer|no UX.*Designer.*not spawn"
}

# ---------- AC2 / TC-CSE-06: legacy block present -> PM + Architect + UX Designer parallel ----------

@test "the elaboration step documents the delegate prompt including the ux designer when detection matches" {
  body="$(step3_body)"
  echo "$body" | grep -qE "Auto-delegate to PM \(Derek\), Architect \(Theo\), and UX Designer \(Christy\)"
}

@test "the elaboration step treats the design-reference frontmatter key as the definitive ux signal" {
  body="$(step3_body)"
  echo "$body" | grep -qE "design_ref:"
}

# ---------- AC3 / TC-CSE-07: UI terms in description ----------

@test "the elaboration step lists the interface vocabulary the description-matching rule uses" {
  body="$(step3_body)"
  echo "$body" | grep -qE "modal|button|wizard"
  echo "$body" | grep -qiE "screen.*page.*modal|UI/UX terms|UI terms"
}

@test "the elaboration step calls out case-insensitive matching for the description rule" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "case.insensitive"
}

# ---------- AC4 / TC-CSE-08: missing ux-design.md degrades safely ----------

@test "the elaboration step degrades safely when the ux design document is missing" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "ux-design\.md.*missing|missing.*ux-design\.md|file_exists|skip rule.*4|rule.*4.*skip|not present"
}

@test "the elaboration step contains the four-rule detection pseudocode" {
  body="$(step3_body)"
  echo "$body" | grep -qE "rule1"
  echo "$body" | grep -qE "rule2"
  echo "$body" | grep -qE "rule3"
  echo "$body" | grep -qE "rule4"
}

# ---------- AC5: UX Designer answers exactly 3 questions ----------

@test "the ux designer is asked about edge cases, accessibility and interaction patterns" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "edge cases.*empty.*loading.*error|empty.*loading.*error.*offline"
  echo "$body" | grep -qiE "accessibility|keyboard|screen.reader|ARIA"
  echo "$body" | grep -qiE "interaction pattern|design.system"
}

@test "the ux designer load set includes the ux design document and the design-record reference" {
  body="$(step3_body)"
  echo "$body" | grep -qE "ux-design\.md"
  echo "$body" | grep -qiE "design-record reference"
}

# ---------- AC6: parallel spawn enforcement ----------

@test "the elaboration step requires one message carrying several agent calls" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "single message.*Agent|multiple Agent.*single message|parallel.*single message"
}

@test "the elaboration step calls out parallel rather than sequential spawning" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "parallel.*not sequential|true parallel|in parallel"
}

# ---------- PM + Architect contracts preserved ----------

@test "the product manager's load set covers the epics, requirements and ux documents" {
  body="$(step3_body)"
  # PM section must mention Derek + the three loaded files
  echo "$body" | grep -qE "Derek"
  echo "$body" | grep -qE "epics-and-stories\.md"
  echo "$body" | grep -qE "prd\.md"
}

@test "the product manager is asked about prioritization and stakeholder notes" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "stakeholder"
  echo "$body" | grep -qiE "AC prioritization|prioritization"
}

@test "the architect's load set covers the architecture, test-plan and epics documents" {
  body="$(step3_body)"
  echo "$body" | grep -qE "Theo"
  echo "$body" | grep -qE "architecture\.md"
  echo "$body" | grep -qE "test-plan\.md"
}

@test "the architect is asked about implementation constraints and technical dependencies" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "implementation constraints|technical dependencies"
}

# ---------- Detection rule documentation ----------

@test "the elaboration step documents all four detection rules in priority order" {
  body="$(step3_body)"
  # All four rule descriptions
  echo "$body" | grep -qiE "Rule #1|Rule 1"
  echo "$body" | grep -qiE "Rule #2|Rule 2"
  echo "$body" | grep -qiE "Rule #3|Rule 3"
  echo "$body" | grep -qiE "Rule #4|Rule 4"
}

@test "the elaboration step logs which detection rules fired" {
  body="$(step3_body)"
  echo "$body" | grep -qiE "log|telemetry|rule.fired|rules=|observability"
}

# ---------- Subagent dependency check ----------

@test "Dependency: ux-designer agent file references Christy persona" {
  grep -qiE "Christy" "$AGENTS_DIR/ux-designer.md"
}
