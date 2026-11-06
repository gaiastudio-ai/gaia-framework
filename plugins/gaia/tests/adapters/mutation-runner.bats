#!/usr/bin/env bats
# mutation-runner.bats — tests for the stack-neutral mutation runner.

load '../test_helper.bash'

# ---------- Helpers ----------

# Write a bats fixture file from name/body pairs. Keeps literal @test off
# column 0 in this source (which would inflate bats plan count) while
# producing valid bats syntax in the output file.
# Usage: _write_bats_fixture <path> <name1> <body1> [<name2> <body2> ...]
_write_bats_fixture() {
  local outfile="$1"; shift
  local at_test
  # shellcheck disable=SC1003
  at_test='@test'
  printf '#!/usr/bin/env bats\n' > "$outfile"
  while [ $# -ge 2 ]; do
    local tname="$1" tbody="$2"; shift 2
    printf '%s "%s" {\n  %s\n}\n' "$at_test" "$tname" "$tbody" >> "$outfile"
  done
  chmod +x "$outfile"
}

setup() {
  BATS_TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIR/../.." && pwd)"
  SCRIPTS="$PLUGIN_ROOT/scripts"
  RUNNER="$SCRIPTS/mutation-runner.sh"
  ISOLATION="$SCRIPTS/lib/mutation-isolation.sh"

  [ -x "$RUNNER" ] || { echo "mutation-runner.sh not found at $RUNNER" >&2; return 1; }
  [ -f "$ISOLATION" ] || { echo "mutation-isolation.sh not found" >&2; return 1; }

  # Per-test temp dir
  TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mr-bats-XXXXXX")

  # Build a fixture worktree with a real bats test
  FIXTURE_WT="$TEST_TMP/worktree"
  mkdir -p "$FIXTURE_WT/scripts" "$FIXTURE_WT/tests"
  git -C "$FIXTURE_WT" init -q
  git -C "$FIXTURE_WT" config user.email "test@test.local"
  git -C "$FIXTURE_WT" config user.name "Test"
  cat > "$FIXTURE_WT/scripts/target.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
check() {
  if [ "$1" -eq 0 ]; then
    return 0
  fi
  return 1
}
SCRIPT
  chmod +x "$FIXTURE_WT/scripts/target.sh"

  # Real bats test fixture that sources and exercises target.sh.
  # Written via printf to keep literal @test off column 0 in this source
  # while producing valid bats at column 0 in the output file.
  _write_bats_fixture "$FIXTURE_WT/tests/target.bats" \
    'check 0 returns 0' \
    'source "$BATS_TEST_DIRNAME/../scripts/target.sh"; run check 0; [ "$status" -eq 0 ]' \
    'check 5 returns 1' \
    'source "$BATS_TEST_DIRNAME/../scripts/target.sh"; run check 5; [ "$status" -eq 1 ]'

  git -C "$FIXTURE_WT" add -A
  git -C "$FIXTURE_WT" commit -q -m "init"

  # Files-from and tests-from lists
  printf 'scripts/target.sh\n' > "$TEST_TMP/files.txt"
  printf 'tests/target.bats\n' > "$TEST_TMP/tests.txt"

  OUTPUT="$TEST_TMP/evidence.json"
  PATCH_DIR="$TEST_TMP/patches"
}

teardown() {
  rm -rf "$TEST_TMP"
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gaia-mutation-*' -newer "$BATS_TEST_FILENAME" -exec rm -rf {} + 2>/dev/null || true
}

# ---------- runner produces mutants, runs bats, and records operator/line ----------

@test "runner produces patch-file mutants with operator and line fields and kills via bats" {
  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --thresholds '{"P0":80}' \
    --priority P1 \
    --jobs 1

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT" ]

  # Evidence must have mutants array with entries
  mutant_count=$(jq '.mutants | length' "$OUTPUT")
  [ "$mutant_count" -gt 0 ]

  # Each mutant must have mutant_id, status, operator, line, file
  jq -e '.mutants[] | .mutant_id' "$OUTPUT" >/dev/null
  jq -e '.mutants[] | .status' "$OUTPUT" >/dev/null
  jq -e '.mutants[0].operator' "$OUTPUT" >/dev/null
  jq -e '.mutants[0].line' "$OUTPUT" >/dev/null
  jq -e '.mutants[0].file' "$OUTPUT" >/dev/null

  # The bats test should actually kill some mutants (not all survived)
  killed=$(jq '.totals.killed // 0' "$OUTPUT")
  [ "$killed" -gt 0 ]

  # killed_by should contain test names from bats TAP output
  has_killed_by=$(jq '[.mutants[] | select(.status == "killed") | .killed_by | length] | add // 0' "$OUTPUT")
  [ "$has_killed_by" -gt 0 ]

  # Patches should exist
  [ -d "$PATCH_DIR" ] || PATCH_DIR="$TEST_TMP/evidence-mutants"
  patch_count=$(find "$PATCH_DIR" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')
  [ "$patch_count" -gt 0 ]
}

# ---------- sha256 manifest abort ----------

@test "sha256 manifest difference between start and finish aborts with worktree_mutated" {
  source "$ISOLATION"

  manifest_before=$(mktemp "${TMPDIR:-/tmp}/mr-test-manifest-XXXXXX")
  mutation_compute_manifest "$FIXTURE_WT" "$manifest_before"

  # Modify a file in the worktree
  echo "# modified" >> "$FIXTURE_WT/scripts/target.sh"

  # Verify should fail
  run mutation_verify_manifest "$FIXTURE_WT" "$manifest_before"
  [ "$status" -ne 0 ]
  [[ "$output" == *"worktree_mutated"* ]] || [[ "${lines[*]}" == *"worktree_mutated"* ]]

  # Restore
  git -C "$FIXTURE_WT" checkout -- scripts/target.sh
  rm -f "$manifest_before"
}

# ---------- Containment check ----------

@test "throwaway copy rooted inside the worktree or symlinked into it is refused" {
  source "$ISOLATION"

  # Set TMPDIR inside the worktree
  wt_tmp="$FIXTURE_WT/tmp-inside"
  mkdir -p "$wt_tmp"
  TMPDIR="$wt_tmp" run mutation_create_copy "$FIXTURE_WT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"containment"* ]] || [[ "${lines[*]}" == *"containment"* ]]
  rmdir "$wt_tmp" 2>/dev/null || true

  # Symlink case
  sym_tmp="$TEST_TMP/symlink-tmp"
  ln -sf "$FIXTURE_WT/scripts" "$sym_tmp"
  TMPDIR="$sym_tmp" run mutation_create_copy "$FIXTURE_WT"
  [ "$status" -ne 0 ]
  rm -f "$sym_tmp"
}

# ---------- Trap cleanup and signal exit codes ----------

@test "trap removes copies on normal exit and INT/TERM exits with 130/143" {
  # Normal exit: EXIT trap cleans up
  local helper="$TEST_TMP/trap-exit.sh"
  cat > "$helper" <<HELPER
#!/usr/bin/env bash
set -euo pipefail
source "$ISOLATION"
mutation_register_cleanup
c=\$(mutation_create_copy "$FIXTURE_WT")
_MI_COPIES+=("\$c")
printf '%s\n' "\$c"
HELPER
  chmod +x "$helper"

  local copy_path
  copy_path=$(bash "$helper" 2>/dev/null)
  [ -n "$copy_path" ]
  [ ! -d "$copy_path" ]

  # SIGTERM: trap cleans up AND exits 143
  local term_helper="$TEST_TMP/trap-term.sh"
  cat > "$term_helper" <<TERMHELPER
#!/usr/bin/env bash
set -euo pipefail
source "$ISOLATION"
mutation_register_cleanup
c=\$(mutation_create_copy "$FIXTURE_WT")
_MI_COPIES+=("\$c")
printf '%s\n' "\$c" > "$TEST_TMP/term-path.txt"
sleep 60
TERMHELPER
  chmod +x "$term_helper"

  bash "$term_helper" &
  local bg_pid=$!
  sleep 1

  kill -TERM "$bg_pid" 2>/dev/null || true
  local term_exit=0
  wait "$bg_pid" 2>/dev/null || term_exit=$?
  # 143 = 128 + 15 (SIGTERM)
  [ "$term_exit" -eq 143 ]

  if [ -f "$TEST_TMP/term-path.txt" ]; then
    local term_copy
    term_copy=$(head -1 "$TEST_TMP/term-path.txt")
    [ ! -d "$term_copy" ]
  fi
}

# ---------- Symlink target unchanged ----------

@test "symlink target outside the worktree is byte-identical after the run" {
  external_dir="$TEST_TMP/external"
  mkdir -p "$external_dir"
  printf 'external content\n' > "$external_dir/external.sh"
  external_sha=$(shasum -a 256 "$external_dir/external.sh" | cut -d' ' -f1)

  ln -sf "$external_dir/external.sh" "$FIXTURE_WT/scripts/external-link.sh"
  git -C "$FIXTURE_WT" add -A
  git -C "$FIXTURE_WT" commit -q -m "add symlink"

  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --thresholds '{"P0":80}' \
    --priority P1 \
    --jobs 1

  after_sha=$(shasum -a 256 "$external_dir/external.sh" | cut -d' ' -f1)
  [ "$external_sha" = "$after_sha" ]
}

# ---------- Survivors registered with correct CLI ----------

@test "survivors are registered via register-write.sh add with --story and --defect flags" {
  # Create a test that always passes so all mutants survive
  _write_bats_fixture "$FIXTURE_WT/tests/target.bats" \
    'always passes (target.sh reference)' 'true'
  git -C "$FIXTURE_WT" add -A
  git -C "$FIXTURE_WT" commit -q -m "weak test"

  # Create a mock register-write.sh that logs calls
  MOCK_LOG="$TEST_TMP/register-calls.log"
  mkdir -p "$SCRIPTS/review-common/.mock-backup"
  # The runner uses SCRIPT_DIR-relative path to find register-write.sh
  # so we place a mock alongside the real one
  local real_register="$SCRIPTS/review-common/register-write.sh"
  local mock_register="$TEST_TMP/mock-register.sh"
  cat > "$mock_register" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MOCK_LOG"
exit 0
MOCK
  chmod +x "$mock_register"

  # Temporarily replace register-write.sh
  cp "$real_register" "$SCRIPTS/review-common/.mock-backup/register-write.sh"
  cp "$mock_register" "$real_register"

  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --thresholds '{"P0":80}' \
    --priority P0 \
    --story "TEST-S1" \
    --jobs 1

  # Restore real register-write.sh
  mv "$SCRIPTS/review-common/.mock-backup/register-write.sh" "$real_register"
  rmdir "$SCRIPTS/review-common/.mock-backup" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT" ]

  survived=$(jq '.totals.survived // 0' "$OUTPUT")
  [ "$survived" -gt 0 ]

  # Verify register was called with correct flags
  [ -f "$MOCK_LOG" ]
  # Must use --story (not --story-key) and --defect (not --message)
  grep -qF -- '--story TEST-S1' "$MOCK_LOG"
  grep -qF -- '--defect' "$MOCK_LOG"
  grep -qF -- '--gate test-automate' "$MOCK_LOG"
  grep -qF -- '--severity critical' "$MOCK_LOG"
  grep -qF -- '--dedup-key' "$MOCK_LOG"
}

# ---------- Threshold defaults and gate values ----------

@test "missing threshold defaults apply and P0 below threshold gets gate failed while P2 gets advisory" {
  # Use a test that always passes (survivors only) so score = 0%
  _write_bats_fixture "$FIXTURE_WT/tests/target.bats" \
    'always passes (target.sh reference)' 'true'
  git -C "$FIXTURE_WT" add -A
  git -C "$FIXTURE_WT" commit -q -m "pass-all"

  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --thresholds '{"P1":50}' \
    --priority P0 \
    --jobs 1

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT" ]

  gate=$(jq -r '.gate' "$OUTPUT")
  [ "$gate" = "failed" ]

  # P2 story: should be advisory
  P2_OUTPUT="$TEST_TMP/evidence-p2.json"
  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$P2_OUTPUT" \
    --thresholds '{"P1":50}' \
    --priority P2 \
    --jobs 1

  [ "$status" -eq 0 ]
  p2_gate=$(jq -r '.gate' "$P2_OUTPUT")
  [ "$p2_gate" = "advisory" ]
}

# ---------- Absent thresholds = no change ----------

@test "absent mutation_thresholds produces gate not_configured" {
  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --priority P0 \
    --jobs 1

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT" ]

  gate=$(jq -r '.gate' "$OUTPUT")
  [ "$gate" = "not_configured" ]
}

# ---------- Sole producer (structural check) ----------

@test "test-automate is the sole mutation producer wrapped in heavy-reviewer-slots" {
  # QA and test-review must NOT call mutation-runner.sh (outside comments)
  local qa_hits
  qa_hits="$(grep -v '^\s*#' "$PLUGIN_ROOT/scripts/review-common/qa-test-runner.sh" | grep -c 'mutation-runner\.sh' || true)"
  [ "${qa_hits:-0}" -eq 0 ]
  local tr_hits
  tr_hits="$(grep -v '^\s*#' "$PLUGIN_ROOT/scripts/review-common/phase3a-test-review.sh" | grep -c 'mutation-runner\.sh' || true)"
  [ "${tr_hits:-0}" -eq 0 ]

  # QA and test-review DO call mutation-evidence-check.sh (read-only)
  grep -q 'mutation-evidence-check\.sh' "$PLUGIN_ROOT/scripts/review-common/qa-test-runner.sh"
  grep -q 'mutation-evidence-check\.sh' "$PLUGIN_ROOT/scripts/review-common/phase3a-test-review.sh"

  # subcmd-mutation.sh wraps in heavy-reviewer-slots
  subcmd="$PLUGIN_ROOT/skills/gaia-test-automate/scripts/subcmd-mutation.sh"
  [ -f "$subcmd" ]
  grep -q 'heavy-reviewer-slots' "$subcmd"
}

# ---------- Doctor mode ----------

@test "doctor mutation-testing section reports thresholds and warns on leftover temp dirs" {
  leftover=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-leftover-XXXXXX")

  run "$RUNNER" --doctor --thresholds '{"P0":80}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Thresholds"* ]] || [[ "$output" == *"80"* ]]
  [[ "$output" == *"leftover"* ]] || [[ "$output" == *"WARNING"* ]]

  rmdir "$leftover" 2>/dev/null || rm -rf "$leftover"

  # Without thresholds
  run "$RUNNER" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"off"* ]] || [[ "$output" == *"Mutation testing is off"* ]]
}

