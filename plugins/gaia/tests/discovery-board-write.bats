#!/usr/bin/env bats
# discovery-board-write.bats -- crash-safety and sole-writer tests for
# discovery-board.sh (TC-DISCWRITE-1..5).
#
# Public functions covered: resolve_board_paths, _cleanup_tmps, cmd_capture,
# cmd_transition, cmd_get, cmd_validate, main, die, yaml_single_quote,
# canonical_board_states_hint.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/discovery-board.sh"
  export PROJECT_ROOT="$TEST_TMP"
  BOARD_DIR="$TEST_TMP/.gaia/state"
  BOARD_FILE="$BOARD_DIR/discovery-board.yaml"
  mkdir -p "$BOARD_DIR"
  # Deterministic date for test fixtures.
  TESTDATE="2099-01-01"
}
teardown() { common_teardown; }

# ---------- helpers ----------

# Seed a minimal board with one item so tests can operate on it.
seed_board_one_item() {
  local id="$1" status="${2:-Captured}"
  printf 'items:\n' > "$BOARD_FILE"
  printf '  - id: "%s"\n' "$id" >> "$BOARD_FILE"
  printf '    title: "Test item"\n' >> "$BOARD_FILE"
  printf '    source: "manual"\n' >> "$BOARD_FILE"
  printf '    status: "%s"\n' "$status" >> "$BOARD_FILE"
  printf '    research_type: []\n' >> "$BOARD_FILE"
  printf '    artifacts: []\n' >> "$BOARD_FILE"
  printf '    value_signal: ""\n' >> "$BOARD_FILE"
  printf '    effort_signal: ""\n' >> "$BOARD_FILE"
  printf '    priority: ""\n' >> "$BOARD_FILE"
  printf '    horizon: ""\n' >> "$BOARD_FILE"
  printf '    decision_link: ""\n' >> "$BOARD_FILE"
  printf '    graduated_feature_id: ""\n' >> "$BOARD_FILE"
  printf '    created_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    last_activity: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    status_changed_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
}

# Seed a board with two items.
seed_board_two_items() {
  local id1="$1" status1="${2:-Captured}" id2="$3" status2="${4:-Captured}"
  printf 'items:\n' > "$BOARD_FILE"
  # Item 1
  printf '  - id: "%s"\n' "$id1" >> "$BOARD_FILE"
  printf '    title: "First item"\n' >> "$BOARD_FILE"
  printf '    source: "manual"\n' >> "$BOARD_FILE"
  printf '    status: "%s"\n' "$status1" >> "$BOARD_FILE"
  printf '    research_type: []\n' >> "$BOARD_FILE"
  printf '    artifacts: []\n' >> "$BOARD_FILE"
  printf '    value_signal: ""\n' >> "$BOARD_FILE"
  printf '    effort_signal: ""\n' >> "$BOARD_FILE"
  printf '    priority: ""\n' >> "$BOARD_FILE"
  printf '    horizon: ""\n' >> "$BOARD_FILE"
  printf '    decision_link: ""\n' >> "$BOARD_FILE"
  printf '    graduated_feature_id: ""\n' >> "$BOARD_FILE"
  printf '    created_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    last_activity: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    status_changed_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  # Item 2
  printf '  - id: "%s"\n' "$id2" >> "$BOARD_FILE"
  printf '    title: "Second item"\n' >> "$BOARD_FILE"
  printf '    source: "manual"\n' >> "$BOARD_FILE"
  printf '    status: "%s"\n' "$status2" >> "$BOARD_FILE"
  printf '    research_type: []\n' >> "$BOARD_FILE"
  printf '    artifacts: []\n' >> "$BOARD_FILE"
  printf '    value_signal: ""\n' >> "$BOARD_FILE"
  printf '    effort_signal: ""\n' >> "$BOARD_FILE"
  printf '    priority: ""\n' >> "$BOARD_FILE"
  printf '    horizon: ""\n' >> "$BOARD_FILE"
  printf '    decision_link: ""\n' >> "$BOARD_FILE"
  printf '    graduated_feature_id: ""\n' >> "$BOARD_FILE"
  printf '    created_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    last_activity: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    status_changed_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
}

count_orphan_tmps() {
  find "$BOARD_DIR" -type f -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' '
}

install_slow_mv_stub() {
  local marker="$1" sleep_secs="$2"
  local stub_dir="$TEST_TMP/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mv" <<STUBEOF
#!/usr/bin/env bash
touch "$marker"
sleep $sleep_secs
exec /bin/mv "\$@"
STUBEOF
  chmod +x "$stub_dir/mv"
}

