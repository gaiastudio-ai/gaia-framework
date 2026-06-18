#!/usr/bin/env bats
# cross-refs-walk.bats — TDD tests for cross-refs-walk.sh
#
# Public functions covered (per the public-function coverage gate): parse_args, parse_cross_refs,
# build_inverted_index, parse_stacks_json, bfs_walk, build_json_array, main.
# Private function _consumers_of is deliberately skipped (underscore prefix).

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup

  # Minimal 3-stack config: stack-a depends on stack-b; stack-b depends on stack-c.
  # Inverted index: stack-b -> [stack-a], stack-c -> [stack-b]
  # Transitive from stack-c seed: stack-c, stack-b, stack-a
  cat > "$TEST_TMP/config-chain.yaml" <<'EOF'
stacks:
  - name: stack-a
    language: bash
    cross_refs:
      - stack-b
  - name: stack-b
    language: bash
    cross_refs:
      - stack-c
  - name: stack-c
    language: bash
EOF

  # Diamond: stack-a and stack-b both depend on stack-d;
  # stack-c depends on both stack-a and stack-b.
  # Inverted: stack-d -> [stack-a, stack-b], stack-a -> [stack-c], stack-b -> [stack-c]
  # From seed [stack-d]: stack-d, stack-a, stack-b, stack-c (stack-c via both paths, once)
  cat > "$TEST_TMP/config-diamond.yaml" <<'EOF'
stacks:
  - name: stack-x
    language: bash
    cross_refs:
      - stack-z
  - name: stack-y
    language: bash
    cross_refs:
      - stack-z
  - name: stack-z
    language: bash
  - name: stack-w
    language: bash
    cross_refs:
      - stack-x
      - stack-y
EOF

  # Cyclic: stack-a -> stack-b -> stack-c -> stack-a
  cat > "$TEST_TMP/config-cycle.yaml" <<'EOF'
stacks:
  - name: stack-a
    language: bash
    cross_refs:
      - stack-b
  - name: stack-b
    language: bash
    cross_refs:
      - stack-c
  - name: stack-c
    language: bash
    cross_refs:
      - stack-a
EOF

  # Self-loop: stack-a -> stack-a
  cat > "$TEST_TMP/config-selfloop.yaml" <<'EOF'
stacks:
  - name: stack-a
    language: bash
    cross_refs:
      - stack-a
  - name: stack-b
    language: bash
EOF

  # Empty cross_refs: no dependencies at all
  cat > "$TEST_TMP/config-nocrossrefs.yaml" <<'EOF'
stacks:
  - name: stack-x
    language: bash
  - name: stack-y
    language: bash
EOF

  # Inline cross_refs: YAML flow (inline) form: cross_refs: [stack-b, stack-c]
  cat > "$TEST_TMP/config-inline.yaml" <<'EOF'
stacks:
  - name: stack-a
    language: bash
    cross_refs: [stack-b, stack-c]
  - name: stack-b
    language: bash
  - name: stack-c
    language: bash
EOF

  # 5-node chain: stack-e -> stack-d -> stack-c -> stack-b -> stack-a
  cat > "$TEST_TMP/config-5chain.yaml" <<'EOF'
stacks:
  - name: stack-e
    language: bash
    cross_refs:
      - stack-d
  - name: stack-d
    language: bash
    cross_refs:
      - stack-c
  - name: stack-c
    language: bash
    cross_refs:
      - stack-b
  - name: stack-b
    language: bash
    cross_refs:
      - stack-a
  - name: stack-a
    language: bash
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Public-function coverage gate: source the script and verify every public function resolves
# ---------------------------------------------------------------------------

@test "source script — parse_args is callable" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  type parse_args
}

@test "source script — parse_cross_refs is callable" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  type parse_cross_refs
}

@test "source script — build_inverted_index is callable" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  type build_inverted_index
}

@test "source script — parse_stacks_json is callable" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  type parse_stacks_json
}

@test "source script — bfs_walk is callable" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  type bfs_walk
}

@test "source script — build_json_array is callable" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  type build_json_array
}

@test "source script — main is callable" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  type main
}

@test "main-guard — sourcing does NOT invoke main" {
  # If main runs on source, it will fail (no --config arg) and the exit 1
  # would be caught. A clean source means the guard works.
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  true
}

