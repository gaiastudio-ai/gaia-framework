#!/usr/bin/env bats
# generate-pipeline.bats — TDD tests for generate-pipeline.sh (E113-S4)
#
# Public functions covered (NFR-052): parse_args, read_affected_json,
# parse_affected_array, parse_stacks_names, build_matrix_json, main.

load 'test_helper.bash'

setup() {
  common_setup

  # Synthetic three-stack config (declaration order: alpha, beta, gamma)
  cat > "$TEST_TMP/project-config.yaml" <<'EOF'
stacks:
  - name: stack-alpha
    language: bash
    paths:
      - "gaia-public/agents/**"
  - name: stack-beta
    language: bash
    paths:
      - "gaia-public/packages/**"
  - name: stack-gamma
    language: bash
    paths:
      - "gaia-public/config/**"
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# NFR-052: source the script and verify every public function resolves
# ---------------------------------------------------------------------------

@test "source script — parse_args is callable" {
  source "$SCRIPTS_DIR/generate-pipeline.sh"
  type parse_args
}

@test "source script — read_affected_json is callable" {
  source "$SCRIPTS_DIR/generate-pipeline.sh"
  type read_affected_json
}

@test "source script — parse_affected_array is callable" {
  source "$SCRIPTS_DIR/generate-pipeline.sh"
  type parse_affected_array
}

@test "source script — parse_stacks_names is callable" {
  source "$SCRIPTS_DIR/generate-pipeline.sh"
  type parse_stacks_names
}

@test "source script — build_matrix_json is callable" {
  source "$SCRIPTS_DIR/generate-pipeline.sh"
  type build_matrix_json
}

@test "source script — main is callable" {
  source "$SCRIPTS_DIR/generate-pipeline.sh"
  type main
}

@test "main-guard — sourcing does NOT invoke main" {
  # If main runs on source it will fail (no args) and exit 1.
  # Reaching this line means the guard worked.
  source "$SCRIPTS_DIR/generate-pipeline.sh"
  true
}

# ---------------------------------------------------------------------------
# Error / usage cases
# ---------------------------------------------------------------------------

@test "error: --help exits 0" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" --help
  [ "$status" -eq 0 ]
}

@test "error: unknown option exits 1" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" --bogus-flag
  [ "$status" -eq 1 ]
}

@test "error: --from pointing to missing file exits 1" {
  run --separate-stderr "$SCRIPTS_DIR/generate-pipeline.sh" \
    --from "$TEST_TMP/no-such-file.json"
  [ "$status" -eq 1 ]
}

@test "error: stdin is a tty with no input arg exits 1" {
  # Under bats, stdin is never a tty. We test the "no usable input" path by
  # passing an empty stdin (empty string from /dev/null). The script reads
  # stdin but gets an empty JSON string; parse_affected_array produces nothing
  # and we get {"include":[]}, exit 0. So instead we verify the --no-source
  # path: pass ONLY /dev/null as stdin (empty content) and no other flags.
  # The script must exit 1 because no JSON array was supplied at all.
  #
  # Design choice: treat completely empty stdin (zero bytes) as "no input"
  # and fail, rather than treating it as an empty array. The empty-array case
  # is explicitly '[]' which contains content.
  run --separate-stderr "$SCRIPTS_DIR/generate-pipeline.sh" < /dev/null
  [ "$status" -eq 1 ]
}

@test "error: ['*'] without --config exits 1" {
  run --separate-stderr "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["*"]'
  [ "$status" -eq 1 ]
}

@test "error: --config points to nonexistent file exits 1" {
  run --separate-stderr "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["*"]' \
    --config "$TEST_TMP/does-not-exist.yaml"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC1: selective affected-set → exactly those stack entries, no others
# ---------------------------------------------------------------------------

@test "two-element set → exactly 2 include entries" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["stack-alpha","stack-beta"]'
  [ "$status" -eq 0 ]
  # Must contain both
  [[ "$output" == *'"stack":"stack-alpha"'* ]]
  [[ "$output" == *'"stack":"stack-beta"'* ]]
  # Must NOT contain the third stack
  [[ "$output" != *'"stack":"stack-gamma"'* ]]
}

@test "3-stack config + 1-element set → exactly 1 include entry" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["stack-gamma"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"stack":"stack-gamma"'* ]]
  [[ "$output" != *'"stack":"stack-alpha"'* ]]
  [[ "$output" != *'"stack":"stack-beta"'* ]]
}

