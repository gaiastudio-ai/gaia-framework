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

@test "a JSON object literal is detected as json" {
  run bash -c 'printf "%s" "{ \"k\": 1 }" | "$0"' "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "json" ]
}

@test "a JSON array literal is detected as json" {
  run bash -c 'printf "%s" "[1, 2, 3]" | "$0"' "$HELPER"
  [ "$output" = "json" ]
}

@test "a TypeScript interface is detected as ts" {
  run bash -c 'printf "%s" "interface User { id: string }" | "$0"' "$HELPER"
  [ "$output" = "ts" ]
}

@test "a TypeScript type alias is detected as ts" {
  run bash -c 'printf "%s" "type ID = string;" | "$0"' "$HELPER"
  [ "$output" = "ts" ]
}

@test "a TypeScript exported function is detected as ts" {
  run bash -c 'printf "%s" "export function foo() { return 1; }" | "$0"' "$HELPER"
  [ "$output" = "ts" ]
}

@test "a Python function definition is detected as py" {
  run bash -c 'printf "%s" "def foo(x):\n    return x + 1" | "$0"' "$HELPER"
  [ "$output" = "py" ]
}

@test "a Python import is detected as py" {
  run bash -c 'printf "%s" "import os\nimport sys" | "$0"' "$HELPER"
  [ "$output" = "py" ]
}

@test "a bash shebang is detected as sh" {
  run bash -c 'printf "%s" "#!/usr/bin/env bash\nset -euo pipefail" | "$0"' "$HELPER"
  [ "$output" = "sh" ]
}

@test "a POSIX sh shebang is detected as sh" {
  run bash -c 'printf "%s" "#!/bin/sh\necho hi" | "$0"' "$HELPER"
  [ "$output" = "sh" ]
}

@test "a Markdown heading is detected as md" {
  run bash -c 'printf "%s" "# Title\n\nA paragraph." | "$0"' "$HELPER"
  [ "$output" = "md" ]
}

@test "a Go package clause is detected as go" {
  run bash -c 'printf "%s" "package main\n\nfunc main() {}" | "$0"' "$HELPER"
  [ "$output" = "go" ]
}

@test "a Swift import is detected as swift" {
  run bash -c 'printf "%s" "import Foundation\n\nstruct User {}" | "$0"' "$HELPER"
  [ "$output" = "swift" ]
}

@test "a Kotlin function is detected as kt" {
  run bash -c 'printf "%s" "fun main() { println(\"hi\") }" | "$0"' "$HELPER"
  [ "$output" = "kt" ]
}

@test "a Rust main function is detected as rs" {
  run bash -c 'printf "%s" "fn main() { println!(\"hi\"); }" | "$0"' "$HELPER"
  [ "$output" = "rs" ]
}

@test "a Java public class is detected as java" {
  run bash -c 'printf "%s" "public class Foo { public static void main(String[] args) {} }" | "$0"' "$HELPER"
  [ "$output" = "java" ]
}

@test "ambiguous freeform prose defaults to md" {
  run bash -c 'printf "%s" "we should probably revisit auth tokens." | "$0"' "$HELPER"
  [ "$output" = "md" ]
}

@test "empty content defaults to md" {
  run bash -c 'printf "" | "$0"' "$HELPER"
  [ "$output" = "md" ]
}
