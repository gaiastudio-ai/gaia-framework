#!/usr/bin/env bats
# detect-orchestration-mode.bats — E84-S3 / ADR-093 dual-mode resolver coverage.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/detect-orchestration-mode.sh"
  CONFIG="$TEST_TMP/project-config.yaml"
}
teardown() { common_teardown; }

# Helper: build a project-config.yaml with a given orchestration.mode value.
make_config() {
  # make_config <mode-or-empty>
  local mode="${1:-}"
  if [ -n "$mode" ]; then
    cat > "$CONFIG" <<EOF
project:
  name: test

orchestration:
  mode: $mode

other_section:
  foo: bar
EOF
  else
    cat > "$CONFIG" <<'EOF'
project:
  name: test
EOF
  fi
}

# ---- Mode A (default / silent fallback) ----

@test "Mode A: env unset + config unset -> subagent" {
  make_config ""
  unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS || true
  run "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "subagent" ]]
}

@test "Mode A: env=1 + config unset -> subagent (silent fallback)" {
  make_config ""
  run env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "subagent" ]]
}

@test "Mode A: env unset + config=team -> subagent (silent fallback)" {
  make_config "team"
  unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS || true
  run "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "subagent" ]]
}

@test "Mode A: env=0 + config=team -> subagent" {
  make_config "team"
  run env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "subagent" ]]
}

@test "Mode A: env=1 + config=subagent (explicit Mode A) -> subagent" {
  make_config "subagent"
  run env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "subagent" ]]
}

# ---- Mode B (opt-in: BOTH conditions required) ----

@test "Mode B: env=1 + config=team -> team" {
  make_config "team"
  run env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "team" ]]
}

# ---- Edge cases ----

@test "missing project-config.yaml -> subagent (graceful default)" {
  run env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 "$SCRIPT" --config "$TEST_TMP/does-not-exist.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == "subagent" ]]
}

@test "config with quoted mode value 'team' -> team" {
  cat > "$CONFIG" <<'EOF'
orchestration:
  mode: "team"
EOF
  run env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "team" ]]
}

@test "config with inline comment after mode -> team" {
  cat > "$CONFIG" <<'EOF'
orchestration:
  mode: team    # opt in to persistent teammates
EOF
  run env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "team" ]]
}

@test "config with orchestration block but unknown mode value -> subagent" {
  cat > "$CONFIG" <<'EOF'
orchestration:
  mode: bogus
EOF
  run env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == "subagent" ]]
}

@test "custom --env-flag name resolves correctly" {
  make_config "team"
  run env MY_CUSTOM_FLAG=1 "$SCRIPT" --config "$CONFIG" --env-flag MY_CUSTOM_FLAG
  [ "$status" -eq 0 ]
  [[ "$output" == "team" ]]
}

# ---- usage / args ----

@test "--help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "unknown flag exits 2" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}
