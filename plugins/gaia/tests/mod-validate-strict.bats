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

# Checks one bats file: every @test that calls the claude CLI must first
# hard-fail when it is missing ("command -v claude || false"), and the file
# must never skip. Prints the number of CLI-using tests it checked.
_check_cli_guard() {
  awk '
    /^@test / { intest = 1; guarded = 0; name = $0; next }
    intest && /^}/ { intest = 0; next }
    /^[[:space:]]*skip([[:space:]]|$)/ || /(\|\||&&)[[:space:]]*skip([[:space:]]|$)/ { print "skip used: " FILENAME ":" FNR; bad = 1 }
    intest && /^[[:space:]]*command -v claude \|\| false[[:space:]]*$/ { guarded = 1; next }
    intest && /^[[:space:]]*(run[[:space:]]+)?claude[[:space:]]/ {
      checked[name] = 1
      if (!guarded) { print "unguarded claude call: " FILENAME ":" FNR; bad = 1 }
    }
    END { n = 0; for (k in checked) n++; print "cli tests checked: " n; exit bad }
  ' "$1"
}

@test "every test that calls the claude CLI hard-fails when it is missing" {
  local f total=0 n
  for f in "$REPO_ROOT"/plugins/gaia/tests/mod-*.bats; do
    run _check_cli_guard "$f"
    echo "$f: $output"
    [ "$status" -eq 0 ]
    n="${output##*cli tests checked: }"
    total=$((total + n))
  done
  # validate-strict, empty-body and mutant-kill all call the CLI.
  [ "$total" -ge 6 ] || false
}

@test "the CLI guard check fails on a test without the guard or with a skip" {
  local bad="$BATS_TEST_TMPDIR/bad.bats"
  printf '%s\n' '@test "x" {' '  run claude plugin validate .' '}' > "$bad"
  run _check_cli_guard "$bad"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unguarded claude call: $bad:2"* ]] || false

  # The skip word is split so this file does not trip its own check.
  local word="sk""ip"
  printf '%s\n' '@test "y" {' "  command -v claude || $word \"no cli\"" '  run claude plugin validate .' '}' > "$bad"
  run _check_cli_guard "$bad"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"skip used: $bad:2"* ]] || false
}
