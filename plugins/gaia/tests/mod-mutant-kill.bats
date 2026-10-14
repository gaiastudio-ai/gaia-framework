#!/usr/bin/env bats
# mod-mutant-kill.bats -- Automated mutant-kill tests.
# Each mutation is surgical (marker-targeted), the mutated file must still
# parse as ESM (node --input-type=module), the plugin test must FAIL with
# an assertion failure (not a module-load error), and the original passes.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  HOOKS_DIR="$REPO_ROOT/plugins/gaia/hooks"
  INDEX_JS="$HOOKS_DIR/index.js"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
}

# Helper: verify file parses as ESM (not just CJS).
# Copies to .mjs so node treats it as ESM regardless of package.json.
assert_esm_parse() {
  local f="$1"
  local tmpfile="${f}.check.mjs"
  cp "$f" "$tmpfile"
  run node --check "$tmpfile"
  rm -f "$tmpfile"
  [ "$status" -eq 0 ]
}

# Helper: assert output does NOT contain a module-load error.
assert_no_load_error() {
  local out="$1"
  if [[ "$out" == *SyntaxError* ]] || [[ "$out" == *"Cannot find module"* ]] || [[ "$out" == *"Failed to load"* ]]; then
    echo "FAIL: mutant failed due to module load error, not an assertion"
    return 1
  fi
}

# Helper: prepare a mutant dir with the plugin manifest and hooks files.
prepare_mutant() {
  local dir="$1"
  mkdir -p "$dir/.claude-plugin" "$dir/hooks"
  cp "$PLUGIN_DIR/.claude-plugin/plugin.json" "$dir/.claude-plugin/"
  cp "$HOOKS_DIR"/* "$dir/hooks/"
}

@test "capability-detection try-catch guards present in source" {
  [ -f "$INDEX_JS" ] || false

  grep -q 'MARKER:CAP_DETECT_CMD' "$INDEX_JS"
  grep -q 'MARKER:CAP_DETECT_CMD_END' "$INDEX_JS"
  grep -q 'MARKER:CAP_DETECT_CLK' "$INDEX_JS"
  grep -q 'MARKER:CAP_DETECT_CLK_END' "$INDEX_JS"
  grep -q 'MARKER:PROCESS_PROBE' "$INDEX_JS"
  grep -q 'MARKER:PROCESS_PROBE_END' "$INDEX_JS"
}

@test "removing command.register try-catch turns partial-caps test red" {
  command -v claude || false
  [ -f "$INDEX_JS" ] || false

  MUTANT_DIR="${BATS_TMPDIR}/mutant-m1a-$$"
  prepare_mutant "$MUTANT_DIR"

  sed '/MARKER:CAP_DETECT_CMD$/d' "$MUTANT_DIR/hooks/index.js" > "$MUTANT_DIR/hooks/_t.js"
  mv "$MUTANT_DIR/hooks/_t.js" "$MUTANT_DIR/hooks/index.js"
  sed '/MARKER:CAP_DETECT_CMD_END$/d' "$MUTANT_DIR/hooks/index.js" > "$MUTANT_DIR/hooks/_t.js"
  mv "$MUTANT_DIR/hooks/_t.js" "$MUTANT_DIR/hooks/index.js"

  run diff "$INDEX_JS" "$MUTANT_DIR/hooks/index.js"
  [ "$status" -ne 0 ]

  assert_esm_parse "$MUTANT_DIR/hooks/index.js"

  run claude plugin test "$MUTANT_DIR"
  [ "$status" -ne 0 ]

  # The partial-caps test must be the one that fails (assertion, not load error)
  [[ "$output" == *"command.register throws"* ]] || false
  assert_no_load_error "$output"

  run claude plugin test "$PLUGIN_DIR"
  [ "$status" -eq 0 ]

  rm -rf "$MUTANT_DIR"
}

@test "removing process capability flag turns pane test red" {
  command -v claude || false
  [ -f "$INDEX_JS" ] || false

  MUTANT_DIR="${BATS_TMPDIR}/mutant-m1c-$$"
  prepare_mutant "$MUTANT_DIR"

  sed '/caps\.process = true/d' "$MUTANT_DIR/hooks/index.js" > "$MUTANT_DIR/hooks/_t.js"
  mv "$MUTANT_DIR/hooks/_t.js" "$MUTANT_DIR/hooks/index.js"

  run diff "$INDEX_JS" "$MUTANT_DIR/hooks/index.js"
  [ "$status" -ne 0 ]

  assert_esm_parse "$MUTANT_DIR/hooks/index.js"

  run claude plugin test "$MUTANT_DIR"
  [ "$status" -ne 0 ]
  assert_no_load_error "$output"

  run claude plugin test "$PLUGIN_DIR"
  [ "$status" -eq 0 ]

  rm -rf "$MUTANT_DIR"
}

@test "removing staleness guard turns staleness test red" {
  command -v claude || false
  [ -f "$INDEX_JS" ] || false

  MUTANT_DIR="${BATS_TMPDIR}/mutant-m2-$$"
  prepare_mutant "$MUTANT_DIR"

  sed '/MARKER:STALENESS_GUARD/d' "$MUTANT_DIR/hooks/index.js" > "$MUTANT_DIR/hooks/_t.js"
  mv "$MUTANT_DIR/hooks/_t.js" "$MUTANT_DIR/hooks/index.js"

  run diff "$INDEX_JS" "$MUTANT_DIR/hooks/index.js"
  [ "$status" -ne 0 ]

  assert_esm_parse "$MUTANT_DIR/hooks/index.js"

  run claude plugin test "$MUTANT_DIR"
  [ "$status" -ne 0 ]
  assert_no_load_error "$output"

  run claude plugin test "$PLUGIN_DIR"
  [ "$status" -eq 0 ]

  rm -rf "$MUTANT_DIR"
}
