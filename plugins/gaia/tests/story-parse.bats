#!/usr/bin/env bats
# story-parse.bats — coverage for skills/gaia-dev-story/scripts/story-parse.sh
#
# Story: E57-S5 — story-parse.sh (P0-1) + detect-mode.sh (P0-2)
# Traces: TC-DSS-01 (golden path), TC-DSS-02 (error paths)
# ACs: AC1, AC2, AC6, AC7

load 'test_helper.bash'

setup() {
  common_setup
  STORY_PARSE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/story-parse.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts
  export PROJECT_PATH="$TEST_TMP"
}

teardown() { common_teardown; }

# Write a well-formed story file
_write_story() {
  local key="$1"
  cat > "docs/implementation-artifacts/${key}-test.md" <<EOF
---
template: 'story'
key: "$key"
title: "Test Story"
epic: "E57"
status: ready-for-dev
risk: "low"
depends_on: ["E1-S1", "E1-S2"]
---

# Story: Test

## Acceptance Criteria

- [ ] AC1: First criterion
- [ ] AC2: Second criterion
- [x] AC3: Third (already done)

## Tasks / Subtasks

- [ ] Task 1: Open task
  - [ ] Subtask 1a
  - [x] Subtask 1b done
- [x] Task 2: Done task

## Dev Notes

End of file.
EOF
  echo "docs/implementation-artifacts/${key}-test.md"
}

# ---------------------------------------------------------------------------
# AC1 / TC-DSS-01 — Golden path: eval round-trip populates 10 vars
# ---------------------------------------------------------------------------

@test "story-parse: golden path emits all 10 canonical env-vars" {
  path="$(_write_story "E57-S5")"
  run "$STORY_PARSE" "$path"
  [ "$status" -eq 0 ]
  # Each canonical var must appear as KEY='...'
  echo "$output" | grep -q "^STORY_KEY="
  echo "$output" | grep -q "^STATUS="
  echo "$output" | grep -q "^RISK="
  echo "$output" | grep -q "^EPIC_KEY="
  echo "$output" | grep -q "^TYPE="
  echo "$output" | grep -q "^DEPENDS_ON="
  echo "$output" | grep -q "^SUBTASK_COUNT="
  echo "$output" | grep -q "^SUBTASK_CHECKED="
  echo "$output" | grep -q "^AC_COUNT="
  echo "$output" | grep -q "^STORY_PATH="
}

@test "story-parse: eval round-trip populates shell variables correctly" {
  path="$(_write_story "E57-S5")"
  output_text="$("$STORY_PARSE" "$path")"
  # eval into subshell and emit values
  eval "$output_text"
  [ "$STORY_KEY" = "E57-S5" ]
  [ "$STATUS" = "ready-for-dev" ]
  [ "$RISK" = "low" ]
  [ "$EPIC_KEY" = "E57" ]
  [ "$TYPE" = "story" ]
  [ "$DEPENDS_ON" = "E1-S1,E1-S2" ]
}

@test "story-parse: subtask and AC counts are accurate" {
  path="$(_write_story "E57-S5")"
  eval "$("$STORY_PARSE" "$path")"
  # Tasks / Subtasks: 2 unchecked (Task 1, Subtask 1a) + 2 checked (Subtask 1b, Task 2) = 4 total
  [ "$SUBTASK_COUNT" = "4" ]
  [ "$SUBTASK_CHECKED" = "2" ]
  # Acceptance Criteria: 3 items total
  [ "$AC_COUNT" = "3" ]
}

@test "story-parse: empty depends_on emits empty value" {
  cat > "docs/implementation-artifacts/E10-S1-test.md" <<'EOF'
---
template: 'story'
key: "E10-S1"
epic: "E10"
status: ready-for-dev
risk: "low"
depends_on: []
---

# Story
## Acceptance Criteria
- [ ] AC1

## Tasks / Subtasks
- [ ] T1
EOF
  eval "$("$STORY_PARSE" docs/implementation-artifacts/E10-S1-test.md)"
  [ "$DEPENDS_ON" = "" ]
}

# ---------------------------------------------------------------------------
# AC2 / TC-DSS-02 — Error paths
# ---------------------------------------------------------------------------

@test "story-parse: missing file exits 1 with stderr naming path" {
  run "$STORY_PARSE" "docs/implementation-artifacts/E99-S99-nonexistent.md"
  [ "$status" -eq 1 ]
  # No stdout STORY_KEY var on error
  ! echo "$output" | grep -q "^STORY_KEY="
  # bats combines stderr into $output by default
  echo "$output" | grep -F "E99-S99-nonexistent.md"
}

