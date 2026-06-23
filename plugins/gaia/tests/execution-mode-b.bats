#!/usr/bin/env bats
# execution-mode-b.bats — Mode B readiness tests for the 9 execution/sprint
# heavy-procedural skills.
#
# Covers the execution-lifecycle Mode B migration:
#   AC1 — dev-story persists the stack-developer teammate across phases
#   AC2 — sprint-plan spawns the sm subagent via the shared library seam
#   AC3 — run-all-reviews keeps reviewers one-shot (clean-room invariant)
#   AC4 — existing skill bats remain green (exercised by separate suites)
#   AC5 — shutdown is called at skill exit (no leaked panes)

load 'test_helper.bash'

setup() {
  common_setup

  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  LIB_DIR="$SCRIPTS_DIR/lib"
  DT_LIB="$LIB_DIR/dispatch-teammate.sh"
  EMB_LIB="$LIB_DIR/execution-mode-b-bridge.sh"

  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

  # The 9 execution/sprint skills under migration.
  EXECUTION_SKILLS=(
    gaia-dev-story
    gaia-sprint-plan
    gaia-run-all-reviews
    gaia-add-feature
    gaia-quick-spec
    gaia-quick-dev
    gaia-readiness-check
    gaia-atdd
    gaia-sprint-review
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

@test "execution bridge library exists at canonical lib path" {
  [ -f "$EMB_LIB" ]
}

@test "execution bridge sources dispatch-teammate library" {
  grep -qF "dispatch-teammate.sh" "$EMB_LIB"
}

@test "execution bridge exposes execution_spawn_subagent function (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  declare -F execution_spawn_subagent
}

@test "execution bridge exposes execution_relay_turn function" {
  source "$DT_LIB"
  source "$EMB_LIB"
  declare -F execution_relay_turn
}

@test "execution bridge exposes execution_shutdown function (AC5)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  declare -F execution_shutdown
}

# ============================================================
# AC1 — spawn seam routes through spawn_teammate
# ============================================================

@test "execution_spawn_subagent calls spawn_teammate and returns a handle (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" 2>/dev/null)"
  [ -n "$handle" ]
}

@test "execution_spawn_subagent registers in dispatch-teammate registry (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" >/dev/null 2>&1
  local count
  count="$(_dt_active_count)"
  [ "$count" -ge 1 ]
}

@test "execution_spawn_subagent records teammate dispatch provenance (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" >/dev/null 2>&1
  grep -qF "dispatched_via:teammate" "$GAIA_PROVENANCE_LOG"
}

@test "execution_spawn_subagent rejects reviewer persona via clean-room gate (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  run execution_spawn_subagent "validator" "gaia-run-all-reviews"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

# ============================================================
# AC1 (doc) — each of the 9 skills declares Mode B readiness
# ============================================================

@test "each execution skill declares a Mode B Readiness section (AC1)" {
  for skill in "${EXECUTION_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$md" ] || { echo "missing SKILL.md: $skill"; return 1; }
    grep -qiF "Mode B Readiness" "$md" || { echo "no Mode B Readiness in $skill"; return 1; }
  done
}

@test "each execution skill names the shared bridge library (AC1)" {
  for skill in "${EXECUTION_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "execution-mode-b-bridge.sh" "$md" || { echo "no bridge ref in $skill"; return 1; }
  done
}

@test "each execution skill names the spawn seam (AC1)" {
  for skill in "${EXECUTION_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "execution_spawn_subagent" "$md" || { echo "no spawn seam in $skill"; return 1; }
  done
}

@test "each execution skill names the shutdown seam (AC5)" {
  for skill in "${EXECUTION_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "execution_shutdown" "$md" || { echo "no shutdown seam in $skill"; return 1; }
  done
}

# ============================================================
# AC1 — dev-story persists the stack-developer across phases
# ============================================================

@test "dev-story spawn under Mode B yields a handle for the stack developer (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" 2>/dev/null)"
  [ -n "$handle" ]
  local persona
  persona="$(_dt_read_persona "$handle")"
  [ "$persona" = "gaia:python-dev" ]
}

@test "dev-story single teammate drives multiple phase turns without re-spawn (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" 2>/dev/null)"
  drive_turn "$handle" "plan phase" 2>/dev/null || true
  execution_relay_turn "$handle" "plan complete" 2>/dev/null
  drive_turn "$handle" "implement phase" 2>/dev/null || true
  execution_relay_turn "$handle" "implement complete" 2>/dev/null
  drive_turn "$handle" "test phase" 2>/dev/null || true
  execution_relay_turn "$handle" "test complete" 2>/dev/null
  # Still exactly one active teammate — no re-spawn across phases.
  [ "$(_dt_active_count)" -eq 1 ]
}

