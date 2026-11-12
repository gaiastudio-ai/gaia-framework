#!/usr/bin/env bats
# mutation-go-adapter.bats — tests for the Go mutation adapter.
#
# Uses stub go-mutesting and stub go binaries from test/fixtures/stubs/bin/
# so CI runs without the real Go toolchain.

load '../test_helper.bash'

setup() {
  BATS_TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIR/../.." && pwd)"
  ADAPTER_DIR="$PLUGIN_ROOT/scripts/adapters/mutation-go"
  GENERATE="$ADAPTER_DIR/generate.sh"
  RUN_SH="$ADAPTER_DIR/run.sh"
  CAPTURE="$ADAPTER_DIR/capture-mutant.sh"
  STUBS_BIN="$ADAPTER_DIR/test/fixtures/stubs/bin"
  FIXTURE_DIR="$ADAPTER_DIR/test/fixtures"

  [ -x "$GENERATE" ] || { echo "generate.sh not found at $GENERATE" >&2; return 1; }
  [ -x "$RUN_SH" ]   || { echo "run.sh not found at $RUN_SH" >&2; return 1; }

  TEST_TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/mga-bats-XXXXXX")" && pwd -P)"
  export TMPDIR="$TEST_TMP/tmp"
  mkdir -p "$TMPDIR"

  # Build a source dir from fixtures inside a gaia-mutation- prefix
  COPY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-test-XXXXXX")
  cp -r "$FIXTURE_DIR"/. "$COPY_DIR/" 2>/dev/null || true

  # A separate worktree for the generator (not inside gaia-mutation-)
  FIXTURE_WT="$TEST_TMP/worktree"
  mkdir -p "$FIXTURE_WT"
  cp -r "$FIXTURE_DIR"/. "$FIXTURE_WT/"

  FILES_LIST="$TEST_TMP/files.txt"
  printf 'calc/calc.go\n' > "$FILES_LIST"
  GEN_OUT="$TEST_TMP/gen-out"
  mkdir -p "$GEN_OUT"
}

teardown() {
  rm -rf "$TEST_TMP" "$COPY_DIR"
}

# ---------- Generation through the capture hook (scenario 2) ----------

