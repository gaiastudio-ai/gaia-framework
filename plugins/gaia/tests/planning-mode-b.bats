#!/usr/bin/env bats
# planning-mode-b.bats — Mode B readiness tests for the 10 planning-lifecycle
# skills.
#
# Covers the planning-lifecycle Mode B migration:
#   AC1 — each skill spawns its authoring subagent via the shared library seam
#   AC2 — create-prd artifact structure is identical between modes
#   AC3 — create-arch artifact structure is identical between modes
#   AC4 — existing skill bats remain green (exercised by separate suites)
#   AC5 — shutdown is called at skill exit (no leaked panes)

load 'test_helper.bash'

setup() {
  common_setup

  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  LIB_DIR="$SCRIPTS_DIR/lib"
  DT_LIB="$LIB_DIR/dispatch-teammate.sh"
  PMB_LIB="$LIB_DIR/planning-mode-b-bridge.sh"

  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

  # The 10 planning-lifecycle skills under migration.
  PLANNING_SKILLS=(
    gaia-create-prd
    gaia-create-arch
    gaia-create-epics
    gaia-create-ux
    gaia-create-story
    gaia-product-brief
    gaia-edit-prd
    gaia-edit-arch
    gaia-edit-ux
    gaia-edit-test-plan
  )

  # Session dirs for dispatch-teammate.
  export GAIA_SESSION_DIR="$TEST_TMP/session"
  export GAIA_PROVENANCE_LOG="$TEST_TMP/session/provenance.log"
  export GAIA_SESSION_TRANSCRIPT="$TEST_TMP/session/transcript.md"
  mkdir -p "$GAIA_SESSION_DIR"

  # Force substrate unavailable — tests exercise plumbing + fallback.
  export GAIA_MODE_B_SUBSTRATE="${GAIA_MODE_B_SUBSTRATE:-unavailable}"
}

teardown() { common_teardown; }

# ============================================================
# Bridge library reachability + public seam
# ============================================================

@test "planning bridge library exists at canonical lib path" {
  [ -f "$PMB_LIB" ]
}

@test "planning bridge sources dispatch-teammate library" {
  grep -qF "dispatch-teammate.sh" "$PMB_LIB"
}

@test "planning bridge exposes planning_spawn_subagent function (AC1)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  declare -F planning_spawn_subagent
}

@test "planning bridge exposes planning_relay_turn function" {
  source "$DT_LIB"
  source "$PMB_LIB"
  declare -F planning_relay_turn
}

@test "planning bridge exposes planning_shutdown function (AC5)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  declare -F planning_shutdown
}

# ============================================================
# AC1 — spawn seam routes through spawn_teammate
# ============================================================

@test "planning_spawn_subagent calls spawn_teammate and returns a handle (AC1)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  local handle
  handle="$(planning_spawn_subagent "gaia:pm" "gaia-create-prd" 2>/dev/null)"
  [ -n "$handle" ]
}

@test "planning_spawn_subagent registers in dispatch-teammate registry (AC1)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  planning_spawn_subagent "gaia:architect" "gaia-create-arch" >/dev/null 2>&1
  local count
  count="$(_dt_active_count)"
  [ "$count" -ge 1 ]
}

@test "planning_spawn_subagent records teammate dispatch provenance (AC1)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  planning_spawn_subagent "gaia:ux-designer" "gaia-create-ux" >/dev/null 2>&1
  grep -qF "dispatched_via:teammate" "$GAIA_PROVENANCE_LOG"
}

@test "planning_spawn_subagent rejects reviewer persona via clean-room gate (AC1)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  run planning_spawn_subagent "validator" "gaia-create-prd"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

# ============================================================
# AC1 (doc) — each of the 10 skills declares Mode B readiness
# ============================================================

@test "each planning skill declares a Mode B Readiness section (AC1)" {
  for skill in "${PLANNING_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$md" ] || { echo "missing SKILL.md: $skill"; return 1; }
    grep -qiF "Mode B Readiness" "$md" || { echo "no Mode B Readiness in $skill"; return 1; }
  done
}

@test "each planning skill names the shared bridge library (AC1)" {
  for skill in "${PLANNING_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "planning-mode-b-bridge.sh" "$md" || { echo "no bridge ref in $skill"; return 1; }
  done
}

@test "each planning skill names the spawn seam (AC1)" {
  for skill in "${PLANNING_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "planning_spawn_subagent" "$md" || { echo "no spawn seam in $skill"; return 1; }
  done
}

