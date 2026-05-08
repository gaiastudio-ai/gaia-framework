#!/usr/bin/env bats
# loop-detector.bats — gaia-meeting loop detector (E76-S6)
#
# AC6 / FR-MTG-30 / TC-MTG-GUARD-4: three or more consecutive turns alternating
# between exactly two agents with no progress signal triggers a forced
# FACILITATOR / LOOP-BREAK insertion.
#
# Progress signal = new source citation OR new decision OR new scratchpad pin.
# Three-way alternation (A-B-C) does NOT trigger.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/loop-detector.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: loop-detector.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC6: A-B-A with no progress fires the detector" {
  cat > "$TMP/turns.txt" <<'EOF'
theo|no-progress|just opinions
derek|no-progress|just opinions
theo|no-progress|just opinions
EOF
  run "$HELPER" --turns-file "$TMP/turns.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOOP-BREAK"* ]]
  [[ "$output" == *"FACILITATOR"* ]]
}

@test "AC6: A-B-A with new citation does NOT fire" {
  cat > "$TMP/turns.txt" <<'EOF'
theo|no-progress|just opinions
derek|no-progress|just opinions
theo|new-citation|see docs/foo.md
EOF
  run "$HELPER" --turns-file "$TMP/turns.txt"
  [ "$status" -eq 1 ]
}

@test "AC6: A-B-A with new decision does NOT fire" {
  cat > "$TMP/turns.txt" <<'EOF'
theo|no-progress|opinion
derek|no-progress|opinion
theo|new-decision|adopt X
EOF
  run "$HELPER" --turns-file "$TMP/turns.txt"
  [ "$status" -eq 1 ]
}

@test "AC6: A-B-A with new scratchpad pin does NOT fire" {
  cat > "$TMP/turns.txt" <<'EOF'
theo|no-progress|opinion
derek|no-progress|opinion
theo|new-pin|SP-3
EOF
  run "$HELPER" --turns-file "$TMP/turns.txt"
  [ "$status" -eq 1 ]
}

@test "AC6: three-way alternation A-B-C does NOT fire (exact two-agent rule)" {
  cat > "$TMP/turns.txt" <<'EOF'
theo|no-progress|opinion
derek|no-progress|opinion
nate|no-progress|opinion
EOF
  run "$HELPER" --turns-file "$TMP/turns.txt"
  [ "$status" -eq 1 ]
}

@test "AC6: only two consecutive turns does NOT fire (need three)" {
  cat > "$TMP/turns.txt" <<'EOF'
theo|no-progress|opinion
derek|no-progress|opinion
EOF
  run "$HELPER" --turns-file "$TMP/turns.txt"
  [ "$status" -eq 1 ]
}

@test "AC6: B-A-B (alternation starting with B) also fires" {
  cat > "$TMP/turns.txt" <<'EOF'
derek|no-progress|opinion
theo|no-progress|opinion
derek|no-progress|opinion
EOF
  run "$HELPER" --turns-file "$TMP/turns.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOOP-BREAK"* ]]
}

@test "AC6: A-A-A (same agent three times) does NOT fire (need exactly two distinct)" {
  cat > "$TMP/turns.txt" <<'EOF'
theo|no-progress|opinion
theo|no-progress|opinion
theo|no-progress|opinion
EOF
  run "$HELPER" --turns-file "$TMP/turns.txt"
  [ "$status" -eq 1 ]
}
