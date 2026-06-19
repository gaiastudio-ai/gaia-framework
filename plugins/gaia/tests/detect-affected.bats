#!/usr/bin/env bats
# detect-affected.bats — TDD tests for detect-affected.sh
#
# Public functions covered (per the public-function coverage gate): parse_args, parse_stacks,
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
  - name: stack-plugin
    language: bash
    paths:
      - "gaia-public/plugins/gaia/scripts/**"
      - "gaia-public/plugins/gaia/skills/**"
      - "gaia-public/plugins/gaia/agents/**"
      - "gaia-public/plugins/gaia/knowledge/**"
      - "gaia-public/plugins/gaia/tests/**"
      - "gaia-public/plugins/gaia/schemas/**"
      - "gaia-public/plugins/gaia/templates/**"
      - "gaia-public/plugins/gaia/config/**"
      - "gaia-public/plugins/gaia/hooks/**"
      - "gaia-public/plugins/gaia/rubrics/**"
      - "gaia-public/plugins/gaia/tools/**"
      - "gaia-public/plugins/gaia/docs/**"
      - "gaia-public/plugins/gaia/test/**"
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Public-function coverage gate: source the script and verify every public function resolves
# ---------------------------------------------------------------------------

@test "source script — parse_args is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type parse_args
}

@test "source script — parse_stacks is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type parse_stacks
}

@test "source script — normalize_glob is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type normalize_glob
}

@test "source script — find_best_prefix_match is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type find_best_prefix_match
}

@test "source script — find_glob_match is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type find_glob_match
}

@test "source script — match_path is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type match_path
}

@test "source script — build_json_array is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type build_json_array
}

@test "source script — main is callable" {
  source "$SCRIPTS_DIR/detect-affected.sh"
  type main
}

@test "main-guard — sourcing does NOT invoke main" {
  # If main runs on source, it will fail (no --config arg) and the test
  # would catch the exit 1. A clean source means the guard works.
  source "$SCRIPTS_DIR/detect-affected.sh"
  # If we reach here, main did not run on source.
  true
}

# ---------------------------------------------------------------------------
# AC1: prefix match → valid JSON array
# ---------------------------------------------------------------------------

@test "path under agents/ prefix returns stack-alpha as JSON" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "agents/my-agent.md"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

@test "path under packages/shared/ returns stack-alpha (prefix match)" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "packages/shared/utils.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

@test "dedup — same stack matched by two files emits one entry" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "agents/agent1.md" "agents/agent2.md"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

# ---------------------------------------------------------------------------
# AC2: glob fallback for non-/** globs (config/*.yaml)
# ---------------------------------------------------------------------------

@test "glob fallback — config/settings.yaml matches stack-beta via glob" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "config/settings.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-beta"]' ]]
}

@test "glob fallback does NOT fire for deep nested path under config/" {
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

@test "longest-prefix wins — packages/shared/util.sh → stack-alpha not stack-beta" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "packages/shared/util.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

@test "shallower path under packages/ (not shared/) → stack-beta" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "packages/other/module.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-beta"]' ]]
}

@test "reorder-invariant — same result with stacks in reversed declaration order" {
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

@test "promotion-push with files → outputs [\"*\"]" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --event promotion-push \
    --files "agents/my-agent.md"
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

@test "promotion-push with no files → still outputs [\"*\"]" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --event promotion-push
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

# ---------------------------------------------------------------------------
# AC5: valid JSON array / empty → [] / unmatched → []
# ---------------------------------------------------------------------------

@test "unmatched path →" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "some/unknown/path.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == '[]' ]]
}

@test "empty files list (files-from of empty file) →" {
  printf '' > "$TEST_TMP/empty-list.txt"
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files-from "$TEST_TMP/empty-list.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == '[]' ]]
}

@test "output is parseable JSON array (jq check)" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "agents/agent.md"
  [ "$status" -eq 0 ]
  # Validate that output is a JSON array
  printf '%s\n' "$output" | jq -e '. | type == "array"'
}

@test "missing --config flag → exit 1 with error on stderr" {
  run "$SCRIPTS_DIR/detect-affected.sh" --files "agents/agent.md"
  [ "$status" -eq 1 ]
}

@test "config pointing to non-existent file → exit 1" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/does-not-exist.yaml" \
    --files "agents/agent.md"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC6: latency — 50 paths resolved within 5 seconds
# ---------------------------------------------------------------------------

@test "50 paths resolved within 5 seconds" {
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
# Subtree-to-stack coverage — every load-bearing plugin subtree resolves
# ---------------------------------------------------------------------------

@test "hooks subtree resolves to the owning plugin stack" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/hooks/post-commit.json"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "rubrics subtree resolves to the owning plugin stack" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/rubrics/base/code-review.json"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "tools subtree resolves to the owning plugin stack" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/tools/gaia-tools/entrypoint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "docs subtree resolves to the owning plugin stack" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/docs/CI-NOTES.md"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "test subtree resolves to the owning plugin stack" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/test/scripts/some-test.bats"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "hooks path and scripts path deduplicate to single stack entry" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/hooks/post-commit.json" "plugins/gaia/scripts/detect-affected.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "existing scripts-only path still resolves after glob additions" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/scripts/detect-affected.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "excluded _memory path returns empty affected-set" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/_memory/sidecar.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == '[]' ]]
}

@test "excluded spikes path returns empty affected-set" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/spikes/some-spike/readme.md"
  [ "$status" -eq 0 ]
  [[ "$output" == '[]' ]]
}

# ---------------------------------------------------------------------------
# config-path-to-stack coverage — plugin config tree must resolve to a stack
# ---------------------------------------------------------------------------

@test "config-only path resolves to the owning plugin stack" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "config path and scripts path in one run produce deduplicated single-entry affected-set" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --files "plugins/gaia/config/project-config.yaml" "plugins/gaia/scripts/detect-affected.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-plugin"]' ]]
}

@test "verbose stderr includes the config glob match decision" {
  run "$SCRIPTS_DIR/detect-affected.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --verbose \
    --files "plugins/gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  # --verbose writes per-path decisions to stderr; bats captures both in $output
  # when using run. The config/** glob is prefix-type, so expect [PREFIX-MATCH].
  [[ "$output" == *"[PREFIX-MATCH]"* ]]
  [[ "$output" == *"plugins/gaia/config/project-config.yaml"* ]]
  [[ "$output" == *"stack-plugin"* ]]
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
