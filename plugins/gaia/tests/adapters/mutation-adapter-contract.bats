#!/usr/bin/env bats
# mutation-adapter-contract.bats — parameterised contract harness for every
# mutation adapter under scripts/adapters/mutation-*/.
#
# Discovers each adapter directory dynamically and checks:
# - the five-flag CLI (--source-dir, --patch-file, --test-command, --output, --timeout)
# - output record shape (status, test_output)
# - exit 0 when all mutants survive
# - timeout status when the test exceeds --timeout
# Each adapter supplies its own fixtures under test/fixtures/.

load '../test_helper.bash'

setup() {
  BATS_TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIR/../.." && pwd)"
  SCRIPTS="$PLUGIN_ROOT/scripts"
  ADAPTER_BASE="$SCRIPTS/adapters"
  TEST_TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/mac-bats-XXXXXX")" && pwd -P)"
  # A shared TMPDIR would put other runs' directories within reach of this suite.
  export TMPDIR="$TEST_TMP/tmp"
  mkdir -p "$TMPDIR"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- Discover adapters ----------

_list_adapters() {
  local d
  for d in "$ADAPTER_BASE"/mutation-*/; do
    [ -d "$d" ] || continue
    [ -f "$d/mutation-adapter.json" ] || continue
    [ -x "$d/generate.sh" ] || continue
    [ -x "$d/run.sh" ] || continue
    printf '%s\n' "$d"
  done
}

# _assert_all_exercised <count> — every adapter that ships fixtures must have
# been driven end to end; a silently skipped adapter fails the contract.
_assert_all_exercised() {
  local want=0 d
  while IFS= read -r d; do
    [ -d "${d%/}/test/fixtures" ] && want=$((want + 1))
  done < <(_list_adapters)
  [ "$want" -gt 0 ] || { echo "FAIL: no adapters with fixtures found"; return 1; }
  [ "$1" -eq "$want" ] || { echo "FAIL: exercised $1 of $want adapters"; return 1; }
}

# _adapter_path <adapter_dir> — PATH for calling an adapter. An adapter that
# ships tool stubs under test/fixtures/stubs/bin gets them first on PATH, so
# the contract exercises it even where the real mutation tool is absent.
_adapter_path() {
  local stubs="${1%/}/test/fixtures/stubs/bin"
  if [ -d "$stubs" ]; then
    printf '%s:%s' "$stubs" "$PATH"
  else
    printf '%s' "$PATH"
  fi
}

# ---------- Contract: manifest validates ----------

@test "every mutation adapter has a valid manifest with required fields" {
  while IFS= read -r adapter_dir; do
    [ -n "$adapter_dir" ] || continue
    local name
    name=$(basename "$adapter_dir")
    local manifest="$adapter_dir/mutation-adapter.json"

    # Required fields
    jq -e '.provider' "$manifest" >/dev/null 2>&1 || { echo "FAIL: $name missing .provider"; return 1; } # lint-pack:allow spliced-yq-jq — static jq program, file path is an argument
    jq -e '.["file-extensions"]' "$manifest" >/dev/null 2>&1 || { echo "FAIL: $name missing .file-extensions"; return 1; } # lint-pack:allow spliced-yq-jq — static jq program, file path is an argument
    jq -e '.["default-timeout-seconds"]' "$manifest" >/dev/null 2>&1 || { echo "FAIL: $name missing .default-timeout-seconds"; return 1; } # lint-pack:allow spliced-yq-jq — static jq program, file path is an argument
    jq -e '.["mutant-format"]' "$manifest" >/dev/null 2>&1 || { echo "FAIL: $name missing .mutant-format"; return 1; } # lint-pack:allow spliced-yq-jq — static jq program, file path is an argument

    # mutant-format must be patch or tool-native
    local fmt
    fmt=$(jq -r '.["mutant-format"]' "$manifest")
    case "$fmt" in
      patch|tool-native) ;;
      *) echo "FAIL: $name has invalid mutant-format: $fmt"; return 1 ;;
    esac
  done < <(_list_adapters)
}

# ---------- Contract: five-flag CLI ----------

