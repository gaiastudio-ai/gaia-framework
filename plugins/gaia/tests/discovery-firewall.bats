#!/usr/bin/env bats
# discovery-firewall.bats -- sprint-decoupling firewall guards.
#
# Verifies that the sprint-plan surface has NO read path to the discovery board
# and that the guard fails closed on planted references, its own absence/
# mis-scope, and sole-backlog-edge violations.
#
# Public functions covered: main (discovery-firewall-guard.sh).

load 'test_helper.bash'

setup() {
  common_setup
  GUARD="$SCRIPTS_DIR/discovery-firewall-guard.sh"
  FIXTURE_DIR="$TEST_TMP/fixture-surface"
  mkdir -p "$FIXTURE_DIR/skills/gaia-sprint-plan/scripts"
  mkdir -p "$FIXTURE_DIR/scripts/lib"
}
teardown() { common_teardown; }

# ---------- helpers ----------

# seed_clean_surface — write a minimal sprint-plan surface with NO board refs.
seed_clean_surface() {
  # Include script references so the guard resolves them into the surface.
  printf 'name: gaia-sprint-plan\nsteps:\n  - setup\n  - plan\n' \
    > "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"
  printf 'scripts: sprint-state.sh backlog-select-lint.sh sm-capacity-check.sh\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"
  printf 'scripts: detect-sweep-shape.sh escalation-halt.sh priority-flag.sh\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"
  printf 'scripts: set-story-sprint.sh transition-story-status.sh resolve-story-file.sh\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"
  printf 'scripts: resolve-config.sh backfill-story-index.sh val-sidecar-write.sh\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"
  printf 'scripts: detect-orchestration-mode.sh orchestration-warning.sh\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"
  printf 'scripts: dispatch-teammate.sh execution-mode-b-bridge.sh\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"
  printf 'scripts: resolve-test-artifact-per-story.sh\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' \
    > "$FIXTURE_DIR/skills/gaia-sprint-plan/scripts/setup.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' \
    > "$FIXTURE_DIR/skills/gaia-sprint-plan/scripts/finalize.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' \
    > "$FIXTURE_DIR/skills/gaia-sprint-plan/scripts/ground-truth-gate.sh"
  # Create referenced scripts at the top-level scripts/ dir.
  for s in sprint-state.sh backlog-select-lint.sh sm-capacity-check.sh \
           detect-sweep-shape.sh escalation-halt.sh priority-flag.sh \
           set-story-sprint.sh transition-story-status.sh resolve-story-file.sh \
           resolve-config.sh backfill-story-index.sh val-sidecar-write.sh \
           detect-orchestration-mode.sh orchestration-warning.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_DIR/scripts/$s"
  done
  for s in dispatch-teammate.sh execution-mode-b-bridge.sh resolve-test-artifact-per-story.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_DIR/scripts/lib/$s"
  done
}

# plant_board_ref — inject a discovery-board reference into a surface file.
plant_board_ref() {
  local file="$1" ref="${2:-discovery-board.yaml}"
  printf '# reads %s for aging\n' "$ref" >> "$file"
}

# ---------- TC-DISCFIRE-1: planted board ref trips the guard (AC1) ----------

@test "guard fails closed when sprint-plan surface contains discovery-board.yaml ref (AC1)" {
  seed_clean_surface
  plant_board_ref "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md" "discovery-board.yaml"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"discovery-board"* ]]
}

@test "guard fails closed when sprint-plan surface contains discovery-board.sh ref (AC1)" {
  seed_clean_surface
  plant_board_ref "$FIXTURE_DIR/scripts/sprint-state.sh" "discovery-board.sh"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"discovery-board"* ]]
}

@test "guard fails closed when sprint-plan surface contains gaia-discover ref (AC1)" {
  seed_clean_surface
  plant_board_ref "$FIXTURE_DIR/skills/gaia-sprint-plan/scripts/setup.sh" "gaia-discover"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gaia-discover"* ]] || [[ "$output" == *"discovery"* ]]
}

# ---------- TC-DISCFIRE-2: clean surface passes (AC2) ----------

@test "guard passes on a clean fixture surface with no board references (AC2)" {
  seed_clean_surface

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -eq 0 ]
}

@test "guard passes on the real sprint-plan surface (AC2)" {
  run "$GUARD" --surface-root "$SCRIPTS_DIR/.."
  [ "$status" -eq 0 ]
}

# ---------- TC-DISCFIRE-3: fail-closed on own absence/mis-scope (AC1) ----------

@test "guard fails closed when SKILL.md is missing from the surface (AC1)" {
  seed_clean_surface
  rm "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SKILL.md"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"absent"* ]]
}

