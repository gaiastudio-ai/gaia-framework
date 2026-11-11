#!/usr/bin/env bats
# regression-rule-gate.bats — tests for regression-rule-check.sh, register-write.sh
# --pattern-class, and register-write.sh link-rule.

setup() {
  export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
  export RRC="$SCRIPT_DIR/regression-rule-check.sh"
  export RW="$SCRIPT_DIR/review-common/register-write.sh"
  export TMPDIR="${BATS_TEST_TMPDIR}"
  export TEST_DIR
  TEST_DIR="$(mktemp -d "$TMPDIR/rr-gate-XXXXXX")"

  # Ensure yq and jq are available.
  command -v yq  >/dev/null 2>&1 || skip "yq not found"  # lint-pack:allow-skip
  command -v jq  >/dev/null 2>&1 || skip "jq not found"  # lint-pack:allow-skip

  # Create a minimal project structure.
  mkdir -p "$TEST_DIR/.gaia/config"
  mkdir -p "$TEST_DIR/.gaia/custom/lint-rules"
  mkdir -p "$TEST_DIR/.gaia/artifacts/implementation-artifacts/K0-R1-test/review-reports"

  # Minimal story file.
  cat > "$TEST_DIR/.gaia/artifacts/implementation-artifacts/K0-R1-test/story.md" <<'STORY'
---
template: 'story'
version: 1.4.0
key: "K0-R1"
title: "Test story"
status: review
sprint_id: "sprint-test"
---
# Story: Test story

## Acceptance Criteria

- [ ] **AC1:** test criterion
STORY

  # Minimal project config (no regression_rule_gate_enabled).
  cat > "$TEST_DIR/.gaia/config/project-config.yaml" <<'CONFIG'
stacks:
  - name: bash
    path: "."
CONFIG

  # Set environment for the scripts.
  export PROJECT_ROOT="$TEST_DIR"
  export CLAUDE_PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export PROJECT_CONFIG="$TEST_DIR/.gaia/config/project-config.yaml"

  # Create git repo for story-check to work.
  (
    cd "$TEST_DIR"
    git init -q
    git add .
    git commit -q -m "init" --allow-empty
  )
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ---- enabled subcommand ----

@test "enabled: absent key prints on" {
  run bash "$RRC" enabled
  [ "$status" -eq 0 ]
  [ "$output" = "on" ]
}

@test "enabled: key set to true prints on" {
  yq -i '.review.regression_rule_gate_enabled = true' "$PROJECT_CONFIG"
  run bash "$RRC" enabled
  [ "$status" -eq 0 ]
  [ "$output" = "on" ]
}

@test "enabled: key set to false prints off" {
  yq -i '.review.regression_rule_gate_enabled = false' "$PROJECT_CONFIG"
  run bash "$RRC" enabled
  [ "$status" -eq 0 ]
  [ "$output" = "off" ]
}

@test "enabled: string false does not turn off" {
  yq -i '.review.regression_rule_gate_enabled = "false"' "$PROJECT_CONFIG"
  run bash "$RRC" enabled
  [ "$status" -eq 0 ]
  [ "$output" = "on" ]
}

@test "enabled: string no does not turn off" {
  yq -i '.review.regression_rule_gate_enabled = "no"' "$PROJECT_CONFIG"
  run bash "$RRC" enabled
  [ "$status" -eq 0 ]
  [ "$output" = "on" ]
}

# ---- library-check subcommand ----

@test "library-check: shipped library with valid rules passes" {
  run bash "$RRC" library-check
  [ "$status" -eq 0 ]
  local result
  result="$(printf '%s' "$output" | jq -r '.library_errors | length')"
  [ "$result" = "0" ]
}

@test "library-check: rule without test directory fails" {
  mkdir -p "$TEST_DIR/.gaia/custom/lint-rules/bad-rule"
  cat > "$TEST_DIR/.gaia/custom/lint-rules/bad-rule/rule.yml" <<'RULE'
rules:
  - id: bad-rule
    pattern: "bad"
    message: "bad"
    languages: [go]
    severity: ERROR
RULE
  export GAIA_CUSTOM_DIR="$TEST_DIR/.gaia/custom"
  run bash "$RRC" library-check
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.library_errors[] | select(.rule == "bad-rule" and (.reason | test("test.*directory")))'
}

@test "library-check: rule with deleted must-fire fixture fails" {
  mkdir -p "$TEST_DIR/.gaia/custom/lint-rules/no-fire/test"
  cat > "$TEST_DIR/.gaia/custom/lint-rules/no-fire/rule.yml" <<'RULE'
rules:
  - id: no-fire
    pattern: "bad"
    message: "bad"
    languages: [go]
    severity: ERROR
RULE
  # Only create an ok: fixture, no ruleid: fixture.
  cat > "$TEST_DIR/.gaia/custom/lint-rules/no-fire/test/safe.go" <<'FIX'
// ok: no-fire
func good() {}
FIX
  export GAIA_CUSTOM_DIR="$TEST_DIR/.gaia/custom"
  run bash "$RRC" library-check
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.library_errors[] | select(.rule == "no-fire" and (.reason | test("must-fire")))'
}

@test "library-check: project rule with symlink outside library is refused" {
  mkdir -p "$TEST_DIR/outside"
  cat > "$TEST_DIR/outside/rule.yml" <<'RULE'
rules:
  - id: escaped
    pattern: "bad"
    message: "bad"
    languages: [go]
    severity: ERROR
RULE
  mkdir -p "$TEST_DIR/outside/test"
  echo "// ruleid: escaped" > "$TEST_DIR/outside/test/fire.go"
  echo "// ok: escaped" > "$TEST_DIR/outside/test/safe.go"
  mkdir -p "$TEST_DIR/.gaia/custom/lint-rules"
  ln -s "$TEST_DIR/outside" "$TEST_DIR/.gaia/custom/lint-rules/escaped"
  export GAIA_CUSTOM_DIR="$TEST_DIR/.gaia/custom"
  run bash "$RRC" library-check
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.library_errors[] | select(.rule == "escaped" and (.reason | test("outside")))'
}

@test "library-check: semgrep not installed still runs structural checks" {
  # This test always passes structural checks on the shipped library.
  # The note about semgrep being deferred is checked.
  if command -v semgrep >/dev/null 2>&1; then
    skip "semgrep is installed; cannot test the absent case"
  fi
  run bash "$RRC" library-check
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.note | test("semgrep not installed")'
}

# ---- register-write.sh --pattern-class ----

@test "add --pattern-class stores pattern_class on critical finding" {
  bash "$RW" add --story K0-R1 --defect "test pattern" --type bug \
    --severity critical --gate code-review --pattern-class "sql-injection"
  local reg
  reg="$("$SCRIPT_DIR/resolve-review-report-path.sh" --key K0-R1 --type findings-register)"
  local pc
  pc="$(yq '.entries[0].pattern_class' "$reg")"
  [ "$pc" = "sql-injection" ]
}

@test "add --pattern-class stores pattern_class on high finding" {
  bash "$RW" add --story K0-R1 --defect "high pattern" --type bug \
    --severity high --gate code-review --pattern-class "auth-bypass"
  local reg
  reg="$("$SCRIPT_DIR/resolve-review-report-path.sh" --key K0-R1 --type findings-register)"
  local pc
  pc="$(yq '.entries[0].pattern_class' "$reg")"
  [ "$pc" = "auth-bypass" ]
}

@test "add --pattern-class rejected on medium finding" {
  run bash "$RW" add --story K0-R1 --defect "medium" --type bug \
    --severity medium --gate code-review --pattern-class "auth-bypass"
  [ "$status" -ne 0 ]
  [[ "$output" == *"critical or high"* ]]
}

@test "add --pattern-class rejects bad slug" {
  run bash "$RW" add --story K0-R1 --defect "bad slug" --type bug \
    --severity critical --gate code-review --pattern-class "../escape"
  [ "$status" -ne 0 ]
  [[ "$output" == *"slug"* ]]
}

@test "add --pattern-class rejects uppercase slug" {
  run bash "$RW" add --story K0-R1 --defect "bad slug" --type bug \
    --severity critical --gate code-review --pattern-class "BadSlug"
  [ "$status" -ne 0 ]
  [[ "$output" == *"slug"* ]]
}

# ---- register-write.sh link-rule ----

@test "link-rule links a rule to a finding" {
  bash "$RW" add --story K0-R1 --defect "pattern bug" --type bug \
    --severity critical --gate code-review --pattern-class "hardcoded-credentials"
  bash "$RW" link-rule --story K0-R1 --id RF-1 --rule hardcoded-credentials
  local reg
  reg="$("$SCRIPT_DIR/resolve-review-report-path.sh" --key K0-R1 --type findings-register)"
  local rules
  rules="$(yq '.entries[0].regression_rules[0]' "$reg")"
  [ "$rules" = "hardcoded-credentials" ]
}

@test "link-rule rejects unknown rule id" {
  bash "$RW" add --story K0-R1 --defect "pattern bug" --type bug \
    --severity critical --gate code-review --pattern-class "test-class"
  run bash "$RW" link-rule --story K0-R1 --id RF-1 --rule nonexistent-rule
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "link-rule rejects unknown register entry" {
  bash "$RW" add --story K0-R1 --defect "pattern bug" --type bug \
    --severity critical --gate code-review --pattern-class "test-class"
  run bash "$RW" link-rule --story K0-R1 --id RF-99 --rule hardcoded-credentials
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "link-rule is idempotent (no duplicate)" {
  bash "$RW" add --story K0-R1 --defect "pattern bug" --type bug \
    --severity critical --gate code-review --pattern-class "hardcoded-credentials"
  bash "$RW" link-rule --story K0-R1 --id RF-1 --rule hardcoded-credentials
  bash "$RW" link-rule --story K0-R1 --id RF-1 --rule hardcoded-credentials
  local reg
  reg="$("$SCRIPT_DIR/resolve-review-report-path.sh" --key K0-R1 --type findings-register)"
  local count
  count="$(yq '.entries[0].regression_rules | length' "$reg")"
  [ "$count" = "1" ]
}

# ---- story-check subcommand ----

@test "story-check: no register passes" {
  run bash "$RRC" story-check --story K0-R1
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.missing | length == 0'
}

@test "story-check: pattern finding without linked rule fails" {
  # Create a register with a round and a pattern entry.
  bash "$RW" record-round --story K0-R1 --run-id round-20261101T000000Z-1 \
    --repo "$TEST_DIR" --gate code-review="initial review"
  bash "$RW" add --story K0-R1 --defect "hardcoded creds" --type bug \
    --severity critical --gate code-review --pattern-class "hardcoded-credentials"
  run bash "$RRC" story-check --story K0-R1
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.missing[] | select(.pattern_class == "hardcoded-credentials")'
}

@test "story-check: linked rule with change since round passes" {
  # Use a project-library rule so the git diff check works within the test repo.
  mkdir -p "$TEST_DIR/.gaia/custom/lint-rules/test-cred-rule/test"
  cat > "$TEST_DIR/.gaia/custom/lint-rules/test-cred-rule/rule.yml" <<'R'
rules:
  - id: test-cred-rule
    pattern: "bad"
    message: "bad"
    languages: [go]
    severity: ERROR
R
  echo "// ruleid: test-cred-rule" > "$TEST_DIR/.gaia/custom/lint-rules/test-cred-rule/test/fire.go"
  echo "// ok: test-cred-rule" > "$TEST_DIR/.gaia/custom/lint-rules/test-cred-rule/test/safe.go"
  (cd "$TEST_DIR" && git add . && git commit -q -m "add project rule")

  export GAIA_CUSTOM_DIR="$TEST_DIR/.gaia/custom"

  bash "$RW" record-round --story K0-R1 --run-id round-20261101T000000Z-1 \
    --repo "$TEST_DIR" --gate code-review="initial review"
  bash "$RW" add --story K0-R1 --defect "cred pattern" --type bug \
    --severity critical --gate code-review --pattern-class "test-cred"
  bash "$RW" link-rule --story K0-R1 --id RF-1 --rule test-cred-rule

  # Make a change in the rule directory after the round and commit.
  echo "update" >> "$TEST_DIR/.gaia/custom/lint-rules/test-cred-rule/test/fire.go"
  (cd "$TEST_DIR" && git add . && git commit -q -m "update rule")

  run bash "$RRC" story-check --story K0-R1
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.missing | length == 0'
}

@test "story-check: linked rule unchanged since finding fails" {
  # Use a project-library rule.
  mkdir -p "$TEST_DIR/.gaia/custom/lint-rules/test-unchanged-rule/test"
  cat > "$TEST_DIR/.gaia/custom/lint-rules/test-unchanged-rule/rule.yml" <<'R'
rules:
  - id: test-unchanged-rule
    pattern: "bad"
    message: "bad"
    languages: [go]
    severity: ERROR
R
  echo "// ruleid: test-unchanged-rule" > "$TEST_DIR/.gaia/custom/lint-rules/test-unchanged-rule/test/fire.go"
  echo "// ok: test-unchanged-rule" > "$TEST_DIR/.gaia/custom/lint-rules/test-unchanged-rule/test/safe.go"
  (cd "$TEST_DIR" && git add . && git commit -q -m "add project rule")

  export GAIA_CUSTOM_DIR="$TEST_DIR/.gaia/custom"

  bash "$RW" record-round --story K0-R1 --run-id round-20261101T000000Z-1 \
    --repo "$TEST_DIR" --gate code-review="initial review"
  bash "$RW" add --story K0-R1 --defect "unchanged pattern" --type bug \
    --severity critical --gate code-review --pattern-class "unchanged-class"
  bash "$RW" link-rule --story K0-R1 --id RF-1 --rule test-unchanged-rule

  # No new commit after the round — rule unchanged.
  run bash "$RRC" story-check --story K0-R1
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.missing[] | select(.reason | test("not updated"))'
}

@test "story-check: partial links — fails only for unlinked entries" {
  # Use a project-library rule for the linked entry.
  mkdir -p "$TEST_DIR/.gaia/custom/lint-rules/partial-rule/test"
  cat > "$TEST_DIR/.gaia/custom/lint-rules/partial-rule/rule.yml" <<'R'
rules:
  - id: partial-rule
    pattern: "bad"
    message: "bad"
    languages: [go]
    severity: ERROR
R
  echo "// ruleid: partial-rule" > "$TEST_DIR/.gaia/custom/lint-rules/partial-rule/test/fire.go"
  echo "// ok: partial-rule" > "$TEST_DIR/.gaia/custom/lint-rules/partial-rule/test/safe.go"
  (cd "$TEST_DIR" && git add . && git commit -q -m "add project rule")

  export GAIA_CUSTOM_DIR="$TEST_DIR/.gaia/custom"

  bash "$RW" record-round --story K0-R1 --run-id round-20261101T000000Z-1 \
    --repo "$TEST_DIR" --gate code-review="initial review"
  # Entry 1: linked.
  bash "$RW" add --story K0-R1 --defect "cred bug" --type bug \
    --severity critical --gate code-review --pattern-class "partial-cred"
  bash "$RW" link-rule --story K0-R1 --id RF-1 --rule partial-rule
  # Make a change so the linked one passes.
  echo "update" >> "$TEST_DIR/.gaia/custom/lint-rules/partial-rule/test/fire.go"
  (cd "$TEST_DIR" && git add . && git commit -q -m "rule change")

  # Entry 2 and 3: unlinked.
  bash "$RW" add --story K0-R1 --defect "auth bypass" --type bug \
    --severity critical --gate code-review --pattern-class "auth-bypass"
  bash "$RW" add --story K0-R1 --defect "sql injection" --type bug \
    --severity high --gate code-review --pattern-class "sql-injection"

  run bash "$RRC" story-check --story K0-R1
  [ "$status" -eq 1 ]
  local missing_count
  missing_count="$(printf '%s' "$output" | jq '.missing | length')"
  [ "$missing_count" = "2" ]
}

@test "story-check: entry without run_id fails closed with round unknown" {
  # Create a register entry manually without a round (simulates pre-upgrade).
  bash "$RW" add --story K0-R1 --defect "old pattern" --type bug \
    --severity critical --gate code-review --pattern-class "old-pattern"
  bash "$RW" link-rule --story K0-R1 --id RF-1 --rule hardcoded-credentials
  run bash "$RRC" story-check --story K0-R1
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.missing[] | select(.reason | test("round unknown"))'
}

@test "story-check: non-git workspace fails closed" {
  # Remove the .git directory to simulate a non-git workspace.
  rm -rf "$TEST_DIR/.git"
  bash "$RW" add --story K0-R1 --defect "pattern bug" --type bug \
    --severity critical --gate code-review --pattern-class "test-pattern"
  bash "$RW" link-rule --story K0-R1 --id RF-1 --rule hardcoded-credentials
  # Manually add a run_id to the entry so we reach the git check.
  local reg
  reg="$("$SCRIPT_DIR/resolve-review-report-path.sh" --key K0-R1 --type findings-register)"
  yq -i '.entries[0].run_id = "round-20261101T000000Z-1"' "$reg"
  yq -i '.rounds = [{"run_id": "round-20261101T000000Z-1", "status": "open", "selected_gates": [{"gate": "code-review"}], "commit_sha": "0000000000000000000000000000000000000000"}]' "$reg"

  run bash "$RRC" story-check --story K0-R1
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.missing[] | select(.reason | test("non-git"))'
}

# ---- add stores run_id from current open round ----

@test "add stores run_id from the open round" {
  bash "$RW" record-round --story K0-R1 --run-id round-20261101T120000Z-1 \
    --repo "$TEST_DIR" --gate code-review="review pass"
  bash "$RW" add --story K0-R1 --defect "test" --type bug \
    --severity critical --gate code-review --pattern-class "test-class"
  local reg
  reg="$("$SCRIPT_DIR/resolve-review-report-path.sh" --key K0-R1 --type findings-register)"
  local stored_run_id
  stored_run_id="$(yq '.entries[0].run_id' "$reg")"
  [ "$stored_run_id" = "round-20261101T120000Z-1" ]
}

@test "add without open round stores no run_id" {
  bash "$RW" add --story K0-R1 --defect "test" --type bug \
    --severity critical --gate code-review --pattern-class "test-class"
  local reg
  reg="$("$SCRIPT_DIR/resolve-review-report-path.sh" --key K0-R1 --type findings-register)"
  local stored_run_id
  stored_run_id="$(yq '.entries[0].run_id' "$reg")"
  # Should be null or empty.
  [ "$stored_run_id" = "null" ] || [ -z "$stored_run_id" ]
}
