#!/usr/bin/env bats
# discovery-board-render.bats -- board render, prioritize, idle-advisory,
# and gesture-routing tests for discovery-board.sh S2 subcommands.
#
# Public functions covered: cmd_board, cmd_prioritize, main (board/prioritize
# subcommand dispatch).

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
  local id="$1" status="${2:-Captured}" priority="${3:-}" horizon="${4:-}" last_activity="${5:-${TESTDATE}T00:00:00Z}"
  if [ ! -f "$BOARD_FILE" ]; then
    printf 'items:\n' > "$BOARD_FILE"
  fi
  {
    printf '  - id: "%s"\n' "$id"
    printf '    title: "Item %s"\n' "$id"
    printf '    source: "manual"\n'
    printf '    status: "%s"\n' "$status"
    printf '    research_type: []\n'
    printf '    artifacts: []\n'
    printf '    value_signal: ""\n'
    printf '    effort_signal: ""\n'
    printf '    priority: "%s"\n' "$priority"
    printf '    horizon: "%s"\n' "$horizon"
    printf '    decision_link: ""\n'
    printf '    graduated_feature_id: ""\n'
    printf '    created_at: "%sT00:00:00Z"\n' "$TESTDATE"
    printf '    last_activity: "%s"\n' "$last_activity"
    printf '    status_changed_at: "%sT00:00:00Z"\n' "$TESTDATE"
  } >> "$BOARD_FILE"
}

# ---------- AC1: gesture routing — board and prioritize are accepted subcommands ----------

@test "board subcommand is accepted by discovery-board.sh (AC1)" {
  seed_board_item "ITEM-1"
  run "$SCRIPT" board
  [ "$status" -eq 0 ]
}

@test "prioritize subcommand is accepted by discovery-board.sh (AC1)" {
  seed_board_item "ITEM-1" "Captured" "" ""
  run "$SCRIPT" prioritize --id ITEM-1 --priority High --horizon Now
  [ "$status" -eq 0 ]
}

@test "unknown subcommand still rejected (AC1)" {
  run "$SCRIPT" frobnicate
  [ "$status" -ne 0 ]
}

@test "help lists board and prioritize subcommands (AC1)" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"board"* ]]
  [[ "$output" == *"prioritize"* ]]
}

# ---------- AC3: board render — basic output ----------

@test "board renders item titles and statuses (AC3)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  seed_board_item "ITEM-2" "Researching" "Medium" "Next"
  run "$SCRIPT" board
  [ "$status" -eq 0 ]
  [[ "$output" == *"ITEM-1"* ]]
  [[ "$output" == *"ITEM-2"* ]]
  [[ "$output" == *"Captured"* ]]
  [[ "$output" == *"Researching"* ]]
}

# ---------- AC3: board render — horizon filter ----------

@test "board --horizon Now shows only Now items (AC3)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  seed_board_item "ITEM-2" "Researching" "Medium" "Next"
  run "$SCRIPT" board --horizon Now
  [ "$status" -eq 0 ]
  [[ "$output" == *"ITEM-1"* ]]
  # ITEM-2 has horizon=Next, should be excluded
  run "$SCRIPT" board --horizon Now
  local count
  count=$(printf '%s\n' "$output" | grep -c "ITEM-2" || true)
  [ "$count" -eq 0 ]
}

# ---------- AC3: board render — priority filter ----------

@test "board --priority High shows only High items (AC3)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  seed_board_item "ITEM-2" "Researching" "Medium" "Next"
  run "$SCRIPT" board --priority High
  [ "$status" -eq 0 ]
  [[ "$output" == *"ITEM-1"* ]]
  local count
  count=$(printf '%s\n' "$output" | grep -c "ITEM-2" || true)
  [ "$count" -eq 0 ]
}

# ---------- AC3: board render — combined filters ----------

@test "board --horizon Now --priority High intersects both filters (AC3)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  seed_board_item "ITEM-2" "Researching" "High" "Next"
  seed_board_item "ITEM-3" "Captured" "Medium" "Now"
  run "$SCRIPT" board --horizon Now --priority High
  [ "$status" -eq 0 ]
  [[ "$output" == *"ITEM-1"* ]]
  local count2
  count2=$(printf '%s\n' "$output" | grep -c "ITEM-2" || true)
  [ "$count2" -eq 0 ]
  local count3
  count3=$(printf '%s\n' "$output" | grep -c "ITEM-3" || true)
  [ "$count3" -eq 0 ]
}

# ---------- AC3: board render — empty board ----------

