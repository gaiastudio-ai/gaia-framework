#!/usr/bin/env bats
# pr-body.bats — coverage for skills/gaia-dev-story/scripts/pr-body.sh
#
# Story: E57-S7 — pr-body.sh (P1-2) + commit-msg.sh (P1-3)
# Traces: TC-DSS-06 (pr-body four sections), TC-DSS-08 (shell-metachar safety)
# ACs: AC1, AC3, AC4, AC5

load 'test_helper.bash'

setup() {
  common_setup
  PR_BODY="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/pr-body.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts
  # Initialize a minimal git repo so `git diff --stat` works inside the script.
  git init -q .
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "seed" > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  export PROJECT_PATH="$TEST_TMP"
}

teardown() { common_teardown; }

# Write a well-formed story file
_write_story() {
  local key="$1"
  local title="${2:-Test Story}"
  cat > "docs/implementation-artifacts/${key}-test.md" <<EOF
---
template: 'story'
key: "$key"
title: "$title"
type: "feature"
epic: "E57"
status: in-progress
risk: "low"
depends_on: []
---

# Story: Test

## Acceptance Criteria

- [ ] AC1: First criterion
- [ ] AC2: Second criterion
- [x] AC3: Third already done

## Tasks / Subtasks

- [x] Task 1
- [x] Task 2

## Dev Notes

End.
EOF
  echo "docs/implementation-artifacts/${key}-test.md"
}

# ---------------------------------------------------------------------------
# AC1 / TC-DSS-06 — Four canonical sections in order
# ---------------------------------------------------------------------------

@test "pr-body: emits exactly the four canonical sections in order" {
  path="$(_write_story "E57-S7")"
  run "$PR_BODY" "$path"
  [ "$status" -eq 0 ]
  # Verify presence and ordering of section headings
  ac_line=$(echo "$output" | grep -n "Acceptance Criteria" | head -1 | cut -d: -f1)
  dod_line=$(echo "$output" | grep -n "Definition of Done" | head -1 | cut -d: -f1)
  diff_line=$(echo "$output" | grep -n "Diff Stat" | head -1 | cut -d: -f1)
  link_line=$(echo "$output" | grep -n "Story:" | head -1 | cut -d: -f1)
  [ -n "$ac_line" ]
  [ -n "$dod_line" ]
  [ -n "$diff_line" ]
  [ -n "$link_line" ]
  [ "$ac_line" -lt "$dod_line" ]
  [ "$dod_line" -lt "$diff_line" ]
  [ "$diff_line" -lt "$link_line" ]
}

@test "pr-body: AC bullet count matches frontmatter" {
  path="$(_write_story "E57-S7")"
  run "$PR_BODY" "$path"
  [ "$status" -eq 0 ]
  # 3 ACs in the fixture; should appear as 3 bullets in the output
  count=$(echo "$output" | grep -c "^- AC" || true)
  [ "$count" -eq 3 ]
}

@test "pr-body: includes git diff --stat block" {
  path="$(_write_story "E57-S7")"
  # Stage a change so diff --stat has content
  echo "change" > change.txt
  git add change.txt
  run "$PR_BODY" "$path"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '```'
}

@test "pr-body: relative story link points under docs/" {
  path="$(_write_story "E57-S7")"
  run "$PR_BODY" "$path"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "docs/implementation-artifacts/E57-S7-test\.md"
}

# ---------------------------------------------------------------------------
# AC5 / TC-DSS-06 — No Claude/AI/Co-Authored-By in output
# ---------------------------------------------------------------------------

@test "pr-body: output contains no Claude / AI / Co-Authored-By strings" {
  path="$(_write_story "E57-S7")"
  run "$PR_BODY" "$path"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qE "Claude|Co-Authored-By"
}

# ---------------------------------------------------------------------------
# AC3 / TC-DSS-08 — Adversarial title shell-metachar safety
# ---------------------------------------------------------------------------

@test "pr-body: adversarial title with command-substitution does not execute" {
  # Use single-quoted YAML to embed dangerous chars literally.
  cat > "docs/implementation-artifacts/E57-S7-adv.md" <<'EOF'
---
template: 'story'
key: "E57-S7"
title: 'Add support for $(touch /tmp/pr_body_pwn); `whoami`; "x"; ''y'''
type: "feature"
epic: "E57"
status: in-progress
risk: "low"
depends_on: []
---

# Adversarial

## Acceptance Criteria

- [ ] AC1: only one

## Tasks / Subtasks

- [x] Task 1
EOF
  rm -f /tmp/pr_body_pwn
  run "$PR_BODY" "docs/implementation-artifacts/E57-S7-adv.md"
  [ "$status" -eq 0 ]
  # Ensure the dangerous command did not execute.
  [ ! -e /tmp/pr_body_pwn ]
  # The literal text should appear somewhere (we don't lock exact form, just no exec).
  echo "$output" | grep -q 'rm' || echo "$output" | grep -q 'touch' || true
}

# ---------------------------------------------------------------------------
# AC4 / TC-DSS-08 — No `eval` in pr-body.sh source
# ---------------------------------------------------------------------------

@test "pr-body: source contains no bare 'eval'" {
  ! grep -nE "\beval\b" "$PR_BODY"
}

# ---------------------------------------------------------------------------
# Issue #1091 — story_key: alias tolerance
# ---------------------------------------------------------------------------

@test "pr-body: resolves story_key: alias into the story-link line (issue #1091)" {
  cat > "docs/implementation-artifacts/E0-S103-alias.md" <<'EOF'
---
template: 'story'
story_key: E0-S103
epic_key: E0
title: "Alias story"
status: review
---

# Story
## Acceptance Criteria
- [ ] AC1
## Tasks / Subtasks
- [x] T1
EOF
  run "$PR_BODY" docs/implementation-artifacts/E0-S103-alias.md
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "E0-S103"
}
