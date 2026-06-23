#!/usr/bin/env bats
# discovery-board-state.bats -- schema, state-machine, graduation gate, and
# timestamp tests for discovery-board.sh (TC-DISCBOARD-1..7, TC-DISCGRAD-1..3).
#
# Public functions covered: is_canonical_board_state, assert_canonical_board_state,
# validate_board_transition, cmd_capture, cmd_transition, cmd_get, cmd_validate,
# main.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/discovery-board.sh"
  export PROJECT_ROOT="$TEST_TMP"
  BOARD_DIR="$TEST_TMP/.gaia/state"
  BOARD_FILE="$BOARD_DIR/discovery-board.yaml"
  mkdir -p "$BOARD_DIR"
  TESTDATE="2099-01-01"
}
teardown() { common_teardown; }

# ---------- helpers ----------

seed_board_item() {
  local id="$1" status="${2:-Captured}" priority="${3:-}" horizon="${4:-}" parked_from="${5:-}"
  printf 'items:\n' > "$BOARD_FILE"
  printf '  - id: "%s"\n' "$id" >> "$BOARD_FILE"
  printf '    title: "Test item"\n' >> "$BOARD_FILE"
  printf '    source: "manual"\n' >> "$BOARD_FILE"
  printf '    status: "%s"\n' "$status" >> "$BOARD_FILE"
  printf '    research_type: []\n' >> "$BOARD_FILE"
  printf '    artifacts: []\n' >> "$BOARD_FILE"
  printf '    value_signal: ""\n' >> "$BOARD_FILE"
  printf '    effort_signal: ""\n' >> "$BOARD_FILE"
  printf '    priority: "%s"\n' "$priority" >> "$BOARD_FILE"
  printf '    horizon: "%s"\n' "$horizon" >> "$BOARD_FILE"
  printf '    decision_link: ""\n' >> "$BOARD_FILE"
  printf '    graduated_feature_id: ""\n' >> "$BOARD_FILE"
  printf '    created_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    last_activity: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    status_changed_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  if [ -n "$parked_from" ]; then
    printf '    parked_from: "%s"\n' "$parked_from" >> "$BOARD_FILE"
  fi
}

# ---------- TC-DISCBOARD-6 / TC-DISCBOARD-7: capture + schema (AC3) ----------

@test "capture writes all 15 required fields with initial Captured status (AC3)" {
  run "$SCRIPT" capture --title "Raw idea" --source "brainstorm"
  [ "$status" -eq 0 ]
  [ -f "$BOARD_FILE" ]

  # All 15 fields must be present.
  local required_fields=(
    id title source status research_type artifacts
    value_signal effort_signal priority horizon
    decision_link graduated_feature_id created_at
    last_activity status_changed_at
  )
  for field in "${required_fields[@]}"; do
    grep -q "${field}:" "$BOARD_FILE"
  done

  # Status must be Captured.
  grep -qE 'status:.*Captured' "$BOARD_FILE"
}

@test "validate rejects a board item with an unknown status value (AC3)" {
  seed_board_item "ITEM-1" "Captured"
  # Corrupt the status to a non-canonical value.
  sed -i.bak 's/status: "Captured"/status: "Invented"/' "$BOARD_FILE"

  run "$SCRIPT" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invented"* ]] || [[ "$output" == *"invalid"* ]] || [[ "$output" == *"non-canonical"* ]]
}

# ---------- TC-DISCBOARD-1: legal edges accepted + persisted (AC4) ----------

@test "legal transition Captured to Researching accepted and persisted (AC4)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" transition --id ITEM-1 --to Researching
  [ "$status" -eq 0 ]
  grep -qE 'status:.*"?Researching"?' "$BOARD_FILE"
}

@test "legal transition Captured to Evaluated accepted (AC4)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Evaluated
  [ "$status" -eq 0 ]
  grep -qE 'status:.*"?Evaluated"?' "$BOARD_FILE"
}

@test "legal transition Researching to Evaluated accepted (AC4)" {
  seed_board_item "ITEM-1" "Researching" "High" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Evaluated
  [ "$status" -eq 0 ]
}

