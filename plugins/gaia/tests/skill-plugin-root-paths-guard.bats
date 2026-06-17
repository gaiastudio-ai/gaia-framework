#!/usr/bin/env bats
# skill-plugin-root-paths-guard.bats — E28-S203 regression guard.
#
# Story: E28-S203 — Fix SKILL.md ${CLAUDE_PLUGIN_ROOT}/../scripts/ -> /scripts/
# path typo in 11 skills.
#
# Context: ${CLAUDE_PLUGIN_ROOT} is set by Claude Code when it loads the plugin
# and already points at plugins/gaia/ (the directory containing
# .claude-plugin/plugin.json). Helper scripts live INSIDE that plugin root at
# scripts/<helper>.sh — so every path reference from a SKILL.md MUST be
# ${CLAUDE_PLUGIN_ROOT}/scripts/<helper>.sh. The pattern
# ${CLAUDE_PLUGIN_ROOT}/../scripts/<helper>.sh is malformed: it climbs one
# directory above the plugin root, where scripts/ does not exist, and every LLM
# invocation that follows the prose fails with "no such file or directory"
# before the LLM self-corrects.
#
# This guard scans every SKILL.md under plugins/gaia/skills/*/ and fails if the
# malformed ${CLAUDE_PLUGIN_ROOT}/../scripts/ pattern reappears. On failure it
# prints each offending file and line so the regression is trivial to locate.

load test_helper

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
  export PLUGIN_ROOT SKILLS_DIR
}

teardown() { common_teardown; }

# ---------- AC1, AC3: no SKILL.md may contain ${CLAUDE_PLUGIN_ROOT}/../scripts/ ----------

@test "no SKILL.md contains \${CLAUDE_PLUGIN_ROOT}/../scripts/<helper> (the '../' path typo)" {
  local hits
  hits="$(grep -rnE '\$\{CLAUDE_PLUGIN_ROOT\}/\.\./scripts' "$SKILLS_DIR"/*/SKILL.md 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "SKILL.md files still reference \${CLAUDE_PLUGIN_ROOT}/../scripts/ — helper scripts live INSIDE the plugin root at scripts/, not a sibling directory. The '../' is a path typo and every invocation fails with 'no such file or directory'. Rewrite each match to \${CLAUDE_PLUGIN_ROOT}/scripts/<helper>.sh:"
    printf '  %s\n' "$hits"
    return 1
  fi
}
