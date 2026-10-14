#!/usr/bin/env bats
# mod-empty-body.bats -- An empty register body loads without error.
# RED phase: This test passes independently (uses a temp scaffold),
# but validates that the mod infrastructure works.

setup() {
  TMPMOD="${BATS_TMPDIR}/mod-empty-body-$$"
  mkdir -p "$TMPMOD/.claude-plugin"
  mkdir -p "$TMPMOD/hooks"

  cat > "$TMPMOD/.claude-plugin/plugin.json" <<'PJSON'
{
  "name": "empty-body-test",
  "version": "0.1.0",
  "description": "Test fixture: empty register body",
  "author": { "name": "test" }
}
PJSON

  cat > "$TMPMOD/hooks/hooks.json" <<'HJSON'
{"modules":["./index.js"],"hooks":{}}
HJSON

  cat > "$TMPMOD/hooks/index.js" <<'MOD'
export function register(on, options) {}
MOD
}

teardown() {
  rm -rf "$TMPMOD"
}

@test "empty register body loads without error" {
  command -v claude || false

  run claude plugin validate --strict "$TMPMOD"
  echo "validate output: $output"
  [ "$status" -eq 0 ]

  # plugin test exits 1 when no *.test.ts files exist (expected).
  # Assert the message is the "no tests" message, not a load error.
  run claude plugin test "$TMPMOD"
  echo "test output: $output"
  echo "$output" | grep -q 'no \*\.test\.ts'
}
