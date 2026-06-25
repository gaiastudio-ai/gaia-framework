#!/usr/bin/env bats
# resolve-config-cwd-independence.bats — AF-2026-05-17-2 regression guard
#
# Asserts that resolve-config.bats's setup() cd's into TEST_TMP so the
# subject script's L5 $PWD discovery step finds no project-config.yaml
# at $PWD and falls through to the CLAUDE_SKILL_DIR fixture path.
#
# Without this guard, running bats from a directory whose CWD (or an
# ancestor, via the walk-up step at L4b) contains config/project-config.yaml
# silently substitutes the real project config for the fixture and breaks
# all fixture-based assertions — 16 of 76 tests fail when bats runs from
# the project root instead of from gaia-public/.
#
# This regression test does NOT modify the script's documented precedence
# ladder ($PWD > CLAUDE_SKILL_DIR per L5/L6); it only verifies that the
# resolve-config.bats setup() compensates by cd'ing into a clean directory
# so the fixture path can be exercised.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  BATS_FILE="$REPO_ROOT/plugins/gaia/tests/resolve-config.bats"
  export LC_ALL=C
}

@test "resolve-config.bats exists" {
  [ -f "$BATS_FILE" ]
}

@test "resolve-config.bats setup cd's into TEST_TMP" {
  # The setup function must contain a 'cd "$TEST_TMP"' line so the L5
  # $PWD-discovery step misses and falls through to CLAUDE_SKILL_DIR.
  run grep -E 'cd "\$TEST_TMP"' "$BATS_FILE"
  [ "$status" -eq 0 ]
}

@test "resolve-config.bats setup references lineage" {
  run grep -E 'AF-2026-05-17-2' "$BATS_FILE"
  [ "$status" -eq 0 ]
}

@test "resolve-config.bats runs green from a parent-of-gaia-public CWD" {
  # The whole point of AF-2026-05-17-2 — bats invocation from project root
  # (one dir up from gaia-public/) must succeed end-to-end.
  cd "$REPO_ROOT/.."
  run bats "$BATS_FILE"
  [ "$status" -eq 0 ]
  # Expect the standard plan line for the suite
  [[ "$output" == *"1.."* ]]
}

# ---------------------------------------------------------------------------
# Default synthesis for memory_path / checkpoint_path when unset
# ---------------------------------------------------------------------------
# These tests verify that resolve-config.sh synthesises project-root-anchored
# defaults for memory_path and checkpoint_path instead of dying with
# "missing required field" when neither config nor env supplies them.

# Helper: create a minimal fixture config that deliberately OMITS
# memory_path and checkpoint_path so the synthesis path is exercised.
_mk_no_mem_config() {
  local dir="$1"
  mkdir -p "$dir/config"
  cat > "$dir/config/project-config.yaml" <<'YAML'
project_root: /tmp/synth-test
project_path: /tmp/synth-test/app
installed_path: /tmp/synth-test/_gaia
framework_version: 1.200.0
date: 1970-01-01
YAML
}

@test "checkpoint_path synthesises from project root when unset (AC1)" {
  local tmp
  tmp="$(mktemp -d)"
  _mk_no_mem_config "$tmp/skill"
  cd "$tmp"

  # No GAIA_CHECKPOINT_PATH, no checkpoint_path in config — must NOT die.
  unset GAIA_CHECKPOINT_PATH 2>/dev/null || true
  unset GAIA_MEMORY_PATH 2>/dev/null || true
  CLAUDE_SKILL_DIR="$tmp/skill" run "$REPO_ROOT/plugins/gaia/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"checkpoint_path='/tmp/synth-test/.gaia/memory/checkpoints'"* ]]

  rm -rf "$tmp"
}

@test "memory_path synthesises from project root when unset (AC2)" {
  local tmp
  tmp="$(mktemp -d)"
  _mk_no_mem_config "$tmp/skill"
  cd "$tmp"

  unset GAIA_CHECKPOINT_PATH 2>/dev/null || true
  unset GAIA_MEMORY_PATH 2>/dev/null || true
  CLAUDE_SKILL_DIR="$tmp/skill" run "$REPO_ROOT/plugins/gaia/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory_path='/tmp/synth-test/.gaia/memory'"* ]]

  rm -rf "$tmp"
}

@test "explicit GAIA_CHECKPOINT_PATH override wins over synthesis (AC3)" {
  local tmp
  tmp="$(mktemp -d)"
  _mk_no_mem_config "$tmp/skill"
  cd "$tmp"

  unset GAIA_MEMORY_PATH 2>/dev/null || true
  GAIA_CHECKPOINT_PATH="/custom/cp" \
    CLAUDE_SKILL_DIR="$tmp/skill" run "$REPO_ROOT/plugins/gaia/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"checkpoint_path='/custom/cp'"* ]]

  rm -rf "$tmp"
}

@test "explicit GAIA_MEMORY_PATH override wins over synthesis (AC4)" {
  local tmp
  tmp="$(mktemp -d)"
  _mk_no_mem_config "$tmp/skill"
  cd "$tmp"

  unset GAIA_CHECKPOINT_PATH 2>/dev/null || true
  GAIA_MEMORY_PATH="/custom/mem" \
    CLAUDE_SKILL_DIR="$tmp/skill" run "$REPO_ROOT/plugins/gaia/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory_path='/custom/mem'"* ]]

  rm -rf "$tmp"
}
