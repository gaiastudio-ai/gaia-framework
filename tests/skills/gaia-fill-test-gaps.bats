#!/usr/bin/env bats
# gaia-fill-test-gaps.bats — fill-test-gaps skill structural tests (E49-S2)
#
# Validates:
#   AC1: Severity-filter prompt appears in Step 2 for normal mode
#   AC2: YOLO mode auto-applies default (critical+high) without prompting
#   AC3: Inline gap-triage rule table in Step 4 (6 rows, ADR-039 §10.22.8.2)
#   AC4: sprint-status.yaml fallback warning emitted when story file missing
#   AC5: Perf-budget note rendered before Step 6 when row count exceeds threshold
#
# Usage:
#   bats tests/skills/gaia-fill-test-gaps.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SKILL_DIR="$SKILLS_DIR/gaia-fill-test-gaps"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"
}

# ---------- Baseline structural checks ----------

@test "SKILL.md exists at gaia-fill-test-gaps skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "SKILL.md has YAML frontmatter delimiters" {
  head -1 "$SKILL_FILE" | grep -q "^---$"
  awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$SKILL_FILE"
}

@test "SKILL.md frontmatter contains name: gaia-fill-test-gaps" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^name: gaia-fill-test-gaps"
}

# ---------- AC1: Severity prompt in normal mode ----------

@test "AC1: Step 2 declares an interactive severity-filter prompt for normal mode" {
  # Step 2 must mention prompting for severity in normal (non-YOLO) mode
  awk '/^### Step 2/,/^### Step 3/' "$SKILL_FILE" | \
    grep -qiE "prompt.*severity|severity.*prompt"
}

@test "AC1: Step 2 prompt advertises default critical+high" {
  awk '/^### Step 2/,/^### Step 3/' "$SKILL_FILE" | \
    grep -qE "critical\+high|critical \+ high|critical, high"
}

@test "AC1: Step 2 lists severity options critical/high/medium/all" {
  body="$(awk '/^### Step 2/,/^### Step 3/' "$SKILL_FILE")"
  echo "$body" | grep -qi "critical"
  echo "$body" | grep -qi "high"
  echo "$body" | grep -qi "medium"
  echo "$body" | grep -qi "\\ball\\b"
}

@test "AC1: Step 2 documents --severity flag precedence over prompt" {
  awk '/^### Step 2/,/^### Step 3/' "$SKILL_FILE" | \
    grep -qE "\\-\\-severity.*precedence|precedence.*--severity|explicit.*--severity|--severity.*provided"
}

# ---------- AC2: YOLO mode auto-apply ----------

@test "AC2: Step 2 specifies YOLO auto-applies default without prompting" {
  awk '/^### Step 2/,/^### Step 3/' "$SKILL_FILE" | \
    grep -qiE "yolo.*auto|auto.*yolo|yolo mode.*default|yolo.*skip.*prompt"
}

@test "AC2: SKILL.md documents the severity-gated triage contract" {
  grep -qiE "severity|CRITICAL|gate" "$SKILL_FILE"
}

# ---------- AC3: Inline rule table in Step 4 ----------

@test "AC3: Step 4 contains an inline rule table (markdown table syntax)" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qE "^[[:space:]]*\|.*gap_type.*\|.*story_status.*\|"
}

@test "AC3: Inline table row for uncovered-ac (pipe-delimited)" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qE "^[[:space:]]*\\|.*uncovered-ac.*\\|.*append_ac.*\\|"
}

@test "AC3: Inline table row for missing-test (pipe-delimited)" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qE "^[[:space:]]*\\|.*missing-test.*\\|.*new_story.*\\|"
}

@test "AC3: Inline table row for missing-edge-case (pipe-delimited)" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qE "^[[:space:]]*\\|.*missing-edge-case.*\\|.*append_edge_case.*\\|"
}

@test "AC3: Inline table row for unexecuted (pipe-delimited)" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qE "^[[:space:]]*\\|.*unexecuted.*\\|.*expand_automation.*\\|"
}

@test "AC3: Inline table row for in-progress/review/blocked skip (pipe-delimited)" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qiE "^[[:space:]]*\\|.*in-progress.*\\|.*skip.*\\|"
}

@test "AC3: Inline table row for unknown gap_type skip (pipe-delimited)" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qE "^[[:space:]]*\\|.*unknown.*\\|.*skip.*\\|"
}

@test "AC3: Step 4 applies the remediation rule table" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qiE "rule table|gap-triage-rules|remediation"
}

@test "AC3: Runtime gap-triage-rules.js retained as source of truth" {
  grep -q "scripts/lib/gap-triage-rules.js" "$SKILL_FILE"
}

# ---------- AC4: Sprint-status.yaml fallback warning ----------

@test "AC4: Step 4 declares sprint-status.yaml fallback path before skip" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qE "sprint-status\\.yaml.*fallback|fallback.*sprint-status\\.yaml"
}

@test "AC4: Fallback warning text matches required format" {
  awk '/^### Step 4/,/^### Step 5/' "$SKILL_FILE" | \
    grep -qE "WARNING: Story file not found for .* falling back to sprint-status\\.yaml"
}

@test "AC4: Sprint-status.yaml read-only safety rule re-asserted" {
  grep -qiE "sprint-status\\.yaml is NEVER written|never write.*sprint-status|read-only.*sprint-status|sprint-status.*read-only" "$SKILL_FILE"
}

# ---------- AC5: Perf-budget note ----------

@test "AC5: Perf-budget note threshold constant declared" {
  grep -qE "PERF_BUDGET_THRESHOLD|perf-budget threshold|perf_budget_threshold" "$SKILL_FILE"
}

@test "AC5: Threshold default is 20 rows" {
  grep -qE "20[- ]row|threshold.*20|20.*threshold|default.*20" "$SKILL_FILE"
}

@test "AC5: Perf-budget warning text format documented" {
  grep -qE "Perf-budget note: .* remediation rows exceed the .*-row threshold" "$SKILL_FILE"
}

@test "AC5: Perf-budget note emitted between Step 5 and Step 6" {
  # The perf-budget note should be documented in Step 5 close or Step 6 start
  awk '/^### Step 5/,/^### Step 7/' "$SKILL_FILE" | \
    grep -qE "Perf-budget note|perf-budget note"
}

# ---------- Setup/finalize integrity ----------

@test "setup.sh exists and is executable" {
  [ -x "$SETUP_SCRIPT" ]
}

@test "finalize.sh exists and is executable" {
  [ -x "$FINALIZE_SCRIPT" ]
}
