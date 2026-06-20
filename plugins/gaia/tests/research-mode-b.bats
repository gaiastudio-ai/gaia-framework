#!/usr/bin/env bats
# research-mode-b.bats — Mode B readiness tests for the 16
# research / testing / infrastructure / misc skills.
#
# Covers the Mode B migration for this skill cohort:
#   AC1 — each skill runs its working subagent via the shared library seam
#   AC2 — deploy runs under Mode B
#   AC3 — init runs under Mode B
#   AC4 — existing skill bats remain green (exercised by separate suites)
#   AC5 — shutdown is routed at skill exit (no leaked panes)

load 'test_helper.bash'

setup() {
  common_setup

  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  LIB_DIR="$SCRIPTS_DIR/lib"
  DT_LIB="$LIB_DIR/dispatch-teammate.sh"
  RMB_LIB="$LIB_DIR/research-mode-b-bridge.sh"

  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

  # The 16 skills under migration.
  RESEARCH_SKILLS=(
    gaia-nfr
    gaia-advanced-elicitation
    gaia-market-research
    gaia-tech-research
    gaia-domain-research
    gaia-innovation
    gaia-infra-design
    gaia-deploy
    gaia-init
    gaia-brownfield
    gaia-mobile-testing
    gaia-perf-testing
    gaia-test-a11y
    gaia-test-perf
    gaia-a11y-testing
    gaia-storytelling
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

@test "research bridge library exists at canonical lib path" {
  [ -f "$RMB_LIB" ]
}

@test "research bridge sources dispatch-teammate library" {
  grep -qF "dispatch-teammate.sh" "$RMB_LIB"
}

@test "research bridge exposes research_spawn_subagent function (AC1)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  declare -F research_spawn_subagent
}

@test "research bridge exposes research_relay_turn function" {
  source "$DT_LIB"
  source "$RMB_LIB"
  declare -F research_relay_turn
}

@test "research bridge exposes research_shutdown function (AC5)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  declare -F research_shutdown
}

# ============================================================
# AC1 — spawn seam routes through spawn_teammate
# ============================================================

@test "research_spawn_subagent runs spawn_teammate and returns a handle (AC1)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  local handle
  handle="$(research_spawn_subagent "gaia:analyst" "gaia-market-research" 2>/dev/null)"
  [ -n "$handle" ]
}

@test "research_spawn_subagent registers in dispatch-teammate registry (AC1)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  research_spawn_subagent "gaia:devops" "gaia-infra-design" >/dev/null 2>&1
  local count
  count="$(_dt_active_count)"
  [ "$count" -ge 1 ]
}

@test "research_spawn_subagent records teammate dispatch provenance (AC1)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  research_spawn_subagent "gaia:devops" "gaia-perf-testing" >/dev/null 2>&1
  grep -qF "dispatched_via:teammate" "$GAIA_PROVENANCE_LOG"
}

@test "research_spawn_subagent rejects reviewer persona via clean-room gate (AC1)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  run research_spawn_subagent "validator" "gaia-nfr"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

# ============================================================
# AC1 (doc) — each of the 16 skills declares Mode B readiness
# ============================================================

@test "each research skill declares a Mode B Readiness section (AC1)" {
  for skill in "${RESEARCH_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$md" ] || { echo "missing SKILL.md: $skill"; return 1; }
    grep -qiF "Mode B Readiness" "$md" || { echo "no Mode B Readiness in $skill"; return 1; }
  done
}

@test "each research skill names the shared bridge library (AC1)" {
  for skill in "${RESEARCH_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "research-mode-b-bridge.sh" "$md" || { echo "no bridge ref in $skill"; return 1; }
  done
}

@test "each research skill names the spawn seam (AC1)" {
  for skill in "${RESEARCH_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "research_spawn_subagent" "$md" || { echo "no spawn seam in $skill"; return 1; }
  done
}