@test "go adapter generates patches via capture hook with stub go-mutesting" {
  PATH="$STUBS_BIN:$PATH" \
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]
  [ -f "$GEN_OUT/index.json" ]

  mutant_count=$(jq 'length' "$GEN_OUT/index.json")
  [ "$mutant_count" -gt 0 ]

  # Each mutant is a unified diff with a/ and b/ prefixes
  for pf in "$GEN_OUT"/*.patch; do
    [ -f "$pf" ] || continue
    first_line=$(head -1 "$pf")
    second_line=$(sed -n '2p' "$pf")
    [[ "$first_line" == "--- a/"* ]]
    [[ "$second_line" == "+++ b/"* ]]
  done

  # Patches must apply cleanly with patch -p1 (scenario 7 partial)
  first_patch=$(jq -r '.[0].patch_file // empty' "$GEN_OUT/index.json")
  [ -n "$first_patch" ]
  apply_dir=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-apply-XXXXXX")
  cp -r "$FIXTURE_WT"/. "$apply_dir/"
  run patch -p1 -d "$apply_dir" < "$GEN_OUT/$first_patch"
  [ "$status" -eq 0 ]
  rm -rf "$apply_dir"

  # Index entries have required fields
  jq -e '.[0].mutant_id' "$GEN_OUT/index.json" >/dev/null 2>&1
  jq -e '.[0].patch_file' "$GEN_OUT/index.json" >/dev/null 2>&1
  jq -e '.[0].file' "$GEN_OUT/index.json" >/dev/null 2>&1
  jq -e '.[0].line' "$GEN_OUT/index.json" >/dev/null 2>&1
  jq -e '.[0].operator' "$GEN_OUT/index.json" >/dev/null 2>&1
}

# ---------- Five-flag CLI conformance (scenario 1) ----------

@test "go adapter run.sh accepts five flags and exits 0 on survived" {
  PATH="$STUBS_BIN:$PATH" \
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]

  first_patch=$(jq -r '.[0].patch_file // empty' "$GEN_OUT/index.json")
  [ -n "$first_patch" ]

  RESULT="$TEST_TMP/result.json"

  run "$RUN_SH" \
    --source-dir "$COPY_DIR" \
    --patch-file "$GEN_OUT/$first_patch" \
    --test-command "true" \
    --output "$RESULT" \
    --timeout 60

  [ "$status" -eq 0 ]
  [ -f "$RESULT" ]

  result_status=$(jq -r '.status' "$RESULT")
  [ "$result_status" = "survived" ]

  # Output record has the contract fields
  jq -e '.status' "$RESULT" >/dev/null 2>&1
  jq -e '.test_output' "$RESULT" >/dev/null 2>&1
}

# ---------- Killed mutant with test name extraction (scenario 3) ----------

@test "go adapter reports killed status and extracts test names from go test output" {
  PATH="$STUBS_BIN:$PATH" \
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]

  first_patch=$(jq -r '.[0].patch_file // empty' "$GEN_OUT/index.json")
  [ -n "$first_patch" ]

  RESULT="$TEST_TMP/killed-result.json"

  # The test command prints Go test output with a FAIL line and exits 1
  run "$RUN_SH" \
    --source-dir "$COPY_DIR" \
    --patch-file "$GEN_OUT/$first_patch" \
    --test-command 'printf "=== RUN   TestAddPositive\n--- FAIL: TestAddPositive (0.00s)\n    calc_test.go:7: Add(1, 2) = -1, want 3\nFAIL\n"; exit 1' \
    --output "$RESULT" \
    --timeout 60

  [ "$status" -eq 0 ]
  [ -f "$RESULT" ]

  result_status=$(jq -r '.status' "$RESULT")
  [ "$result_status" = "killed" ]

  # killed_by should contain the failing test name
  kb_count=$(jq '.killed_by | length' "$RESULT")
  [ "$kb_count" -ge 1 ]
  first_kb=$(jq -r '.killed_by[0]' "$RESULT")
  [ "$first_kb" = "TestAddPositive" ]
}

# ---------- Survived mutant (scenario 4) ----------

@test "go adapter reports survived status and exits 0 when tests pass" {
  PATH="$STUBS_BIN:$PATH" \
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]

  first_patch=$(jq -r '.[0].patch_file // empty' "$GEN_OUT/index.json")
  [ -n "$first_patch" ]

  RESULT="$TEST_TMP/survived-result.json"

  # All tests pass — mutant survived
  run "$RUN_SH" \
    --source-dir "$COPY_DIR" \
    --patch-file "$GEN_OUT/$first_patch" \
    --test-command 'printf "=== RUN   TestAddPositive\n--- PASS: TestAddPositive (0.00s)\nPASS\n"; exit 0' \
    --output "$RESULT" \
    --timeout 60

  [ "$status" -eq 0 ]
  [ -f "$RESULT" ]

  result_status=$(jq -r '.status' "$RESULT")
  [ "$result_status" = "survived" ]
}

# ---------- Timeout handling (scenario 5) ----------

@test "go adapter terminates a hanging test on timeout and reports status timeout" {
  PATH="$STUBS_BIN:$PATH" \
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]

  first_patch=$(jq -r '.[0].patch_file // empty' "$GEN_OUT/index.json")
  [ -n "$first_patch" ]

  RESULT="$TEST_TMP/timeout-result.json"

  run "$RUN_SH" \
    --source-dir "$COPY_DIR" \
    --patch-file "$GEN_OUT/$first_patch" \
    --test-command "sleep 999" \
    --output "$RESULT" \
    --timeout 2

  [ "$status" -eq 0 ]
  [ -f "$RESULT" ]

  timeout_status=$(jq -r '.status' "$RESULT")
  [ "$timeout_status" = "timeout" ]
}

# ---------- Missing tool (scenario 6) ----------

@test "go adapter generate.sh exits non-zero when go-mutesting is missing" {
  # Build a PATH with only basic utilities — no go-mutesting.
  # Never save and reuse the parent PATH: rebuild from stub-free dirs
  # so the stub cannot leak through.
  _mga_clean_path=""
  for _mga_d in /usr/bin /bin /usr/sbin /sbin; do
    [ -d "$_mga_d" ] || continue
    if [ -z "$_mga_clean_path" ]; then
      _mga_clean_path="$_mga_d"
    else
      _mga_clean_path="${_mga_clean_path}:${_mga_d}"
    fi
  done

  PATH="$_mga_clean_path" \
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -ne 0 ]

  # The error message names the missing tool
  [[ "$output" == *"go-mutesting"* ]]
}

# ---------- Baseline: zero-byte patch ----------

@test "go adapter runs a zero-byte patch unmutated inside the copy" {
  empty_patch="$TEST_TMP/empty.patch"
  : > "$empty_patch"

  RESULT="$TEST_TMP/baseline-result.json"

  run "$RUN_SH" \
    --source-dir "$COPY_DIR" \
    --patch-file "$empty_patch" \
    --test-command 'pwd -P > here.txt' \
    --output "$RESULT" \
    --timeout 10

  [ "$status" -eq 0 ]

  result_status=$(jq -r '.status' "$RESULT")
  [ "$result_status" = "survived" ]

  # The command ran inside the copy dir
  [ -f "$COPY_DIR/here.txt" ]
  here_content=$(cat "$COPY_DIR/here.txt")
  copy_real=$(cd "$COPY_DIR" && pwd -P)
  [ "$here_content" = "$copy_real" ]
}

# ---------- Containment guard ----------

@test "go adapter run.sh refuses a source-dir outside gaia-mutation- root" {
  non_mutation_dir="$TEST_TMP/not-mutation-dir"
  mkdir -p "$non_mutation_dir"
  empty_patch="$TEST_TMP/empty2.patch"
  : > "$empty_patch"

  run "$RUN_SH" \
    --source-dir "$non_mutation_dir" \
    --patch-file "$empty_patch" \
    --test-command "true" \
    --output "$TEST_TMP/nope.json" \
    --timeout 10

  [ "$status" -ne 0 ]
  [[ "$output" == *"gaia-mutation-"* ]]
}

# ---------- Operator captured from go-mutesting output ----------

@test "go adapter captures operator names from go-mutesting output into index.json" {
  PATH="$STUBS_BIN:$PATH" \
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]

  # The stub go-mutesting produces expression/comparison and expression/arithmetic
  comp_ops=$(jq '[.[] | select(.operator | contains("expression"))] | length' "$GEN_OUT/index.json")
  [ "$comp_ops" -gt 0 ]
}

# ---------- Error status on test cannot-run ----------

@test "go adapter reports error status when the test command cannot be found" {
  empty_patch="$TEST_TMP/empty3.patch"
  : > "$empty_patch"

  RESULT="$TEST_TMP/error-result.json"

  run "$RUN_SH" \
    --source-dir "$COPY_DIR" \
    --patch-file "$empty_patch" \
    --test-command 'exit 127' \
    --output "$RESULT" \
    --timeout 10

  [ "$status" -eq 0 ]

  error_status=$(jq -r '.status' "$RESULT")
  [ "$error_status" = "error" ]
}

# ---------- TMPDIR isolation ----------

@test "this suite works in its own TMPDIR and its teardown leaves other runs' directories alone" {
  [[ "$TMPDIR" == "$TEST_TMP"/* ]]
  local shared="$TEST_TMP/shared"
  mkdir -p "$shared/gaia-mutation-another-run"
  ( export TMPDIR="$shared"; TEST_TMP="$shared/mine"; COPY_DIR="$shared/mine-copy"; teardown )
  [ -d "$shared/gaia-mutation-another-run" ]
}