@test "board on empty board file exits with error (AC3)" {
  run "$SCRIPT" board
  [ "$status" -ne 0 ]
}

# ---------- AC3: idle advisory — 30/60/90 day labels ----------

@test "board shows idle advisory for item inactive >30 days (AC3)" {
  # Seed an item with last_activity 35 days in the past relative to a controlled now.
  local old_ts="2099-01-01T00:00:00Z"
  seed_board_item "ITEM-OLD" "Captured" "" "" "$old_ts"
  # Set controlled now to 36 days later.
  export GAIA_DISCOVERY_NOW=4074019200  # 2099-02-06T00:00:00Z (36 days after 2099-01-01)
  run "$SCRIPT" board
  [ "$status" -eq 0 ]
  # Should show a 30-day idle advisory.
  [[ "$output" == *"idle 30"* ]] || [[ "$output" == *"idle-30"* ]] || [[ "$output" == *"30d idle"* ]] || [[ "$output" == *"idle >30d"* ]]
}

@test "board shows idle advisory for item inactive >60 days (AC3)" {
  local old_ts="2099-01-01T00:00:00Z"
  seed_board_item "ITEM-OLD" "Captured" "" "" "$old_ts"
  # Set controlled now to 65 days later.
  export GAIA_DISCOVERY_NOW=5765760  # Relative: we need an absolute epoch
  # 2099-01-01T00:00:00Z in epoch: date -d '2099-01-01T00:00:00Z' +%s → 4070908800 (approx)
  # +65 days = +5616000 seconds = 4076524800
  export GAIA_DISCOVERY_NOW=4076524800
  run "$SCRIPT" board
  [ "$status" -eq 0 ]
  [[ "$output" == *"idle 60"* ]] || [[ "$output" == *"idle-60"* ]] || [[ "$output" == *"60d idle"* ]] || [[ "$output" == *"idle >60d"* ]]
}

@test "board shows idle advisory for item inactive >90 days (AC3)" {
  local old_ts="2099-01-01T00:00:00Z"
  seed_board_item "ITEM-OLD" "Captured" "" "" "$old_ts"
  # +95 days = +8208000 seconds
  export GAIA_DISCOVERY_NOW=4079116800
  run "$SCRIPT" board
  [ "$status" -eq 0 ]
  [[ "$output" == *"idle 90"* ]] || [[ "$output" == *"idle-90"* ]] || [[ "$output" == *"90d idle"* ]] || [[ "$output" == *"idle >90d"* ]]
}

@test "board shows no idle advisory for recently active item (AC3)" {
  local recent_ts="2099-01-01T00:00:00Z"
  seed_board_item "ITEM-FRESH" "Captured" "" "" "$recent_ts"
  # Set controlled now to 5 days later.
  export GAIA_DISCOVERY_NOW=4071340800  # 2099-01-06
  run "$SCRIPT" board
  [ "$status" -eq 0 ]
  # No idle advisory should appear.
  local idle_count
  idle_count=$(printf '%s\n' "$output" | grep -ci "idle" || true)
  [ "$idle_count" -eq 0 ]
}

# ---------- AC3: board render is read-only — sha256 identical before/after ----------

@test "board render does not mutate the board file (AC3)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  local before_sha
  before_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')

  run "$SCRIPT" board
  [ "$status" -eq 0 ]

  local after_sha
  after_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

@test "board with idle advisory does not mutate the board file (AC3)" {
  local old_ts="2099-01-01T00:00:00Z"
  seed_board_item "ITEM-OLD" "Captured" "" "" "$old_ts"
  export GAIA_DISCOVERY_NOW=4076524800  # 65 days later

  local before_sha
  before_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')

  run "$SCRIPT" board
  [ "$status" -eq 0 ]

  local after_sha
  after_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

# ---------- AC4: prioritize sets priority and horizon ----------

@test "prioritize sets priority and horizon on an item (AC4)" {
  seed_board_item "ITEM-1" "Captured" "" ""
  run "$SCRIPT" prioritize --id ITEM-1 --priority High --horizon Now
  [ "$status" -eq 0 ]
  grep -qE "priority:.*High" "$BOARD_FILE"
  grep -qE "horizon:.*Now" "$BOARD_FILE"
}

@test "prioritize updates existing priority and horizon (AC4)" {
  seed_board_item "ITEM-1" "Captured" "Low" "Later"
  run "$SCRIPT" prioritize --id ITEM-1 --priority High --horizon Now
  [ "$status" -eq 0 ]
  grep -qE "priority:.*High" "$BOARD_FILE"
  grep -qE "horizon:.*Now" "$BOARD_FILE"
}

@test "prioritize requires --id flag (AC4)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" prioritize --priority High --horizon Now
  [ "$status" -ne 0 ]
}

