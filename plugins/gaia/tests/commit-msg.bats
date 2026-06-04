#!/usr/bin/env bats
# commit-msg.bats — coverage for skills/gaia-dev-story/scripts/commit-msg.sh
#
# Story: E57-S7 — pr-body.sh (P1-2) + commit-msg.sh (P1-3)
# Traces: TC-DSS-07 (commit-msg type mapping), TC-DSS-08 (shell-metachar safety)
# ACs: AC2, AC3, AC4, AC5

load 'test_helper.bash'

setup() {
  common_setup
  COMMIT_MSG="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/commit-msg.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts
  export PROJECT_PATH="$TEST_TMP"
}

teardown() { common_teardown; }

_write_story() {
  local key="$1"
  local type_field="$2"   # may be empty
  local title="${3:-Test Story}"
  local type_line=""
  if [ -n "$type_field" ]; then
    type_line="type: \"$type_field\""
  fi
  cat > "docs/implementation-artifacts/${key}-test.md" <<EOF
---
template: 'story'
key: "$key"
title: "$title"
$type_line
epic: "E57"
status: in-progress
risk: "low"
depends_on: []
---

# Story

## Acceptance Criteria

- [ ] AC1

## Tasks / Subtasks

- [x] Task 1
EOF
  echo "docs/implementation-artifacts/${key}-test.md"
}

# ---------------------------------------------------------------------------
# AC2 / TC-DSS-07 — Type mapping
# ---------------------------------------------------------------------------

@test "commit-msg: type=feature -> feat(<key>): wire <title>" {
  path="$(_write_story "E57-S7" "feature" "Add login flow")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  [ "$subject" = "feat(E57-S7): wire Add login flow" ]
}

@test "commit-msg: type=bug -> fix(<key>): fix <title>" {
  path="$(_write_story "E1-S1" "bug" "Crash on save")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  [ "$subject" = "fix(E1-S1): fix Crash on save" ]
}

@test "commit-msg: type=refactor -> refactor(<key>): refactor <title>" {
  path="$(_write_story "E1-S2" "refactor" "Extract helper")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  [ "$subject" = "refactor(E1-S2): refactor Extract helper" ]
}

@test "commit-msg: type=chore -> chore(<key>): update <title>" {
  path="$(_write_story "E1-S3" "chore" "Deps")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  [ "$subject" = "chore(E1-S3): update Deps" ]
}

@test "commit-msg: type unrecognized -> default feat with wire verb" {
  path="$(_write_story "E1-S4" "weird" "Something")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  [ "$subject" = "feat(E1-S4): wire Something" ]
}

@test "commit-msg: type missing -> default feat with wire verb" {
  path="$(_write_story "E1-S5" "" "No type field")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  [ "$subject" = "feat(E1-S5): wire No type field" ]
}

# ---------------------------------------------------------------------------
# AC2 — subject regex + 72-char cap
# ---------------------------------------------------------------------------

@test "commit-msg: subject matches Conventional Commit regex" {
  path="$(_write_story "E57-S7" "feature" "Add login")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  echo "$subject" | grep -qE '^(feat|fix|refactor|chore)\([A-Z][0-9]+-S[0-9]+\): .+$'
}

