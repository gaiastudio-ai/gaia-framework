#!/usr/bin/env bats
# load-taxonomy.bats — Unit tests for the closed-list taxonomy loader (E88-S1)
# Covers TC-DPD-1, TC-DPD-2, TC-DPD-3 per ADR-107.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  export LIB_DIR
}

teardown() {
  common_teardown
}

# TC-DPD-1 — deferral mode emits exactly 6 lines.
@test "TC-DPD-1: load-taxonomy.sh --taxonomy deferral emits exactly 6 v1 phrases" {
  run "$LIB_DIR/load-taxonomy.sh" --taxonomy deferral
  [ "$status" -eq 0 ]
  # Count non-empty lines.
  local n
  n=$(printf '%s\n' "$output" | grep -cE '.')
  [ "$n" -eq 6 ]
  # Sanity-check each canonical phrase.
  printf '%s\n' "$output" | grep -qxF 'deferred'
  printf '%s\n' "$output" | grep -qxF 'follow-up integration story'
  printf '%s\n' "$output" | grep -qxF 'stub seam'
  printf '%s\n' "$output" | grep -qxF 'harness wiring lands'
  printf '%s\n' "$output" | grep -qxF 'not-yet-wired'
  printf '%s\n' "$output" | grep -qxF 'production wiring'
}

# TC-DPD-2 — dispatch mode emits exactly 5 lines.
@test "TC-DPD-2: load-taxonomy.sh --taxonomy dispatch emits exactly 5 v1 verbs" {
  run "$LIB_DIR/load-taxonomy.sh" --taxonomy dispatch
  [ "$status" -eq 0 ]
  local n
  n=$(printf '%s\n' "$output" | grep -cE '.')
  [ "$n" -eq 5 ]
  printf '%s\n' "$output" | grep -qxF 'spawns'
  printf '%s\n' "$output" | grep -qxF 'dispatches'
  printf '%s\n' "$output" | grep -qxF 'invokes'
  printf '%s\n' "$output" | grep -qxF 'wires'
  printf '%s\n' "$output" | grep -qxF 'calls'
}

# TC-DPD-3 — unknown taxonomy exits 1 with stderr enumerating valid names.
@test "TC-DPD-3: load-taxonomy.sh --taxonomy unknown exits 1 with helpful stderr" {
  # Capture stderr into output for `run`-friendly assertion (combined 2>&1).
  run bash -c '"$0" --taxonomy frobnicate 2>&1' "$LIB_DIR/load-taxonomy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *deferral* ]]
  [[ "$output" == *dispatch* ]]
}

# AC3 — --as-grep-file produces a path consumable by grep -wFf.
@test "AC3: --as-grep-file deferral writes tempfile usable by grep -wFf" {
  run "$LIB_DIR/load-taxonomy.sh" --taxonomy deferral --as-grep-file
  [ "$status" -eq 0 ]
  local tmp="$output"
  [ -f "$tmp" ]
  # File contains exactly 6 lines.
  local n
  n=$(grep -cE '.' "$tmp")
  [ "$n" -eq 6 ]
  # grep -wFf accepts it.
  echo "stub seam appears here" | grep -wFf "$tmp" >/dev/null
  rm -f "$tmp"
}

@test "AC3: --as-grep-file dispatch writes tempfile usable by grep -wFf" {
  run "$LIB_DIR/load-taxonomy.sh" --taxonomy dispatch --as-grep-file
  [ "$status" -eq 0 ]
  local tmp="$output"
  [ -f "$tmp" ]
  local n
  n=$(grep -cE '.' "$tmp")
  [ "$n" -eq 5 ]
  echo "the orchestrator spawns a sub-agent" | grep -wFf "$tmp" >/dev/null
  rm -f "$tmp"
}