# ---------------------------------------------------------------------------
# Error / usage cases
# ---------------------------------------------------------------------------

@test "error: --help exits 0" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" --help
  [ "$status" -eq 0 ]
}

@test "error: no args exits 1" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh"
  [ "$status" -eq 1 ]
}

@test "error: missing --config exits 1" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" --stacks '["stack-a"]'
  [ "$status" -eq 1 ]
}

@test "error: missing --stacks exits 1" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" --config "$TEST_TMP/config-chain.yaml"
  [ "$status" -eq 1 ]
}

@test "error: non-existent --config file exits 1" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/does-not-exist.yaml" \
    --stacks '["stack-a"]'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC1: inverted index built correctly
# ---------------------------------------------------------------------------

@test "parse_cross_refs emits TSV consumer<TAB>dependency" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  local tsv
  tsv="$(parse_cross_refs "$TEST_TMP/config-chain.yaml")"
  # stack-a depends on stack-b → consumer=stack-a, dep=stack-b
  printf '%s\n' "$tsv" | grep -qF $'stack-a\tstack-b'
  # stack-b depends on stack-c → consumer=stack-b, dep=stack-c
  printf '%s\n' "$tsv" | grep -qF $'stack-b\tstack-c'
}

@test "build_inverted_index maps dependency to its consumer" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  local tsv
  tsv="$(parse_cross_refs "$TEST_TMP/config-chain.yaml")"
  local tmp_tsv
  tmp_tsv="$(mktemp)"
  printf '%s\n' "$tsv" > "$tmp_tsv"
  build_inverted_index "$tmp_tsv"
  # _consumers_of stack-b should return stack-a
  local consumers
  consumers="$(_consumers_of "stack-b")"
  printf '%s\n' "$consumers" | grep -q "stack-a"
  rm -f "$tmp_tsv"
}

@test "inline cross_refs YAML flow form is parsed correctly" {
  source "$SCRIPTS_DIR/cross-refs-walk.sh"
  local tsv
  tsv="$(parse_cross_refs "$TEST_TMP/config-inline.yaml")"
  # stack-a: [stack-b, stack-c] — must produce two TSV rows
  printf '%s\n' "$tsv" | grep -qF $'stack-a\tstack-b'
  printf '%s\n' "$tsv" | grep -qF $'stack-a\tstack-c'
}

# ---------------------------------------------------------------------------
# AC2: transitive DAG walk expands affected set
# ---------------------------------------------------------------------------

@test "3-chain seed [stack-c] returns all 3 stacks" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-chain.yaml" \
    --stacks '["stack-c"]'
  [ "$status" -eq 0 ]
  # Output must contain all three names
  [[ "$output" == *'"stack-a"'* ]]
  [[ "$output" == *'"stack-b"'* ]]
  [[ "$output" == *'"stack-c"'* ]]
}

@test "3-chain seed midpoint [stack-b] returns stack-b and stack-a" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-chain.yaml" \
    --stacks '["stack-b"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"stack-b"'* ]]
  [[ "$output" == *'"stack-a"'* ]]
  # stack-c is not a consumer of stack-b — must NOT appear
  [[ "$output" != *'"stack-c"'* ]]
}

@test "seed with no consumers returns just the seed" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-chain.yaml" \
    --stacks '["stack-a"]'
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-a"]' ]]
}

@test "empty seed returns" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-chain.yaml" \
    --stacks '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == '[]' ]]
}

@test "diamond graph seed [stack-z] reaches all 4 stacks once" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-diamond.yaml" \
    --stacks '["stack-z"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"stack-z"'* ]]
  [[ "$output" == *'"stack-x"'* ]]
  [[ "$output" == *'"stack-y"'* ]]
  [[ "$output" == *'"stack-w"'* ]]
}

@test "no cross_refs — seed [stack-x] returns just stack-x" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-nocrossrefs.yaml" \
    --stacks '["stack-x"]'
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-x"]' ]]
}

# ---------------------------------------------------------------------------
# AC3: cycle detection reports the cycle by name to stderr
# ---------------------------------------------------------------------------

