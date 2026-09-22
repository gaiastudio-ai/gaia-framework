#!/usr/bin/env bats
# edge-case-pipeline.bats — gaia-create-story Steps 3b/3c/3d V1 edge-case pipeline restoration (E54-S4)
#
# Validates that SKILL.md documents the restored V1 edge-case pipeline:
#   AC1 (TC-CSE-13): edge-cases skill failure -> edge_case_results=[], warning logged, Step 3c proceeds
#   AC2 (TC-CSE-14): primary AC count drift -> append aborted, warning logged, ACs unchanged
#   AC3 (TC-CSE-15): re-run dedup by (story_key, scenario) pair -> no duplicate TC IDs
#   AC4 (TC-CSE-16): size:S story -> Step 3b skipped (skip-log line)
#   AC5 (TC-CSE-17): >8K token edge-case set -> truncation order respected, telemetry logged
#   AC6:            YOLO mode compatibility -> non-interactive, same output as non-YOLO
#
# Usage:
#   bats tests/skills/gaia-create-story/edge-case-pipeline.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SKILL_DIR="$SKILLS_DIR/gaia-create-story"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  EDGE_CASES_SKILL="$SKILLS_DIR/edge-cases/SKILL.md"
  # Steps 3c and 3d delegate their behaviour to these two scripts; the step
  # bodies now point at them instead of restating the rules in prose. The
  # scripts are where the contract actually lives, so that is what we assert.
  APPEND_ACS="$SKILL_DIR/scripts/append-edge-case-acs.sh"
  APPEND_TESTS="$SKILL_DIR/scripts/append-edge-case-tests.sh"
}

# Extract the body of a numbered step section by header text.
# Stops at the next "### Step " heading.
step_body() {
  local header="$1"
  awk -v hdr="$header" '
    $0 ~ "^### " hdr "($|[^A-Za-z0-9])" { capture=1; next }
    /^### Step / && capture { exit }
    capture { print }
  ' "$SKILL_FILE"
}

# ---------- Pre-flight ----------

@test "Pre-flight: SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

@test "Pre-flight: edge-cases skill exists (dependency)" {
  [ -f "$EDGE_CASES_SKILL" ]
}

# ---------- Step ordering ----------