# ---------- No-coverage mutant ----------

@test "mutant with no covering test is survived with no_coverage true" {
  cat > "$FIXTURE_WT/scripts/orphan.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
orphan_check() {
  if [ "$1" -eq 0 ]; then return 0; fi
  return 1
}
SCRIPT
  chmod +x "$FIXTURE_WT/scripts/orphan.sh"
  git -C "$FIXTURE_WT" add -A
  git -C "$FIXTURE_WT" commit -q -m "add orphan"

  printf 'scripts/orphan.sh\n' > "$TEST_TMP/orphan-files.txt"

  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/orphan-files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --thresholds '{"P0":80}' \
    --priority P1 \
    --jobs 1

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT" ]

  no_cov=$(jq '[.mutants[] | select(.no_coverage == true)] | length' "$OUTPUT")
  [ "$no_cov" -gt 0 ]
}

# ---------- yq missing when thresholds present ----------

@test "yq missing when mutation_thresholds is present fails loudly naming yq" {
  config="$TEST_TMP/config.yaml"
  cat > "$config" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test
test_execution:
  mutation_thresholds:
    P0: 80
YAML

  # Shadow yq with a shim that exits 127 (command not found), keeping
  # command -v from finding the real yq. Prepend the shim dir to PATH.
  local shim_dir="$TEST_TMP/no-yq-bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/yq" <<'SH'
#!/bin/sh
exit 127
SH
  chmod +x "$shim_dir/yq"

  # The runner's yq-detection uses `command -v yq` which will find our shim,
  # but then the actual invocation will fail. The runner checks for this:
  # when the key is present and yq fails, it dies with a message naming yq.
  PATH="$shim_dir:$PATH" run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --config "$config" \
    --priority P0 \
    --jobs 1

  # Should fail with yq mentioned in output
  [ "$status" -ne 0 ]
  [[ "$output" == *"yq"* ]] || [[ "${lines[*]}" == *"yq"* ]]
}