# ============================================================
# AC2 — sprint-plan spawns the sm subagent via the seam
# ============================================================

@test "sprint-plan spawn under Mode B yields a handle for the sm subagent (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" 2>/dev/null)"
  [ -n "$handle" ]
  local persona
  persona="$(_dt_read_persona "$handle")"
  [ "$persona" = "gaia:sm" ]
}

@test "sprint-plan relay carries planning output verbatim into transcript (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" 2>/dev/null)"
  drive_turn "$handle" "plan sprint" 2>/dev/null || true
  execution_relay_turn "$handle" "$(printf '## Sprint\n- selected: story-A')" 2>/dev/null
  grep -qF "## Sprint" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "selected: story-A" "$GAIA_SESSION_TRANSCRIPT"
}

# ============================================================
# AC3 — run-all-reviews clean-room invariant (reviewers one-shot)
# ============================================================

@test "run-all-reviews declares NO reviewer persona in any teammate roster (AC3)" {
  local md="$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  # Pull any persona declared on a roster: line (Mode B teammate roster).
  local rosters
  rosters="$(grep -E '^\s+persona:' "$md" 2>/dev/null || true)"
  # No roster lines at all is the strongest form of compliance.
  if [ -z "$rosters" ]; then
    return 0
  fi
  # If any roster line exists, it must NOT name a reviewer persona.
  local reviewers
  reviewers="$(grep -vE '^\s*#' "$SKILLS_DIR/../knowledge/reviewer-personas.txt" | grep -vE '^\s*$')"
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if printf '%s' "$rosters" | grep -qiE "persona:[[:space:]]*(gaia:)?${entry}([[:space:]]|$)"; then
      echo "run-all-reviews declares reviewer teammate: $entry"
      return 1
    fi
  done <<< "$reviewers"
  return 0
}

@test "run-all-reviews Mode B section states reviewers stay one-shot/clean-room (AC3)" {
  local md="$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  grep -qiE "one-shot" "$md"
  grep -qiE "clean-room|clean room" "$md"
}

@test "execution bridge clean-room gate blocks every reviewer persona (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local reviewers
  reviewers="$(grep -vE '^\s*#' "$SKILLS_DIR/../knowledge/reviewer-personas.txt" | grep -vE '^\s*$')"
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    run execution_spawn_subagent "$entry" "gaia-run-all-reviews"
    [ "$status" -ne 0 ] || { echo "reviewer NOT blocked: $entry"; return 1; }
  done <<< "$reviewers"
}

# ============================================================
# AC5 — shutdown at skill exit (no leaked panes)
# ============================================================

@test "execution_shutdown clears all active teammates (AC5)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" >/dev/null 2>&1
  execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" >/dev/null 2>&1
  [ "$(_dt_active_count)" -ge 2 ]
  execution_shutdown 2>/dev/null
  [ "$(_dt_active_count)" -eq 0 ]
}

@test "execution_shutdown is idempotent with no active teammates (AC5)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  run execution_shutdown
  [ "$status" -eq 0 ]
}

# ============================================================
# AC1/AC5 — fallback honesty (substrate-gated)
# ============================================================

@test "execution_spawn_subagent emits MODE_B_FALLBACK when substrate absent — substrate-gated (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" >"$TEST_TMP/handle.txt" 2>"$stderr_out"
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "execution drive_turn is bookkeeping-only — no send, no MODE_B_FALLBACK (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local handle
  handle="$(execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" 2>/dev/null)"
  local stderr_out="$TEST_TMP/stderr.txt"
  run drive_turn "$handle" "plan" 2>"$stderr_out"
  [ "$status" -eq 0 ]
  # drive_turn never sends (the orchestrator's SendMessage does) so it never
  # falls back — regression guard for the old fallback-emitting stub.
  ! grep -qF "MODE_B_FALLBACK" "$stderr_out"
  await_reply "$handle"
}

# ============================================================
# No leaked IDs in the new bridge (regression gate)
# ============================================================

@test "execution-mode-b-bridge.sh contains no leaked internal IDs (regression)" {
  local f="$EMB_LIB"
  run grep -cE '(FR|NFR|ADR|TC)-[0-9]' "$f"
  [ "${output:-0}" -eq 0 ]
  run grep -cE 'E[0-9]+-S[0-9]+' "$f"
  [ "${output:-0}" -eq 0 ]
}