@test "every mutation adapter run.sh accepts the five-flag CLI and exits 0 on survived" {
  local exercised=0
  while IFS= read -r adapter_dir; do
    [ -n "$adapter_dir" ] || continue
    local name
    name=$(basename "$adapter_dir")
    local gen="$adapter_dir/generate.sh"
    local runner="$adapter_dir/run.sh"
    local fixture_dir="$adapter_dir/test/fixtures"

    # Need fixtures
    [ -d "$fixture_dir" ] || { echo "SKIP: $name has no test/fixtures/"; continue; }

    # Build a source dir for the generator
    local src_dir="$TEST_TMP/${name}-src"
    mkdir -p "$src_dir"
    cp -r "$fixture_dir"/. "$src_dir/" 2>/dev/null || true

    # Find source files by extension from the manifest
    local extensions
    extensions=$(jq -r '.["file-extensions"][]' "$adapter_dir/mutation-adapter.json" 2>/dev/null || true)
    local files_list="$TEST_TMP/${name}-files.txt"
    : > "$files_list"
    for ext in $extensions; do
      find "$src_dir" -name "*${ext}" -type f 2>/dev/null | while IFS= read -r f; do
        printf '%s\n' "${f#"$src_dir/"}" >> "$files_list"
      done
    done
    [ -s "$files_list" ] || { echo "SKIP: $name has no fixture source files"; continue; }

    # Generate mutants
    local gen_out="$TEST_TMP/${name}-gen"
    mkdir -p "$gen_out"
    local apath
    apath=$(_adapter_path "$adapter_dir")
    run env PATH="$apath" "$gen" --source-dir "$src_dir" --files-from "$files_list" --out-dir "$gen_out"
    [ "$status" -eq 0 ] || { echo "FAIL: $name generate.sh exited $status"; return 1; }
    [ -f "$gen_out/index.json" ] || { echo "FAIL: $name generate.sh produced no index.json"; return 1; }

    # Get the first patch
    local first_patch
    first_patch=$(jq -r '.[0].patch_file // empty' "$gen_out/index.json" 2>/dev/null || true)
    [ -n "$first_patch" ] || { echo "FAIL: $name generated zero mutants"; return 1; }

    # Create a throwaway copy (inside a gaia-mutation- prefix for containment)
    local copy_dir
    copy_dir=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-contract-XXXXXX")
    cp -rL "$src_dir"/. "$copy_dir/" 2>/dev/null || true

    # Run with --test-command "true" (mutant survives)
    local result="$TEST_TMP/${name}-result.json"
    run env PATH="$apath" "$runner" \
      --source-dir "$copy_dir" \
      --patch-file "$gen_out/$first_patch" \
      --test-command "true" \
      --output "$result" \
      --timeout 10

    rm -rf "$copy_dir"

    [ "$status" -eq 0 ] || { echo "FAIL: $name run.sh exited $status (expected 0 on survived)"; return 1; }
    [ -f "$result" ] || { echo "FAIL: $name run.sh wrote no output"; return 1; }

    # Validate output record shape
    jq -e '.status' "$result" >/dev/null 2>&1 || { echo "FAIL: $name result missing .status"; return 1; } # lint-pack:allow spliced-yq-jq — static jq program, file path is an argument
    local s
    s=$(jq -r '.status' "$result")
    [ "$s" = "survived" ] || { echo "FAIL: $name expected survived, got $s"; return 1; }
    exercised=$((exercised + 1))
  done < <(_list_adapters)
  _assert_all_exercised "$exercised"
}

# ---------- Contract: baseline call and outcome honesty ----------

@test "every mutation adapter runs a zero-byte patch unmutated, inside the copy, and tells failure from cannot-run" {
  local checked=0
  while IFS= read -r adapter_dir; do
    [ -n "$adapter_dir" ] || continue
    [ "$(jq -r '.["mutant-format"]' "$adapter_dir/mutation-adapter.json")" = "patch" ] || continue
    local copy_dir result="$TEST_TMP/outcome.json" empty="$TEST_TMP/empty.patch"
    copy_dir=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-contract-XXXXXX")
    : > "$empty"

    run "$adapter_dir/run.sh" --source-dir "$copy_dir" --patch-file "$empty" --test-command 'pwd -P > here.txt' --output "$result" --timeout 10
    [ "$status" -eq 0 ]
    [ "$(jq -r .status "$result")" = "survived" ]
    [ "$(cat "$copy_dir/here.txt")" = "$(cd "$copy_dir" && pwd -P)" ]

    run "$adapter_dir/run.sh" --source-dir "$copy_dir" --patch-file "$empty" --test-command 'exit 1' --output "$result" --timeout 10
    [ "$status" -eq 0 ]
    [ "$(jq -r .status "$result")" = "killed" ]

    run "$adapter_dir/run.sh" --source-dir "$copy_dir" --patch-file "$empty" --test-command 'exit 127' --output "$result" --timeout 10
    [ "$status" -eq 0 ]
    [ "$(jq -r .status "$result")" = "error" ]

    rm -rf "$copy_dir"
    checked=$((checked + 1))
  done < <(_list_adapters)
  [ "$checked" -gt 0 ]
}