@test "legal transition Evaluated to Graduated accepted with priority+horizon (AC4)" {
  seed_board_item "ITEM-1" "Evaluated" "High" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Graduated
  [ "$status" -eq 0 ]
  grep -qE 'status:.*"?Graduated"?' "$BOARD_FILE"
}

@test "legal fast-track Captured to Graduated with priority+horizon (AC4)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Graduated
  [ "$status" -eq 0 ]
}

@test "legal transition to Parked from Captured (AC4)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" transition --id ITEM-1 --to Parked
  [ "$status" -eq 0 ]
  grep -qE 'status:.*"?Parked"?' "$BOARD_FILE"
}

@test "legal transition to Parked from Researching (AC4)" {
  seed_board_item "ITEM-1" "Researching"
  run "$SCRIPT" transition --id ITEM-1 --to Parked
  [ "$status" -eq 0 ]
}

@test "legal transition to Parked from Evaluated (AC4)" {
  seed_board_item "ITEM-1" "Evaluated" "High" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Parked
  [ "$status" -eq 0 ]
}

@test "legal transition to Archived from Captured (AC4)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" transition --id ITEM-1 --to Archived
  [ "$status" -eq 0 ]
}

@test "legal revive from Parked restores prior state (AC4)" {
  seed_board_item "ITEM-1" "Parked" "" "" "Researching"
  run "$SCRIPT" transition --id ITEM-1 --to Researching
  [ "$status" -eq 0 ]
  grep -qE 'status:.*"?Researching"?' "$BOARD_FILE"
}

@test "park writes status and parked_from in a single atomic pass (AC4)" {
  # Item has no parked_from field -- the park transition must insert it
  # in the same write that sets status=Parked (no intermediate state).
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" transition --id ITEM-1 --to Parked
  [ "$status" -eq 0 ]
  grep -qE 'status:.*"?Parked"?' "$BOARD_FILE"
  grep -qE 'parked_from:.*"?Captured"?' "$BOARD_FILE"
}

@test "re-park updates parked_from to the new prior state (AC4)" {
  # Item already has parked_from from a previous park. Revive it, then
  # park again from a different state -- parked_from must reflect the
  # new origin.
  seed_board_item "ITEM-1" "Parked" "" "" "Captured"
  run "$SCRIPT" transition --id ITEM-1 --to Captured
  [ "$status" -eq 0 ]
  # Now transition Captured -> Researching -> Parked.
  run "$SCRIPT" transition --id ITEM-1 --to Researching
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --id ITEM-1 --to Parked
  [ "$status" -eq 0 ]
  grep -qE 'status:.*"?Parked"?' "$BOARD_FILE"
  grep -qE 'parked_from:.*"?Researching"?' "$BOARD_FILE"
}

# ---------- TC-DISCBOARD-2: illegal edge rejected fast w/ diagnostic (AC4) ----------

@test "illegal transition Researching to Graduated rejected with from-to diagnostic (AC4)" {
  seed_board_item "ITEM-1" "Researching"
  run "$SCRIPT" transition --id ITEM-1 --to Graduated
  [ "$status" -ne 0 ]
  [[ "$output" == *"Researching"* ]]
  [[ "$output" == *"Graduated"* ]]
}

@test "illegal transition with non-canonical target rejected fast (AC4)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" transition --id ITEM-1 --to Invented
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invented"* ]]
}

# ---------- TC-DISCBOARD-3: illegal transition leaves board sha256-identical (AC4) ----------

@test "illegal transition leaves board file sha256-identical (AC4)" {
  seed_board_item "ITEM-1" "Researching"
  local before_sha
  before_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')

  run "$SCRIPT" transition --id ITEM-1 --to Graduated
  [ "$status" -ne 0 ]

  local after_sha
  after_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

# ---------- TC-DISCBOARD-4 / TC-DISCBOARD-5: terminal sinks (AC4) ----------

@test "Graduated is terminal -- no outbound transitions (AC4)" {
  seed_board_item "ITEM-1" "Graduated" "High" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Researching
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* ]] || [[ "$output" == *"Graduated"* ]]
}

@test "Archived is terminal -- no outbound transitions (AC4)" {
  seed_board_item "ITEM-1" "Archived"
  run "$SCRIPT" transition --id ITEM-1 --to Captured
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* ]] || [[ "$output" == *"Archived"* ]]
}

