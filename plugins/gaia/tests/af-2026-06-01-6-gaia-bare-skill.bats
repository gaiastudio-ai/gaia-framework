#!/usr/bin/env bats
# AF-2026-06-01-6 — bare `/gaia` slash command has no implementing SKILL.md.
#
# Symptom (operator-reported):
#   `/gaia` returns "The file exists but produced no visible output."
#
# Root cause: the plugin advertises `/gaia` as a slash command (it shares
# the plugin's own `name: "gaia"` from .claude-plugin/plugin.json), but
# there was no `plugins/gaia/skills/gaia/SKILL.md` to back it. The
# orchestrator persona that the slug is supposed to load lives at
# `plugins/gaia/agents/orchestrator.md` — but the substrate routes
# `/gaia` to a SKILL.md, not to an agent file directly.
#
# Fix: add `plugins/gaia/skills/gaia/SKILL.md` — a thin wrapper that
# loads the orchestrator persona and presents the main routing menu.
#
# Bash-3.2 compatible. Wired into the cross-platform-portability CI
# matrix via the standard plugins/gaia/tests/ collection.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GAIA_SKILL="$PLUGIN_ROOT/skills/gaia/SKILL.md"
  ORCHESTRATOR_AGENT="$PLUGIN_ROOT/agents/orchestrator.md"
}

teardown() { common_teardown; }

# ===========================================================================
# Existence — the SKILL.md backing /gaia is on disk
# ===========================================================================

@test "AF-32-4 #/gaia: plugins/gaia/skills/gaia/SKILL.md exists" {
  [ -f "$GAIA_SKILL" ]
}

@test "AF-32-4 #/gaia: orchestrator agent persona file exists at the cited path" {
  # The fix delegates to the persona file; if the persona moves, the
  # fix breaks silently. Pin its location.
  [ -f "$ORCHESTRATOR_AGENT" ]
}

# ===========================================================================
# Frontmatter shape — the substrate registers the slug
# ===========================================================================

@test "AF-32-4 #/gaia: SKILL.md frontmatter declares name: gaia" {
  run grep -E '^name: gaia$' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

@test "AF-32-4 #/gaia: SKILL.md frontmatter declares allowed-tools includes Agent for subagent dispatch" {
  run grep -E '^allowed-tools:.*Agent' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

@test "AF-32-4 #/gaia: SKILL.md frontmatter declares argument-hint (so /gaia surfaces its arg shape)" {
  run grep -E '^argument-hint:' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

@test "AF-32-4 #/gaia: SKILL.md frontmatter declares description naming 'orchestrator'" {
  run grep -E '^description:.*orchestrator' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Body shape — the skill loads the persona; does NOT re-implement routing
# ===========================================================================

@test "AF-32-4 #/gaia: body instructs Read of the orchestrator persona file at \${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md" {
  run grep -F '${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

@test "AF-32-4 #/gaia: body forbids re-implementing orchestrator logic locally" {
  run grep -F 'Do NOT re-implement orchestrator logic here' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

@test "AF-32-4 #/gaia: body documents the 'sprint' and 'story' fast-paths" {
  run grep -F 'Sprint Execution Mode' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
  run grep -F 'Story Creation Mode' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

@test "AF-32-4 #/gaia: body hands off to /gaia-help for context-sensitive guidance (no duplication)" {
  run grep -F '/gaia-help' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Anti-duplication — the skill must NOT carry the routing categories verbatim
# (those live in the orchestrator agent file; SKILL.md keeps a single
# source of truth)
# ===========================================================================

@test "AF-32-4 #/gaia: SKILL.md does NOT carry the orchestrator's full Routing Categories table" {
  # The orchestrator file lists ## Routing Categories with **LIFECYCLE** /
  # **CREATIVE** / **TESTING** etc. as the heading anchors. If the SKILL
  # duplicates them verbatim we get the drift class the FR-327 / ADR-048
  # 'framework knowledge lives in SKILL.md files' rule was written to
  # prevent. Allow naming them in prose; reject the H2 anchor.
  run grep -E '^## Routing Categories$' "$GAIA_SKILL"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# Integration sanity — the orchestrator persona's title matches the
# skill's framing (so the user always sees "Gaia" on first turn)
# ===========================================================================

@test "AF-32-4 #/gaia: SKILL.md identifies the persona as 'Gaia'" {
  run grep -F 'Gaia' "$GAIA_SKILL"
  [ "$status" -eq 0 ]
}

@test "AF-32-4 #/gaia: orchestrator agent file declares the same persona name 'Gaia'" {
  run grep -F 'You are **Gaia**' "$ORCHESTRATOR_AGENT"
  [ "$status" -eq 0 ]
}
