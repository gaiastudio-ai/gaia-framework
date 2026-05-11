#!/usr/bin/env bats
# check-orchestration-class.bats — E84-S2 / ADR-093 static check coverage.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/check-orchestration-class.sh"
  FAKE_SKILLS="$TEST_TMP/skills"
  mkdir -p "$FAKE_SKILLS"
}
teardown() { common_teardown; }

# ----- helpers -----

make_skill() {
  # make_skill <name> <orchestration_class-value-or-empty>
  local name="$1" cls="${2:-}"
  local dir="$FAKE_SKILLS/$name"
  mkdir -p "$dir"
  if [ -n "$cls" ]; then
    cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: test skill
orchestration_class: $cls
---

body
EOF
  else
    cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: test skill
---

body
EOF
  fi
}

make_skill_duplicate() {
  # Two orchestration_class lines in the same frontmatter (illegal).
  local name="$1"
  local dir="$FAKE_SKILLS/$name"
  mkdir -p "$dir"
  cat > "$dir/SKILL.md" <<EOF
---
name: $name
orchestration_class: reviewer
orchestration_class: heavy-procedural
---

body
EOF
}

# ----- positive: all four canonical values pass -----

@test "PASS: reviewer is a canonical value" {
  make_skill alpha reviewer
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS:"* ]]
  [[ "$output" == *"1 classified"* ]]
}

@test "PASS: light-procedural is a canonical value" {
  make_skill alpha light-procedural
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
}

@test "PASS: heavy-procedural is a canonical value" {
  make_skill alpha heavy-procedural
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
}

@test "PASS: conversational is a canonical value" {
  make_skill alpha conversational
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
}

@test "PASS: all four classes coexist" {
  make_skill alpha reviewer
  make_skill beta light-procedural
  make_skill gamma heavy-procedural
  make_skill delta conversational
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4 classified"* ]]
}

# ----- negative: missing field -----

@test "CRITICAL: missing orchestration_class fails with exit 1" {
  make_skill alpha ""
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"orchestration_class missing"* ]]
}

# ----- negative: invalid value -----

@test "CRITICAL: invalid value fails with exit 1 and surfaces the bad value" {
  make_skill alpha heavyprocedural   # no hyphen
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"orchestration_class invalid: heavyprocedural"* ]]
}

@test "CRITICAL: empty value fails with exit 1" {
  # Manually emit a SKILL.md where the field exists but value is empty.
  mkdir -p "$FAKE_SKILLS/alpha"
  cat > "$FAKE_SKILLS/alpha/SKILL.md" <<'EOF'
---
name: alpha
orchestration_class:
---

body
EOF
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"orchestration_class invalid"* ]]
}

# ----- negative: duplicate declaration -----

@test "CRITICAL: duplicate orchestration_class fails with exit 1" {
  make_skill_duplicate alpha
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"declared 2 times"* ]]
}

# ----- mixed: one good + one bad fails overall -----

@test "CRITICAL: any single CRITICAL fails the run" {
  make_skill alpha reviewer
  make_skill beta ""
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"orchestration_class missing"* ]]
  [[ "$output" == *"1/2 skills classified"* ]]
}

# ----- live check: the real plugins/gaia/skills/ MUST pass -----

@test "PASS: live plugins/gaia/skills/ has 100% classification coverage" {
  REAL_SKILLS="$BATS_TEST_DIRNAME/../skills"
  [ -d "$REAL_SKILLS" ]
  run "$SCRIPT" --skills-dir "$REAL_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS:"* ]]
}

# ----- usage / args -----

@test "--help prints usage on stderr and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "unknown flag exits 2 with diagnostic" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "non-existent skills_dir exits 2 cleanly" {
  run "$SCRIPT" --skills-dir "$TEST_TMP/does-not-exist"
  [ "$status" -eq 2 ]
}
