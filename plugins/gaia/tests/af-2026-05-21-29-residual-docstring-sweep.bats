#!/usr/bin/env bats
# AF-21-29: residual docstring/comment/display-string sweep.
# Final pass: conservative canonical-path migration for non-control-flow
# lines (comments, printf/echo/log/cat strings, markdown content, csv data,
# JS/MJS docstrings, agent personas, knowledge docs).
#
# Sweep tool: /tmp/canonical-sweep-v3.py — preserves shell control flow
# (if/elif/else/case/etc.), variable assignments, function defs, and lines
# mentioning legacy/fallback/pre-ADR-111 keywords.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "analyst.md persona output paths canonical" {
  grep -qF '.gaia/artifacts/planning-artifacts/' "$PLUGIN_ROOT/agents/analyst.md"
  ! grep -qE "Output to \`docs/planning-artifacts/\`" "$PLUGIN_ROOT/agents/analyst.md"
}

@test "tdd-reviewer.md persona refs canonical" {
  grep -qF '.gaia/artifacts/' "$PLUGIN_ROOT/agents/tdd-reviewer.md"
}

@test "token-reduction JS files canonical" {
  grep -qF '.gaia/artifacts/test-artifacts/' "$PLUGIN_ROOT/test/scripts/token-reduction/consolidate.mjs"
  grep -qF '.gaia/artifacts/test-artifacts/' "$PLUGIN_ROOT/test/scripts/token-reduction/index.js"
}

@test "stack templates Source comments canonical" {
  for stack in flutter swift react-native kotlin; do
    grep -qF '.gaia/artifacts/planning-artifacts/' "$PLUGIN_ROOT/config/stacks/$stack.yaml"
  done
}

@test "claude-code-plugin stack template canonical" {
  grep -qF '.gaia/artifacts/planning-artifacts/prd/' "$PLUGIN_ROOT/config/stacks/claude-code-plugin.yaml"
  grep -qF '.gaia/artifacts/planning-artifacts/architecture/' "$PLUGIN_ROOT/config/stacks/claude-code-plugin.yaml"
}

@test "scripts/adapters/BOUNDARIES.md canonical" {
  grep -qF '.gaia/artifacts/' "$PLUGIN_ROOT/scripts/adapters/BOUNDARIES.md"
}

@test "control-flow / smart-fallback branches preserved (gaia-create-epics)" {
  # The else-branch in smart-fallback retains legacy docs/ — sweep must NOT
  # mangle this. ARCHITECTURE/PRD keep their inline docs/ fallbacks.
  grep -qE 'else\s*$' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
  grep -qF 'ARCHITECTURE="docs/planning-artifacts/architecture.md"' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
  # AF-2026-05-27-8 / Test06 F-008: the TEST_PLAN legacy docs/ rung moved into
  # the shared resolver (finalize.sh delegates to resolve-artifact-path.sh); the
  # legacy fallback is preserved there, not inline.
  grep -qF 'resolve-artifact-path.sh' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
  # The legacy docs/test-artifacts rung is built from LEGACY_TA in the resolver.
  grep -qF 'docs/test-artifacts' "$PLUGIN_ROOT/scripts/lib/resolve-artifact-path.sh"
  grep -qF '${LEGACY_TA}/test-plan.md' "$PLUGIN_ROOT/scripts/lib/resolve-artifact-path.sh"
}

@test "control-flow / smart-fallback branches preserved (sprint-close)" {
  # AF-2026-05-22-6 Bug-10: the variable previously named `canonical` was
  # renamed to `legacy_docs` to clarify intent (the docs/ path is the LEGACY
  # location, not the canonical post-ADR-111 one). Assert against the new
  # name OR the old name so the fixture survives both pre- and post-AF-22-6
  # checkouts.
  grep -qE '(canonical|legacy_docs)="\$PROJECT_PATH/docs/implementation-artifacts/sprint-status\.yaml"' "$PLUGIN_ROOT/skills/gaia-sprint-close/scripts/close.sh"
}
