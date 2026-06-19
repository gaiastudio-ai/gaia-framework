#!/usr/bin/env bats
# embedded-dev-wiring.bats — embedded-dev agent (Nils) canonical-stack wiring tests
#
# Covers AC1-AC5 for the embedded-dev persona and stack wiring, including
# high-specificity auto-detection from ESP-IDF/PlatformIO/FreeRTOS markers
# and the bare-CMakeLists.txt false-positive guard.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  AGENTS_DIR="$(cd "$BATS_TEST_DIRNAME/../agents" && pwd)"
  KNOWLEDGE_DIR="$(cd "$BATS_TEST_DIRNAME/../knowledge" && pwd)"
  OVERLAY_SCRIPT="$SCRIPTS_DIR/review-common/agent-overlay.sh"
  PERSONA_SCRIPT="$SCRIPTS_DIR/load-stack-persona.sh"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — embedded-dev.md persona file exists with valid structure
# ---------------------------------------------------------------------------

@test "agents/embedded-dev.md exists (AC1)" {
  [ -f "$AGENTS_DIR/embedded-dev.md" ]
}

@test "embedded-dev.md frontmatter contains name: embedded-dev (AC1)" {
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "name: embedded-dev"
}

@test "embedded-dev.md frontmatter contains context: main (AC1)" {
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "context: main"
}

@test "embedded-dev.md frontmatter contains allowed-tools with Read, Write, Edit, Bash (AC1)" {
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "allowed-tools:"
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "Read"
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "Write"
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "Edit"
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "Bash"
}

@test "embedded-dev.md inherits shared dev persona from _base-dev.md (AC1)" {
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "Inherit all shared dev persona, mission, and protocols from"
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "_base-dev.md"
}

@test "embedded-dev.md identity is Nils (AC1)" {
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "Nils"
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "Embedded Developer"
}

@test "embedded-dev.md has Stack: embedded in Expertise section (AC1)" {
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "Stack:** embedded"
}

@test "embedded-dev.md describes C/C++/ESP-IDF/FreeRTOS capabilities (AC1)" {
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "ESP-IDF"
  assert_file_contains "$AGENTS_DIR/embedded-dev.md" "FreeRTOS"
}

# ---------------------------------------------------------------------------
# AC2 — agent-overlay.sh accepts embedded-dev as canonical stack
# ---------------------------------------------------------------------------

@test "is_canonical_stack accepts embedded-dev (agent-overlay resolves embedded-dev) (AC2)" {
  run "$OVERLAY_SCRIPT" --skill gaia-review-code --stack embedded-dev
  [ "$status" -eq 0 ]
}

@test "agent-overlay returns embedded-dev agent_id for --stack embedded-dev (AC2)" {
  run "$OVERLAY_SCRIPT" --skill gaia-review-code --stack embedded-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent_id":"embedded-dev"'* ]]
  [[ "$output" == *'"sidecar_path":"_memory/embedded-dev-sidecar.md"'* ]]
}

# ---------------------------------------------------------------------------
# AC3 — high-specificity auto-detection from ESP-IDF/PlatformIO/FreeRTOS markers
# ---------------------------------------------------------------------------

@test "sdkconfig auto-detects embedded-dev via load-stack-persona.sh (AC3)" {
  cd "$TEST_TMP"
  touch sdkconfig
  run "$PERSONA_SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack='embedded-dev'"* ]] || [[ "$output" == *"stack=embedded-dev"* ]]
  [[ "$output" == *"embedded-dev.md"* ]]
}

@test "idf_component.yml auto-detects embedded-dev via load-stack-persona.sh (AC3)" {
  cd "$TEST_TMP"
  touch idf_component.yml
  run "$PERSONA_SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack='embedded-dev'"* ]] || [[ "$output" == *"stack=embedded-dev"* ]]
  [[ "$output" == *"embedded-dev.md"* ]]
}

@test "platformio.ini auto-detects embedded-dev via load-stack-persona.sh (AC3)" {
  cd "$TEST_TMP"
  touch platformio.ini
  run "$PERSONA_SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack='embedded-dev'"* ]] || [[ "$output" == *"stack=embedded-dev"* ]]
  [[ "$output" == *"embedded-dev.md"* ]]
}

@test "CMakeLists.txt with FreeRTOS reference auto-detects embedded-dev (AC3)" {
  cd "$TEST_TMP"
  cat > CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(my_firmware)
# FreeRTOS component
idf_component_register(SRCS "main.c" INCLUDE_DIRS "." REQUIRES freertos)
CMAKE
  run "$PERSONA_SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack='embedded-dev'"* ]] || [[ "$output" == *"stack=embedded-dev"* ]]
  [[ "$output" == *"embedded-dev.md"* ]]
}

@test "detect-signals.sh emits embedded ecosystem name for sdkconfig (AC3)" {
  cd "$TEST_TMP"
  touch sdkconfig
  run "$SCRIPTS_DIR/detect-signals.sh" --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"embedded"'* ]]
}

@test "detect-signals.sh emits embedded ecosystem name for platformio.ini (AC3)" {
  cd "$TEST_TMP"
  touch platformio.ini
  run "$SCRIPTS_DIR/detect-signals.sh" --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"embedded"'* ]]
}

# ---------------------------------------------------------------------------
# AC4 — false-positive guard: bare CMakeLists.txt does NOT resolve to embedded
# ---------------------------------------------------------------------------

@test "bare CMakeLists.txt without FreeRTOS does NOT resolve to embedded-dev (AC4)" {
  cd "$TEST_TMP"
  cat > CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(my_host_tool)
add_executable(tool main.c)
CMAKE
  run "$PERSONA_SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  # Should either exit 2 (no stack) or detect a non-embedded stack — never embedded-dev.
  if [ "$status" -eq 0 ]; then
    [[ "$output" != *"embedded-dev"* ]]
  else
    [ "$status" -eq 2 ]
  fi
}

@test "bare CMakeLists.txt does NOT emit embedded in detect-signals.sh (AC4)" {
  cd "$TEST_TMP"
  cat > CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(my_host_tool)
add_executable(tool main.c)
CMAKE
  run "$SCRIPTS_DIR/detect-signals.sh" --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"embedded"'* ]]
}

# ---------------------------------------------------------------------------
# AC5 — agent-manifest.csv + init-project.sh
# ---------------------------------------------------------------------------

@test "agent-manifest.csv contains embedded-dev row with Nils display name (AC5)" {
  grep -q '"embedded-dev"' "$KNOWLEDGE_DIR/agent-manifest.csv"
  grep -q '"Nils"' "$KNOWLEDGE_DIR/agent-manifest.csv"
}

@test "embedded-dev manifest row has dev module (AC5)" {
  local row
  row="$(grep '"embedded-dev"' "$KNOWLEDGE_DIR/agent-manifest.csv")"
  [[ "$row" == *'"dev"'* ]]
}

@test "init-project.sh source contains embedded-dev in agents roster (AC5)" {
  grep -q 'embedded-dev' "$SCRIPTS_DIR/init-project.sh"
}

@test "init-project.sh display-name case maps embedded-dev (AC5)" {
  grep -qE 'embedded-dev\)' "$SCRIPTS_DIR/init-project.sh"
}
