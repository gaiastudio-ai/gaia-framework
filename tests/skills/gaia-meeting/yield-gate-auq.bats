#!/usr/bin/env bats
# yield-gate-auq.bats — E76-S18 / AF-2026-05-10-1 substrate-replacement contract
#
# Story: E76-S18 — AskUserQuestion 5-boundary yield primitive — substrate
# replacement for stdout-sentinel mechanism.
#
# This file holds the bats-runnable subset of the TC-MTG-AUQ-* test suite
# documented in ATDD `docs/test-artifacts/atdd-E76-S18.md`. The manual
# transcript-inspection tests (TC-MTG-AUQ-2/5/8/11/14 substrate-halt under
# Auto Mode) are documented in the ATDD file but are NOT bats-runnable —
# they require a live `/gaia-meeting` invocation.
#
# Bats-runnable test surface (4 static checks):
#
#   AC7  yield-gate.sh emits ZERO `<<YIELD-STOP` sentinel lines
#   AC7  yield-gate.sh preserves last_checkpoint_phase + last_yield_emitted_at
#   AC7  yield-gate.sh accepts --side-effect-only flag (default behavior under AF-2026-05-10-1)
#   AC8  SKILL.md §Procedure yield-boundary subsections each contain an AskUserQuestion call (5 boundaries)
#   cross-cut E76-S15 — gaia-meeting-stdout-sentinel-forbid.bats live-SKILL.md scan exits clean

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting"
  HELPER="$SKILL_DIR/scripts/yield-gate.sh"
  SESSION_HELPER="$SKILL_DIR/scripts/session-state.sh"
  SCANNER="$SKILL_DIR/scripts/stdout-sentinel-scan.sh"
  SKILL_MD="$SKILL_DIR/SKILL.md"

  TMP="$(mktemp -d)"
  SESSION_FILE="$TMP/2026-05-10-test.yaml"
}

teardown() {
  rm -rf "$TMP"
}

# --- AC7 — yield-gate.sh sentinel-emission removed ---------------------------

@test "AC7: yield-gate.sh contains ZERO '<<YIELD-STOP' literal strings" {
  count="$(grep -c '<<YIELD-STOP' "$HELPER" || true)"
  [ "$count" -eq 0 ]
}

@test "AC7: yield-gate.sh produces ZERO stdout output (default invocation)" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-auq-001" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id sess-auq-001
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "AC7: yield-gate.sh preserves session-state writes (last_checkpoint_phase + last_yield_emitted_at)" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-auq-002" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id sess-auq-002
  [ "$status" -eq 0 ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "pre-save" ]
  iso_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_emitted_at)"
  [[ "$iso_val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "AC7: yield-gate.sh accepts --side-effect-only flag (idempotent with default)" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-auq-003" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-research --session-id sess-auq-003 --side-effect-only
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "post-research" ]
}

@test "AC7: yield-gate.sh has at least 2 session-state write call sites (last_checkpoint_phase + last_yield_emitted_at)" {
  count_phase="$(grep -c 'last_checkpoint_phase' "$HELPER" || true)"
  count_iso="$(grep -c 'last_yield_emitted_at' "$HELPER" || true)"
  [ "$count_phase" -ge 1 ]
  [ "$count_iso" -ge 1 ]
}

# --- AC8 — SKILL.md procedure prose contains AskUserQuestion at 5 boundaries

# The SKILL.md §Procedure subsections at the 5 yield boundaries MUST each
# contain a documented AskUserQuestion call. We assert this by counting the
# number of yield-boundary subsection headers that have an AskUserQuestion
# reference within their body.

@test "AC8: SKILL.md post-CHARTER yield procedure references AskUserQuestion" {
  # Match anywhere from "Post-CHARTER checkpoint yield" until the next ##/###
  # heading. Use awk for the subsection extraction.
  body="$(awk '
    /^### .*[Pp]ost-CHARTER/ || /[Pp]ost-CHARTER (checkpoint )?yield/ { in_sect=1 }
    in_sect && /^### / && !/[Pp]ost-CHARTER/ { in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "AC8: SKILL.md post-RESEARCH yield procedure references AskUserQuestion" {
  body="$(awk '
    /[Pp]ost-RESEARCH (checkpoint )?yield/ { in_sect=1 }
    in_sect && /^### / { c++; if (c>1) in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "AC8: SKILL.md discuss-cadence yield procedure references AskUserQuestion" {
  body="$(awk '
    /[Dd]iscuss-cadence|[Ee]very-N DISCUSS/ { in_sect=1 }
    in_sect && /^### / { c++; if (c>1) in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "AC8: SKILL.md pre-CLOSE yield procedure references AskUserQuestion" {
  body="$(awk '
    /[Pp]re-CLOSE (checkpoint )?yield/ { in_sect=1 }
    in_sect && /^### / { c++; if (c>1) in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "AC8: SKILL.md pre-SAVE yield procedure references AskUserQuestion" {
  body="$(awk '
    /[Pp]re-SAVE (checkpoint )?yield/ { in_sect=1 }
    in_sect && /^### / { c++; if (c>1) in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "AC8: SKILL.md §Procedure subsections contain ZERO '<<YIELD-STOP' tokens (cross-cut E76-S15)" {
  run "$SCANNER" "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
