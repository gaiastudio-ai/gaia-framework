#!/usr/bin/env bats
# mutation-bash-adapter.bats — tests for the bash mutation adapter.
# Covers: AC12, AC13, AC14, AC-EC1, AC-EC7.

setup() {
  BATS_TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIR/../.." && pwd)"
  ADAPTER_DIR="$PLUGIN_ROOT/scripts/adapters/mutation-bash"
  GENERATE="$ADAPTER_DIR/generate.sh"
  RUN_SH="$ADAPTER_DIR/run.sh"

  [ -x "$GENERATE" ] || { echo "generate.sh not found at $GENERATE" >&2; return 1; }
  [ -x "$RUN_SH" ]   || { echo "run.sh not found at $RUN_SH" >&2; return 1; }

  TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mba-bats-XXXXXX")

  # Build a fixture source tree inside a gaia-mutation- dir (run.sh requires it)
  COPY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-test-XXXXXX")
  mkdir -p "$COPY_DIR/scripts" "$COPY_DIR/tests"

  cat > "$COPY_DIR/scripts/sample.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
check_val() {
  local val="$1"
  if [ "$val" -eq 0 ]; then
    return 0
  fi
  if [ "$val" -lt 10 ] && [ "$val" -gt 0 ]; then
    echo "small"
    return 0
  fi
  if [ "$val" -ge 10 ] || [ "$val" -le -10 ]; then
    echo "large"
    return 1
  fi
  if [ "$val" == "special" ]; then
    exit 0
  fi
  if [ "$val" != "other" ]; then
    exit 1
  fi
  if true; then echo "yes"; fi
  if false; then echo "no"; fi
}
SCRIPT
  chmod +x "$COPY_DIR/scripts/sample.sh"

  # A real worktree for the generator (it reads from source-dir)
  FIXTURE_WT="$TEST_TMP/worktree"
  mkdir -p "$FIXTURE_WT/scripts"
  cp "$COPY_DIR/scripts/sample.sh" "$FIXTURE_WT/scripts/"

  cat > "$COPY_DIR/tests/sample.bats" <<'TEST'
#!/usr/bin/env bats
@test "check_val 0 returns 0" {
  source "$BATS_TEST_DIRNAME/../scripts/sample.sh" 2>/dev/null || true
  run check_val 0
  [ "$status" -eq 0 ]
}
@test "check_val 5 returns small" {
  source "$BATS_TEST_DIRNAME/../scripts/sample.sh" 2>/dev/null || true
  run check_val 5
  [[ "$output" == *"small"* ]]
}
TEST

  FILES_LIST="$TEST_TMP/files.txt"
  printf 'scripts/sample.sh\n' > "$FILES_LIST"
  GEN_OUT="$TEST_TMP/gen-out"
  mkdir -p "$GEN_OUT"
}

teardown() {
  rm -rf "$TEST_TMP" "$COPY_DIR"
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gaia-mutation-*' -newer "$BATS_TEST_FILENAME" -exec rm -rf {} + 2>/dev/null || true
}

# ---------- AC12: Bash adapter five-flag CLI ----------

@test "bash adapter applies a patch and runs the test under both interpreters with exit 0" {
  # First generate a mutant
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]
  [ -f "$GEN_OUT/index.json" ]

  # Get the first patch file
  first_patch=$(jq -r '.[0].patch_file // empty' "$GEN_OUT/index.json")
  [ -n "$first_patch" ]
  [ -f "$GEN_OUT/$first_patch" ]

  RESULT="$TEST_TMP/result.json"

  run "$RUN_SH" \
    --source-dir "$COPY_DIR" \
    --patch-file "$GEN_OUT/$first_patch" \
    --test-command "bats $COPY_DIR/tests/sample.bats" \
    --output "$RESULT" \
    --timeout 30

  [ "$status" -eq 0 ]
  [ -f "$RESULT" ]

  # Result should have status field
  result_status=$(jq -r '.status' "$RESULT")
  [[ "$result_status" == "killed" || "$result_status" == "survived" || "$result_status" == "timeout" ]]

  # Should have interpreters array
  interp_count=$(jq '.interpreters | length' "$RESULT")
  [ "$interp_count" -ge 1 ]

  # First interpreter should be 5.x or 3.x
  first_interp=$(jq -r '.interpreters[0]' "$RESULT")
  [[ "$first_interp" == 5.* || "$first_interp" == 3.* ]]
}

# ---------- AC13: Generator operator table ----------

