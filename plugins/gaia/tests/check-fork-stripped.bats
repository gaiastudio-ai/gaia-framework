#!/usr/bin/env bats
# check-fork-stripped.bats — E84-S3 / ADR-093 static check coverage.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/check-fork-stripped.sh"
  FAKE_SKILLS="$TEST_TMP/skills"
  mkdir -p "$FAKE_SKILLS"
}
teardown() { common_teardown; }

make_skill() {
  # make_skill <name> <orchestration_class> <with-fork?>
  local name="$1" cls="$2" fork="${3:-no}"
  local dir="$FAKE_SKILLS/$name"
  mkdir -p "$dir"
  if [ "$fork" = "yes" ]; then
    cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: test
context: fork
orchestration_class: $cls
---
body
EOF
  else
    cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: test
orchestration_class: $cls
---
body
EOF
  fi
}

# ---- positive: non-reviewers without fork ----

@test "PASS: light-procedural without context:fork passes" {
  make_skill alpha light-procedural no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "PASS: heavy-procedural without context:fork passes" {
  make_skill alpha heavy-procedural no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
}

@test "PASS: conversational without context:fork passes" {
  make_skill alpha conversational no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
}

# ---- positive: reviewers MAY retain fork ----

@test "PASS: reviewer WITH context:fork is allowed" {
  make_skill alpha reviewer yes
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "PASS: reviewer WITHOUT context:fork is also allowed" {
  make_skill alpha reviewer no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
}

# ---- negative: non-reviewer with fork is CRITICAL ----

@test "CRITICAL: light-procedural with context:fork fails" {
  make_skill alpha light-procedural yes
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"orchestration_class=light-procedural"* ]]
}

@test "CRITICAL: heavy-procedural with context:fork fails" {
  make_skill alpha heavy-procedural yes
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"orchestration_class=heavy-procedural"* ]]
}

@test "CRITICAL: conversational with context:fork fails" {
  make_skill alpha conversational yes
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"orchestration_class=conversational"* ]]
}

# ---- mixed scenarios ----

@test "CRITICAL: one violation among many passes fails the run" {
  make_skill alpha light-procedural no
  make_skill beta reviewer yes
  make_skill gamma heavy-procedural yes  # offender
  make_skill delta conversational no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gamma"* ]]
  [[ "$output" != *"alpha"*"CRITICAL"* ]]
  [[ "$output" != *"beta"*"CRITICAL"* ]]
  [[ "$output" != *"delta"*"CRITICAL"* ]]
}

@test "PASS: all reviewers with fork + all non-reviewers without fork" {
  make_skill alpha reviewer yes
  make_skill beta light-procedural no
  make_skill gamma heavy-procedural no
  make_skill delta conversational no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4 skills checked"* ]]
}

# ---- live: the real plugins/gaia/skills/ MUST pass ----

@test "PASS: live plugins/gaia/skills/ post-strip invariant holds" {
  REAL_SKILLS="$BATS_TEST_DIRNAME/../skills"
  [ -d "$REAL_SKILLS" ]
  run "$SCRIPT" --skills-dir "$REAL_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---- regression guard: agent persona files left alone ----

@test "REGRESSION: validator agent retains context: fork" {
  # E84-S3 explicitly does NOT touch agent persona files. Verify
  # validator.md still declares context: fork in its frontmatter.
  AGENT="$BATS_TEST_DIRNAME/../agents/validator.md"
  [ -f "$AGENT" ]
  run awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm && /^context:[[:space:]]*fork[[:space:]]*$/{print "yes"; exit}' "$AGENT"
  [[ "$output" == "yes" ]]
}

@test "REGRESSION: tdd-reviewer agent retains context: fork" {
  AGENT="$BATS_TEST_DIRNAME/../agents/tdd-reviewer.md"
  [ -f "$AGENT" ]
  run awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm && /^context:[[:space:]]*fork[[:space:]]*$/{print "yes"; exit}' "$AGENT"
  [[ "$output" == "yes" ]]
}

# ---- usage / args ----

@test "--help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "unknown flag exits 2" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "non-existent skills_dir exits 2 cleanly" {
  run "$SCRIPT" --skills-dir "$TEST_TMP/does-not-exist"
  [ "$status" -eq 2 ]
}