# ---------- Contract: timeout handling ----------

@test "every mutation adapter reports timeout status when test exceeds deadline" {
  local exercised=0
  while IFS= read -r adapter_dir; do
    [ -n "$adapter_dir" ] || continue
    local name
    name=$(basename "$adapter_dir")
    local gen="$adapter_dir/generate.sh"
    local runner="$adapter_dir/run.sh"
    local fixture_dir="$adapter_dir/test/fixtures"
    [ -d "$fixture_dir" ] || continue

    # Build source dir and generate
    local src_dir="$TEST_TMP/${name}-to-src"
    mkdir -p "$src_dir"
    cp -r "$fixture_dir"/. "$src_dir/" 2>/dev/null || true
    local extensions
    extensions=$(jq -r '.["file-extensions"][]' "$adapter_dir/mutation-adapter.json" 2>/dev/null || true)
    local files_list="$TEST_TMP/${name}-to-files.txt"
    : > "$files_list"
    for ext in $extensions; do
      find "$src_dir" -name "*${ext}" -type f 2>/dev/null | while IFS= read -r f; do
        printf '%s\n' "${f#"$src_dir/"}" >> "$files_list"
      done
    done
    [ -s "$files_list" ] || continue

    local gen_out="$TEST_TMP/${name}-to-gen"
    mkdir -p "$gen_out"
    local apath
    apath=$(_adapter_path "$adapter_dir")
    PATH="$apath" "$gen" --source-dir "$src_dir" --files-from "$files_list" --out-dir "$gen_out" 2>/dev/null \
      || { echo "FAIL: $name generate.sh failed"; return 1; }
    local first_patch
    first_patch=$(jq -r '.[0].patch_file // empty' "$gen_out/index.json" 2>/dev/null || true)
    [ -n "$first_patch" ] || { echo "FAIL: $name generated zero mutants"; return 1; }

    local copy_dir
    copy_dir=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-contract-XXXXXX")
    cp -rL "$src_dir"/. "$copy_dir/" 2>/dev/null || true

    local result="$TEST_TMP/${name}-to-result.json"
    run env PATH="$apath" "$runner" \
      --source-dir "$copy_dir" \
      --patch-file "$gen_out/$first_patch" \
      --test-command "sleep 999" \
      --output "$result" \
      --timeout 2

    rm -rf "$copy_dir"

    [ "$status" -eq 0 ] || { echo "FAIL: $name run.sh exited $status on timeout (expected 0)"; return 1; }
    [ -f "$result" ] || { echo "FAIL: $name run.sh wrote no output on timeout"; return 1; }
    local ts
    ts=$(jq -r '.status' "$result" 2>/dev/null || true)
    [ "$ts" = "timeout" ] || { echo "FAIL: $name expected timeout, got $ts"; return 1; }
    exercised=$((exercised + 1))
  done < <(_list_adapters)
  _assert_all_exercised "$exercised"
}

# ---------- this suite and other runs ----------

@test "this suite works in its own TMPDIR and its teardown leaves other runs' directories alone" {
  [[ "$TMPDIR" == "$TEST_TMP"/* ]]
  local shared="$TEST_TMP/shared"
  mkdir -p "$shared/gaia-mutation-another-run"
  # Only the guard belongs in the subshell: everything else it would remove is
  # pointed elsewhere, so the real teardown still runs afterwards.
  ( export TMPDIR="$shared"; TEST_TMP="$shared/mine"; COPY_DIR="$shared/mine-copy"; teardown )
  [ -d "$shared/gaia-mutation-another-run" ]
}
