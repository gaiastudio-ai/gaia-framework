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
  # E66-S6 / AC2: failure_kind is null for non-failure states.
  echo "$output" | jq -e '.failure_kind == null' >/dev/null
}

@test "probe: not_applicable when file-list is empty" {
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  : > "$FILE_LIST"

  run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "not_applicable"' >/dev/null
  # E66-S6 / AC2: failure_kind is null for non-failure states.
  echo "$output" | jq -e '.failure_kind == null' >/dev/null
}

# --- AC1 / TC-RSV2-PROBE-01: expected_and_missing ---

@test "probe: expected_and_missing when adapter declares tool absent from PATH" {
  write_adapter_json "$ADAPTER_DIR/adapter.json" "definitely-not-a-real-binary-xyz"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/app.ts\n' > "$FILE_LIST"

  run -1 --separate-stderr "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  echo "$output" | jq -e '.state == "expected_and_missing"' >/dev/null
  echo "$output" | jq -e '.skip_reason == null' >/dev/null
  # E66-S6 / AC1: failure_kind = "tool_missing" when state == expected_and_missing.
  echo "$output" | jq -e '.failure_kind == "tool_missing"' >/dev/null
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
  # E66-S6 / AC1: failure_kind = "runtime_crash" for non-timeout non-zero exits.
  echo "$output" | jq -e '.failure_kind == "runtime_crash"' >/dev/null
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
  # E66-S6 / AC1: failure_kind = "timeout" when run.sh hits the timeout wrapper.
  echo "$output" | jq -e '.failure_kind == "timeout"' >/dev/null
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
  # E66-S6 / AC2: failure_kind is null for non-failure states.
  echo "$output" | jq -e '.failure_kind == null' >/dev/null
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

@test "probe: output JSON has exactly the canonical keys (E66-S6 adds failure_kind)" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/app.ts\n' > "$FILE_LIST"

  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 0 ]
  # E66-S6: schema is now five keys -- state, skip_reason, error_detail, failure_kind.
  # NB: failure_kind is the additive E66-S6 field (AC4: backward-compatible additive schema).
  echo "$output" | jq -e '(keys | sort) == (["error_detail","failure_kind","skip_reason","state"])' >/dev/null
}

# --- E66-S6 / AC1 + AC3: failure_kind enum domain ---

