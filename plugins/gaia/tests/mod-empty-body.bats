#!/usr/bin/env bats
# mod-empty-body.bats -- A hooks module whose register body is empty loads
# without error, and the harness actually loads it.

load 'test_helper.bash'

setup() {
  TMPMOD="$BATS_TEST_TMPDIR/mod-empty-body"
  mkdir -p "$TMPMOD/.claude-plugin" "$TMPMOD/hooks"

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

  # A test file makes the harness load the module and start a session
  # through it: with no hooks registered, the session start reaches the
  # bottom unchanged.
  cat > "$TMPMOD/hooks/index.test.ts" <<'TEST'
import { test, expect } from 'claude-code/testing'
test('empty module passes session start through', async ($, on) => {
  on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
  const result = await $.session.start({ cwd: '/somewhere', surface: 'terminal', isInteractive: true })
  expect(result).toEqual({ cwd: '/somewhere' })
})
TEST
}

@test "empty register body loads without error" {
  command -v claude || false

  run claude plugin validate --strict "$TMPMOD"
  echo "validate output: $output"
  [ "$status" -eq 0 ]

  run claude plugin test "$TMPMOD"
  echo "test output: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(pass) empty module passes session start through"* ]] || false
  [[ "$output" == *" 1 pass"* ]] || false
  [[ "$output" == *" 0 fail"* ]] || false
  [[ "$output" != *rror* ]] || false
  [[ "$output" != *arning* ]] || false
}
