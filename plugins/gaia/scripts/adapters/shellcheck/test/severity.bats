#!/usr/bin/env bats
# adapters/shellcheck/test/severity.bats — severity calibration + auto-skip + output shape (E77-S11).
#
# These tests exercise run.sh end-to-end. They require `shellcheck` and `jq` on PATH;
# when shellcheck is missing, the relevant tests are skipped (NOT failed) so CI runners
# without shellcheck do not block (the contract.bats four-state probe still covers
# expected_and_missing).
#
# AC mapping:
#   AC5 — six critical rules => severity=error; all others => warning.
#   AC6 — zero .sh files in input => exit 0, empty findings, stderr log.
#   AC7 — output conforms to analysis-results checks[] fragment shape.

bats_require_minimum_version 1.5.0

ADAPTER_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN_SH="$ADAPTER_DIR/run.sh"

setup() {
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/shellcheck-sev-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

require_shellcheck() {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not on PATH"
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"
}

# AC6: zero .sh files in input => auto-skip cleanly.
@test "shellcheck severity: auto-skip when input contains no .sh files" {
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"

  local input="$WORK_TMP/files.txt"
  printf 'src/main.py\nREADME.md\n' > "$input"

  run --separate-stderr "$RUN_SH" --input "$input"

  [ "$status" -eq 0 ]
  # stdout = canonical fragment with empty findings + status=passed (or skipped).
  echo "$output" | jq -e '.name == "shellcheck" and (.findings | length == 0)' >/dev/null
  # stderr should mention the skip reason.
  echo "$stderr" | grep -q "No .sh files"
}

# AC6: empty file list => same auto-skip behavior.
@test "shellcheck severity: auto-skip when input file is empty" {
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"

  local input="$WORK_TMP/files.txt"
  : > "$input"

  run --separate-stderr "$RUN_SH" --input "$input"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
}

# AC5: SC2086 (unquoted variable) maps to severity=error.
@test "shellcheck severity: SC2086 unquoted variable => error" {
  require_shellcheck

  local script="$WORK_TMP/sc2086.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
foo=$1
echo $foo
EOF

  local input="$WORK_TMP/files.txt"
  printf '%s\n' "$script" > "$input"

  run "$RUN_SH" --input "$input"

  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  echo "$output" | jq -e '.findings[] | select(.rule == "SC2086") | .severity == "error"' >/dev/null
}

# AC5: SC2034 (advisory) maps to severity=warning, NOT error.
@test "shellcheck severity: SC2034 unused variable => warning (advisory)" {
  require_shellcheck

  local script="$WORK_TMP/sc2034.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
unused_var="hello"
echo "world"
EOF

  local input="$WORK_TMP/files.txt"
  printf '%s\n' "$script" > "$input"

  run "$RUN_SH" --input "$input"

  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # SC2034 finding present and severity is warning (advisory), not error.
  echo "$output" | jq -e '.findings[] | select(.rule == "SC2034") | .severity == "warning"' >/dev/null
}

# AC7: output is a valid analysis-results checks[] fragment.
@test "shellcheck severity: output fragment has canonical {name,status,findings} shape" {
  require_shellcheck

  local script="$WORK_TMP/clean.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
echo "hello"
EOF

  local input="$WORK_TMP/files.txt"
  printf '%s\n' "$script" > "$input"

  run "$RUN_SH" --input "$input"

  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  echo "$output" | jq -e '
    has("name") and has("status") and has("findings")
    and (.name == "shellcheck")
    and (.status == "passed" or .status == "failed")
    and (.findings | type == "array")
  ' >/dev/null
}

# AC9 indirect: mixed .sh + non-.sh inputs => only .sh files scanned.
@test "shellcheck severity: mixed input scans only .sh files" {
  require_shellcheck

  local sh_script="$WORK_TMP/test.sh"
  cat > "$sh_script" <<'EOF'
#!/usr/bin/env bash
foo=$1
echo $foo
EOF
  local py_script="$WORK_TMP/test.py"
  echo 'print("hi")' > "$py_script"
  local md_doc="$WORK_TMP/test.md"
  echo "# heading" > "$md_doc"

  local input="$WORK_TMP/files.txt"
  printf '%s\n%s\n%s\n' "$sh_script" "$py_script" "$md_doc" > "$input"

  run "$RUN_SH" --input "$input"

  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # Findings should reference only the .sh file.
  echo "$output" | jq -e '
    .findings | all(.file | test("\\.sh$"))
  ' >/dev/null
}

# All six critical rules map to severity=error.
@test "shellcheck severity: all six critical rules (SC2086/SC2154/SC2046/SC2068/SC2155/SC2178) => error" {
  require_shellcheck

  local script="$WORK_TMP/critical.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
# SC2086 (unquoted)
foo=$1
echo $foo
# SC2154 (referenced but not assigned)
echo "$undeclared_var"
# SC2046 (unquoted command sub)
echo $(date)
# SC2068 (unquoted array)
arr=(a b c)
echo ${arr[@]}
# SC2155 (declare and assign)
declare -r mydate=$(date)
EOF

  local input="$WORK_TMP/files.txt"
  printf '%s\n' "$script" > "$input"

  run "$RUN_SH" --input "$input"

  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # Every critical-rule finding present in this file must be severity=error.
  echo "$output" | jq -e '
    [.findings[] | select(.rule | IN("SC2086","SC2154","SC2046","SC2068","SC2155","SC2178"))]
    | length > 0
    and all(.severity == "error")
  ' >/dev/null
}