@test "probe (E66-S6): failure_kind value is one of the documented enum or null" {
  # Sanity check covering each emitted failure_kind across cases. The valid
  # domain is {tool_missing, version_mismatch, runtime_crash, timeout} or null.
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"

  # Case A: not_applicable -> null
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/main.py\n' > "$FILE_LIST"
  run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  echo "$output" | jq -e '.failure_kind == null' >/dev/null

  # Case B: expected_and_missing -> "tool_missing"
  # Use --separate-stderr because the probe writes a "tool not on PATH" diagnostic
  # to stderr; without separation it would interleave with the JSON on stdout.
  write_adapter_json "$ADAPTER_DIR/adapter.json" "definitely-not-a-real-binary-xyz"
  printf 'src/app.ts\n' > "$FILE_LIST"
  run -1 --separate-stderr "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  echo "$output" | jq -e '.failure_kind == "tool_missing"' >/dev/null

  # Case C: ran_and_errored (runtime_crash) -> "runtime_crash"
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 1 "boom"
  printf 'src/app.ts\n' > "$FILE_LIST"
  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  echo "$output" | jq -e '.failure_kind == "runtime_crash"' >/dev/null

  # Case D: ran_and_errored (timeout) -> "timeout"
  write_run_sh "$ADAPTER_DIR/run.sh" 0 "" 5
  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST" --timeout 1
  echo "$output" | jq -e '.failure_kind == "timeout"' >/dev/null

  # Case E: available -> null
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  echo "$output" | jq -e '.failure_kind == null' >/dev/null
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

# --- E77-S3 / FR-405 / ADR-089: tri-state tool-availability semantics ---
#
# The new tri-state mode is opted-in via --tool <name> --config <project-config.yaml>.
# Without --tool, the legacy single-adapter probe behaviour is unchanged (AC6).
#
# Three states classified from the project-config.yaml `tool_adapters:` block:
#   - omitted  : no key for <name>            -> exit 0, no JSON, no advisory output (AC1)
#   - null     : key present, value is `null` -> JSON {probe_state:"null", severity:"WARNING", ...} (AC2)
#   - declared : key present, value is a map  -> probe; on missing binary emit
#                JSON {probe_state:"declared", severity:"WARNING", ...} (AC3)
#                On binary present: {probe_state:"declared", severity:null, available:true} (AC4)

# write_project_config <path> <project_kind> <body>
write_project_config() {
  local path="$1"
  local kind="$2"
  local body="$3"
  cat > "$path" <<EOF
project_kind: $kind
$body
EOF
}

# --- AC1 / TC-PLUGIN-PROBE-1: omitted ---

@test "probe (E77-S3, AC1): omitted tool emits no output and exits 0" {
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "claude-code-plugin" "tool_adapters:
  eslint: null"

  run "$SCRIPT" --tool shellcheck --config "$cfg"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- AC2 / TC-PLUGIN-PROBE-2: null ---

@test "probe (E77-S3, AC2): null + binary absent -> WARNING advisory" {
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "claude-code-plugin" "tool_adapters:
  not-a-real-binary-xyz: null"

  run "$SCRIPT" --tool not-a-real-binary-xyz --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.probe_state == "null"' >/dev/null
  echo "$output" | jq -e '.severity == "WARNING"' >/dev/null
  echo "$output" | jq -e '.available == false' >/dev/null
  echo "$output" | jq -e '.message | ascii_downcase | contains("advisory")' >/dev/null
}

@test "probe (E77-S3, AC2): null + binary present -> available" {
  local fake_path; fake_path="$(fake_tool_dir myfake 0)"
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "claude-code-plugin" "tool_adapters:
  myfake: null"

  PATH="$fake_path:$PATH" run "$SCRIPT" --tool myfake --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.probe_state == "null"' >/dev/null
  echo "$output" | jq -e '.available == true' >/dev/null
  echo "$output" | jq -e '.severity == null' >/dev/null
}

# --- AC3 / TC-PLUGIN-PROBE-3: declared, binary absent -> WARNING (not CRITICAL) ---

@test "probe (E77-S3, AC3): declared + binary absent -> WARNING (not CRITICAL)" {
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "claude-code-plugin" "tool_adapters:
  not-a-real-binary-xyz:
    path: /opt/missing/not-a-real-binary-xyz"

  run "$SCRIPT" --tool not-a-real-binary-xyz --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.probe_state == "declared"' >/dev/null
  echo "$output" | jq -e '.severity == "WARNING"' >/dev/null
  echo "$output" | jq -e '.severity != "CRITICAL"' >/dev/null
  echo "$output" | jq -e '.available == false' >/dev/null
}

# --- AC4: declared + binary present -> available, no warning ---

@test "probe (E77-S3, AC4): declared + binary present -> available, severity null" {
  local fake_path; fake_path="$(fake_tool_dir myfake 0)"
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "claude-code-plugin" "tool_adapters:
  myfake:
    path: /opt/myfake"

  PATH="$fake_path:$PATH" run "$SCRIPT" --tool myfake --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.probe_state == "declared"' >/dev/null
  echo "$output" | jq -e '.available == true' >/dev/null
  echo "$output" | jq -e '.severity == null' >/dev/null
}

# --- AC5: tri-state semantics generalize across project_kind ---

@test "probe (E77-S3, AC5): tri-state generalizes -- web-app + null + absent -> WARNING" {
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "web-app" "tool_adapters:
  not-a-real-binary-xyz: null"

  run "$SCRIPT" --tool not-a-real-binary-xyz --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.probe_state == "null"' >/dev/null
  echo "$output" | jq -e '.severity == "WARNING"' >/dev/null
}

@test "probe (E77-S3, AC5): tri-state generalizes -- backend-service + declared + absent -> WARNING" {
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "backend-service" "tool_adapters:
  not-a-real-binary-xyz:
    path: /opt/missing"

  run "$SCRIPT" --tool not-a-real-binary-xyz --config "$cfg"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.probe_state == "declared"' >/dev/null
  echo "$output" | jq -e '.severity == "WARNING"' >/dev/null
}

@test "probe (E77-S3, AC5): tri-state generalizes -- mobile-app + omitted -> no output" {
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "mobile-app" "tool_adapters:
  eslint: null"

  run "$SCRIPT" --tool shellcheck --config "$cfg"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- AC6: backward compatibility — adapter-dir mode unchanged ---

@test "probe (E77-S3, AC6): legacy adapter-dir mode JSON shape unchanged (no probe_state, no severity)" {
  local fake_path; fake_path="$(fake_tool_dir eslint 0)"
  write_adapter_json "$ADAPTER_DIR/adapter.json"
  write_run_sh "$ADAPTER_DIR/run.sh" 0
  printf 'src/app.ts\n' > "$FILE_LIST"

  PATH="$fake_path:$PATH" run "$SCRIPT" --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [ "$status" -eq 0 ]
  # Legacy four-key shape preserved exactly. No new keys leak into adapter-dir mode.
  echo "$output" | jq -e '(keys | sort) == (["error_detail","failure_kind","skip_reason","state"])' >/dev/null
  echo "$output" | jq -e 'has("probe_state") | not' >/dev/null
  echo "$output" | jq -e 'has("severity") | not' >/dev/null
}

# --- mutual exclusivity ---

@test "probe (E77-S3): --tool requires --config" {
  run -1 --separate-stderr "$SCRIPT" --tool shellcheck
  [[ "$stderr" == *"--config"* ]]
}

@test "probe (E77-S3): --tool and --adapter-dir are mutually exclusive" {
  local cfg="$TEST_TMP/project-config.yaml"
  write_project_config "$cfg" "claude-code-plugin" "tool_adapters: {}"
  run -1 --separate-stderr "$SCRIPT" \
    --tool shellcheck --config "$cfg" \
    --adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST"
  [[ "$stderr" == *"mutually exclusive"* || "$stderr" == *"--adapter-dir"* ]]
}

@test "probe (E77-S3): --config without tool_adapters block treats every tool as omitted" {
  local cfg="$TEST_TMP/project-config.yaml"
  cat > "$cfg" <<'EOF'
project_kind: claude-code-plugin
EOF

  run "$SCRIPT" --tool shellcheck --config "$cfg"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
