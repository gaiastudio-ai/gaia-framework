#!/usr/bin/env bats
# mod-mutant-kill.bats -- Mutant-kill checks for the hooks module, run
# through the real `claude plugin test` harness. Each mutation is marker
# targeted, the mutated module must still parse, and the named harness test
# (and no load error) must be the one that fails.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  HOOKS_DIR="$REPO_ROOT/plugins/gaia/hooks"
  INDEX_JS="$HOOKS_DIR/index.js"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
}

# Builds a plugin copy with the sed expression $1 applied to index.js.
# Fails when the expression changes nothing or the result does not parse.
prepare_mutant() {
  MUTANT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/mutant.XXXXXX")"
  mkdir -p "$MUTANT_DIR/.claude-plugin" "$MUTANT_DIR/hooks"
  cp "$PLUGIN_DIR/.claude-plugin/plugin.json" "$MUTANT_DIR/.claude-plugin/"
  cp "$HOOKS_DIR"/* "$MUTANT_DIR/hooks/"
  sed "$1" "$INDEX_JS" > "$MUTANT_DIR/hooks/index.js"
  if cmp -s "$INDEX_JS" "$MUTANT_DIR/hooks/index.js"; then
    echo "mutation '$1' changed nothing" >&2
    return 1
  fi
  cp "$MUTANT_DIR/hooks/index.js" "$MUTANT_DIR/check.mjs"
  node --check "$MUTANT_DIR/check.mjs"
  rm -f "$MUTANT_DIR/check.mjs"
}

# Asserts the harness output reports the named test as failed and shows no
# module load error.
assert_failed_test() {
  local name="$1"
  if ! printf '%s\n' "$output" | grep -qF "(fail) $name ["; then
    echo "expected a failure of: $name" >&2
    return 1
  fi
  if [[ "$output" == *SyntaxError* ]] || [[ "$output" == *"did not load"* ]] || [[ "$output" == *"Cannot find module"* ]]; then
    echo "mutant failed to load instead of failing an assertion" >&2
    return 1
  fi
}

@test "the unmodified plugin passes its mod tests" {
  command -v claude || false
  run claude plugin test "$PLUGIN_DIR"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *" 0 fail"* ]] || false
}

@test "removing the command.register try-catch turns the partial-caps test red" {
  command -v claude || false
  prepare_mutant '/MARKER:CAP_DETECT_CMD$/d;/MARKER:CAP_DETECT_CMD_END$/d'
  run claude plugin test "$MUTANT_DIR"
  echo "$output"
  [ "$status" -ne 0 ]
  assert_failed_test "partial capabilities > command.register throws but root detection and probe succeed: sprint is active"
}

@test "never setting the process capability turns the refresh-first tests red" {
  command -v claude || false
  prepare_mutant '/MARKER:PROCESS_CAP$/d'
  run claude plugin test "$MUTANT_DIR"
  echo "$output"
  [ "$status" -ne 0 ]
  assert_failed_test "session start does not wait for the snapshot > session start returns while the first snapshot is still running"
  assert_failed_test "/sprint command > refresh runs first: a snapshot that creates the cache gives an active sprint"
}

@test "removing the staleness guard turns the staleness test red" {
  command -v claude || false
  prepare_mutant '/MARKER:STALENESS_GUARD$/d'
  run claude plugin test "$MUTANT_DIR"
  echo "$output"
  [ "$status" -ne 0 ]
  assert_failed_test "clock and staleness > 90 s old cache triggers one snapshot then one invalidate; 30 s triggers none"
}