# ---------- TC-DISCGRAD-1: missing priority OR horizon rejects (AC5) ----------

@test "transition to Evaluated without priority rejects (AC5)" {
  seed_board_item "ITEM-1" "Captured" "" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Evaluated
  [ "$status" -ne 0 ]
  [[ "$output" == *"priority"* ]] || [[ "$output" == *"horizon"* ]]
}

@test "transition to Evaluated without horizon rejects (AC5)" {
  seed_board_item "ITEM-1" "Captured" "High" ""
  run "$SCRIPT" transition --id ITEM-1 --to Evaluated
  [ "$status" -ne 0 ]
  [[ "$output" == *"horizon"* ]] || [[ "$output" == *"priority"* ]]
}

@test "transition to Graduated without priority rejects (AC5)" {
  seed_board_item "ITEM-1" "Evaluated" "" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Graduated
  [ "$status" -ne 0 ]
}

# ---------- TC-DISCGRAD-2: blank/whitespace priority/horizon rejects (AC5) ----------

@test "transition to Evaluated with whitespace-only priority rejects (AC5)" {
  seed_board_item "ITEM-1" "Captured" "   " "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Evaluated
  [ "$status" -ne 0 ]
}

@test "transition to Evaluated with whitespace-only horizon rejects (AC5)" {
  seed_board_item "ITEM-1" "Captured" "High" "   "
  run "$SCRIPT" transition --id ITEM-1 --to Evaluated
  [ "$status" -ne 0 ]
}

# ---------- TC-DISCGRAD-3: valid priority+horizon accepts (AC5) ----------

@test "transition to Evaluated with valid priority and horizon accepts (AC5)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Evaluated
  [ "$status" -eq 0 ]
}

@test "transition to Graduated with valid priority and horizon accepts (AC5)" {
  seed_board_item "ITEM-1" "Evaluated" "High" "Now"
  run "$SCRIPT" transition --id ITEM-1 --to Graduated
  [ "$status" -eq 0 ]
}

# ---------- AC6: timestamps on mutating writes only ----------

@test "capture stamps created_at and last_activity (AC6)" {
  run "$SCRIPT" capture --title "Timestamped" --source "manual"
  [ "$status" -eq 0 ]
  grep -q 'created_at:' "$BOARD_FILE"
  grep -q 'last_activity:' "$BOARD_FILE"
  grep -q 'status_changed_at:' "$BOARD_FILE"
}

@test "transition stamps last_activity and status_changed_at (AC6)" {
  seed_board_item "ITEM-1" "Captured"
  local before_activity
  before_activity=$(grep 'last_activity:' "$BOARD_FILE")

  # Small sleep so timestamps differ.
  sleep 1
  run "$SCRIPT" transition --id ITEM-1 --to Researching
  [ "$status" -eq 0 ]

  local after_activity
  after_activity=$(grep 'last_activity:' "$BOARD_FILE")
  [ "$before_activity" != "$after_activity" ]
}

@test "get does not modify last_activity (AC6)" {
  seed_board_item "ITEM-1" "Captured"
  local before_sha
  before_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')

  run "$SCRIPT" get --id ITEM-1
  [ "$status" -eq 0 ]

  local after_sha
  after_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

@test "validate does not modify the board (AC6)" {
  seed_board_item "ITEM-1" "Captured"
  local before_sha
  before_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')

  run "$SCRIPT" validate
  [ "$status" -eq 0 ]

  local after_sha
  after_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

# ---------- usage / help ----------

@test "discovery-board.sh --help lists subcommands (AC1)" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"capture"* ]]
  [[ "$output" == *"transition"* ]]
  [[ "$output" == *"get"* ]]
  [[ "$output" == *"validate"* ]]
}

@test "discovery-board.sh unknown subcommand exits 1 (AC1)" {
  run "$SCRIPT" frobnicate
  [ "$status" -ne 0 ]
}

@test "get --id on nonexistent item exits 1 with diagnostic (AC3)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" get --id ITEM-MISSING
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"ITEM-MISSING"* ]]
}