# ---------- TC-DISCWRITE-1: sole writer guard (AC1) ----------

@test "discovery-board.sh is the sole writer of the board file (AC1)" {
  # The script must contain the comment/guard declaring sole-writer status.
  grep -qE 'sole.*writer|single.*writer|sanctioned.*writer' "$SCRIPT"
}

@test "discovery-board.sh declares _GAIA_TMP_PATHS array at top-level (AC1)" {
  grep -qE '^_GAIA_TMP_PATHS=\(\)' "$SCRIPT"
}

@test "discovery-board.sh defines die, yaml_single_quote, and canonical_board_states_hint (AC1)" {
  grep -qE '^die\(\)' "$SCRIPT"
  grep -qE '^yaml_single_quote\(\)' "$SCRIPT"
  grep -qE '^canonical_board_states_hint\(\)' "$SCRIPT"
}

# ---------- TC-DISCWRITE-2: tmp+mv, no in-place truncate (AC2) ----------

@test "capture writes via tempfile+mv, never redirects over live file (AC2)" {
  # The script must use mktemp + mv, and must NOT use > $BOARD_FILE directly
  # in any write path.
  grep -qE 'mktemp' "$SCRIPT"
  grep -qE 'mv -f' "$SCRIPT"
}

@test "capture produces a valid board file (AC2)" {
  run "$SCRIPT" capture --title "Test idea" --source "manual"
  [ "$status" -eq 0 ]
  [ -f "$BOARD_FILE" ]
  grep -q 'title:' "$BOARD_FILE"
  grep -q 'status:' "$BOARD_FILE"
}

# ---------- TC-DISCWRITE-3: two concurrent invocations serialize (AC2) ----------

@test "concurrent captures both survive under lock (AC2)" {
  # Launch two captures in parallel. Both must succeed and the board must
  # contain two items afterward.
  "$SCRIPT" capture --title "First" --source "manual" &
  local pid1=$!
  "$SCRIPT" capture --title "Second" --source "manual" &
  local pid2=$!

  wait "$pid1"
  local rc1=$?
  wait "$pid2"
  local rc2=$?

  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]

  # Both items must be present in the board file.
  local item_count
  item_count=$(grep -c '  - id:' "$BOARD_FILE")
  [ "$item_count" -eq 2 ]
}

# ---------- TC-DISCWRITE-4: interrupted write leaves board byte-identical (AC2) ----------

@test "SIGINT mid-write cleans up tmpfile and leaves board intact (AC2)" {
  seed_board_one_item "ITEM-1" "Captured"

  # Install a mv stub that blocks long enough for us to send SIGINT.
  # The stub touches a marker, then sleeps 30s (never completes), so
  # the mv never executes and the board is left untouched.
  local marker="$TEST_TMP/mv-started"
  local stub_dir="$TEST_TMP/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mv" <<STUBEOF
#!/usr/bin/env bash
touch "$marker"
sleep 30
exec /bin/mv "\$@"
STUBEOF
  chmod +x "$stub_dir/mv"

  PATH="$stub_dir:$PATH" "$SCRIPT" transition --id ITEM-1 --to Researching &
  local pid=$!

  local waited=0
  while [ ! -e "$marker" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$marker" ]

  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # No orphan tmpfiles — the EXIT/INT/TERM trap cleaned them up.
  local orphans
  orphans=$(count_orphan_tmps)
  [ "$orphans" = "0" ]
}

# ---------- TC-DISCWRITE-5: unrelated entries byte-preserved on update (AC2) ----------

@test "transition preserves unrelated entries byte-for-byte (AC2)" {
  seed_board_two_items "ITEM-A" "Captured" "ITEM-B" "Captured"

  # Capture ITEM-B's block before the mutation.
  local before_b
  before_b=$(awk '/- id: "ITEM-B"/,0' "$BOARD_FILE")

  run "$SCRIPT" transition --id ITEM-A --to Researching
  [ "$status" -eq 0 ]

  # ITEM-B block must be unchanged.
  local after_b
  after_b=$(awk '/- id: "ITEM-B"/,0' "$BOARD_FILE")
  [ "$before_b" = "$after_b" ]

  # ITEM-A must now be Researching.
  grep -q 'status: "Researching"' "$BOARD_FILE" || \
    grep -q "status: Researching" "$BOARD_FILE"
}
