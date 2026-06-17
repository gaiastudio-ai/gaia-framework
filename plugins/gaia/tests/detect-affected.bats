#!/usr/bin/env bats
# detect-affected.bats — TDD tests for detect-affected.sh (E113-S2)
#
# Public functions covered (NFR-052): parse_args, parse_stacks,
# normalize_glob, find_best_prefix_match, find_glob_match, match_path,
# build_json_array, main.

load 'test_helper.bash'

setup() {
  common_setup

  # Synthetic two-stack config: stack-alpha owns agents/ (deeper when combined)
  # and stack-beta owns a shallower prefix packages/.
  # stack-gamma owns a non-/** glob: config/*.yaml
  cat > "$TEST_TMP/project-config.yaml" <<'EOF'
stacks:
  - name: stack-alpha
    language: bash
    paths:
      - "gaia-public/agents/**"
      - "gaia-public/packages/shared/**"
  - name: stack-beta
    language: bash
    paths:
      - "gaia-public/packages/**"
      - "gaia-public/config/*.yaml"
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# NFR-052: source the script and verify every public function resolves
# ---------------------------------------------------------------------------

@test "NFR-052: source script — parse_args is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type parse_args
}

@test "NFR-052: source script — parse_stacks is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type parse_stacks
}

@test "NFR-052: source script — normalize_glob is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type normalize_glob
}

@test "NFR-052: source script — find_best_prefix_match is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type find_best_prefix_match
}

@test "NFR-052: source script — find_glob_match is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type find_glob_match
}

@test "NFR-052: source script — match_path is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type match_path
}

@test "NFR-052: source script — build_json_array is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type build_json_array
}

@test "NFR-052: source script — main is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type main
}

@test "NFR-052: main-guard — sourcing does NOT invoke main" {
  # If main runs on source, it will fail (no --config arg) and the test
  # would catch the exit 1. A clean source means the guard works.
  source "$SCRIPTS_DIR/detect-affected.sh"
  # If we reach here, main did not run on source.
  true
}

# ---------------------------------------------------------------------------
# AC1: prefix match → valid JSON array
# ---------------------------------------------------------------------------

@test "AC1: path under agents/ prefix returns stack-alpha as JSON" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "agents/my-agent.md"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

@test "AC1: path under packages/shared/ returns stack-alpha (prefix match)" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "packages/shared/utils.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

@test "AC1: dedup — same stack matched by two files emits one entry" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "agents/agent1.md" "agents/agent2.md"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

# ---------------------------------------------------------------------------
# AC2: glob fallback for non-/** globs (config/*.yaml)
# ---------------------------------------------------------------------------

@test "AC2: glob fallback — config/settings.yaml matches stack-beta via glob" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "config/settings.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-beta"]' ]]
}

@test "AC2: glob fallback does NOT fire for deep nested path under config/" {
  # config/subdir/deep.yaml is NOT matched by config/*.yaml (single-level glob)
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "config/subdir/deep.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == '[]' ]]
}

# ---------------------------------------------------------------------------
# AC3: longest-prefix wins (two-stack synthetic setup)
# packages/shared/ is deeper than packages/ — stack-alpha should win
# ---------------------------------------------------------------------------

@test "AC3: longest-prefix wins — packages/shared/util.sh → stack-alpha not stack-beta" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "packages/shared/util.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

@test "AC3: shallower path under packages/ (not shared/) → stack-beta" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "packages/other/module.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-beta"]' ]]
}

@test "AC3: reorder-invariant — same result with stacks in reversed declaration order" {
  # Build a config with reversed declaration order
  cat > "$TEST_TMP/reversed-config.yaml" <<'EOF'
stacks:
  - name: stack-beta
    language: bash
    paths:
      - "gaia-public/packages/**"
      - "gaia-public/config/*.yaml"
  - name: stack-alpha
    language: bash
    paths:
      - "gaia-public/agents/**"
      - "gaia-public/packages/shared/**"
EOF
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/reversed-config.yaml" \
    --files "packages/shared/util.sh"
  [ "$status" -eq 0 ]
  # Longest prefix ALWAYS wins, regardless of declaration order
  [[ "$output" == '["stack-alpha"]' ]]
}

# ---------------------------------------------------------------------------
# AC4: promotion-push event → ["*"] wildcard
# ---------------------------------------------------------------------------

@test "AC4: promotion-push with files → outputs [\"*\"]" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --event promotion-push \
    --files "agents/my-agent.md"
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

@test "AC4: promotion-push with no files → still outputs [\"*\"]" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --event promotion-push
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

# ---------------------------------------------------------------------------
# AC5: valid JSON array / empty → [] / unmatched → []
# ---------------------------------------------------------------------------

@test "AC5: unmatched path → []" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "some/unknown/path.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == '[]' ]]
}

@test "AC5: empty files list (files-from of empty file) → []" {
  printf '' > "$TEST_TMP/empty-list.txt"
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files-from "$TEST_TMP/empty-list.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == '[]' ]]
}

@test "AC5: output is parseable JSON array (jq check)" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "agents/agent.md"
  [ "$status" -eq 0 ]
  # Validate that output is a JSON array
  printf '%s\n' "$output" | jq -e '. | type == "array"'
}

@test "AC5: missing --config flag → exit 1 with error on stderr" {
  run "$SCRIPTS_DIR/detect-affected.sh" --files "agents/agent.md"
  [ "$status" -eq 1 ]
}

@test "AC5: --config pointing to non-existent file → exit 1" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/does-not-exist.yaml" \
    --files "agents/agent.md"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC6: latency — 50 paths resolved within 5 seconds
# ---------------------------------------------------------------------------

@test "AC6: 50 paths resolved within 5 seconds" {
  # Build a list of 50 synthetic paths
  local list_file="$TEST_TMP/fifty-paths.txt"
  local i
  for i in $(seq 1 50); do
    printf 'agents/path-%d/file.sh\n' "$i"
  done > "$list_file"

  local start end elapsed
  start=$(date +%s)
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files-from "$list_file"
  end=$(date +%s)
  elapsed=$(( end - start ))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 5 ]
}

# ---------------------------------------------------------------------------
# Real-config sanity: agents/ path → gaia-plugin (uses real project-config)
# ---------------------------------------------------------------------------

@test "real-config sanity: scripts/ path → gaia-plugin stack" {
  local real_config="${GAIA_PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}/.gaia/config/project-config.yaml"
  [ -n "${GAIA_PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}" ] && [ -f "$real_config" ] || skip "real project-config not available"
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$real_config" \
    --files "plugins/gaia/scripts/detect-affected.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["gaia-plugin"]' ]]
}