@test "each research skill names the shutdown seam (AC5)" {
  for skill in "${RESEARCH_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "research_shutdown" "$md" || { echo "no shutdown seam in $skill"; return 1; }
  done
}

# ============================================================
# AC2 — deploy runs under Mode B
# ============================================================

@test "deploy spawn under Mode B yields a handle for the devops subagent (AC2)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  local handle
  handle="$(research_spawn_subagent "gaia:devops" "gaia-deploy" 2>/dev/null)"
  [ -n "$handle" ]
  local persona
  persona="$(_dt_read_persona "$handle")"
  [ "$persona" = "gaia:devops" ]
}

@test "deploy relay carries content verbatim into transcript (AC2)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  local handle
  handle="$(research_spawn_subagent "gaia:devops" "gaia-deploy" 2>/dev/null)"
  drive_turn "$handle" "deploy checklist" 2>/dev/null
  research_relay_turn "$handle" "$(printf '## Deploy\n- step: roll forward')" 2>/dev/null
  grep -qF "## Deploy" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "step: roll forward" "$GAIA_SESSION_TRANSCRIPT"
}

# ============================================================
# AC3 — init runs under Mode B
# ============================================================

@test "init spawn under Mode B yields a handle for the devops subagent (AC3)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  local handle
  handle="$(research_spawn_subagent "gaia:devops" "gaia-init" 2>/dev/null)"
  [ -n "$handle" ]
  local persona
  persona="$(_dt_read_persona "$handle")"
  [ "$persona" = "gaia:devops" ]
}

@test "init relay carries content verbatim into transcript (AC3)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  local handle
  handle="$(research_spawn_subagent "gaia:devops" "gaia-init" 2>/dev/null)"
  drive_turn "$handle" "bootstrap config" 2>/dev/null
  research_relay_turn "$handle" "$(printf '## Config\n- shape: single-stack')" 2>/dev/null
  grep -qF "## Config" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "shape: single-stack" "$GAIA_SESSION_TRANSCRIPT"
}

# ============================================================
# AC5 — shutdown at skill exit (no leaked panes)
# ============================================================

@test "research_shutdown clears all active teammates (AC5)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  research_spawn_subagent "gaia:devops" "gaia-deploy" >/dev/null 2>&1
  research_spawn_subagent "gaia:devops" "gaia-perf-testing" >/dev/null 2>&1
  [ "$(_dt_active_count)" -ge 2 ]
  research_shutdown 2>/dev/null
  [ "$(_dt_active_count)" -eq 0 ]
}

@test "research_shutdown is idempotent with no active teammates (AC5)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  run research_shutdown
  [ "$status" -eq 0 ]
}

# ============================================================
# AC1/AC5 — fallback honesty (substrate-gated)
# ============================================================

@test "research_spawn_subagent emits MODE_B_FALLBACK when substrate absent — substrate-gated (AC1)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  research_spawn_subagent "gaia:analyst" "gaia-tech-research" >"$TEST_TMP/handle.txt" 2>"$stderr_out"
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "research_relay_turn drive emits MODE_B_FALLBACK under substrate-absent — substrate-gated (AC1)" {
  source "$DT_LIB"
  source "$RMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local handle
  handle="$(research_spawn_subagent "gaia:devops" "gaia-deploy" 2>/dev/null)"
  local stderr_out="$TEST_TMP/stderr.txt"
  drive_turn "$handle" "draft" 2>"$stderr_out" || true
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

# ============================================================
# No leaked IDs in the new bridge (regression gate)
# ============================================================

@test "research-mode-b-bridge.sh contains no leaked internal IDs (regression)" {
  local f="$RMB_LIB"
  run grep -cE '(FR|NFR|ADR|TC)-[0-9]' "$f"
  [ "${output:-0}" -eq 0 ]
  run grep -cE 'E[0-9]+-S[0-9]+' "$f"
  [ "${output:-0}" -eq 0 ]
}