@test "story-parse: malformed YAML (no closing ---) exits 2" {
  cat > "docs/implementation-artifacts/E10-S1-bad.md" <<'EOF'
---
key: "E10-S1"
status: ready-for-dev
# missing closing marker
# Story body
EOF
  run "$STORY_PARSE" "docs/implementation-artifacts/E10-S1-bad.md"
  [ "$status" -eq 2 ]
  ! echo "$output" | grep -q "^STORY_KEY=" || false
}

@test "story-parse: missing required key field exits 2" {
  cat > "docs/implementation-artifacts/E10-S1-nokey.md" <<'EOF'
---
status: ready-for-dev
risk: low
---

# Story
EOF
  run "$STORY_PARSE" "docs/implementation-artifacts/E10-S1-nokey.md"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC6 — Path traversal rejection
# ---------------------------------------------------------------------------

@test "story-parse: path containing .. is rejected before any read" {
  run "$STORY_PARSE" "docs/implementation-artifacts/../../etc/passwd"
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q "^STORY_KEY=" || false
}

@test "story-parse: bare .. path is rejected" {
  run "$STORY_PARSE" "../etc/passwd"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC7 / TC-DSS-01 — Shell metacharacter single-quote safety
# ---------------------------------------------------------------------------

@test "story-parse: shell metachars in title round-trip without exec" {
  cat > "docs/implementation-artifacts/E10-S1-meta.md" <<'EOF'
---
template: 'story'
key: "E10-S1"
title: "Title with $(echo PWNED) backticks `id`"
epic: "E10"
status: ready-for-dev
risk: "low"
depends_on: []
---

# Story
## Acceptance Criteria
- [ ] AC1

## Tasks / Subtasks
- [ ] T1
EOF
  # If injection succeeded, eval would execute $(echo PWNED) at eval time
  out="$("$STORY_PARSE" docs/implementation-artifacts/E10-S1-meta.md)"
  # Verify single quotes wrap values (no unquoted $)
  ! echo "$out" | grep -E "^[A-Z_]+=[^'].*\\\$\(" || false
  # eval-safe: should not produce a "PWNED" subshell expansion
  eval "$out"
  [ "$STORY_KEY" = "E10-S1" ]
}

@test "story-parse: value containing single quote is properly escaped" {
  cat > "docs/implementation-artifacts/E10-S1-quote.md" <<'EOF'
---
template: 'story'
key: "E10-S1"
title: "It's a test"
epic: "E10"
status: ready-for-dev
risk: "low"
depends_on: []
---

# Story
## Acceptance Criteria
- [ ] AC1

## Tasks / Subtasks
- [ ] T1
EOF
  eval "$("$STORY_PARSE" docs/implementation-artifacts/E10-S1-quote.md)"
  [ "$STORY_KEY" = "E10-S1" ]
}

# ---------------------------------------------------------------------------
# Issue #1091 — story_key:/epic_key: alias tolerance
# ---------------------------------------------------------------------------

@test "story-parse: resolves story_key:/epic_key: alias frontmatter (issue #1091)" {
  cat > "docs/implementation-artifacts/E0-S103-alias.md" <<'EOF'
---
template: 'story'
story_key: E0-S103
epic_key: E0
title: "Alias story"
status: backlog
risk: low
---

# Story
## Acceptance Criteria
- [ ] AC1

## Tasks / Subtasks
- [ ] T1
EOF
  run "$STORY_PARSE" docs/implementation-artifacts/E0-S103-alias.md
  [ "$status" -eq 0 ]
  eval "$("$STORY_PARSE" docs/implementation-artifacts/E0-S103-alias.md)"
  [ "$STORY_KEY" = "E0-S103" ]
  [ "$EPIC_KEY" = "E0" ]
}

@test "story-parse: canonical key:/epic: take precedence over alias when both present (issue #1091)" {
  cat > "docs/implementation-artifacts/E2-S2-both.md" <<'EOF'
---
template: 'story'
key: E2-S2
story_key: WRONG-KEY
epic: E2
epic_key: WRONG-EPIC
title: "Precedence story"
status: backlog
---

# Story
## Acceptance Criteria
- [ ] AC1

## Tasks / Subtasks
- [ ] T1
EOF
  eval "$("$STORY_PARSE" docs/implementation-artifacts/E2-S2-both.md)"
  [ "$STORY_KEY" = "E2-S2" ]
  [ "$EPIC_KEY" = "E2" ]
}

@test "story-parse: missing both key and story_key names the alias in the error (issue #1091)" {
  cat > "docs/implementation-artifacts/E10-S1-nokey2.md" <<'EOF'
---
template: 'story'
status: ready-for-dev
risk: low
---

# Story
EOF
  run "$STORY_PARSE" docs/implementation-artifacts/E10-S1-nokey2.md
  [ "$status" -eq 2 ]
  echo "$output" | grep -F "story_key"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

@test "story-parse: missing arg shows usage" {
  run "$STORY_PARSE"
  [ "$status" -ne 0 ]
}
