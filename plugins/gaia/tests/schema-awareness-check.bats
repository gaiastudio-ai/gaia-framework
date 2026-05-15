#!/usr/bin/env bats
# schema-awareness-check.bats — E91-S2 schema-lookup.sh tests.
#
# Covers TC-SRF-4..7:
#   TC-SRF-4: CSV target missing-column -> exit 1 + valid columns on stderr
#   TC-SRF-5: SKILL.md missing-frontmatter-key -> exit 1 + valid keys on stderr
#   TC-SRF-6: CSV target with real column -> exit 0
#   TC-SRF-7: SKILL.md target with real frontmatter key -> exit 0

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  HELPER="$LIB_DIR/schema-lookup.sh"
  export LIB_DIR HELPER

  # Stage fixtures.
  FIXTURE_CSV="$TEST_TMP/manifest.csv"
  cat > "$FIXTURE_CSV" <<'EOF'
name,displayName,description,module,phase,path,command,agent
foo,Foo,foo desc,modA,phase1,foo.sh,/cmd-foo,agentA
EOF

  FIXTURE_MD="$TEST_TMP/skill.md"
  cat > "$FIXTURE_MD" <<'EOF'
---
name: gaia-test-skill
description: "Test fixture for schema-lookup.sh"
allowed-tools: [Bash, Read]
---

# Skill body
EOF
  export FIXTURE_CSV FIXTURE_MD
}

teardown() {
  common_teardown
}

# ---------------- TC-SRF-4: CSV missing column -> exit 1 ----------------
@test "TC-SRF-4: CSV target with missing column emits stderr valid-columns list" {
  run "$HELPER" --target "$FIXTURE_CSV" --name dependencies
  [ "$status" -eq 1 ]
  [[ "$output" == *"valid columns"* ]]
  [[ "$output" == *"name"* ]]
  [[ "$output" == *"agent"* ]]
}

# ---------------- TC-SRF-5: SKILL.md missing key -> exit 1 ----------------
@test "TC-SRF-5: SKILL.md target with missing frontmatter key emits stderr valid-keys list" {
  run "$HELPER" --target "$FIXTURE_MD" --name when_to_use
  [ "$status" -eq 1 ]
  [[ "$output" == *"valid frontmatter keys"* ]]
  [[ "$output" == *"name"* ]]
  [[ "$output" == *"description"* ]]
}

# ---------------- TC-SRF-6: CSV with real column -> exit 0 ----------------
@test "TC-SRF-6: CSV target with real column exits 0" {
  run "$HELPER" --target "$FIXTURE_CSV" --name agent
  [ "$status" -eq 0 ]
}

@test "TC-SRF-6b: CSV target with the first column (name) exits 0" {
  run "$HELPER" --target "$FIXTURE_CSV" --name name
  [ "$status" -eq 0 ]
}

# ---------------- TC-SRF-7: SKILL.md with real frontmatter key -> exit 0 ----------------
@test "TC-SRF-7: SKILL.md target with real frontmatter key exits 0" {
  run "$HELPER" --target "$FIXTURE_MD" --name description
  [ "$status" -eq 0 ]
}

# ---------------- TC-SRF-8: Missing target file -> exit 2 (usage error) ----------------
@test "TC-SRF-8: missing target file exits 2 (usage error)" {
  run "$HELPER" --target "$TEST_TMP/nonexistent.csv" --name foo
  [ "$status" -eq 2 ]
}

# ---------------- TC-SRF-9: Unsupported target extension -> exit 2 ----------------
@test "TC-SRF-9: unsupported target extension exits 2" {
  local fixture="$TEST_TMP/unknown.txt"
  printf 'not a csv or md\n' > "$fixture"
  run "$HELPER" --target "$fixture" --name foo
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsupported target extension"* ]]
}

# ---------------- TC-SRF-10: Retroactive — E86-S6-style 'dependencies column' drift ----------------
@test "TC-SRF-10: retroactive — E86-S6 'dependencies column' drift is caught by schema-lookup" {
  # Reproduces the column shape from Val F6 on AF-2026-05-14-9
  # (canonical columns: name,displayName,description,module,phase,path,command,agent).
  # E86-S6 AC2 cited 'dependencies column' — non-existent.
  local manifest="$TEST_TMP/sample-canonical-shape.csv"
  cat > "$manifest" <<'EOF'
name,displayName,description,module,phase,path,command,agent
EOF
  run "$HELPER" --target "$manifest" --name dependencies
  [ "$status" -eq 1 ]
}

# ---------------- TC-SRF-11: Retroactive — E86-S6-style 'when_to_use' drift ----------------
@test "TC-SRF-11: retroactive — E86-S6 'when_to_use' frontmatter drift is caught" {
  local fixture="$TEST_TMP/claude-code-skill-shape.md"
  cat > "$fixture" <<'EOF'
---
name: example
description: "Claude Code skill frontmatter shape"
allowed-tools: [Bash]
---

# Body
EOF
  run "$HELPER" --target "$fixture" --name when_to_use
  [ "$status" -eq 1 ]
}
