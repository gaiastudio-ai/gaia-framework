#!/usr/bin/env bats
# tool-availability-probe.bats — unit tests for plugins/gaia/scripts/tool-availability-probe.sh (E66-S2)
# Covers TC-RSV2-PROBE-01..04, AC1..AC4, AC6, NFR-RSV2-9.
#
# The probe classifies an adapter invocation into one of four states:
#   - available           : tool installed, files match, run.sh exits 0
#   - expected_and_missing: tool declared in adapter.json but not on PATH
#   - ran_and_errored     : tool exits non-zero or times out (with error_detail)
#   - not_applicable      : no input files match the adapter's category extensions
#
# Output is a single-line JSON object on stdout:
#   {"state":"<state>","skip_reason":<string|null>,"error_detail":<string|null>}

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/tool-availability-probe.sh"
  ADAPTER_DIR="$TEST_TMP/adapter"
  mkdir -p "$ADAPTER_DIR/test"
  FILE_LIST="$TEST_TMP/file-list.txt"
}
teardown() { common_teardown; }

# --- helpers ---

# write_adapter_json <path> [provider] [extensions-json] [default-timeout]
write_adapter_json() {
  local path="$1"
  local provider="${2:-eslint}"
  local exts="${3:-[\".ts\",\".tsx\"]}"
  local timeout="${4:-30}"
  cat > "$path" <<EOF
{
  "provider": "$provider",
  "category": "linter",
  "version-range": ">=8.0.0",
  "runtime-profile": "subprocess",
  "default-timeout-seconds": $timeout,
  "file-extensions": $exts
}
EOF
}

# write_run_sh <path> <exit-code> [stderr-msg] [sleep-seconds]
write_run_sh() {
  local path="$1"
  local rc="${2:-0}"
  local err="${3:-}"
  local sleep_s="${4:-0}"
  cat > "$path" <<EOF
#!/usr/bin/env bash
set -u
if [ "$sleep_s" -gt 0 ]; then sleep "$sleep_s"; fi
if [ -n "$err" ]; then printf '%s\n' "$err" >&2; fi
exit $rc
EOF
  chmod +x "$path"
}

# fake_tool_dir <tool-name> [exit-code] — returns a dir that puts a fake binary on PATH
fake_tool_dir() {
  local tool="$1"
  local rc="${2:-0}"
  local dir="$TEST_TMP/fake-bin-$tool"
  mkdir -p "$dir"
  cat > "$dir/$tool" <<EOF
#!/usr/bin/env bash
exit $rc
EOF
  chmod +x "$dir/$tool"
  printf '%s' "$dir"
}

# --- AC4: CLI / interface ---

@test "probe: --help exits 0 and lists usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--adapter-dir"* ]]
  [[ "$output" == *"--file-list"* ]]
  [[ "$output" == *"--timeout"* ]]
}

@test "probe: missing --adapter-dir exits 1" {
  run -1 --separate-stderr "$SCRIPT" --file-list "$FILE_LIST"
  [[ "$stderr" == *"--adapter-dir"* ]]
}

@test "probe: missing --file-list exits 1" {
  run -1 "$SCRIPT" --adapter-dir "$ADAPTER_DIR"
}

@test "probe: missing adapter.json exits 1 with diagnostic" {
  : > "$FILE_LIST"
  run -1 --separate-stderr "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [[ "$stderr" == *"adapter.json"* ]]
}

@test "probe: malformed adapter.json exits 1 with diagnostic" {
  printf 'not-json' > "$ADAPTER_DIR/adapter.json"
  : > "$FILE_LIST"
  run -1 --separate-stderr "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [[ "$stderr" == *"adapter.json"* ]]
}

# --- AC3 / TC-RSV2-PROBE-03: not_applicable ---

@test "probe: not_applicable when file-list has no matching extensions" {
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/main.py\nsrc/util.py\n' > "$FILE_LIST"

  run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "not_applicable"' >/dev/null
  echo "$output" | jq -e '.skip_reason | length > 0' >/dev/null
  echo "$output" | jq -e '.error_detail == null' >/dev/null
}

