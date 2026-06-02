#!/usr/bin/env bats
# e28-s187-revert-tools-field.bats — E28-S187 TDD RED tests
#
# These assertions validate the REVERT of E28-S185. The official Claude Code
# skills docs at https://code.claude.com/docs/en/skills confirm that
# `allowed-tools:` IS the canonical frontmatter key (both list form and
# string form are accepted). This test file enforces that every plugin
# SKILL.md uses `allowed-tools:` (NOT `tools:`) as the top-level frontmatter
# key, and that the companion revert script exists and round-trips correctly.
#
# Story: E28-S187

load test_helper

setup() {
  common_setup
  PLUGIN_SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  REVERTER="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/revert-skill-tools-field.sh"
  export PLUGIN_SKILLS_DIR REVERTER
}

teardown() { common_teardown; }

# ---------- AC1, AC2: tree-wide frontmatter key ----------

@test "AC1: no plugin SKILL.md uses the post-E28-S185 tools: top-level key" {
  local hits
  hits="$(grep -l '^tools:' "$PLUGIN_SKILLS_DIR"/*/SKILL.md 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "SKILL.md files still using tools: (E28-S185 form):"
    printf '  %s\n' $hits
    return 1
  fi
}

@test "AC2: every plugin SKILL.md declares allowed-tools: as top-level key" {
  local total with_allowed
  total="$(ls "$PLUGIN_SKILLS_DIR"/*/SKILL.md | wc -l | tr -d ' ')"
  with_allowed="$(grep -l '^allowed-tools:' "$PLUGIN_SKILLS_DIR"/*/SKILL.md | wc -l | tr -d ' ')"
  [ "$total" -ge 115 ]
  [ "$with_allowed" = "$total" ]
}

# ---------- AC3: list form for allowed-tools: ----------

@test "AC3: every allowed-tools: value uses YAML list form [A, B, C]" {
  local offenders=""
  while IFS= read -r file; do
    local line
    line="$(grep '^allowed-tools:' "$file" | head -1)"
    # Match `allowed-tools: [...]` — the canonical list form.
    if ! echo "$line" | grep -qE '^allowed-tools:[[:space:]]*\['; then
      offenders="$offenders$file:$line\n"
    fi
  done < <(ls "$PLUGIN_SKILLS_DIR"/*/SKILL.md)
  if [ -n "$offenders" ]; then
    echo -e "SKILL.md files NOT using YAML list form for allowed-tools:\n$offenders"
    return 1
  fi
}

# ---------- Revert script behavioral tests (Task 1) ----------

@test "revert-skill-tools-field.sh exists and is executable" {
  [ -x "$REVERTER" ]
}

@test "reverter converts tools: A, B, C -> allowed-tools: [A, B, C]" {
  local file="$TEST_TMP/SKILL.md"
  cat > "$file" <<'EOF'
---
name: test
description: test
tools: Read, Bash, Grep
---

body
EOF
  run "$REVERTER" "$file"
  [ "$status" -eq 0 ]
  grep -q '^allowed-tools: \[Read, Bash, Grep\]$' "$file"
  ! grep -q '^tools:' "$file"
}

@test "reverter converts tools: A -> allowed-tools: [A] (single tool)" {
  local file="$TEST_TMP/SKILL.md"
  cat > "$file" <<'EOF'
---
name: test
description: test
tools: Read
---
EOF
  run "$REVERTER" "$file"
  [ "$status" -eq 0 ]
  grep -q '^allowed-tools: \[Read\]$' "$file"
}

@test "reverter is idempotent on second run" {
  local file="$TEST_TMP/SKILL.md"
  cat > "$file" <<'EOF'
---
name: test
description: test
tools: Read, Write
---
EOF
  "$REVERTER" "$file" >/dev/null
  local first_sha
  first_sha="$(shasum -a 256 "$file" | awk '{print $1}')"
  run "$REVERTER" "$file"
  [ "$status" -eq 0 ]
  local second_sha
  second_sha="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$first_sha" = "$second_sha" ]
}

@test "reverter leaves SKILL.md without a tools: line untouched" {
  local file="$TEST_TMP/SKILL.md"
  cat > "$file" <<'EOF'
---
name: test
description: test
---

body
EOF
  local before
  before="$(shasum -a 256 "$file" | awk '{print $1}')"
  run "$REVERTER" "$file"
  [ "$status" -eq 0 ]
  local after
  after="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "reverter does not touch body content mentioning tools:" {
  local file="$TEST_TMP/SKILL.md"
  cat > "$file" <<'EOF'
---
name: test
description: test
tools: Read
---

Body mentions tools: [SomeExample] in documentation.
EOF
  run "$REVERTER" "$file"
  [ "$status" -eq 0 ]
  grep -q 'Body mentions tools: \[SomeExample\] in documentation\.' "$file"
}

@test "reverter rejects zero-arg invocation" {
  run "$REVERTER"
  [ "$status" -eq 1 ]
}

# ---------- Enterprise mirror (AC4) ----------

@test "AC4: enterprise SKILL.md files do not use the post-E28-S185 tools: key" {
  local framework_root
  framework_root="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  local ent_dir="$framework_root/gaia-enterprise/plugins/gaia-enterprise/skills"
  if [ ! -d "$ent_dir" ]; then
    skip "gaia-enterprise skills directory not available in this checkout"
  fi
  local hits
  hits="$(grep -l '^tools:' "$ent_dir"/*/SKILL.md 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "Enterprise SKILL.md still using tools::"
    printf '  %s\n' $hits
    return 1
  fi
}

# ---------- AC5: skill-frontmatter-guard.bats enforces the reverted direction ----------

@test "AC5: skill-frontmatter-guard.bats enforces allowed-tools as canonical key" {
  local guard="$BATS_TEST_DIRNAME/skill-frontmatter-guard.bats"
  # The guard must assert that allowed-tools: is required (not forbidden).
  grep -q 'allowed-tools.*required\|allowed-tools.*declare\|declares.*allowed-tools\|allowed-tools frontmatter' "$guard" \
    || grep -q 'every plugin SKILL.md declares an allowed-tools' "$guard"
}

@test "AC5: skill-frontmatter-guard.bats forbids tools: as top-level key" {
  local guard="$BATS_TEST_DIRNAME/skill-frontmatter-guard.bats"
  grep -q 'legacy tools\|retired tools\|no plugin SKILL.md uses.*tools:' "$guard" \
    || grep -q '"\^tools:".*legacy\|forbidden.*tools:\|forbid.*tools:' "$guard"
}

# ---------- AC6: CI lint flipped ----------

@test "AC6: lint-skill-frontmatter.sh accepts allowed-tools and rejects tools:" {
  local framework_root
  framework_root="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  local repo_root="$framework_root/gaia-public"
  local lint="$repo_root/.github/scripts/lint-skill-frontmatter.sh"
  [ -f "$lint" ]
  # The lint script must treat allowed-tools as the canonical key and
  # surface retired tools: usage as an error.
  grep -qE 'allowed-tools' "$lint"
  grep -qE "retired.*tools:|tools:.*retired|forbidden.*tools:|rename.*to.*allowed-tools" "$lint"
}
