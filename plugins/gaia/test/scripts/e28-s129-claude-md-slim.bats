#!/usr/bin/env bats
# e28-s129-claude-md-slim.bats — bats tests for the slim CLAUDE.md (E28-S129)
#
# Asserts NFR-049 size cap + FR-327 content scope against gaia-framework/CLAUDE.md.
# The file is the single source of truth for the slim content; the project-root
# CLAUDE.md (NFR-049 normative target) is synced from this copy byte-identically.
#
# RED phase: gaia-framework/CLAUDE.md does not yet exist — tests fail until Green
# writes the file.

PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
GAIA_PUBLIC="$(cd "$PLUGIN_DIR/../.." && pwd)"
CLAUDE_MD="$GAIA_PUBLIC/CLAUDE.md"

@test "E28-S129: gaia-framework/CLAUDE.md exists" {
  [ -f "$CLAUDE_MD" ]
}

@test "E28-S129: AC1 line count is in [30, 50] range" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  local count
  count=$(wc -l < "$CLAUDE_MD" | tr -d ' ')
  [ "$count" -ge 30 ]
  [ "$count" -le 50 ]
}

@test "E28-S129: AC5 first non-empty line matches version heading regex" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  local first_line
  first_line=$(grep -m1 -v '^$' "$CLAUDE_MD")
  [[ "$first_line" =~ ^\#\ GAIA\ Framework\ v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]
}

@test "E28-S129: AC2 contains Environment section" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  grep -qE '^## Environment' "$CLAUDE_MD"
}

@test "E28-S129: AC2 contains How to Start section" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  grep -qE '^## How to Start' "$CLAUDE_MD"
}

@test "E28-S129: AC2 contains Hard Rules section" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  grep -qE '^## Hard Rules' "$CLAUDE_MD"
}

@test "E28-S129: AC3 does NOT contain 'workflow engine' narrative" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  ! grep -qiE 'workflow engine' "$CLAUDE_MD"
}

@test "E28-S129: AC3 does NOT contain 'Step Execution' / 'Checkpoint Discipline' / 'Config Resolution' section headers" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  ! grep -qE '^### (Step Execution|Checkpoint Discipline|Config Resolution|Context Budget|Quality Gates|Sprint-Status Write Safety)' "$CLAUDE_MD"
}

@test "E28-S129: AC3 does NOT contain workflow.xml / .resolved/ / core/protocols references" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  ! grep -qE 'workflow\.xml|\.resolved/|core/protocols' "$CLAUDE_MD"
}

@test "E28-S129: AC3 does NOT contain Sprint State Machine section" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  ! grep -qE '^## Sprint State Machine' "$CLAUDE_MD"
}

@test "E28-S129: AC3 does NOT contain Naming Conventions section" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  ! grep -qE '^## Naming Conventions' "$CLAUDE_MD"
}

@test "E28-S129: AC3 does NOT contain Developer Agent System section" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  ! grep -qE '^## Developer Agent System' "$CLAUDE_MD"
}

@test "E28-S129: AC3 does NOT contain Memory Hygiene section" {
  [ -f "$CLAUDE_MD" ] || skip "CLAUDE.md not yet present"
  ! grep -qE '^## Memory Hygiene' "$CLAUDE_MD"
}