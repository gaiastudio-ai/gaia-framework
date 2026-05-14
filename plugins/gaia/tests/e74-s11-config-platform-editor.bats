#!/usr/bin/env bats
# e74-s11-config-platform-editor.bats — E74-S11
#
# AC1, AC2, AC8 — `/gaia-config-platform` editor: add/remove/list, validation,
# idempotency.

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
EDITOR="$SCRIPTS/gaia-config-platform-edit.sh"

setup() {
  common_setup
  CFG="$TEST_TMP/project-config.yaml"
  cat > "$CFG" <<'YAML'
project_root: /tmp/x
project_path: /tmp/x
memory_path: /tmp/x/_memory
checkpoint_path: /tmp/x/_memory/checkpoints
installed_path: /tmp/x
framework_version: 0.0.0
date: 2026-05-05

stacks:
  - name: app
    language: swift
    paths: ["src/**"]
YAML
}
teardown() { common_teardown; }

# AC1 add ---------------------------------------------------------

@test "add ios writes platforms: [ios] when section absent" {
  run "$EDITOR" --config "$CFG" add ios
  [ "$status" -eq 0 ]
  grep -qE '^platforms:' "$CFG"
  grep -qE '^- ios$|^  - ios$' "$CFG"
}

@test "add android appends to existing platforms list" {
  printf '\nplatforms:\n  - ios\n' >> "$CFG"
  run "$EDITOR" --config "$CFG" add android
  [ "$status" -eq 0 ]
  run "$EDITOR" --config "$CFG" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ios"* ]]
  [[ "$output" == *"android"* ]]
}

# AC1 remove ------------------------------------------------------

@test "remove ios drops it from platforms" {
  printf '\nplatforms:\n  - ios\n  - android\n' >> "$CFG"
  run "$EDITOR" --config "$CFG" remove ios
  [ "$status" -eq 0 ]
  run "$EDITOR" --config "$CFG" list
  [ "$status" -eq 0 ]
  [[ "$output" != *"ios"* ]]
  [[ "$output" == *"android"* ]]
}

@test "remove of absent platform is a no-op success" {
  printf '\nplatforms:\n  - android\n' >> "$CFG"
  run "$EDITOR" --config "$CFG" remove ios
  [ "$status" -eq 0 ]
}

# AC1 list --------------------------------------------------------

@test "list emits each platform on its own line" {
  printf '\nplatforms:\n  - ios\n  - android\n' >> "$CFG"
  run "$EDITOR" --config "$CFG" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ios"* ]]
  [[ "$output" == *"android"* ]]
}

# AC2 known-enum warning + invalid identifier ---------------------

@test "add unknown but valid kebab-case id warns and proceeds" {
  run --separate-stderr "$EDITOR" --config "$CFG" add harmonyos
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"warning"* || "$stderr" == *"unknown"* ]]
  run "$EDITOR" --config "$CFG" list
  [[ "$output" == *"harmonyos"* ]]
}

@test "add empty id is discoverability prompt (E71-S9 AC1): exit 0 with baseline menu" {
  # E71-S9 AC1 amended the contract: no-arg `add` is a discoverability prompt
  # (SKILL.md Step 2c: "Re-prompt the user for an identifier — DO NOT exit
  # non-zero. The empty argument is a discoverability hint, not a validation
  # failure"). Was exit 1 prior to E71-S9; now exit 0 with menu on stderr.
  run --separate-stderr "$EDITOR" --config "$CFG" add ""
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"web"* ]]
  [[ "$stderr" == *"ios"* ]]
  [[ "$stderr" == *"android"* ]]
}

@test "add invalid characters rejected with exit 1" {
  run "$EDITOR" --config "$CFG" add 'i;rm -rf'
  [ "$status" -eq 1 ]
}

# AC8 idempotency -------------------------------------------------

@test "add ios twice produces a single entry" {
  run "$EDITOR" --config "$CFG" add ios
  [ "$status" -eq 0 ]
  run "$EDITOR" --config "$CFG" add ios
  [ "$status" -eq 0 ]
  run grep -c '^  - ios$' "$CFG"
  [ "$output" = "1" ]
}
