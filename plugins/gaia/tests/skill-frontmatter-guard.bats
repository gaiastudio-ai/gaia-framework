#!/usr/bin/env bats
# skill-frontmatter-guard.bats — E28-S187 regression guard.
#
# The official Claude Code skills documentation at
# https://code.claude.com/docs/en/skills confirms that `allowed-tools:` IS
# the canonical frontmatter field name in SKILL.md. Both the list form
# (`allowed-tools: [Read, Bash]`) and the string form (`allowed-tools: Read,
# Bash`) are accepted. E28-S185 mistakenly renamed the field to `tools:`
# based on a misreading of those docs; E28-S187 reverts that rename.
#
# This guard asserts:
#   - every plugin SKILL.md declares `allowed-tools:` as a top-level key;
#   - no plugin SKILL.md uses the post-E28-S185 `tools:` top-level key.
#
# The assertions fail loudly in CI so the regression cannot land.

load test_helper

setup() {
  common_setup
  PLUGIN_SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export PLUGIN_SKILLS_DIR
}

teardown() { common_teardown; }

@test "every plugin SKILL.md declares an allowed-tools frontmatter key" {
  local total with_allowed
  total="$(ls "$PLUGIN_SKILLS_DIR"/*/SKILL.md | wc -l | tr -d ' ')"
  with_allowed="$(grep -l '^allowed-tools:' "$PLUGIN_SKILLS_DIR"/*/SKILL.md | wc -l | tr -d ' ')"
  [ "$total" -ge 115 ]
  [ "$with_allowed" = "$total" ]
}

@test "no plugin SKILL.md uses the legacy tools: top-level frontmatter key" {
  local hits
  hits="$(grep -l '^tools:' "$PLUGIN_SKILLS_DIR"/*/SKILL.md 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "SKILL.md files still using the legacy tools: key (E28-S185 form):"
    printf '  %s\n' $hits
    return 1
  fi
}

@test "every allowed-tools: value uses YAML list form" {
  local offenders=""
  while IFS= read -r file; do
    local line
    line="$(grep '^allowed-tools:' "$file" | head -1)"
    if ! grep -qE '^allowed-tools:[[:space:]]*\[' <<<"$line"; then
      offenders="$offenders$file\n"
    fi
  done < <(ls "$PLUGIN_SKILLS_DIR"/*/SKILL.md)
  if [ -n "$offenders" ]; then
    echo -e "SKILL.md files not using YAML list form for allowed-tools::\n$offenders"
    return 1
  fi
}
