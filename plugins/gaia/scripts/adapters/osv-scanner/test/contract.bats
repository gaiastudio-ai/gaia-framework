#!/usr/bin/env bats
# adapters/osv-scanner/test/contract.bats — four-state probe parity test.
#
# Project-scope adapter: file-extensions is empty, so the probe classifies
# by non-empty file list (available/expected_and_missing/ran_and_errored)
# vs empty file list (not_applicable).

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "osv-scanner contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "osv-scanner contract: state=available when tool on PATH and matching files" {
  printf 'src/go.mod\n' > "$WORK_TMP/files.txt"
  local fake_dir; fake_dir="$(_contract_fake_bin_dir "$(_contract_provider)" 0)"
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage"
  cp "$ADAPTER_DIR/adapter.json" "$stage/adapter.json"
  cat > "$stage/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -u
exit 0
RUNEOF
  chmod +x "$stage/run.sh"
  PATH="$fake_dir:$PATH" run --separate-stderr "$PROBE" --adapter-dir "$stage" --file-list "$WORK_TMP/files.txt"
  echo "$output" | jq -e '.state == "available"' >/dev/null
  assert_fragment_shape
}

@test "osv-scanner contract: state=expected_and_missing when tool absent from PATH" {
  # Project-scope: must have a non-empty file list to reach the availability check.
  printf 'src/go.mod\n' > "$WORK_TMP/files.txt"
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage"
  cp "$ADAPTER_DIR/adapter.json" "$stage/adapter.json"
  # Rename provider to a non-existent binary.
  jq --arg p "osv-scanner-not-real-xyz-$$" '.provider = $p' "$stage/adapter.json" > "$stage/adapter.json.tmp"
  mv "$stage/adapter.json.tmp" "$stage/adapter.json"
  cat > "$stage/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
exit 0
RUNEOF
  chmod +x "$stage/run.sh"
  run --separate-stderr "$PROBE" --adapter-dir "$stage" --file-list "$WORK_TMP/files.txt"
  echo "$output" | jq -e '.state == "expected_and_missing"' >/dev/null
  assert_fragment_shape
}

@test "osv-scanner contract: state=ran_and_errored when run.sh exits non-zero" {
  printf 'src/go.mod\n' > "$WORK_TMP/files.txt"
  local fake_dir; fake_dir="$(_contract_fake_bin_dir "$(_contract_provider)" 0)"
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage"
  cp "$ADAPTER_DIR/adapter.json" "$stage/adapter.json"
  cat > "$stage/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -u
echo "adapter crash" >&2
exit 1
RUNEOF
  chmod +x "$stage/run.sh"
  PATH="$fake_dir:$PATH" run --separate-stderr "$PROBE" --adapter-dir "$stage" --file-list "$WORK_TMP/files.txt"
  echo "$output" | jq -e '.state == "ran_and_errored"' >/dev/null
  assert_fragment_shape
}

@test "osv-scanner contract: state=not_applicable when file-list is empty" {
  : > "$WORK_TMP/files.txt"
  local fake_dir; fake_dir="$(_contract_fake_bin_dir "$(_contract_provider)" 0)"
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage"
  cp "$ADAPTER_DIR/adapter.json" "$stage/adapter.json"
  cat > "$stage/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
exit 0
RUNEOF
  chmod +x "$stage/run.sh"
  PATH="$fake_dir:$PATH" run --separate-stderr "$PROBE" --adapter-dir "$stage" --file-list "$WORK_TMP/files.txt"
  echo "$output" | jq -e '.state == "not_applicable"' >/dev/null
  assert_fragment_shape
}
