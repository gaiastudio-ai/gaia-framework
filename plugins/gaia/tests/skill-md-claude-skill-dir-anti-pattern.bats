#!/usr/bin/env bats
# skill-md-claude-skill-dir-anti-pattern.bats — permanent regression guard (E92-S3)
#
# Anchor: AI-2026-05-15-1 — PostToolUse hook ${CLAUDE_SKILL_DIR} substitution failure.
# Story:  E92-S3.
#
# ${CLAUDE_SKILL_DIR} is NOT a substrate-supplied substitution variable in
# the Claude Code hook substrate. Using it in SKILL.md frontmatter or in
# _reference-frontmatter.md silently expands to empty string and produces
# bogus bare-root paths (e.g. /scripts/checkpoint.sh) that fail to execute
# non-blocking on every Edit/Write. Use ${CLAUDE_PLUGIN_ROOT}/skills/<skill>/...
# instead — that variable IS substrate-supplied and works everywhere else
# in GAIA.

load 'test_helper.bash'

SKILLS_DIR="$BATS_TEST_DIRNAME/../skills"

@test "no SKILL.md under plugins/gaia/skills/ contains \${CLAUDE_SKILL_DIR}" {
  run bash -c "grep -rln '\${CLAUDE_SKILL_DIR}' \"$SKILLS_DIR\"/*/SKILL.md 2>/dev/null || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no _reference-frontmatter.md under plugins/gaia/skills/ contains \${CLAUDE_SKILL_DIR}" {
  run bash -c "grep -rln '\${CLAUDE_SKILL_DIR}' \"$SKILLS_DIR\"/*/_reference-frontmatter.md 2>/dev/null || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
