#!/usr/bin/env bats
# load-stack-persona.bats — unit tests for plugins/gaia/scripts/load-stack-persona.sh (E65-S1)
# Covers TC-DEJ-PERSONA-01..07, EC-4, EC-5.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/load-stack-persona.sh"
  AGENTS_DIR="$(cd "$BATS_TEST_DIRNAME/../agents" && pwd)"
  export AGENTS_DIR
}
teardown() { common_teardown; }

# Each test creates a project root with the canonical stack file under TEST_TMP.

@test "load-stack-persona.sh: --help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"load-stack-persona.sh"* ]]
}

@test "tsconfig.json -> ts-dev resolves to typescript-dev.md (canonical-name -> filename map)" {
  cd "$TEST_TMP"
  echo '{}' > tsconfig.json
  run "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack='ts-dev'"* ]] || [[ "$output" == *"stack=ts-dev"* ]]
  [[ "$output" == *"typescript-dev.md"* ]]
}

@test "pom.xml -> java-dev / java-dev.md" {
  cd "$TEST_TMP"
  printf '<project/>\n' > pom.xml
  run "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"java-dev"* ]]
  [[ "$output" == *"java-dev.md"* ]]
}

@test "requirements.txt -> python-dev / python-dev.md" {
  cd "$TEST_TMP"
  : > requirements.txt
  run "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"python-dev"* ]]
  [[ "$output" == *"python-dev.md"* ]]
}

@test "go.mod -> go-dev / go-dev.md" {
  cd "$TEST_TMP"
  : > go.mod
  run "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"go-dev"* ]]
  [[ "$output" == *"go-dev.md"* ]]
}

@test "pubspec.yaml -> flutter-dev / flutter-dev.md" {
  cd "$TEST_TMP"
  : > pubspec.yaml
  run "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flutter-dev"* ]]
  [[ "$output" == *"flutter-dev.md"* ]]
}

@test "AndroidManifest.xml -> mobile-dev / mobile-dev.md" {
  cd "$TEST_TMP"
  mkdir -p app/src/main
  : > app/src/main/AndroidManifest.xml
  run "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mobile-dev"* ]]
  [[ "$output" == *"mobile-dev.md"* ]]
}

@test "angular.json -> angular-dev / angular-dev.md" {
  cd "$TEST_TMP"
  : > angular.json
  run "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"angular-dev"* ]]
  [[ "$output" == *"angular-dev.md"* ]]
}

@test "unsupported stack (no canonical files) -> stderr 'unsupported stack' + exit 2" {
  cd "$TEST_TMP"
  # Bare project, no canonical stack files
  run --separate-stderr "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unsupported stack"* ]]
}

@test "load-stack-persona.sh: angular.json takes precedence over package.json/tsconfig.json" {
  cd "$TEST_TMP"
  echo '{}' > tsconfig.json
  echo '{}' > package.json
  : > angular.json
  run "$SCRIPT" --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"angular-dev"* ]]
}

@test "load-stack-persona.sh: explicit --stack flag short-circuits heuristics" {
  cd "$TEST_TMP"
  : > go.mod
  run "$SCRIPT" --stack ts-dev --project-root "$TEST_TMP" --agents-dir "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ts-dev"* ]]
  [[ "$output" == *"typescript-dev.md"* ]]
}
