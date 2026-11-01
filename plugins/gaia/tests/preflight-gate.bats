#!/usr/bin/env bats
# preflight-gate.bats — tests for the preflight-commands and
# post-CI-smoke-commands runner (run-configured-commands.sh).

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/gaia-dev-story/scripts/run-configured-commands.sh"
  CFG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$CFG_DIR"
  WORKDIR="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$WORKDIR"
}

teardown() {
  rm -rf "$BATS_TEST_TMPDIR"
}

# --- Preflight gate tests ---

@test "all preflight commands pass — push proceeds" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
preflight_commands:
  - "true"
  - "echo ok"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 2 commands passed"* ]]
}

@test "one preflight command fails — push halted with command and exit code" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
preflight_commands:
  - "true"
  - "false"
  - "echo never"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"false"* ]]
  [[ "$output" == *"exit 1"* ]]
  # Third command must not run.
  [[ "$output" != *"echo never"* ]] || [[ "$output" != *"[preflight_commands 3/3]"* ]]
}

@test "command not found — push halted with exit 127" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
preflight_commands:
  - "no-such-cmd-e161"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"no-such-cmd-e161"* ]]
  [[ "$output" == *"exit 127"* ]]
}

@test "preflight key absent — silent no-op" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
project_name: test
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "preflight empty array — no-op" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
preflight_commands: []
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "config file missing — silent no-op" {
  run bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/nonexistent.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
}

# --- Post-CI smoke tests ---

@test "smoke passes after green CI" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
post_ci_smoke_commands:
  - "true"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 1 commands passed"* ]]
}

@test "smoke fails — merge halted" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
post_ci_smoke_commands:
  - "false"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"false"* ]]
}

@test "smoke key absent — no-op, merge proceeds" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
project_name: test
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "smoke empty array — no-op" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
post_ci_smoke_commands: []
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
}

# --- Workdir test ---

@test "commands execute in the specified workdir" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
preflight_commands:
  - "pwd"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$WORKDIR"* ]]
}

# --- Usage error ---

@test "missing --key flag exits 2" {
  run bash "$SCRIPT" --config "$CFG_DIR/project-config.yaml"
  [ "$status" -eq 2 ]
}

# --- Command preservation through hydration (special characters) ---

@test "commands with commas, brackets and quotes are preserved" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
preflight_commands:
  - "[ -f go.sum ]"
  - "echo 'a, b'"
YAML
  # Create a go.sum file in the workdir so the bracket test passes.
  touch "$WORKDIR/go.sum"
  run bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 2 commands passed"* ]]
}

# --- yq not installed ---

@test "yq not installed with key present — fails loudly" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
preflight_commands:
  - "true"
YAML
  # Build a minimal PATH that has bash, grep, jq etc. but not yq.
  # Symlink only the binaries the script needs into a clean directory.
  local narrow="$BATS_TEST_TMPDIR/narrow-bin"
  mkdir -p "$narrow"
  for b in bash grep printf cat jq mktemp rm; do
    local p
    p="$(command -v "$b" 2>/dev/null || true)"
    [ -n "$p" ] && ln -sf "$p" "$narrow/$b"
  done
  # Do NOT link yq.
  run env PATH="$narrow" bash "$SCRIPT" --key preflight_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"yq"* ]]
  [[ "$output" == *"preflight_commands"* ]]
}
