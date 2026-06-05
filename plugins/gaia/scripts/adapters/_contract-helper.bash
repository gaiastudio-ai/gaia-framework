#!/usr/bin/env bash
# _contract-helper.bash — shared bats helpers for per-adapter contract.bats.
#
# Each built-in adapter under plugins/gaia/scripts/adapters/{tool}/test/contract.bats sources
# this helper and calls `assert_contract <tool-name> <category-extension> <non-matching-extension>`
# inside its own bats file. The helper exercises all four probe states using fixture inputs:
#
#   - available           : tool installed (fake binary on PATH), files match, run.sh exits 0
#   - expected_and_missing: PATH stripped of the tool's binary
#   - ran_and_errored     : run.sh patched to exit 1 with stderr
#   - not_applicable      : file-list contains only files outside the adapter's extensions
#
# It also asserts that adapter.json and run.sh are present, executable, and that the JSON
# fragment shape conforms to the documented {state, skip_reason, error_detail, failure_kind} schema.

# Resolve the probe and the adapter dir for the calling .bats file.
# BATS_TEST_FILENAME -> .../scripts/adapters/{tool}/test/contract.bats
# adapter dir         -> .../scripts/adapters/{tool}/

contract_setup() {
  local test_dir
  test_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ADAPTER_DIR="$(cd "$test_dir/.." && pwd)"
  PLUGIN_SCRIPTS="$(cd "$ADAPTER_DIR/../.." && pwd)"
  PROBE="$PLUGIN_SCRIPTS/tool-availability-probe.sh"
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/contract-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP"
}

contract_teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# Make a fake binary on a private PATH dir; echo the dir.
_contract_fake_bin_dir() {
  local tool="$1"; local rc="${2:-0}"
  local d="$WORK_TMP/fakebin"
  mkdir -p "$d"
  cat > "$d/$tool" <<EOF
#!/usr/bin/env bash
exit $rc
EOF
  chmod +x "$d/$tool"
  printf '%s' "$d"
}

# Read the adapter's first declared file extension.
_contract_first_ext() {
  jq -r '
    if has("file-extensions") and (.["file-extensions"] | length > 0)
    then .["file-extensions"][0]
    else ""
    end
  ' "$ADAPTER_DIR/adapter.json"
}

# Read the adapter's provider field (binary name).
_contract_provider() {
  jq -r '.provider // ""' "$ADAPTER_DIR/adapter.json"
}

# assert_files_exist — verify the canonical adapter file layout.
assert_files_exist() {
  [ -f "$ADAPTER_DIR/adapter.json" ] || { echo "missing adapter.json" >&2; return 1; }
  [ -x "$ADAPTER_DIR/run.sh" ]       || { echo "run.sh missing or not executable" >&2; return 1; }
  jq -e . "$ADAPTER_DIR/adapter.json" >/dev/null || { echo "adapter.json is not valid JSON" >&2; return 1; }
}

# assert_state — invoke the probe under controlled conditions and assert the resulting state.
# Args: <tool> <state-expected> <ext-or-empty> <patched-rc> <patched-stderr> <patched-sleep> [extra-flags...]
# When <ext-or-empty> is the literal string "EMPTY_FILE_LIST", the file-list will be empty
# (used by project-scope adapters whose not-applicable trigger is "no files to scan").
assert_state() {
  local tool="$1"; local expected="$2"; local ext="$3"; local rc="$4"; local err="$5"; local sleep_s="$6"; shift 6
  local file_list="$WORK_TMP/files.txt"
  if [ "$ext" = "EMPTY_FILE_LIST" ]; then
    : > "$file_list"
  elif [ -n "$ext" ]; then
    printf 'src/example%s\n' "$ext" > "$file_list"
  else
    printf 'src/main.unrelated\n' > "$file_list"
  fi

  # Stage a tmp adapter dir mirroring real adapter.json but with a patched run.sh.
  local stage="$WORK_TMP/stage"
  mkdir -p "$stage"
  cp "$ADAPTER_DIR/adapter.json" "$stage/adapter.json"
  cat > "$stage/run.sh" <<EOF
#!/usr/bin/env bash
set -u
if [ "$sleep_s" -gt 0 ]; then sleep "$sleep_s"; fi
if [ -n "$err" ]; then printf '%s\n' "$err" >&2; fi
exit $rc
EOF
  chmod +x "$stage/run.sh"

  local fake_dir; fake_dir="$(_contract_fake_bin_dir "$tool" 0)"
  local probe_path
  case "$expected" in
    expected_and_missing)
      # Mutate the adapter.json to declare a provider that nothing on PATH
      # could possibly satisfy — keeps the system PATH (jq, timeout, sh)
      # available while guaranteeing the binary lookup fails.
      jq --arg p "${tool}-not-real-xyz-$$" '.provider = $p' "$stage/adapter.json" > "$stage/adapter.json.tmp"
      mv "$stage/adapter.json.tmp" "$stage/adapter.json"
      probe_path="$PATH"
      ;;
    *)
      probe_path="$fake_dir:$PATH"
      ;;
  esac

  PATH="$probe_path" run --separate-stderr "$PROBE" --adapter-dir "$stage" --file-list "$file_list" "$@"

  echo "$output" | jq -e ". | (.state == \"$expected\")" >/dev/null
}

# assert_fragment_shape — assert the probe stdout JSON has the canonical keys.
# Schema is four keys -- failure_kind is additive.
assert_fragment_shape() {
  echo "$output" | jq -e '(keys | sort) == (["error_detail","failure_kind","skip_reason","state"])' >/dev/null
}