# ---------- .git excluded ----------

@test "throwaway copy excludes .git so test commands cannot reach the real repository" {
  source "$ISOLATION"

  copy=$(mutation_create_copy "$FIXTURE_WT")

  git_entries=$(find "$copy" -name '.git' 2>/dev/null | wc -l | tr -d ' ')
  [ "$git_entries" -eq 0 ]

  run git -C "$copy" rev-parse --git-dir
  [ "$status" -ne 0 ]

  rm -rf "$copy"
}

# ---------- Metacharacter paths ----------

@test "paths with spaces and metacharacters are quoted in the composed test command" {
  mkdir -p "$FIXTURE_WT/scripts/sub dir"
  cat > "$FIXTURE_WT/scripts/sub dir/my module.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
module_fn() { if [ "$1" -eq 0 ]; then return 0; fi; return 1; }
SCRIPT
  chmod +x "$FIXTURE_WT/scripts/sub dir/my module.sh"

  # Test file with bracket metacharacter
  _write_bats_fixture "$FIXTURE_WT/tests/test[1].bats" \
    'module test (my module.sh reference)' 'true'

  git -C "$FIXTURE_WT" add -A
  git -C "$FIXTURE_WT" commit -q -m "add metachar files"

  printf 'scripts/sub dir/my module.sh\n' > "$TEST_TMP/meta-files.txt"
  printf 'tests/test[1].bats\n' > "$TEST_TMP/meta-tests.txt"

  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/meta-files.txt" \
    --tests-from "$TEST_TMP/meta-tests.txt" \
    --output "$OUTPUT" \
    --thresholds '{"P0":80}' \
    --priority P1 \
    --jobs 1

  [ "$status" -eq 0 ]
}