@test "prioritize requires --priority flag (AC4)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" prioritize --id ITEM-1 --horizon Now
  [ "$status" -ne 0 ]
}

@test "prioritize requires --horizon flag (AC4)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" prioritize --id ITEM-1 --priority High
  [ "$status" -ne 0 ]
}

@test "prioritize updates last_activity timestamp (AC4)" {
  seed_board_item "ITEM-1" "Captured" "" ""
  local before_activity
  before_activity=$(grep 'last_activity:' "$BOARD_FILE")

  sleep 1
  run "$SCRIPT" prioritize --id ITEM-1 --priority High --horizon Now
  [ "$status" -eq 0 ]

  local after_activity
  after_activity=$(grep 'last_activity:' "$BOARD_FILE")
  [ "$before_activity" != "$after_activity" ]
}

@test "prioritize on nonexistent item exits with error (AC4)" {
  seed_board_item "ITEM-1" "Captured"
  run "$SCRIPT" prioritize --id ITEM-MISSING --priority High --horizon Now
  [ "$status" -ne 0 ]
}

# ---------- AC4: park/revive are explicit manual transitions ----------

@test "park is an explicit transition, not auto-triggered (AC4)" {
  # park is routed through transition --to Parked — verify the script
  # has no auto-park logic (no cron/sweep/auto pattern).
  run grep -ciE 'auto.?park|cron|sweep.*park|auto.*idle' "$SCRIPT"
  [ "$output" = "0" ] || [ "$output" = "" ]
}

@test "revive is an explicit transition, not auto-triggered (AC4)" {
  run grep -ciE 'auto.?revive|cron.*revive|sweep.*revive' "$SCRIPT"
  [ "$output" = "0" ] || [ "$output" = "" ]
}

# ---------- AC3: board render skips terminal-state items in idle advisory ----------

@test "board does not show idle advisory for Graduated items (AC3)" {
  local old_ts="2099-01-01T00:00:00Z"
  seed_board_item "ITEM-GRAD" "Graduated" "High" "Now" "$old_ts"
  export GAIA_DISCOVERY_NOW=4076524800  # 65 days later

  run "$SCRIPT" board
  [ "$status" -eq 0 ]
  # Graduated is terminal — no idle advisory should show for it.
  local idle_count
  idle_count=$(printf '%s\n' "$output" | grep -c "idle" || true)
  [ "$idle_count" -eq 0 ]
}

@test "board does not show idle advisory for Archived items (AC3)" {
  local old_ts="2099-01-01T00:00:00Z"
  seed_board_item "ITEM-ARCH" "Archived" "" "" "$old_ts"
  export GAIA_DISCOVERY_NOW=4076524800  # 65 days later

  run "$SCRIPT" board
  [ "$status" -eq 0 ]
  local idle_count
  idle_count=$(printf '%s\n' "$output" | grep -c "idle" || true)
  [ "$idle_count" -eq 0 ]
}

# ---------- AC3: board with no items matching filter ----------

@test "board with non-matching horizon filter shows no items (AC3)" {
  seed_board_item "ITEM-1" "Captured" "High" "Now"
  run "$SCRIPT" board --horizon Later
  [ "$status" -eq 0 ]
  local count
  count=$(printf '%s\n' "$output" | grep -c "ITEM-1" || true)
  [ "$count" -eq 0 ]
}

# ---------- regression: pipe character in priority/horizon round-trips correctly ----------

@test "prioritize with pipe in priority and horizon values round-trips correctly (AC4)" {
  seed_board_item "ITEM-PIPE" "Captured"
  run "$SCRIPT" prioritize --id ITEM-PIPE --priority 'A|B' --horizon 'C|D'
  [ "$status" -eq 0 ]

  # Read back the raw YAML and verify full values survived (not truncated at |).
  local stored_priority stored_horizon
  stored_priority=$(grep 'priority:' "$BOARD_FILE" | tail -1)
  stored_horizon=$(grep 'horizon:' "$BOARD_FILE" | tail -1)
  [[ "$stored_priority" == *"A|B"* ]]
  [[ "$stored_horizon" == *"C|D"* ]]

  # Verify get subcommand also returns the full values.
  run "$SCRIPT" get --id ITEM-PIPE
  [ "$status" -eq 0 ]
  [[ "$output" == *"A|B"* ]]
  [[ "$output" == *"C|D"* ]]
}
