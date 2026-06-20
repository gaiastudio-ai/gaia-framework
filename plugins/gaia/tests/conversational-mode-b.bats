#!/usr/bin/env bats
# conversational-mode-b.bats — Mode B readiness for the conversational skills.
#
# Asserts the wiring (not a live persistent-teammate round-trip, which the
# substrate cannot exercise in this build):
#   - each conversational SKILL.md declares Mode B readiness + routes
#     participant dispatch through the shared library;
#   - the shared dispatch library is reachable;
#   - the conversational Mode B bridge sources the shared library and exposes
#     a spawn seam that registers in the shared registry;
#   - shutdown discipline — shutdown_all sweeps every spawned participant;
#   - (substrate-gated) the spawn seam emits MODE_B_FALLBACK when the
#     substrate is absent.

load 'test_helper.bash'

setup() {
  common_setup

  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  LIB_DIR="$SCRIPTS_DIR/lib"
  DT_LIB="$LIB_DIR/dispatch-teammate.sh"
  CONV_BRIDGE="$LIB_DIR/conversational-mode-b-bridge.sh"
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

  # Session dirs for the shared dispatch library.
  export GAIA_SESSION_DIR="$TEST_TMP/session"
  export GAIA_PROVENANCE_LOG="$TEST_TMP/session/provenance.log"
  export GAIA_SESSION_TRANSCRIPT="$TEST_TMP/session/transcript.md"
  mkdir -p "$GAIA_SESSION_DIR"

  # Force substrate unavailable — exercise plumbing + fallback.
  export GAIA_MODE_B_SUBSTRATE="${GAIA_MODE_B_SUBSTRATE:-unavailable}"

  CONV_SKILLS=(
    gaia-party
    gaia-brainstorm
    gaia-brainstorming
    gaia-creative-sprint
    gaia-design-thinking
    gaia-problem-solving
    gaia-retro
  )
}

teardown() { common_teardown; }

# ============================================================
# Shared library reachability
# ============================================================

@test "shared dispatch library is reachable from the conversational bridge dir" {
  [ -f "$DT_LIB" ]
}

@test "conversational Mode B bridge exists at the canonical lib path" {
  [ -f "$CONV_BRIDGE" ]
}

@test "conversational Mode B bridge sources the shared dispatch library" {
  grep -qF "dispatch-teammate.sh" "$CONV_BRIDGE"
}

# ============================================================
# Each conversational SKILL.md declares Mode B readiness
# ============================================================

@test "each conversational SKILL.md exists" {
  for s in "${CONV_SKILLS[@]}"; do
    [ -f "$SKILLS_DIR/$s/SKILL.md" ] || { echo "missing: $s"; return 1; }
  done
}

@test "each conversational SKILL.md declares Mode B readiness" {
  for s in "${CONV_SKILLS[@]}"; do
    grep -qiE 'Mode B Readiness' "$SKILLS_DIR/$s/SKILL.md" \
      || { echo "no Mode B readiness declaration: $s"; return 1; }
  done
}

@test "each conversational SKILL.md names the shared dispatch library for routing" {
  for s in "${CONV_SKILLS[@]}"; do
    grep -qF "dispatch-teammate.sh" "$SKILLS_DIR/$s/SKILL.md" \
      || { echo "no shared-library reference: $s"; return 1; }
  done
}

@test "each conversational SKILL.md routes participant dispatch via the bridge spawn seam" {
  for s in "${CONV_SKILLS[@]}"; do
    grep -qF "conversational_spawn_participant" "$SKILLS_DIR/$s/SKILL.md" \
      || { echo "no spawn-seam reference: $s"; return 1; }
  done
}

# ============================================================
# Spawn seam — routes through the shared library
# ============================================================

@test "bridge exposes conversational_spawn_participant function" {
  source "$DT_LIB"
  source "$CONV_BRIDGE"
  declare -F conversational_spawn_participant
}

@test "conversational_spawn_participant returns a handle and registers it" {
  source "$DT_LIB"
  source "$CONV_BRIDGE"
  local handle
  handle="$(conversational_spawn_participant "gaia:analyst" "sess-conv" 2>/dev/null)"
  [ -n "$handle" ]
  local count
  count="$(_dt_active_count)"
  [ "$count" -ge 1 ]
}

@test "conversational_spawn_participant rejects reviewer persona via clean-room gate" {
  source "$DT_LIB"
  source "$CONV_BRIDGE"
  run conversational_spawn_participant "validator" "sess-conv"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

# ============================================================
# Shutdown discipline (AC for no orphaned teammates)
# ============================================================

@test "bridge exposes conversational_shutdown function" {
  source "$DT_LIB"
  source "$CONV_BRIDGE"
  declare -F conversational_shutdown
}

@test "conversational_shutdown sweeps every spawned participant" {
  source "$DT_LIB"
  source "$CONV_BRIDGE"
  conversational_spawn_participant "gaia:analyst" "sess-conv" >/dev/null 2>&1
  conversational_spawn_participant "gaia:pm" "sess-conv" >/dev/null 2>&1
  [ "$(_dt_active_count)" -ge 2 ]
  conversational_shutdown >/dev/null 2>&1
  [ "$(_dt_active_count)" -eq 0 ]
}

@test "conversational_shutdown delegates to shutdown_all from the shared library" {
  grep -qF "shutdown_all" "$CONV_BRIDGE"
}

@test "each conversational SKILL.md wires shutdown at completion" {
  for s in "${CONV_SKILLS[@]}"; do
    grep -qF "shutdown_all" "$SKILLS_DIR/$s/SKILL.md" \
      || { echo "no shutdown wiring: $s"; return 1; }
  done
}

# ============================================================
# Substrate-gated fallback honesty
# ============================================================

@test "conversational_spawn_participant emits MODE_B_FALLBACK when substrate absent — substrate-gated" {
  source "$DT_LIB"
  source "$CONV_BRIDGE"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  conversational_spawn_participant "gaia:architect" "sess-conv" >/dev/null 2>"$stderr_out"
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

# ============================================================
# No leaked internal IDs in the new bridge (regression gate)
# ============================================================

@test "conversational Mode B bridge contains no leaked internal IDs (regression)" {
  run grep -cE '(FR|NFR|SR|ADR|TC)-[0-9]' "$CONV_BRIDGE"
  [ "${output:-0}" -eq 0 ]
  run grep -cE 'E[0-9]+-S[0-9]+' "$CONV_BRIDGE"
  [ "${output:-0}" -eq 0 ]
}