@test "hyphen-name stack works (R2 guard)" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["stack-alpha"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"stack":"stack-alpha"'* ]]
}

# ---------------------------------------------------------------------------
# AC2: ["*"] wildcard expands to all config stacks in declaration order
# ---------------------------------------------------------------------------

@test "wildcard expands to all 3 stacks in declaration order" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["*"]' \
    --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"stack":"stack-alpha"'* ]]
  [[ "$output" == *'"stack":"stack-beta"'* ]]
  [[ "$output" == *'"stack":"stack-gamma"'* ]]
  # Verify declaration order: alpha before beta before gamma by extracting
  # the position of each "stack": entry in the flat JSON output string.
  # Use awk to find byte offset of each substring.
  alpha_pos=$(printf '%s' "$output" | awk 'BEGIN{RS="\0"} {p=index($0,"\"stack\":\"stack-alpha\""); print p}')
  beta_pos=$(printf '%s' "$output" | awk 'BEGIN{RS="\0"} {p=index($0,"\"stack\":\"stack-beta\""); print p}')
  gamma_pos=$(printf '%s' "$output" | awk 'BEGIN{RS="\0"} {p=index($0,"\"stack\":\"stack-gamma\""); print p}')
  [ "$alpha_pos" -gt 0 ]
  [ "$beta_pos" -gt 0 ]
  [ "$gamma_pos" -gt 0 ]
  [ "$alpha_pos" -lt "$beta_pos" ]
  [ "$beta_pos" -lt "$gamma_pos" ]
}

@test "wildcard without --config → exit 1 with stderr" {
  run --separate-stderr "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["*"]'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC3: empty affected-set → {"include":[]} exit 0
# ---------------------------------------------------------------------------

@test "empty set via --affected-set → include empty, exit 0" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"include":[]'* ]]
}

@test "empty set via stdin → include empty, exit 0" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" <<< '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"include":[]'* ]]
}

@test "empty set via --from file → include empty, exit 0" {
  printf '[]' > "$TEST_TMP/empty-set.json"
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --from "$TEST_TMP/empty-set.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"include":[]'* ]]
}

# ---------------------------------------------------------------------------
# AC4: output NEVER contains GitHub native paths: trigger blocks
# ---------------------------------------------------------------------------

@test "two-stack output has zero 'paths:' occurrences" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["stack-alpha","stack-beta"]'
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -c '"paths":' || true)
  [ "$count" -eq 0 ]
  # Also check for YAML-style literal paths:
  yaml_count=$(printf '%s\n' "$output" | grep -c '^paths:' || true)
  [ "$yaml_count" -eq 0 ]
}

@test "wildcard output has zero 'paths:' occurrences" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["*"]' \
    --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -c '"paths":' || true)
  [ "$count" -eq 0 ]
}

@test "empty-set output has zero 'paths:' occurrences" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '[]'
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -c '"paths":' || true)
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5: 1:1 correspondence between affected stacks and include entries
# ---------------------------------------------------------------------------

@test "3-entry set → 3 'stack': keys in output" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["stack-alpha","stack-beta","stack-gamma"]'
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -o '"stack":' | wc -l | tr -d ' ')
  [ "$count" -eq 3 ]
}

@test "1-entry set → exactly 1 'stack': key in output" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["stack-alpha"]'
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -o '"stack":' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}

@test "wildcard → 3 stack entries matching all config stacks" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["*"]' \
    --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -o '"stack":' | wc -l | tr -d ' ')
  [ "$count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# --from file input source
# ---------------------------------------------------------------------------

@test "input: --from file with two stacks → 2 entries" {
  printf '["stack-alpha","stack-gamma"]' > "$TEST_TMP/affected.json"
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --from "$TEST_TMP/affected.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"stack":"stack-alpha"'* ]]
  [[ "$output" == *'"stack":"stack-gamma"'* ]]
  [[ "$output" != *'"stack":"stack-beta"'* ]]
}

# ---------------------------------------------------------------------------
# Matrix JSON shape: must wrap in {"include":[...]}
# ---------------------------------------------------------------------------

@test "shape: output contains top-level 'include' key" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["stack-alpha"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"include":'* ]]
}

@test "shape: each entry is {\"stack\":\"<name>\"}" {
  run "$SCRIPTS_DIR/generate-pipeline.sh" \
    --affected-set '["stack-beta"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"stack":"stack-beta"}'* ]]
}