@test "Ordering: Step 3b appears between Step 3 and Step 4" {
  step3_line=$(grep -n '^### Step 3 -- Elaborate Story' "$SKILL_FILE" | head -1 | cut -d: -f1)
  step3b_line=$(grep -n '^### Step 3b' "$SKILL_FILE" | head -1 | cut -d: -f1)
  step4_line=$(grep -n '^### Step 4 ' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$step3_line" ] && [ -n "$step3b_line" ] && [ -n "$step4_line" ]
  [ "$step3_line" -lt "$step3b_line" ]
  [ "$step3b_line" -lt "$step4_line" ]
}

@test "Ordering: Step 3c appears between Step 3b and Step 4" {
  step3b_line=$(grep -n '^### Step 3b' "$SKILL_FILE" | head -1 | cut -d: -f1)
  step3c_line=$(grep -n '^### Step 3c' "$SKILL_FILE" | head -1 | cut -d: -f1)
  step4_line=$(grep -n '^### Step 4 ' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$step3b_line" ] && [ -n "$step3c_line" ] && [ -n "$step4_line" ]
  [ "$step3b_line" -lt "$step3c_line" ]
  [ "$step3c_line" -lt "$step4_line" ]
}

@test "Ordering: Step 3d appears between Step 3c and Step 4" {
  step3c_line=$(grep -n '^### Step 3c' "$SKILL_FILE" | head -1 | cut -d: -f1)
  step3d_line=$(grep -n '^### Step 3d' "$SKILL_FILE" | head -1 | cut -d: -f1)
  step4_line=$(grep -n '^### Step 4 ' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$step3c_line" ] && [ -n "$step3d_line" ] && [ -n "$step4_line" ]
  [ "$step3c_line" -lt "$step3d_line" ]
  [ "$step3d_line" -lt "$step4_line" ]
}

# ---------- AC4 / TC-CSE-16: size:S skip ----------

@test "the edge-case analysis step documents skipping small stories and logging the skip" {
  body="$(step_body 'Step 3b')"
  echo "$body" | grep -qiE 'size.*=.*"?S"?|SIZE.*=.*"?S"?'
  echo "$body" | grep -qE 'edge_case_skip'
}

# ---------- AC1 / TC-CSE-13: edge-cases skill failure ----------

@test "the edge-case analysis step documents invoking the edge-cases skill just in time" {
  body="$(step_body 'Step 3b')"
  echo "$body" | grep -qiE 'edge-cases|gaia:edge-cases'
  echo "$body" | grep -qiE 'JIT|skill tool|invoke'
}

@test "the edge-case analysis step degrades to an empty result set with a warning and continues" {
  body="$(step_body 'Step 3b')"
  echo "$body" | grep -qE 'edge_case_results.*=.*\[\]|edge_case_results.*=.*empty'
  echo "$body" | grep -qiE 'warning|warn|failed|reason='
  echo "$body" | grep -qiE 'continue|proceed.*Step 3c'
}

# ---------- AC5 / TC-CSE-17: token cap + truncation order ----------

@test "the edge-case analysis step documents its token budget cap" {
  body="$(step_body 'Step 3b')"
  echo "$body" | grep -qE '8K|8000|8 ?K'
  echo "$body" | grep -qiE 'NFR-042|token budget|token.*cap'
}

@test "the edge-case analysis step documents the truncation order across categories" {
  body="$(step_body 'Step 3b')"
  # Must mention all three priority groups in the documented order
  echo "$body" | grep -qiE 'boundary.*error.*security'
  echo "$body" | grep -qiE 'concurrency|timing'
  echo "$body" | grep -qiE 'data.*integration.*environment|integration.*environment'
}

@test "the edge-case analysis step documents its token-usage telemetry log" {
  body="$(step_body 'Step 3b')"
  echo "$body" | grep -qE 'edge_case_token_usage'
}

# ---------- Output schema ----------

@test "Step 3b documents edge_case_results output structure with required fields" {
  body="$(step_body 'Step 3b')"
  echo "$body" | grep -qE 'edge_case_results'
  # All five required fields per edge-cases output schema
  echo "$body" | grep -qiE 'id|EC-1'
  echo "$body" | grep -qE 'scenario'
  echo "$body" | grep -qE 'category'
}

# ---------- AC2 / TC-CSE-14: primary AC drift safety ----------

# Step 3c delegates the append to append-edge-case-acs.sh, so these exercise
# the script rather than the step prose that now just points at it.

# Writes a two-primary-criterion story fixture and echoes its path.
_ac_fixture() {
  local f="$BATS_TEST_TMPDIR/story.md"
  cat > "$f" <<'MD'
# Story

## Acceptance Criteria

- [ ] AC1: primary one
- [ ] AC2: primary two

## Tasks
MD
  printf '%s' "$f"
}

@test "the criterion-append step generates the edge-case criterion numbering format" {
  f="$(_ac_fixture)"
  run "$APPEND_ACS" --file "$f" \
    --edge-cases '[{"id":"EC-1","scenario":"empty input","input":"nothing","expected":"warns","category":"boundary","severity":"medium"}]'
  [ "$status" -eq 0 ]
  grep -qE '^- \[ \] AC-EC1: Given nothing, when empty input, then warns$' "$f"
}

@test "the criterion-append step appends after the primary criteria and leaves them immutable" {
  f="$(_ac_fixture)"
  run "$APPEND_ACS" --file "$f" \
    --edge-cases '[{"id":"EC-1","scenario":"empty input","input":"nothing","expected":"warns","category":"boundary","severity":"medium"}]'
  [ "$status" -eq 0 ]
  # Primary criteria survive byte-identically.
  grep -qE '^- \[ \] AC1: primary one$' "$f"
  grep -qE '^- \[ \] AC2: primary two$' "$f"
  # The generated entry lands after the last primary criterion.
  ac2_line=$(grep -n '^- \[ \] AC2:' "$f" | head -1 | cut -d: -f1)
  ec_line=$(grep -n '^- \[ \] AC-EC1:' "$f" | head -1 | cut -d: -f1)
  [ -n "$ac2_line" ] && [ -n "$ec_line" ]
  [ "$ac2_line" -lt "$ec_line" ]
}

@test "the criterion-append step aborts and reverts when a primary criterion drifts" {
  f="$(_ac_fixture)"
  before="$(cat "$f")"
  # The script's fault-injection hook mutates a primary criterion between the
  # pre- and post-append hash, which is exactly the drift it must catch.
  run env GAIA_APPEND_EC_FAULT_INJECT_MUTATE_PRIMARY=1 "$APPEND_ACS" --file "$f" \
    --edge-cases '[{"id":"EC-1","scenario":"x","input":"i","expected":"e","category":"boundary","severity":"low"}]'
  [[ "$output" == *"drift detected"* ]]
  # Reverted atomically — the file is byte-identical to its pre-run state.
  [ "$(cat "$f")" = "$before" ]
}

# ---------- AC3 / TC-CSE-15: dedup ----------

@test "the test-plan append step resolves its target through the planning-artifacts config key" {
  body="$(step_body 'Step 3d')"
  echo "$body" | grep -qE 'test-plan\.md'
  # The target is resolved via the config key the rest of the framework uses,
  # rather than a hard-coded tree literal that a future move would strand.
  echo "$body" | grep -qE 'planning_artifacts'
}

@test "the test-plan append step warns without blocking when the test plan is missing" {
  body="$(step_body 'Step 3d')"
  echo "$body" | grep -qiE 'non.blocking|missing|not.*exist|warn'
}

@test "the test-plan append step locates the story's section by heading match" {
  plan="$BATS_TEST_TMPDIR/test-plan.md"
  cat > "$plan" <<'MD'
# Test Plan

## E1-S1

| # | Scenario | Type | Severity | Story |
|---|---|---|---|---|
| TC-7 | existing row | functional | high | E1-S1 |

## E1-S2

| # | Scenario | Type | Severity | Story |
|---|---|---|---|---|
| TC-1 | other story | functional | low | E1-S2 |
MD
  run "$APPEND_TESTS" --test-plan "$plan" --story-key "E1-S1" \
    --edge-cases '[{"id":"EC-1","scenario":"empty input","category":"boundary","severity":"medium"}]'
  [ "$status" -eq 0 ]
  # The row lands inside the matched section, not the sibling one, and its
  # number continues that section's highest existing case.
  new_line=$(grep -n '| TC-8 | empty input |' "$plan" | head -1 | cut -d: -f1)
  s2_line=$(grep -n '^## E1-S2' "$plan" | head -1 | cut -d: -f1)
  [ -n "$new_line" ] && [ -n "$s2_line" ]
  [ "$new_line" -lt "$s2_line" ]
}

@test "the test-plan append step computes the next test-case number from the highest existing one" {
  body="$(step_body 'Step 3d')"
  echo "$body" | grep -qiE 'TC-\{N\}|TC-\\{N\\}|TC ID|max.*\+ ?1|next.*TC'
}

@test "the test-plan append step dedups by story and scenario so a re-run is idempotent" {
  body="$(step_body 'Step 3d')"
  echo "$body" | grep -qiE 'dedup|deduplicate|skip.*exist|already.*exist'
  echo "$body" | grep -qiE 'story_key.*scenario|\(story_key, scenario\)|scenario.*pair'
  echo "$body" | grep -qiE 'idempotent|re.run'
}

@test "the test-plan append step documents the appended row format" {
  body="$(step_body 'Step 3d')"
  echo "$body" | grep -qE 'TC-\{N\}'
  echo "$body" | grep -qiE 'edge.case'
  echo "$body" | grep -qE 'severity|category'
}

# ---------- AC6: YOLO compatibility ----------

@test "the three edge-case steps are non-interactive and prompt the user for nothing" {
  body3b="$(step_body 'Step 3b')"
  body3c="$(step_body 'Step 3c')"
  body3d="$(step_body 'Step 3d')"
  # YOLO note must appear at least once across the three steps (or in either of them)
  combined="$body3b $body3c $body3d"
  echo "$combined" | grep -qiE 'non.interactive|no.*user.*prompt|YOLO'
}

# ---------- Reference / traceability ----------
#
# Three cases here asserted that the Step 3b / 3c / 3d bodies cite their
# governing requirement identifiers in the shipped prose. Published source
# must no longer carry internal traceability identifiers, so that citation
# practice was removed on purpose and the behaviour those cases guarded is
# gone rather than drifted. They are deleted rather than re-pinned; the
# behaviour each step actually performs is covered by the cases above.
