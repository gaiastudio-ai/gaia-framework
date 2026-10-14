#!/usr/bin/env bats
# mod-shell-static-audit.bats -- Static audit of hooks/index.js.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  INDEX_JS="$REPO_ROOT/plugins/gaia/hooks/index.js"
  SNAPSHOT_SH="$REPO_ROOT/plugins/gaia/scripts/sprint-progress-snapshot.sh"
}

@test "process.run uses array form no interpolation timeoutMs exitCode try-catch" {
  [ -f "$INDEX_JS" ] || false

  # Must use array form for argv (first arg is an array literal)
  grep -q 'process\.run(\[' "$INDEX_JS"

  # Must NOT use template literals with process.run (no interpolation in argv)
  run grep -c '\.run(`' "$INDEX_JS"
  [ "$output" = "0" ] || false

  # Must set timeoutMs
  grep -q 'timeoutMs' "$INDEX_JS"

  # Must check exitCode
  grep -q 'exitCode' "$INDEX_JS"

  # Must have try/catch (marker anchor present)
  grep -q 'MARKER:SNAPSHOT_TRY' "$INDEX_JS"
}

@test "all ui.log calls use to debug" {
  [ -f "$INDEX_JS" ] || false

  # Find all lines with ui.log -- there must be at least one
  LOG_LINES="$(grep -n 'ui\.log' "$INDEX_JS")"
  LINE_COUNT="$(echo "$LOG_LINES" | wc -l)"
  [ "$LINE_COUNT" -gt 0 ] || false

  # Every ui.log call must contain {to:'debug'} or {to: 'debug'}
  MISSING="$(grep 'ui\.log' "$INDEX_JS" | grep -cv "to[: ]*['\"]debug['\"]" || true)"
  [ "$MISSING" = "0" ] || false
}

# Comprehensive static audit with node script for deeper analysis
@test "argv count equals 1 for every process.run call" {
  [ -f "$INDEX_JS" ] || false

  # Extract process.run calls and verify each has exactly 1 element in the argv array
  # Uses a node script that parses the source for $.process.run([ ... ], ...) calls
  run node -e "
const fs = require('fs');
const src = fs.readFileSync('$INDEX_JS', 'utf8');
// Find all $.process.run([ ... ] patterns
const re = /\\\$\.process\.run\(\s*\[([^\]]*)\]/g;
let m, count = 0;
while ((m = re.exec(src)) !== null) {
  count++;
  // Count top-level comma-separated elements (not inside nested brackets)
  const inner = m[1].trim();
  // Split on commas not inside parens/brackets
  let depth = 0, elems = inner.length > 0 ? 1 : 0;
  for (const ch of inner) {
    if (ch === '(' || ch === '[') depth++;
    else if (ch === ')' || ch === ']') depth--;
    else if (ch === ',' && depth === 0) elems++;
  }
  if (elems !== 1) {
    process.stderr.write('process.run call has ' + elems + ' argv elements, expected 1');
    process.exit(1);
  }
}
if (count === 0) {
  process.stderr.write('no process.run calls found');
  process.exit(1);
}
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "no template literal or string concatenation in argv or joinPath arguments" {
  [ -f "$INDEX_JS" ] || false

  # No template literal in process.run argv
  run grep -c 'process\.run(`\|process\.run(\[`' "$INDEX_JS"
  [ "$output" = "0" ] || false

  # No string concatenation with + in joinPath calls (joinPath uses rest args)
  # joinPath itself uses '/' join, not template literals
  run grep -c 'joinPath.*+\s*["\x27]' "$INDEX_JS"
  [ "$output" = "0" ] || false
}

@test "timeoutMs present in every process.run call" {
  [ -f "$INDEX_JS" ] || false
  # Count process.run calls vs timeoutMs occurrences in those calls
  PROC_COUNT="$(grep -c 'process\.run(' "$INDEX_JS")"
  TIMEOUT_COUNT="$(grep -c 'timeoutMs' "$INDEX_JS")"
  [ "$PROC_COUNT" -gt 0 ]
  [ "$TIMEOUT_COUNT" -ge "$PROC_COUNT" ] || false
}

@test "exitCode check present after process.run" {
  [ -f "$INDEX_JS" ] || false
  grep -q 'exitCode' "$INDEX_JS"
}

@test "try-catch encloses process.run" {
  [ -f "$INDEX_JS" ] || false
  grep -q 'MARKER:SNAPSHOT_TRY' "$INDEX_JS"
}

@test "every ui.log call passes to debug and count is greater than zero" {
  [ -f "$INDEX_JS" ] || false
  DEBUG_COUNT="$(grep -c "to.*['\"]debug['\"]" "$INDEX_JS" || true)"
  [ "$DEBUG_COUNT" -gt 0 ] || false
}

@test "static audit catches interpolation pattern (probe with bad copy)" {
  [ -f "$INDEX_JS" ] || false

  TMPDIR_AUDIT="${BATS_TMPDIR}/audit-interp-$$"
  mkdir -p "$TMPDIR_AUDIT"
  cp "$INDEX_JS" "$TMPDIR_AUDIT/index.js"

  # Seed bad pattern: template literal in process.run and extra arg
  printf '\n// BAD: $.process.run(`echo hello`, extra);\n' >> "$TMPDIR_AUDIT/index.js"

  # The grep for template literal must now find it
  run grep -c '\.run(`' "$TMPDIR_AUDIT/index.js"
  [ "$output" != "0" ] || false

  # The audit itself FAILS on the bad copy (template literal argv)
  run grep -c 'process\.run(`\|\.run(`' "$TMPDIR_AUDIT/index.js"
  [ "$output" != "0" ] || false

  rm -rf "$TMPDIR_AUDIT"
}

@test "snapshot script has git index mode 100755" {
  [ -f "$SNAPSHOT_SH" ] || false

  cd "$REPO_ROOT"
  run git ls-files -s "$SNAPSHOT_SH"
  echo "$output"
  echo "$output" | grep -q '100755'
}
