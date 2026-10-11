#!/usr/bin/env bats
# commit-msg.bats — coverage for skills/gaia-dev-story/scripts/commit-msg.sh
#
# Tests the conventional-commit subject construction, --scope validation,
# story-key stripping, Story: body line emission, and shell-metachar safety.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  COMMIT_MSG="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/commit-msg.sh"
  cd "$TEST_TMP" || return 1
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
epic: "E0"
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
# Type mapping — scopeless subjects
# ---------------------------------------------------------------------------

@test "commit-msg: type=feature emits scopeless feat subject" {
  path="$(_write_story "K3-S7" "feature" "Add login flow")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "feat: wire Add login flow" ]
}

@test "commit-msg: type=bug emits scopeless fix subject" {
  path="$(_write_story "K1-S1" "bug" "Crash on save")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "fix: fix Crash on save" ]
}

@test "commit-msg: type=refactor emits scopeless refactor subject" {
  path="$(_write_story "K1-S2" "refactor" "Extract helper")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "refactor: refactor Extract helper" ]
}

@test "commit-msg: type=chore emits scopeless chore subject" {
  path="$(_write_story "K1-S3" "chore" "Deps")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "chore: update Deps" ]
}

@test "commit-msg: type unrecognized defaults to feat with wire verb" {
  path="$(_write_story "K1-S4" "weird" "Something")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "feat: wire Something" ]
}

@test "commit-msg: type missing defaults to feat with wire verb" {
  path="$(_write_story "K1-S5" "" "No type field")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "feat: wire No type field" ]
}

# ---------------------------------------------------------------------------
# --scope validation
# ---------------------------------------------------------------------------

@test "commit-msg: valid scope produces scoped subject" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run "$COMMIT_MSG" "$path" --scope sprint-state
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "fix(sprint-state): fix Handle empty list" ]
}

@test "commit-msg: no scope produces scopeless subject" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "fix: fix Handle empty list" ]
}

@test "commit-msg: invalid scope uppercase refused" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run --separate-stderr "$COMMIT_MSG" "$path" --scope "Sprint State"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"scope"* ]]
}

@test "commit-msg: digit-leading scope accepted (3d-viewer)" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run "$COMMIT_MSG" "$path" --scope 3d-viewer
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "$subject" = "fix(3d-viewer): fix Handle empty list" ]
}

@test "commit-msg: story-key-shaped scope refused (ab1-s1)" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run --separate-stderr "$COMMIT_MSG" "$path" --scope ab1-s1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "commit-msg: story-key-shaped scope refused (ex12-s3)" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run --separate-stderr "$COMMIT_MSG" "$path" --scope ex12-s3
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "commit-msg: scope without value refused" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run --separate-stderr "$COMMIT_MSG" "$path" --scope
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "commit-msg: empty-string scope refused" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run --separate-stderr "$COMMIT_MSG" "$path" --scope ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "commit-msg: uppercase-only scope refused (SprintState)" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run --separate-stderr "$COMMIT_MSG" "$path" --scope SprintState
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"scope"* ]]
}

@test "commit-msg: unknown extra arg refused" {
  path="$(_write_story "E88-S1" "bug" "Handle empty list")"
  run --separate-stderr "$COMMIT_MSG" "$path" --scope sprint-state --bogus
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Story: body line
# ---------------------------------------------------------------------------

@test "commit-msg: body line has Story: reference with blank separator" {
  path="$(_write_story "E88-S1" "feature" "Add login")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  # Output: line 1 = subject, line 2 = blank, line 3 = Story: KEY
  local blank_line
  blank_line="$(sed -n '2p' <<<"$output")"
  [ -z "$blank_line" ]
  local story_line
  story_line="$(sed -n '3p' <<<"$output")"
  [ "$story_line" = "Story: E88-S1" ]
}

@test "commit-msg: 72-char cap does not cut body line" {
  local long_title="This is a really long title that exceeds seventy-two chars and must be truncated cleanly here"
  path="$(_write_story "K3-S7" "feature" "$long_title")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  [ "${#subject}" -le 72 ]
  # Body line must still be complete — never truncated.
  local story_line
  story_line="$(sed -n '3p' <<<"$output")"
  [ "$story_line" = "Story: K3-S7" ]
}

# ---------------------------------------------------------------------------
# story_key alias tolerance
# ---------------------------------------------------------------------------

@test "commit-msg: resolves story_key alias to body line" {
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
  local story_line
  story_line="$(sed -n '3p' <<<"$output")"
  [ "$story_line" = "Story: E0-S103" ]
}

# ---------------------------------------------------------------------------
# Key stripping from title
# ---------------------------------------------------------------------------

@test "commit-msg: key in title prefix stripped from subject" {
  path="$(_write_story "E88-S1" "bug" "E88-S1: fix the thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "fix: fix the thing" ]
}

@test "commit-msg: key in parens stripped from subject" {
  path="$(_write_story "E88-S1" "feature" "Fix (E88-S1) thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "feat: wire Fix thing" ]
}

