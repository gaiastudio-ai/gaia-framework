#!/usr/bin/env bats
# detect-affected.bats — E113-S1 SPIKE: selective-test-execution feasibility
#
# Tests for spikes/E113-S1/detect-affected.sh
# The script maps changed-file paths to stack names defined in project-config.yaml.
#
# Design facts verified by Val:
#   - project-config.yaml globs carry a "gaia-public/" prefix
#   - git diff --name-only returns paths WITHOUT that prefix
#   - detect-affected.sh strips "gaia-public/" from each glob before matching
#   - bash ** does not recurse; script strips trailing /** and does prefix match
#   - config/ subdir is NOT in the glob list — a known gap tracked for S2
#
# NOTE: This file lives two levels below tests/ (tests/spikes/E113-S1/) so it
# cannot use the shared test_helper.bash (which tries to cd to ../scripts from
# the bats-file dir). setup/teardown are defined inline here.

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/spikes/E113-S1/detect-affected.sh"

setup() {
  local slug
  slug="$(printf '%s' "${BATS_TEST_NAME:-unknown}" | tr -c '[:alnum:]' '_')"
  TEST_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-spike-${slug}-$$"
  mkdir -p "$TEST_TMP"
  export TEST_TMP
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Helper: write a minimal project-config.yaml with a single gaia-plugin stack.
# Globs use the "gaia-public/" prefix — exactly as the real config does.
# ---------------------------------------------------------------------------
_write_gaia_plugin_config() {
  local cfg="$1"
  cat > "$cfg" <<'YAML'
stacks:
  - name: gaia-plugin
    language: bash
    paths:
      - "gaia-public/plugins/gaia/scripts/**"
      - "gaia-public/plugins/gaia/skills/**"
      - "gaia-public/plugins/gaia/agents/**"
      - "gaia-public/plugins/gaia/knowledge/**"
      - "gaia-public/plugins/gaia/tests/**"
      - "gaia-public/plugins/gaia/schemas/**"
      - "gaia-public/plugins/gaia/templates/**"
YAML
}

# ---------------------------------------------------------------------------
# Test 1 — happy path: a scripts/ file is classified as "gaia-plugin"
# ---------------------------------------------------------------------------
@test "happy path: scripts/ file maps to gaia-plugin" {
  local cfg="$TEST_TMP/project-config.yaml"
  local files_list="$TEST_TMP/changed-files.txt"

  _write_gaia_plugin_config "$cfg"
  printf '%s\n' "plugins/gaia/scripts/step-report.sh" > "$files_list"

  run "$SCRIPT" --config "$cfg" --files-from "$files_list"
  [ "$status" -eq 0 ]
  # Output must be a JSON array containing "gaia-plugin"
  echo "$output" | grep -q '"gaia-plugin"'
}

# ---------------------------------------------------------------------------
# Test 2 — unrelated file: README.md at root produces an empty array
# ---------------------------------------------------------------------------
@test "unrelated file produces empty array" {
  local cfg="$TEST_TMP/project-config.yaml"
  local files_list="$TEST_TMP/changed-files.txt"

  _write_gaia_plugin_config "$cfg"
  printf '%s\n' "README.md" > "$files_list"

  run "$SCRIPT" --config "$cfg" --files-from "$files_list"
  [ "$status" -eq 0 ]
  # Strip trailing whitespace/newline before comparing
  local trimmed
  trimmed="$(printf '%s' "$output" | tr -d '[:space:]')"
  [ "$trimmed" = "[]" ]
}

# ---------------------------------------------------------------------------
# Test 3 — multi-file same stack: three skills/ paths → "gaia-plugin" exactly once
# ---------------------------------------------------------------------------
@test "multi-file same stack: gaia-plugin appears exactly once" {
  local cfg="$TEST_TMP/project-config.yaml"
  local files_list="$TEST_TMP/changed-files.txt"

  _write_gaia_plugin_config "$cfg"
  cat > "$files_list" <<'EOF'
plugins/gaia/skills/gaia-retro/SKILL.md
plugins/gaia/skills/gaia-brain-query/SKILL.md
plugins/gaia/skills/gaia-feed/SKILL.md
EOF

  run "$SCRIPT" --config "$cfg" --files-from "$files_list"
  [ "$status" -eq 0 ]
  # Must contain gaia-plugin exactly once (deduplicated)
  local count
  count=$(echo "$output" | grep -o '"gaia-plugin"' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 4 — config/ unclassified: plugins/gaia/config/ path → []
# Known gap: the glob list does not include gaia-public/plugins/gaia/config/**
# This is a real false-negative, tracked for S2.
# ---------------------------------------------------------------------------
@test "config/ path is unclassified (known gap, glob missing, tracked for S2)" {
  local cfg="$TEST_TMP/project-config.yaml"
  local files_list="$TEST_TMP/changed-files.txt"

  _write_gaia_plugin_config "$cfg"
  printf '%s\n' "plugins/gaia/config/project-config.schema.yaml" > "$files_list"

  run "$SCRIPT" --config "$cfg" --files-from "$files_list"
  [ "$status" -eq 0 ]
  # Expect empty array — config/ is not covered by any stack glob
  local trimmed
  trimmed="$(printf '%s' "$output" | tr -d '[:space:]')"
  [ "$trimmed" = "[]" ]
}

# ---------------------------------------------------------------------------
# Test 5 — prefix normalization: glob WITH "gaia-public/" prefix in YAML,
# path WITHOUT prefix fed on CLI → still detected (the strip logic works)
# ---------------------------------------------------------------------------
@test "prefix normalization: gaia-public/ glob matches path without prefix" {
  local cfg="$TEST_TMP/project-config.yaml"
  local files_list="$TEST_TMP/changed-files.txt"

  # Write a config where the glob explicitly has gaia-public/ (same as real config)
  cat > "$cfg" <<'YAML'
stacks:
  - name: test-stack
    language: bash
    paths:
      - "gaia-public/plugins/gaia/agents/**"
YAML

  # Feed a path WITHOUT the prefix
  printf '%s\n' "plugins/gaia/agents/example-dev.md" > "$files_list"

  run "$SCRIPT" --config "$cfg" --files-from "$files_list"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"test-stack"'
}