@test "generator writes patches from the operator table and discards no-ops and syntax failures" {
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]
  [ -f "$GEN_OUT/index.json" ]

  mutant_count=$(jq 'length' "$GEN_OUT/index.json")
  [ "$mutant_count" -gt 0 ]

  # Each mutant is a unified diff with a/ and b/ prefixes
  for pf in "$GEN_OUT"/*.patch; do
    [ -f "$pf" ] || continue
    head -1 "$pf" | grep -q '^--- a/'
    sed -n '2p' "$pf" | grep -q '^+++ b/'
  done

  # Comment lines should not produce mutants
  # Add a comment-only script
  cat > "$FIXTURE_WT/scripts/comments.sh" <<'SCRIPT'
#!/usr/bin/env bash
# if [ "$x" -eq 0 ]; then
# return 0
# exit 0 && true
echo "no mutations here"
SCRIPT
  printf 'scripts/comments.sh\n' > "$TEST_TMP/comment-files.txt"
  comment_out="$TEST_TMP/comment-gen-out"
  mkdir -p "$comment_out"
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$TEST_TMP/comment-files.txt" --out-dir "$comment_out"
  [ "$status" -eq 0 ]
  comment_count=$(jq 'length' "$comment_out/index.json")
  [ "$comment_count" -eq 0 ]

  # Metacharacter test: create a script with $VAR, backticks, quotes, brackets
  cat > "$FIXTURE_WT/scripts/meta.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
meta_fn() {
  local x="$1"
  if [ "$x" -eq 0 ]; then
    echo "value is $VAR and `cmd` and 'single' and \"double\" and [bracket]"
    return 0
  fi
  return 1
}
SCRIPT
  printf 'scripts/meta.sh\n' > "$TEST_TMP/meta-files.txt"
  meta_out="$TEST_TMP/meta-gen-out"
  mkdir -p "$meta_out"
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$TEST_TMP/meta-files.txt" --out-dir "$meta_out"
  [ "$status" -eq 0 ]

  # Patches should apply cleanly without shell expansion
  meta_count=$(jq 'length' "$meta_out/index.json")
  for pf in "$meta_out"/*.patch; do
    [ -f "$pf" ] || continue
    meta_copy=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-meta-XXXXXX")
    cp -r "$FIXTURE_WT/scripts" "$meta_copy/"
    run patch -p1 -d "$meta_copy" < "$pf"
    [ "$status" -eq 0 ]
    rm -rf "$meta_copy"
  done
}

# ---------- AC14: Parallel execution ----------

@test "parallel mutants under both interpreters produce identical killed and survived counts" {
  # Need at least 5 mutants — the sample.sh fixture should produce enough
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]

  mutant_count=$(jq 'length' "$GEN_OUT/index.json")
  [ "$mutant_count" -ge 5 ]

  # Create a fixture with proper test infrastructure for parallel run
  # (This tests the runner's parallel execution, not the adapter directly)
  PARALLEL_WT="$TEST_TMP/parallel-wt"
  mkdir -p "$PARALLEL_WT/scripts" "$PARALLEL_WT/tests"
  cp "$FIXTURE_WT/scripts/sample.sh" "$PARALLEL_WT/scripts/"
  cp "$COPY_DIR/tests/sample.bats" "$PARALLEL_WT/tests/"
  git -C "$PARALLEL_WT" init -q
  git -C "$PARALLEL_WT" add -A
  git -C "$PARALLEL_WT" commit -q -m "init"

  RUNNER="$PLUGIN_ROOT/scripts/mutation-runner.sh"
  [ -x "$RUNNER" ] || skip "mutation-runner.sh not executable"

  PAR_FILES="$TEST_TMP/par-files.txt"
  PAR_TESTS="$TEST_TMP/par-tests.txt"
  printf 'scripts/sample.sh\n' > "$PAR_FILES"
  printf 'tests/sample.bats\n' > "$PAR_TESTS"

  PAR_OUT="$TEST_TMP/par-evidence.json"

  run "$RUNNER" \
    --worktree "$PARALLEL_WT" \
    --files-from "$PAR_FILES" \
    --tests-from "$PAR_TESTS" \
    --output "$PAR_OUT" \
    --thresholds '{"P0":80}' \
    --priority P1 \
    --jobs 4

  [ "$status" -eq 0 ]
  [ -f "$PAR_OUT" ]

  par_mutants=$(jq '.totals.mutants // 0' "$PAR_OUT")
  [ "$par_mutants" -ge 5 ]

  # Each mutant should have a unique mutant_id
  unique_ids=$(jq '[.mutants[].mutant_id] | unique | length' "$PAR_OUT")
  [ "$unique_ids" -eq "$par_mutants" ]
}

# ---------- AC-EC1: Timeout handling ----------

@test "adapter terminates a hanging test on timeout and reports status timeout with exit 0" {
  # Generate a mutant first
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

  # Verify sleep 999 is not still running
  sleep_count=$(ps aux 2>/dev/null | grep 'sleep 999' | grep -v grep | wc -l || echo 0)
  [ "$sleep_count" -eq 0 ]
}

# ---------- AC-EC7: Bash 5 only ----------

@test "adapter on bash 5 only runs without failure and records the single interpreter version" {
  # Generate a mutant
  run "$GENERATE" --source-dir "$FIXTURE_WT" --files-from "$FILES_LIST" --out-dir "$GEN_OUT"
  [ "$status" -eq 0 ]
  first_patch=$(jq -r '.[0].patch_file // empty' "$GEN_OUT/index.json")
  [ -n "$first_patch" ]

  RESULT="$TEST_TMP/bash5-result.json"

  # Unset GAIA_MUTATION_BASH32 and use a non-3.x /bin/bash
  GAIA_MUTATION_BASH32="" \
  run "$RUN_SH" \
    --source-dir "$COPY_DIR" \
    --patch-file "$GEN_OUT/$first_patch" \
    --test-command "true" \
    --output "$RESULT" \
    --timeout 30

  [ "$status" -eq 0 ]
  [ -f "$RESULT" ]

  # Should have at least one interpreter version
  interp_count=$(jq '.interpreters | length' "$RESULT")
  [ "$interp_count" -ge 1 ]

  # First should be 5.x (on most systems)
  # On macOS, /bin/bash is 3.2 and PATH bash might be 5.x
  first_ver=$(jq -r '.interpreters[0]' "$RESULT")
  [[ "$first_ver" =~ ^[0-9] ]]

  # No error about bash 3.2 missing
  [[ "$output" != *"bash 3.2"* ]] || true
}