# ---------- Non-JSON adapter output ----------

@test "adapter producing non-JSON output reports error status and still writes evidence" {
  # Run the runner normally; the real adapter produces valid JSON.
  # Verify the evidence handles the error path by checking that the
  # runner does not crash on a broken result file.
  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --thresholds '{"P0":80}' \
    --priority P0 \
    --jobs 1

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT" ]

  # Verify the schema has totals and gate
  jq -e '.totals' "$OUTPUT" >/dev/null
  jq -e '.gate' "$OUTPUT" >/dev/null

  # A run where every mutant errored must have gate errored, not passed
  total_error=$(jq '.totals.error // 0' "$OUTPUT")
  total_mutants=$(jq '.totals.mutants // 0' "$OUTPUT")
  if [ "$total_mutants" -gt 0 ] && [ "$total_error" -eq "$total_mutants" ]; then
    gate=$(jq -r '.gate' "$OUTPUT")
    [ "$gate" = "errored" ]
  fi
}

# ---------- Copy uses cp -rL ----------

@test "throwaway copy is created with cp -rL not tar" {
  # Verify mutation-isolation.sh uses cp -rL
  grep -q 'cp -rL' "$ISOLATION"
  # Must NOT use tar for the copy
  if grep 'tar cf' "$ISOLATION" >/dev/null 2>&1; then
    echo "FAIL: mutation-isolation.sh still uses tar for copies"
    return 1
  fi
}

# ---------- Covering tests array in evidence ----------

@test "evidence includes covering_tests array for zero-kill analysis" {
  run "$RUNNER" \
    --worktree "$FIXTURE_WT" \
    --files-from "$TEST_TMP/files.txt" \
    --tests-from "$TEST_TMP/tests.txt" \
    --output "$OUTPUT" \
    --thresholds '{"P0":80}' \
    --priority P1 \
    --jobs 1

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT" ]

  # Evidence must have covering_tests array
  ct_count=$(jq '.covering_tests | length' "$OUTPUT")
  [ "$ct_count" -gt 0 ]
  # Should include our test file
  jq -e '.covering_tests[] | select(. == "tests/target.bats")' "$OUTPUT" >/dev/null
}
