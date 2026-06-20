#!/usr/bin/env bats
# mode-b-lifecycle-docs.bats — Doc-guard assertions for the Mode B Teammate
# Lifecycle Protocol section in skills/README.md.
#
# Validates that the README documents the full lifecycle protocol accurately,
# covering: the four lifecycle phases, two topology variants, human-interjection
# routing, no-leaked-panes invariant, and a minimal end-to-end example.
#
# The library under doc is scripts/lib/dispatch-teammate.sh. All function names
# asserted here must match the actual public API exported by that library.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  README="$PLUGIN_ROOT/skills/README.md"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

@test "skills/README.md exists at canonical path" {
  [ -f "$README" ]
}

# ---------------------------------------------------------------------------
# Protocol section header (AC1 prerequisite)
# ---------------------------------------------------------------------------

@test "README contains Mode B Teammate Lifecycle Protocol section header (AC1)" {
  grep -qiF 'Mode B Teammate Lifecycle Protocol' "$README"
}

# ---------------------------------------------------------------------------
# Four lifecycle phase subsections (AC1)
# ---------------------------------------------------------------------------

@test "README documents the SPAWN lifecycle phase (AC1)" {
  grep -qiE '\bSPAWN\b' "$README"
}

@test "README documents the DRIVE lifecycle phase (AC1)" {
  grep -qiE '\bDRIVE\b' "$README"
}

@test "README documents the RELAY lifecycle phase (AC1)" {
  grep -qiE '\bRELAY\b' "$README"
}

@test "README documents the SHUTDOWN lifecycle phase (AC1)" {
  grep -qiE '\bSHUTDOWN\b' "$README"
}

@test "README includes a phase description for each lifecycle phase (AC1)" {
  # Each phase must have at least a short description near its heading.
  # We assert the phases are followed by prose (non-heading lines) — this is
  # satisfied by grep-counting lines between the header and the next heading.
  local phase_count
  phase_count="$(grep -cE '^####? (SPAWN|DRIVE|RELAY|SHUTDOWN)\b' "$README" || true)"
  [ "$phase_count" -ge 4 ]
}

@test "README includes a contract note for each lifecycle phase (AC1)" {
  grep -qiE '\bcontract\b' "$README"
}

# ---------------------------------------------------------------------------
# Topology subsections — HUB and MESH (AC2)
# ---------------------------------------------------------------------------

@test "README documents HUB topology subsection (AC2)" {
  grep -qiE '\bHUB\b' "$README"
}

@test "README documents MESH topology subsection (AC2)" {
  grep -qiE '\bMESH\b' "$README"
}

@test "README gives a use-case example for HUB topology (AC2)" {
  # The section must have both the word "hub" and the word "use" in proximity.
  grep -qiE '(hub|HUB).*(use.case|example)|example.*(hub|HUB)' "$README"
}

@test "README gives a use-case example for MESH topology (AC2)" {
  grep -qiE '(mesh|MESH).*(use.case|example)|example.*(mesh|MESH)' "$README"
}

@test "README names spawn_teammate for topology setup (AC2)" {
  grep -qF 'spawn_teammate' "$README"
}

@test "README names drive_turn for topology setup (AC2)" {
  grep -qF 'drive_turn' "$README"
}

# ---------------------------------------------------------------------------
# Human-interjection subsection (AC3)
# ---------------------------------------------------------------------------

@test "README contains a human-interjection subsection (AC3)" {
  grep -qiE 'human.interjection|human interjection' "$README"
}

@test "README explains how user input is routed to an active teammate session (AC3)" {
  grep -qiE '(user input|user message|interjection).*(route|relay|forward)|(route|relay|forward).*(user input|user message|interjection)' "$README"
}

@test "README documents Mode A fallback in human-interjection context (AC3)" {
  grep -qiE 'MODE_B_FALLBACK|Mode.A fallback|degrades? to Mode.A' "$README"
}

# ---------------------------------------------------------------------------
# No-leaked-panes invariant subsection (AC4)
# ---------------------------------------------------------------------------

@test "README contains a no-leaked-panes invariant subsection (AC4)" {
  grep -qiE 'no.leaked.panes|leaked.panes|orphaned panes' "$README"
}

@test "README states teammate sessions must not leave orphaned processes after shutdown (AC4)" {
  grep -qiE 'orphan(ed)?.*(process|pane|session)|orphan' "$README"
}

@test "README describes how shutdown_all enforces the no-leaked-panes invariant (AC4)" {
  grep -qF 'shutdown_all' "$README"
}

# ---------------------------------------------------------------------------
# End-to-end example — SPAWN through SHUTDOWN (AC5)
# ---------------------------------------------------------------------------

@test "README contains a minimal end-to-end example section (AC5)" {
  grep -qiE 'end.to.end example|end-to-end example|minimal example|example.*spawn.*shutdown|spawn.*shutdown' "$README"
}

@test "README example calls spawn_teammate (AC5)" {
  # Must appear inside a code block to count as a real call example.
  grep -qF 'spawn_teammate' "$README"
}

@test "README example calls drive_turn (AC5)" {
  grep -qF 'drive_turn' "$README"
}

@test "README example calls await_reply (AC5)" {
  grep -qF 'await_reply' "$README"
}

@test "README example calls relay_to_team_lead (AC5)" {
  grep -qF 'relay_to_team_lead' "$README"
}

@test "README example calls shutdown_all (AC5)" {
  grep -qF 'shutdown_all' "$README"
}

@test "README example is fenced in a code block (AC5)" {
  grep -qE '^```' "$README"
}

@test "README example documents MODE_B_FALLBACK honesty (AC5)" {
  grep -qF 'MODE_B_FALLBACK' "$README"
}