@test "commit-msg: key in parens with colon stripped without double space" {
  path="$(_write_story "E88-S1" "feature" "Fix (E88-S1): thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "feat: wire Fix thing" ]
}

@test "commit-msg: key followed by comma stripped" {
  path="$(_write_story "E88-S1" "bug" "Fix E88-S1, thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  # After strip: "Fix thing" → uppercase → verb prepend.
  [ "$subject" = "fix: fix Fix thing" ]
}

@test "commit-msg: key followed by dot stripped" {
  path="$(_write_story "E88-S1" "bug" "Fix E88-S1. thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  # After strip: "Fix thing" → uppercase → verb prepend.
  [ "$subject" = "fix: fix Fix thing" ]
}

@test "commit-msg: colon-glued key at end stripped cleanly" {
  path="$(_write_story "E88-S1" "bug" "Fix:E88-S1")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  # After strip: "Fix" → uppercase → verb prepend. The colon between
  # 'Fix' and the key is consumed with the key (leading-colon rule).
  [ "$subject" = "fix: fix Fix" ]
}

@test "commit-msg: paren pair consumed only when key fills it" {
  # "Fix (E88-S1 thing)" — key does NOT fill the parens → leave parens.
  path="$(_write_story "E88-S1" "feature" "Fix (E88-S1 thing)")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  # The opening paren should NOT be stripped since the key doesn't fill it.
  [ "$subject" = "feat: wire Fix (thing)" ]
}

@test "commit-msg: left-colon glued to word does not eat the word" {
  # "a:E88-S1" — the colon is between 'a' and the key.  Only the key and
  # its colon separator are stripped; the 'a' survives.
  path="$(_write_story "E88-S1" "bug" "a:E88-S1 thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  # "a thing" starts lowercase → no verb prepend.
  [ "$subject" = "fix: a thing" ]
}

@test "commit-msg: lowercase own key stripped from subject" {
  path="$(_write_story "E88-S1" "bug" "e88-s1: fix the thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "fix: fix the thing" ]
}

@test "commit-msg: mixed-case own key stripped from subject" {
  path="$(_write_story "E88-S1" "bug" "e88-S1 regression")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "fix: regression" ]
}

@test "commit-msg: different story key in title left alone" {
  path="$(_write_story "E88-S1" "bug" "Follow-up to K1-S2 work")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  # A different story's key passes through — out of scope to strip.
  [ "$subject" = "fix: fix Follow-up to K1-S2 work" ]
}

@test "commit-msg: key at closing seam stripped without dangling space" {
  # "Fix (thing K1-S1)" — key is inside parens but does NOT fill them.
  # After strip: "Fix (thing)" — no trailing space before ")".
  path="$(_write_story "K1-S1" "feature" "Fix (thing K1-S1)")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "feat: wire Fix (thing)" ]
}

@test "commit-msg: lowercase frontmatter key still stripped and emitted" {
  # Frontmatter key is lowercase — strip + Story: line both work.
  path="$(_write_story "k9-s3" "bug" "k9-s3: handle edge case")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "fix: handle edge case" ]
  local story_line; story_line="$(sed -n '3p' <<<"$output")"
  [ "$story_line" = "Story: k9-s3" ]
}

@test "commit-msg: title that is only the key exits non-zero" {
  path="$(_write_story "E88-S1" "feature" "E88-S1")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -ne 0 ]
}

# Over-strip guard: a longer key must not be stripped.
# Key is E88-S1; title contains E88-S10 — must be left alone.
@test "commit-msg: longer key in title not stripped (over-strip guard)" {
  path="$(_write_story "E88-S1" "feature" "Fix E88-S10 thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "feat: wire Fix E88-S10 thing" ]
}

# Over-strip guard at START: E88-S10 at position 0 with key E88-S1.
@test "commit-msg: longer key at start of title not stripped (over-strip guard)" {
  path="$(_write_story "E88-S1" "feature" "E88-S10 thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "feat: wire E88-S10 thing" ]
}

# Glued-key guard: XE88-S1 has an alphanumeric left neighbour — must not strip.
@test "commit-msg: glued key (left-boundary) not stripped (over-strip guard)" {
  path="$(_write_story "E88-S1" "feature" "XE88-S1 thing")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  [ "$subject" = "feat: wire XE88-S1 thing" ]
}

@test "commit-msg: key in brackets stripped from subject" {
  path="$(_write_story "E88-S1" "bug" "[E88-S1] regression fix")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject; subject="$(sed -n '1p' <<<"$output")"
  # After strip: "regression fix" → starts with lowercase → no verb prepend.
  [ "$subject" = "fix: regression fix" ]
}

# ---------------------------------------------------------------------------
# Subject regex — key-free
# ---------------------------------------------------------------------------

@test "commit-msg: subject matches key-free conventional-commit regex" {
  path="$(_write_story "K3-S7" "feature" "Add login")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  # Must NOT contain the old (<key>) scope pattern.
  ! grep -qE '\([A-Z][0-9]+-S[0-9]+\)' <<<"$subject"
}