@test "commit-msg: 90-char title is truncated to 72-char subject" {
  long_title="This is a really long title that exceeds seventy-two chars and must be truncated cleanly here"
  path="$(_write_story "E57-S7" "feature" "$long_title")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  [ "${#subject}" -le 72 ]
}

# ---------------------------------------------------------------------------
# AC5 — No Claude/Co-Authored-By in output
# ---------------------------------------------------------------------------

@test "commit-msg: output contains no Claude / Co-Authored-By strings" {
  path="$(_write_story "E57-S7" "feature" "Test")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qE "Claude|Co-Authored-By"
}

# ---------------------------------------------------------------------------
# AC3 / TC-DSS-08 — Adversarial title shell-metachar safety
# ---------------------------------------------------------------------------

@test "commit-msg: adversarial title with command-substitution does not execute" {
  cat > "docs/implementation-artifacts/E57-S7-adv.md" <<'EOF'
---
template: 'story'
key: "E57-S7"
title: 'Add support for $(touch /tmp/commit_msg_pwn); `whoami`; "x"; ''y'''
type: "feature"
epic: "E57"
status: in-progress
risk: "low"
depends_on: []
---

# Adversarial

## Acceptance Criteria

- [ ] AC1
EOF
  rm -f /tmp/commit_msg_pwn
  run "$COMMIT_MSG" "docs/implementation-artifacts/E57-S7-adv.md"
  [ "$status" -eq 0 ]
  # Ensure the dangerous command did not execute.
  [ ! -e /tmp/commit_msg_pwn ]
}

@test "commit-msg: adversarial title feeds cleanly into git commit -F -" {
  cat > "docs/implementation-artifacts/E57-S7-adv2.md" <<'EOF'
---
template: 'story'
key: "E57-S7"
title: 'Adv $(rm -rf /); `whoami`; "x"'
type: "feature"
epic: "E57"
status: in-progress
risk: "low"
depends_on: []
---

# Adversarial

## Acceptance Criteria

- [ ] AC1
EOF
  # Set up a throwaway git repo
  git init -q .
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "x" > seed.txt
  git add seed.txt
  echo "y" > another.txt
  git add another.txt
  # Run commit-msg.sh and pipe to git commit -F -
  msg="$("$COMMIT_MSG" "docs/implementation-artifacts/E57-S7-adv2.md")"
  echo "$msg" | git commit -q -F -
}

# ---------------------------------------------------------------------------
# AC4 / TC-DSS-08 — No `eval` in commit-msg.sh source
# ---------------------------------------------------------------------------

@test "commit-msg: source contains no bare 'eval'" {
  ! grep -nE "\beval\b" "$COMMIT_MSG"
}

# ---------------------------------------------------------------------------
# E64-S1 / AC4 / TC-E64-9 — commitlint-safe subjects for ALL-CAPS titles
# ---------------------------------------------------------------------------
#
# commitlint @commitlint/config-conventional defaults reject subjects that
# start with an upper-case / pascal-case word. Story titles often start with
# an ALL-CAPS token (e.g., "SKILL.md gate wiring", "API client") because
# they reference framework identifiers verbatim. The fix prepends a
# lowercase verb derived from the type field so the SUBJECT (the part after
# `<type>(<key>): `) starts with a lowercase letter.

@test "commit-msg: ALL-CAPS title gets a lowercase verb prefix" {
  path="$(_write_story "E64-S1" "feature" "SKILL.md gate wiring")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  # Subject body (after `feat(KEY): `) must start with a lowercase letter
  echo "$subject" | grep -qE '^feat\(E64-S1\): [a-z][a-z]+ SKILL\.md'
}

@test "commit-msg: PascalCase-token title gets a lowercase verb prefix" {
  path="$(_write_story "E64-S2" "feature" "ServiceWorker registration cleanup")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  echo "$subject" | grep -qE '^feat\(E64-S2\): [a-z]+'
}

@test "commit-msg: API-titled story gets a lowercase verb prefix" {
  path="$(_write_story "E64-S3" "feature" "API client retry policy")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  echo "$subject" | grep -qE '^feat\(E64-S3\): [a-z]+'
}

@test "commit-msg: title already starting with lowercase verb is left untouched" {
  # If the title already starts with a lowercase verb, no prefix is needed.
  path="$(_write_story "E64-S4" "feature" "wire SKILL.md gate")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  # Body should still start with "wire" — no double prefix
  echo "$subject" | grep -qE '^feat\(E64-S4\): wire SKILL\.md'
  # No double "wire wire"
  ! echo "$subject" | grep -qE 'wire wire'
}

@test "commit-msg: type=bug ALL-CAPS title prepends 'fix' verb" {
  path="$(_write_story "E64-S5" "bug" "URL encoding regression")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  echo "$subject" | grep -qE '^fix\(E64-S5\): fix URL'
}

@test "commit-msg: type=chore ALL-CAPS title prepends 'update' verb" {
  path="$(_write_story "E64-S6" "chore" "DEPS bump")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  subject=$(echo "$output" | head -1)
  echo "$subject" | grep -qE '^chore\(E64-S6\): update DEPS'
}

# ---------------------------------------------------------------------------
# E64-S1 / Subtask 4.4 / TC-E64-10 — commitlint subject-case e2e
# ---------------------------------------------------------------------------
#
# When commitlint is available locally (e.g., installed via `npm i -g
# @commitlint/cli @commitlint/config-conventional` or wired into the host
# project), feed the generated subject through `commitlint --extends
# @commitlint/config-conventional` and assert exit 0. Skipped on systems
# where commitlint is not installed — the unit-level subject-case checks
# above cover the logic deterministically.

@test "commit-msg: ALL-CAPS-titled subject passes commitlint when available" {
  if ! command -v commitlint >/dev/null 2>&1; then
    skip "commitlint not installed on PATH"
  fi
  if ! node -e "require.resolve('@commitlint/config-conventional')" >/dev/null 2>&1; then
    skip "@commitlint/config-conventional not resolvable"
  fi
  path="$(_write_story "E64-S99" "feature" "SKILL.md gate wiring")"
  subject="$("$COMMIT_MSG" "$path")"
  echo "$subject" | commitlint --extends @commitlint/config-conventional
}

# ---------------------------------------------------------------------------
# Issue #1091 — story_key: alias tolerance
# ---------------------------------------------------------------------------

@test "commit-msg: resolves story_key: alias into the subject scope (issue #1091)" {
  cat > "docs/implementation-artifacts/E0-S103-alias.md" <<'EOF'
---
template: 'story'
story_key: E0-S103
epic_key: E0
title: "Alias story"
type: feature
status: in-progress
---

# Story
## Acceptance Criteria
- [ ] AC1
## Tasks / Subtasks
- [x] T1
EOF
  run "$COMMIT_MSG" docs/implementation-artifacts/E0-S103-alias.md
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "(E0-S103):"
}