@test "guard fails closed when sprint-plan scripts dir is missing (AC1)" {
  seed_clean_surface
  rm -rf "$FIXTURE_DIR/skills/gaia-sprint-plan/scripts"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
}

@test "guard fails closed when --surface-root points to non-existent dir (AC1)" {
  run "$GUARD" --surface-root "$TEST_TMP/nonexistent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"does not exist"* ]]
}

# ---------- TC-DISCFIRE-5: calendar-only aging — no sprint/velocity fields (AC3) ----------

@test "discovery-board schema has no sprint id, counter, or velocity field (AC3)" {
  # Verify the board writer script has no sprint_id / sprint_counter / velocity
  # field definitions in its schema section (the first 50 lines).
  local board_script="$SCRIPTS_DIR/discovery-board.sh"
  [ -f "$board_script" ]
  # The schema comment lists exactly 15 fields. Grep for forbidden fields.
  run grep -cE '(sprint_id|sprint_counter|velocity)' "$board_script"
  # grep -c returns the count; 0 means no matches. Exit code 1 on 0 matches.
  [ "$status" -eq 1 ]  # grep exits 1 when count is 0
}

# ---------- TC-DISCFIRE-6: aging is calendar-only via GAIA_DISCOVERY_NOW (AC3) ----------

@test "aging derives from GAIA_DISCOVERY_NOW and last_activity only (AC3)" {
  local board_script="$SCRIPTS_DIR/discovery-board.sh"
  [ -f "$board_script" ]
  # The aging function uses GAIA_DISCOVERY_NOW (injectable clock).
  grep -q 'GAIA_DISCOVERY_NOW' "$board_script"
  # Aging reads last_activity, not any sprint field.
  grep -q 'last_activity' "$board_script"
}

# ---------- TC-DISCFIRE-7: sole-backlog-edge guard — planted read trips (AC4) ----------

@test "sole-backlog-edge guard fails when sprint-plan surface reads discovery-board (AC4)" {
  seed_clean_surface
  # Plant a board-read that would source backlog stories from the board.
  printf 'BOARD=".gaia/state/discovery-board.yaml"\ncat "$BOARD"\n' \
    >> "$FIXTURE_DIR/scripts/sprint-state.sh"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"discovery-board"* ]]
}

@test "sole-backlog-edge guard passes when sprint-plan surface has no board reads (AC4)" {
  seed_clean_surface

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -eq 0 ]
}

# ---------- TC-DISCFIRE-8: guard matches discovery_board underscore variant (AC1) ----------

@test "guard matches underscore variant discovery_board in surface files (AC1)" {
  seed_clean_surface
  printf '# import discovery_board\n' >> "$FIXTURE_DIR/skills/gaia-sprint-plan/SKILL.md"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
}

# ---------- TC-DISCFIRE-9: idempotent — repeated runs same result (AC3) ----------

@test "guard is idempotent — repeated clean-surface runs all exit 0 (AC3)" {
  seed_clean_surface
  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -eq 0 ]
  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -eq 0 ]
  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -eq 0 ]
}

# ---------- TC-DISCFIRE-10: transitive-source gap — board ref in sourced script (AC1) ----------

@test "guard fails when transitively-sourced script contains board ref (AC1)" {
  seed_clean_surface
  # Create a fixture checkpoint.sh in scripts/ that setup.sh would source
  # (not named in SKILL.md — the transitive gap the defect exposed).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_DIR/scripts/checkpoint.sh"
  # Make setup.sh reference checkpoint.sh so the guard discovers it transitively.
  printf 'CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/scripts/setup.sh"
  # Plant the board reference in the transitively-discovered script.
  plant_board_ref "$FIXTURE_DIR/scripts/checkpoint.sh" "discovery-board.yaml"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"discovery-board"* ]]
  [[ "$output" == *"checkpoint.sh"* ]]
}

# ---------- TC-DISCFIRE-11: unresolvable source reference — fail closed (AC1) ----------

@test "guard fails closed on unresolvable source reference in surface script (AC1)" {
  seed_clean_surface
  # Add a reference to a script that does not exist anywhere in the tree.
  printf 'source "$SCRIPTS_DIR/nonexistent-helper.sh"\n' \
    >> "$FIXTURE_DIR/skills/gaia-sprint-plan/scripts/setup.sh"

  run "$GUARD" --surface-root "$FIXTURE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unresolvable"* ]] || [[ "$output" == *"unresolved"* ]]
  [[ "$output" == *"nonexistent-helper.sh"* ]]
}