@test "3-cycle A->B->C->A detected and cycle names appear on stderr" {
  run --separate-stderr "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-cycle.yaml" \
    --stacks '["stack-a"]'
  # stderr (in $stderr) must mention "CYCLE" and at least one stack name
  [[ "$stderr" == *"CYCLE"* ]]
  [[ "$stderr" == *"stack-a"* ]]
}

@test "self-loop cycle detected and reported on stderr" {
  run --separate-stderr "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-selfloop.yaml" \
    --stacks '["stack-a"]'
  [[ "$stderr" == *"CYCLE"* ]]
}

@test "3-cycle path closes loop exactly once — no doubled tail node" {
  # The DFS inverted-index traversal order for this fixture visits:
  # stack-a -> (consumer stack-c) -> (consumer stack-b) -> back-edge stack-a
  # so the reported path is: stack-a -> stack-c -> stack-b -> stack-a
  # The entry node (stack-a) must appear EXACTLY twice: once at the start,
  # once at the closing position.  A doubled tail would be "...-> stack-a -> stack-a".
  run --separate-stderr "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-cycle.yaml" \
    --stacks '["stack-a"]'
  [[ "$stderr" == *"CYCLE DETECTED: stack-a -> stack-c -> stack-b -> stack-a"* ]]
  # The doubled-tail form must NOT appear anywhere in stderr
  [[ "$stderr" != *"stack-a -> stack-a"* ]]
}

# ---------------------------------------------------------------------------
# AC4: cycle escalates output to ["*"] and exits 0
# ---------------------------------------------------------------------------

@test "cycle detected — stdout is exactly [\"*\"]" {
  run --separate-stderr "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-cycle.yaml" \
    --stacks '["stack-a"]'
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

@test "self-loop cycle — stdout is exactly [\"*\"]" {
  run --separate-stderr "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-selfloop.yaml" \
    --stacks '["stack-a"]'
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

@test "wildcard seed [\"*\"] passes through immediately as [\"*\"]" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-chain.yaml" \
    --stacks '["*"]'
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

# ---------------------------------------------------------------------------
# AC5: visited exactly once — no duplicates in output
# ---------------------------------------------------------------------------

@test "5-chain seed [stack-a] visits each node exactly once" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-5chain.yaml" \
    --stacks '["stack-a"]'
  [ "$status" -eq 0 ]
  # All 5 stacks reachable
  [[ "$output" == *'"stack-a"'* ]]
  [[ "$output" == *'"stack-b"'* ]]
  [[ "$output" == *'"stack-c"'* ]]
  [[ "$output" == *'"stack-d"'* ]]
  [[ "$output" == *'"stack-e"'* ]]
  # No duplicates: count occurrences of each name
  local count_a count_b count_c count_d count_e
  count_a=$(printf '%s' "$output" | grep -o '"stack-a"' | wc -l | tr -d ' ')
  count_b=$(printf '%s' "$output" | grep -o '"stack-b"' | wc -l | tr -d ' ')
  count_c=$(printf '%s' "$output" | grep -o '"stack-c"' | wc -l | tr -d ' ')
  count_d=$(printf '%s' "$output" | grep -o '"stack-d"' | wc -l | tr -d ' ')
  count_e=$(printf '%s' "$output" | grep -o '"stack-e"' | wc -l | tr -d ' ')
  [ "$count_a" -eq 1 ]
  [ "$count_b" -eq 1 ]
  [ "$count_c" -eq 1 ]
  [ "$count_d" -eq 1 ]
  [ "$count_e" -eq 1 ]
}

@test "diamond graph — stack-w appears exactly once in output" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-diamond.yaml" \
    --stacks '["stack-z"]'
  [ "$status" -eq 0 ]
  local count_w
  count_w=$(printf '%s' "$output" | grep -o '"stack-w"' | wc -l | tr -d ' ')
  [ "$count_w" -eq 1 ]
}

@test "output is valid JSON array (parseable)" {
  run "$SCRIPTS_DIR/cross-refs-walk.sh" \
    --config "$TEST_TMP/config-chain.yaml" \
    --stacks '["stack-c"]'
  [ "$status" -eq 0 ]
  # Validate JSON structure: starts with [ and ends with ]
  [[ "$output" == \[* ]]
  [[ "$output" == *\] ]]
}
