#!/usr/bin/env bats
# post-ci-smoke.bats — additional post-CI smoke tests for the
# run-configured-commands.sh runner, covering exit-code 1 scenarios
# and the merge-halt path.

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

@test "smoke command exits 1 — merge halted with exit code named" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
post_ci_smoke_commands:
  - "exit 1"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"exit 1"* ]]
}

@test "smoke multi-command — first passes, second fails, third skipped" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
post_ci_smoke_commands:
  - "true"
  - "exit 42"
  - "echo should-not-run"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"exit 42"* ]]
  [[ "$output" != *"should-not-run"* ]]
}

@test "smoke all pass — merge proceeds" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
post_ci_smoke_commands:
  - "true"
  - "echo health-ok"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 2 commands passed"* ]]
}

@test "smoke key absent on config with other keys — no-op" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
project_name: myproject
ci_cd:
  promotion_chain:
    - staging
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "smoke commands run in the story working tree" {
  cat > "$CFG_DIR/project-config.yaml" <<'YAML'
post_ci_smoke_commands:
  - "pwd"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CFG_DIR/project-config.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$WORKDIR"* ]]
}
