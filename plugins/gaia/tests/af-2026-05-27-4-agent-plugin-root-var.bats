#!/usr/bin/env bats
# af-2026-05-27-4-agent-plugin-root-var.bats
#
# AF-2026-05-27-4 / Test05 F-010.
#
# Agent `!`-prefixed memory-loader header lines used `${PLUGIN_DIR}`, which is
# NOT a Claude Code substrate variable (the documented var is
# `${CLAUDE_PLUGIN_ROOT}`, per the Plugins reference — path variables are
# substituted inline in agent content). The bad var expanded to empty, so the
# header resolved to `!/scripts/memory-loader.sh ...` and the memory load
# silently no-op'd. This suite locks the header to ${CLAUDE_PLUGIN_ROOT}.

load 'test_helper.bash'

setup() {
  common_setup
  AGENTS_DIR="$(cd "$BATS_TEST_DIRNAME/../agents" && pwd)"
}
teardown() { common_teardown; }

@test "F-010: NO agent !-header memory-loader line uses \${PLUGIN_DIR}" {
  run bash -c "grep -rlF '!\${PLUGIN_DIR}/scripts/memory-loader.sh' '$AGENTS_DIR'/*.md 2>/dev/null || true"
  [ -z "$output" ]
}

@test "F-010: every agent that loads memory uses \${CLAUDE_PLUGIN_ROOT} in the header" {
  # Count agents with a memory-loader header; all such headers must be the
  # CLAUDE_PLUGIN_ROOT form. (Excludes _SCHEMA.md template, also checked below.)
  local total ok
  total=$(grep -rlE '^!\$\{(PLUGIN_DIR|CLAUDE_PLUGIN_ROOT)\}/scripts/memory-loader\.sh' "$AGENTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
  ok=$(grep -rlF '!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh' "$AGENTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$total" -gt 0 ]
  [ "$total" -eq "$ok" ]
}

@test "F-010: _SCHEMA.md template uses \${CLAUDE_PLUGIN_ROOT}, not \${PLUGIN_DIR}" {
  grep -qF '!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh <agent-name> ground-truth' "$AGENTS_DIR/_SCHEMA.md"
  ! grep -qF '!${PLUGIN_DIR}/scripts/memory-loader.sh <agent-name> ground-truth' "$AGENTS_DIR/_SCHEMA.md"
}

@test "F-010: _SCHEMA.md documents CLAUDE_PLUGIN_ROOT as the substrate var (not PLUGIN_DIR)" {
  grep -qF '${CLAUDE_PLUGIN_ROOT}` is the canonical Claude Code substrate variable' "$AGENTS_DIR/_SCHEMA.md"
}

@test "F-010: validator.md self-defined bash-block \$PLUGIN_DIR fallback is preserved" {
  # The bash-block local with the ${PLUGIN_DIR:-$(...)} fallback is legitimate
  # (it resolves itself); only the !-header was the broken substrate reference.
  grep -qF 'PLUGIN_DIR="${PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"' "$AGENTS_DIR/validator.md"
  # And validator's OWN memory-loader header is the fixed form.
  grep -qF '!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh validator ground-truth' "$AGENTS_DIR/validator.md"
}