@test "each planning skill names the shutdown seam (AC5)" {
  for skill in "${PLANNING_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "planning_shutdown" "$md" || { echo "no shutdown seam in $skill"; return 1; }
  done
}

# ============================================================
# AC2 — create-prd artifact structure identical between modes
# ============================================================

@test "create-prd spawn under Mode B yields a handle for the pm subagent (AC2)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  local handle
  handle="$(planning_spawn_subagent "gaia:pm" "gaia-create-prd" 2>/dev/null)"
  [ -n "$handle" ]
  local persona
  persona="$(_dt_read_persona "$handle")"
  [ "$persona" = "gaia:pm" ]
}

@test "create-prd relay carries authored content verbatim into transcript (AC2)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  local handle
  handle="$(planning_spawn_subagent "gaia:pm" "gaia-create-prd" 2>/dev/null)"
  drive_turn "$handle" "draft PRD" 2>/dev/null
  planning_relay_turn "$handle" "$(printf '## Goals\n- G1: ship the feature')" 2>/dev/null
  grep -qF "## Goals" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "G1: ship the feature" "$GAIA_SESSION_TRANSCRIPT"
}

# ============================================================
# AC3 — create-arch artifact structure identical between modes
# ============================================================

@test "create-arch spawn under Mode B yields a handle for the architect subagent (AC3)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  local handle
  handle="$(planning_spawn_subagent "gaia:architect" "gaia-create-arch" 2>/dev/null)"
  [ -n "$handle" ]
  local persona
  persona="$(_dt_read_persona "$handle")"
  [ "$persona" = "gaia:architect" ]
}

@test "create-arch relay carries authored content verbatim into transcript (AC3)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  local handle
  handle="$(planning_spawn_subagent "gaia:architect" "gaia-create-arch" 2>/dev/null)"
  drive_turn "$handle" "draft architecture" 2>/dev/null
  planning_relay_turn "$handle" "$(printf '## Components\n- API gateway')" 2>/dev/null
  grep -qF "## Components" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "API gateway" "$GAIA_SESSION_TRANSCRIPT"
}

# ============================================================
# AC5 — shutdown at skill exit (no leaked panes)
# ============================================================

@test "planning_shutdown clears all active teammates (AC5)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  planning_spawn_subagent "gaia:pm" "gaia-create-prd" >/dev/null 2>&1
  planning_spawn_subagent "gaia:architect" "gaia-create-arch" >/dev/null 2>&1
  [ "$(_dt_active_count)" -ge 2 ]
  planning_shutdown 2>/dev/null
  [ "$(_dt_active_count)" -eq 0 ]
}

@test "planning_shutdown is idempotent with no active teammates (AC5)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  run planning_shutdown
  [ "$status" -eq 0 ]
}

# ============================================================
# AC1/AC5 — fallback honesty (substrate-gated)
# ============================================================

@test "planning_spawn_subagent emits MODE_B_FALLBACK when substrate absent — substrate-gated (AC1)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  planning_spawn_subagent "gaia:pm" "gaia-create-prd" >"$TEST_TMP/handle.txt" 2>"$stderr_out"
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "planning drive_turn is bookkeeping-only — no send, no MODE_B_FALLBACK (AC1)" {
  source "$DT_LIB"
  source "$PMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local handle
  handle="$(planning_spawn_subagent "gaia:architect" "gaia-create-arch" 2>/dev/null)"
  local stderr_out="$TEST_TMP/stderr.txt"
  run drive_turn "$handle" "draft" 2>"$stderr_out"
  [ "$status" -eq 0 ]
  # drive_turn never sends (the orchestrator's SendMessage does) so it never
  # falls back — regression guard for the old fallback-emitting stub.
  ! grep -qF "MODE_B_FALLBACK" "$stderr_out"
  await_reply "$handle"
}

# ============================================================
# No leaked IDs in the new bridge (regression gate)
# ============================================================

@test "planning-mode-b-bridge.sh contains no leaked internal IDs (regression)" {
  local f="$PMB_LIB"
  run grep -cE '(FR|NFR|ADR|TC)-[0-9]' "$f"
  [ "${output:-0}" -eq 0 ]
  run grep -cE 'E[0-9]+-S[0-9]+' "$f"
  [ "${output:-0}" -eq 0 ]
}
