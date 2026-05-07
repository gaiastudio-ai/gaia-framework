#!/usr/bin/env bats
# scratchpad-detect-type.bats — gaia-meeting content-type detection (E76-S4)
#
# AC7 / FR-MTG-13. Exercises TC-MTG-SP-4.
#
# Detects content type from a content string and emits one of:
#   json | ts | py | sh | md | go | swift | kt | rs | java
# Default fallback is `md` for ambiguous text.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/scratchpad-detect-type.sh"
}

@test "Pre-flight: scratchpad-detect-type.sh exists and is executable" {
  [ -x "$HELPER" ]
}

_detect() {
  printf '%s' "$1" | "$HELPER"
}

@test "AC7: JSON object literal -> json" {
  run bash -c 'printf "%s" "{ \"k\": 1 }" | "$0"' "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "json" ]
}

@test "AC7: JSON array literal -> json" {
  run bash -c 'printf "%s" "[1, 2, 3]" | "$0"' "$HELPER"
  [ "$output" = "json" ]
}

@test "AC7: TypeScript interface -> ts" {
  run bash -c 'printf "%s" "interface User { id: string }" | "$0"' "$HELPER"
  [ "$output" = "ts" ]
}

@test "AC7: TypeScript type alias -> ts" {
  run bash -c 'printf "%s" "type ID = string;" | "$0"' "$HELPER"
  [ "$output" = "ts" ]
}

@test "AC7: TypeScript export function -> ts" {
  run bash -c 'printf "%s" "export function foo() { return 1; }" | "$0"' "$HELPER"
  [ "$output" = "ts" ]
}

@test "AC7: Python def -> py" {
  run bash -c 'printf "%s" "def foo(x):\n    return x + 1" | "$0"' "$HELPER"
  [ "$output" = "py" ]
}

@test "AC7: Python import -> py" {
  run bash -c 'printf "%s" "import os\nimport sys" | "$0"' "$HELPER"
  [ "$output" = "py" ]
}

@test "AC7: bash shebang -> sh" {
  run bash -c 'printf "%s" "#!/usr/bin/env bash\nset -euo pipefail" | "$0"' "$HELPER"
  [ "$output" = "sh" ]
}

@test "AC7: sh shebang -> sh" {
  run bash -c 'printf "%s" "#!/bin/sh\necho hi" | "$0"' "$HELPER"
  [ "$output" = "sh" ]
}

@test "AC7: Markdown heading -> md" {
  run bash -c 'printf "%s" "# Title\n\nA paragraph." | "$0"' "$HELPER"
  [ "$output" = "md" ]
}

@test "AC7: Go package -> go" {
  run bash -c 'printf "%s" "package main\n\nfunc main() {}" | "$0"' "$HELPER"
  [ "$output" = "go" ]
}

@test "AC7: Swift import -> swift" {
  run bash -c 'printf "%s" "import Foundation\n\nstruct User {}" | "$0"' "$HELPER"
  [ "$output" = "swift" ]
}

@test "AC7: Kotlin fun -> kt" {
  run bash -c 'printf "%s" "fun main() { println(\"hi\") }" | "$0"' "$HELPER"
  [ "$output" = "kt" ]
}

@test "AC7: Rust fn main -> rs" {
  run bash -c 'printf "%s" "fn main() { println!(\"hi\"); }" | "$0"' "$HELPER"
  [ "$output" = "rs" ]
}

@test "AC7: Java public class -> java" {
  run bash -c 'printf "%s" "public class Foo { public static void main(String[] args) {} }" | "$0"' "$HELPER"
  [ "$output" = "java" ]
}

@test "AC7: ambiguous freeform prose defaults to md" {
  run bash -c 'printf "%s" "we should probably revisit auth tokens." | "$0"' "$HELPER"
  [ "$output" = "md" ]
}

@test "AC7: empty content defaults to md" {
  run bash -c 'printf "" | "$0"' "$HELPER"
  [ "$output" = "md" ]
}
