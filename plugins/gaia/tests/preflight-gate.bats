#!/usr/bin/env bats
# preflight-gate.bats — tests for the preflight-commands and
# post-CI-smoke-commands runner (run-configured-commands.sh).

load 'test_helper.bash'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/gaia-dev-story/scripts/run-configured-commands.sh"
  CFG_DIR="$BATS_TEST_TMPDIR/.gaia/config"
  mkdir -p "$CFG_DIR"
  WORKDIR="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$WORKDIR"
  CONFIG="$CFG_DIR/project-config.yaml"
}

teardown() {
  rm -rf "$BATS_TEST_TMPDIR"
}

# --- Config discovery without --config ---

@test "discovers config via CWD walk-up when no --config and no env vars" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "true"
YAML
  # Run from workdir (child of the .gaia tree); unset all env vars.
  run env -u PROJECT_CONFIG -u CLAUDE_PROJECT_ROOT -u PROJECT_ROOT \
    bash -c "cd '$BATS_TEST_TMPDIR/workdir' && bash '$SCRIPT' --key preflight_commands --workdir '$WORKDIR'"
  [ "$status" -eq 0 ]
  grep -q 'all 1 commands passed' <<< "$output"
}

@test "discovers config via CLAUDE_PROJECT_ROOT when set" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "true"
YAML
  run env -u PROJECT_CONFIG PROJECT_ROOT="" \
    CLAUDE_PROJECT_ROOT="$BATS_TEST_TMPDIR" \
    bash "$SCRIPT" --key preflight_commands --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -q 'all 1 commands passed' <<< "$output"
}

@test "discovers config via PROJECT_CONFIG when set" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "true"
YAML
  run env -u CLAUDE_PROJECT_ROOT -u PROJECT_ROOT \
    PROJECT_CONFIG="$CONFIG" \
    bash "$SCRIPT" --key preflight_commands --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -q 'all 1 commands passed' <<< "$output"
}

# --- AC1: preflight pass/fail/127 ---

@test "all preflight commands pass — push proceeds" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "true"
  - "echo ok"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -q 'all 2 commands passed' <<< "$output"
}

@test "one preflight command fails — HALT names command and exit code" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "true"
  - "false"
  - "echo never"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  # Assert on the HALT line itself — not the progress line.
  grep -q 'HALT:.*false.*(exit 1)' <<< "$output"
  # Third command must not run.
  case "$output" in *"[preflight_commands 3/3]"*) return 1 ;; esac
}

@test "command not found — HALT names command and exit 127" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "no-such-cmd-synth"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -q 'HALT:.*no-such-cmd-synth.*(exit 127)' <<< "$output"
}

# --- AC2: absent/empty = silent no-op ---

@test "preflight key absent — silent no-op, empty output" {
  cat > "$CONFIG" <<'YAML'
project_name: test
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "preflight empty array — silent no-op, empty output" {
  cat > "$CONFIG" <<'YAML'
preflight_commands: []
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no config found anywhere — silent no-op" {
  run env -u PROJECT_CONFIG -u CLAUDE_PROJECT_ROOT -u PROJECT_ROOT \
    bash -c "cd /tmp && bash '$SCRIPT' --key preflight_commands --workdir '$WORKDIR'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- AC3: post-CI smoke ---

@test "smoke passes after green CI" {
  cat > "$CONFIG" <<'YAML'
post_ci_smoke_commands:
  - "true"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -q 'all 1 commands passed' <<< "$output"
}

@test "smoke fails — HALT names command" {
  cat > "$CONFIG" <<'YAML'
post_ci_smoke_commands:
  - "false"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -q 'HALT:.*false' <<< "$output"
}

@test "smoke key absent — no-op, empty output" {
  cat > "$CONFIG" <<'YAML'
project_name: test
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "smoke empty array — silent no-op, empty output" {
  cat > "$CONFIG" <<'YAML'
post_ci_smoke_commands: []
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Fail closed on read errors ---

@test "malformed YAML — fails closed with parse error" {
  cat > "$CONFIG" <<'YAML'
preflight_commands: [unterminated
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -q 'HALT' <<< "$output"
  grep -qi 'parse\|failed' <<< "$output"
}

@test "unreadable config — fails closed with permission denied" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "true"
YAML
  chmod 000 "$CONFIG"
  # Skip if running as root (chmod 000 has no effect).
  if [ -r "$CONFIG" ]; then
    chmod 644 "$CONFIG"
    skip "running as root — chmod 000 has no effect"
  fi
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  chmod 644 "$CONFIG"
  [ "$status" -eq 1 ]
  grep -q 'HALT' <<< "$output"
  grep -qi 'not readable\|permission' <<< "$output"
}

# --- Workdir test ---

@test "commands execute in the specified workdir" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "pwd"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -qF "$WORKDIR" <<< "$output"
}

# --- Usage error ---

@test "missing --key flag exits 2" {
  run bash "$SCRIPT" --config "$CONFIG"
  [ "$status" -eq 2 ]
}

# --- Command preservation (special characters) ---

@test "commands with commas, brackets and quotes are preserved" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "[ -f go.sum ]"
  - "echo 'a, b'"
YAML
  touch "$WORKDIR/go.sum"
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -q 'all 2 commands passed' <<< "$output"
}

# --- yq not installed ---

@test "yq not installed with key present — fails closed" {
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "true"
YAML
  local narrow="$BATS_TEST_TMPDIR/narrow-bin"
  mkdir -p "$narrow"
  for b in bash grep printf cat jq mktemp rm dirname pwd basename; do
    local p
    p="$(command -v "$b" 2>/dev/null || true)"
    [ -n "$p" ] && ln -sf "$p" "$narrow/$b"
  done
  run env PATH="$narrow" bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}
