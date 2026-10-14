#!/usr/bin/env bats
# mod-validate-strict.bats -- Plugin validate --strict and hooks.json lint.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
}

@test "plugin validate strict exits 0" {
  command -v claude || false
  run claude plugin validate --strict "$PLUGIN_DIR"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "hooks.json is well-formed JSON" {
  HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
  [ -f "$HOOKS_JSON" ] || false
  run node -e "JSON.parse(require('fs').readFileSync('$HOOKS_JSON','utf8'))"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "CLI presence checked with hard failure not skip" {
  # Design intent: tests requiring the claude CLI must FAIL (not skip)
  # when it is absent. Assert this file uses 'command -v claude || false'
  # and the companion files (mutant-kill, empty-body) do the same.
  THIS_FILE="$REPO_ROOT/plugins/gaia/tests/mod-validate-strict.bats"
  grep -q 'command -v claude || false' "$THIS_FILE"

  # Scan sibling files for 'command -v claude || false' (hard failure present)
  # and no 'claude || skip' (soft skip absent). Exclude this file to avoid
  # self-referential grep.
  for f in \
    "$REPO_ROOT/plugins/gaia/tests/mod-mutant-kill.bats" \
    "$REPO_ROOT/plugins/gaia/tests/mod-empty-body.bats"; do
    [ -f "$f" ] || continue
    grep -q 'command -v claude || false' "$f" || {
      echo "FAIL: $(basename "$f") missing hard-failure CLI check"
      false
    }
    if grep -q 'claude || skip' "$f"; then
      echo "FAIL: $(basename "$f") uses skip when CLI absent"
      false
    fi
  done
}
