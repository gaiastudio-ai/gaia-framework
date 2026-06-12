#!/usr/bin/env bats
# memory-loader.bats — unit tests for plugins/gaia/scripts/memory-loader.sh
# Public contract covered: positional arg parsing, tier dispatch, sidecar
# resolution via _memory/config.yaml, missing-file empty-contract,
# --max-tokens truncation, --format inline, --help, main.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/memory-loader.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  mkdir -p "$MEMORY_PATH"
}
teardown() { common_teardown; }

@test "memory-loader.sh: --help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *[Uu]sage* ]]
}

@test "memory-loader.sh: missing positional args → non-zero" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "memory-loader.sh: invalid tier → exit 1, stderr mentions tier" {
  run "$SCRIPT" nate bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *[Tt]ier* ]]
}

@test "memory-loader.sh: decision-log tier prints decision-log.md" {
  mkdir -p "$MEMORY_PATH/nate-sidecar"
  printf 'DL-NATE\n' > "$MEMORY_PATH/nate-sidecar/decision-log.md"
  run "$SCRIPT" nate decision-log
  [ "$status" -eq 0 ]
  [ "$output" = "DL-NATE" ]
}

@test "memory-loader.sh: ground-truth tier prints ground-truth.md" {
  mkdir -p "$MEMORY_PATH/val-sidecar"
  printf 'GT-VAL\n' > "$MEMORY_PATH/val-sidecar/ground-truth.md"
  run "$SCRIPT" val ground-truth
  [ "$status" -eq 0 ]
  [ "$output" = "GT-VAL" ]
}

@test "memory-loader.sh: all tier prints both with section headers" {
  mkdir -p "$MEMORY_PATH/val-sidecar"
  printf 'GT\n' > "$MEMORY_PATH/val-sidecar/ground-truth.md"
  printf 'DL\n' > "$MEMORY_PATH/val-sidecar/decision-log.md"
  run "$SCRIPT" val all
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Ground Truth"* ]]
  [[ "$output" == *"## Decision Log"* ]]
  [[ "$output" == *"GT"* ]]
  [[ "$output" == *"DL"* ]]
}

@test "memory-loader.sh: config.yaml sidecar mapping wins over default path" {
  mkdir -p "$MEMORY_PATH/sm-sidecar" "$MEMORY_PATH/nate-sidecar"
  printf 'FROM-SM\n' > "$MEMORY_PATH/sm-sidecar/decision-log.md"
  printf 'FROM-NATE\n' > "$MEMORY_PATH/nate-sidecar/decision-log.md"
  cat > "$MEMORY_PATH/config.yaml" <<'EOF'
agents:
  nate:
    sidecar: "sm-sidecar"
archival:
  token_approximation: 4
EOF
  run "$SCRIPT" nate decision-log
  [ "$status" -eq 0 ]
  [ "$output" = "FROM-SM" ]
}

@test "memory-loader.sh: missing sidecar directory → empty stdout, exit 0" {
  run "$SCRIPT" ghost all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "memory-loader.sh: --max-tokens truncates by token_approximation" {
  mkdir -p "$MEMORY_PATH/nate-sidecar"
  python3 -c "print('x' * 1000, end='')" > "$MEMORY_PATH/nate-sidecar/decision-log.md"
  run "$SCRIPT" nate decision-log --max-tokens 100
  [ "$status" -eq 0 ]
  [ "${#output}" -le 400 ]
}

@test "memory-loader.sh: --format inline wraps output in fenced code block" {
  mkdir -p "$MEMORY_PATH/nate-sidecar"
  printf 'INLINE\n' > "$MEMORY_PATH/nate-sidecar/decision-log.md"
  run "$SCRIPT" nate decision-log --format inline
  [ "$status" -eq 0 ]
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$first_line" = '```' ]
  [[ "$output" == *"INLINE"* ]]
}

@test "memory-loader.sh: idempotent — two reads produce identical output" {
  mkdir -p "$MEMORY_PATH/nate-sidecar"
  printf 'stable\n' > "$MEMORY_PATH/nate-sidecar/decision-log.md"
  local a b
  a="$("$SCRIPT" nate decision-log)"
  b="$("$SCRIPT" nate decision-log)"
  [ "$a" = "$b" ]
}

# TC-GTS-19 — lazy staleness backstop: marker present + ground-truth tier load
# emits the single-line stderr WARNING, never blocks the load, never clears the
# marker, and leaves the ground-truth payload on stdout.
@test "memory-loader.sh: ground-truth tier with .ground-truth-stale present → stderr WARNING, load succeeds, marker not cleared" {
  mkdir -p "$MEMORY_PATH/val-sidecar"
  printf 'GT-VAL\n' > "$MEMORY_PATH/val-sidecar/ground-truth.md"
  : > "$MEMORY_PATH/.ground-truth-stale"
  run --separate-stderr "$SCRIPT" val ground-truth
  [ "$status" -eq 0 ]
  # Payload still on stdout (non-blocking).
  [ "$output" = "GT-VAL" ]
  # Single-line WARNING on stderr.
  [[ "$stderr" == *"WARNING"* ]]
  [[ "$stderr" == *".ground-truth-stale"* ]]
  [ "$(printf '%s' "$stderr" | grep -c 'ground-truth may be stale')" -eq 1 ]
  # Marker NOT cleared (non-mutating).
  [ -f "$MEMORY_PATH/.ground-truth-stale" ]
}

# TC-GTS-20 — marker absent + ground-truth load emits no warning (no noise).
@test "memory-loader.sh: ground-truth tier with no .ground-truth-stale → no warning" {
  mkdir -p "$MEMORY_PATH/val-sidecar"
  printf 'GT-VAL\n' > "$MEMORY_PATH/val-sidecar/ground-truth.md"
  run --separate-stderr "$SCRIPT" val ground-truth
  [ "$status" -eq 0 ]
  [ "$output" = "GT-VAL" ]
  [[ "$stderr" != *"ground-truth may be stale"* ]]
}

# Guard — all tier surfaces ground-truth too, so the marker warning fires there.
@test "memory-loader.sh: all tier with .ground-truth-stale present → stderr WARNING" {
  mkdir -p "$MEMORY_PATH/val-sidecar"
  printf 'GT\n' > "$MEMORY_PATH/val-sidecar/ground-truth.md"
  printf 'DL\n' > "$MEMORY_PATH/val-sidecar/decision-log.md"
  : > "$MEMORY_PATH/.ground-truth-stale"
  run --separate-stderr "$SCRIPT" val all
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Ground Truth"* ]]
  [[ "$stderr" == *"ground-truth may be stale"* ]]
}

# Guard — decision-log tier does NOT load ground-truth, so the warning is
# ground-truth-tier-scoped and stays silent even when the marker is present.
@test "memory-loader.sh: decision-log tier with .ground-truth-stale present → no warning" {
  mkdir -p "$MEMORY_PATH/nate-sidecar"
  printf 'DL-NATE\n' > "$MEMORY_PATH/nate-sidecar/decision-log.md"
  : > "$MEMORY_PATH/.ground-truth-stale"
  run --separate-stderr "$SCRIPT" nate decision-log
  [ "$status" -eq 0 ]
  [ "$output" = "DL-NATE" ]
  [[ "$stderr" != *"ground-truth may be stale"* ]]
}