@test "probe: not_applicable when file-list is empty" {
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  : > "$FILE_LIST"

  run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "not_applicable"' >/dev/null
}

# --- AC1 / TC-RSV2-PROBE-01: expected_and_missing ---

@test "probe: expected_and_missing when adapter declares tool absent from PATH" {
  write_adapter_json "$ADAPTER_DIR/adapter.json" "definitely-not-a-real-binary-xyz"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/app.ts\n' > "$FILE_LIST"

  run -1 --separate-stderr "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  echo "$output" | jq -e '.state == "expected_and_missing"' >/dev/null
  echo "$output" | jq -e '.skip_reason == null' >/dev/null
  [[ "$stderr" == *"definitely-not-a-real-binary-xyz"* ]]
}

# --- AC2 / TC-RSV2-PROBE-02: ran_and_errored ---

@test "probe: ran_and_errored captures stderr in error_detail when run.sh exits non-zero" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 1 "segfault: invalid input"
  printf 'src/app.ts\n' > "$FILE_LIST"

  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.state == "ran_and_errored"' >/dev/null
  echo "$output" | jq -e '.error_detail | length > 0' >/dev/null
  echo "$output" | jq -e '.error_detail | contains("segfault")' >/dev/null
}

@test "probe: ran_and_errored on timeout when run.sh exceeds --timeout" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0 "" 5
  printf 'src/app.ts\n' > "$FILE_LIST"

  PATH="$fake_path:$PATH" run "$SCRIPT" \
    --adapter-dir "$ADAPTER_DIR" \
    --file-list "$FILE_LIST" \
    --timeout 1
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.state == "ran_and_errored"' >/dev/null
  echo "$output" | jq -e '.error_detail | ascii_downcase | contains("timeout")' >/dev/null
}

# --- happy-path / available ---

@test "probe: available when tool on PATH, files match, run.sh exits 0" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/app.ts\nsrc/component.tsx\n' > "$FILE_LIST"

  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "available"' >/dev/null
  echo "$output" | jq -e '.skip_reason == null' >/dev/null
  echo "$output" | jq -e '.error_detail == null' >/dev/null
}

# --- AC6 / NFR-RSV2-9: determinism ---

@test "probe: 10 sequential invocations produce identical output (determinism)" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/app.ts\n' > "$FILE_LIST"

  local first=""
  local i out
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out="$(PATH="$fake_path:$PATH" "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST")"
    if [ -z "$first" ]; then
      first="$out"
    else
      [ "$out" = "$first" ] || { echo "iter $i drift: $out vs $first" >&2; false; }
    fi
  done
}

# --- JSON schema shape (AC4) ---

@test "probe: output JSON has exactly the four canonical keys" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/app.ts\n' > "$FILE_LIST"

  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 0 ]
  # Must contain exactly the keys: state, skip_reason, error_detail
  echo "$output" | jq -e '(keys | sort) == (["error_detail","skip_reason","state"])' >/dev/null
}

# --- --timeout from adapter.json default ---

@test "probe: uses adapter.json default-timeout-seconds when --timeout not provided" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  # adapter declares 1s default timeout; run.sh sleeps 4s
  write_adapter_json "$ADAPTER_DIR/adapter.json" "eslint" '[".ts"]' 1
  write_run_sh "$ADAPTER_DIR/run.sh" 0 "" 4
  printf 'src/app.ts\n' > "$FILE_LIST"

  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.state == "ran_and_errored"' >/dev/null
}

# --- CLI --timeout overrides adapter.json default ---

@test "probe: --timeout flag overrides adapter.json default-timeout-seconds" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  # adapter declares 60s default, run.sh sleeps 4s, --timeout 1 overrides
  write_adapter_json "$ADAPTER_DIR/adapter.json" "eslint" '[".ts"]' 60
  write_run_sh "$ADAPTER_DIR/run.sh" 0 "" 4
  printf 'src/app.ts\n' > "$FILE_LIST"

  PATH="$fake_path:$PATH" run "$SCRIPT" \
    --adapter-dir "$ADAPTER_DIR" \
    --file-list "$FILE_LIST" \
    --timeout 1
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.state == "ran_and_errored"' >/dev/null
}