# ---------------------------------------------------------------------------
# No Claude/Co-Authored-By in output
# ---------------------------------------------------------------------------

@test "commit-msg: output contains no Claude / Co-Authored-By strings" {
  path="$(_write_story "K3-S7" "feature" "Test")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  ! grep -qE "Claude|Co-Authored-By" <<<"$output"
}

# ---------------------------------------------------------------------------
# Adversarial title shell-metachar safety
# ---------------------------------------------------------------------------

@test "commit-msg: adversarial title with command-substitution does not execute" {
  cat > "docs/implementation-artifacts/K3-S7-adv.md" <<'EOF'
---
template: 'story'
key: "K3-S7"
title: 'Add support for $(touch /tmp/commit_msg_pwn); `whoami`; "x"; ''y'''
type: "feature"
epic: "E0"
status: in-progress
risk: "low"
depends_on: []
---

# Adversarial

## Acceptance Criteria

- [ ] AC1
EOF
  rm -f /tmp/commit_msg_pwn
  run "$COMMIT_MSG" "docs/implementation-artifacts/K3-S7-adv.md"
  [ "$status" -eq 0 ]
  [ ! -e /tmp/commit_msg_pwn ]
}

@test "commit-msg: adversarial title feeds cleanly into git commit -F -" {
  cat > "docs/implementation-artifacts/K3-S7-adv2.md" <<'EOF'
---
template: 'story'
key: "K3-S7"
title: 'Adv $(rm -rf /); `whoami`; "x"'
type: "feature"
epic: "E0"
status: in-progress
risk: "low"
depends_on: []
---

# Adversarial

## Acceptance Criteria

- [ ] AC1
EOF
  git init -q .
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "x" > seed.txt
  git add seed.txt
  echo "y" > another.txt
  git add another.txt
  msg="$("$COMMIT_MSG" "docs/implementation-artifacts/K3-S7-adv2.md")"
  echo "$msg" | git commit -q -F -
}

# ---------------------------------------------------------------------------
# No eval in source
# ---------------------------------------------------------------------------

@test "commit-msg: source contains no bare 'eval'" {
  ! grep -nE "\beval\b" "$COMMIT_MSG"
}

# ---------------------------------------------------------------------------
# commitlint-safe subjects for ALL-CAPS titles
# ---------------------------------------------------------------------------

@test "commit-msg: ALL-CAPS title gets a lowercase verb prefix (key-free)" {
  path="$(_write_story "K2-S1" "feature" "SKILL.md gate wiring")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  grep -qE '^feat: [a-z]' <<<"$subject"
  # Must not contain a key-scoped parenthetical.
  ! grep -qE '\(K2-S1\)' <<<"$subject"
}

@test "commit-msg: PascalCase-token title key-free" {
  path="$(_write_story "K2-S2" "feature" "ServiceWorker registration cleanup")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  grep -qE '^feat: [a-z]' <<<"$subject"
}

@test "commit-msg: API-titled story key-free" {
  path="$(_write_story "K2-S3" "feature" "API client retry policy")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  grep -qE '^feat: [a-z]' <<<"$subject"
}

@test "commit-msg: title already starting with lowercase verb is left untouched" {
  path="$(_write_story "K2-S4" "feature" "wire SKILL.md gate")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  grep -qE '^feat: wire SKILL\.md' <<<"$subject"
  ! grep -qE 'wire wire' <<<"$subject"
}

@test "commit-msg: type=bug ALL-CAPS title key-free" {
  path="$(_write_story "K2-S5" "bug" "URL encoding regression")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  grep -qE '^fix: fix URL' <<<"$subject"
  ! grep -qE '\(K2-S5\)' <<<"$subject"
}

@test "commit-msg: type=chore ALL-CAPS title key-free" {
  path="$(_write_story "K2-S6" "chore" "DEPS bump")"
  run "$COMMIT_MSG" "$path"
  [ "$status" -eq 0 ]
  local subject
  subject=$(printf '%s\n' "$output" | head -1)
  grep -qE '^chore: update DEPS' <<<"$subject"
  ! grep -qE '\(K2-S6\)' <<<"$subject"
}

# ---------------------------------------------------------------------------
# commitlint e2e (skip when not installed)
# ---------------------------------------------------------------------------

@test "commit-msg: ALL-CAPS-titled subject passes commitlint when available" {
  if ! command -v commitlint >/dev/null 2>&1; then
    skip "commitlint not installed on PATH"
  fi
  if ! node -e "require.resolve('@commitlint/config-conventional')" >/dev/null 2>&1; then
    skip "@commitlint/config-conventional not resolvable"
  fi
  path="$(_write_story "K2-S99" "feature" "SKILL.md gate wiring")"
  subject="$("$COMMIT_MSG" "$path" | head -1)"
  echo "$subject" | commitlint --extends @commitlint/config-conventional
}
