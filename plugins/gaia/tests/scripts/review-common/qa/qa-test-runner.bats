#!/usr/bin/env bats
# qa-test-runner.bats — E67-S4 bats coverage for qa-test-runner.sh.
# Refs: AC3 (tier placement), AC4 (evidence capture), AC5 (failure verdict),
#       AC6 (timeout), AC7 (graceful skip), AC10 (POSIX/bash 3.2).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  STORY_KEY="E67-S4"
  WORKDIR="${TEST_TMP}/.gaia/state/review/qa-tests/${STORY_KEY}"
  mkdir -p "$WORKDIR"
}
teardown() { common_teardown; }

# --- helpers -----------------------------------------------------------

write_config() {
  # write_config <path> <tier1_placement> <tier2_placement> <tier3_placement>
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: ${2:-local}
    command: "true"
    timeout_seconds: 30
  tier_2:
    placement: ${3:-ci-pre-merge}
    command: "true"
    timeout_seconds: 60
  tier_3:
    placement: ${4:-ci-post-merge}
    command: "true"
    timeout_seconds: 120
EOF
}

write_failing_command_config() {
  # tier_1.placement=local, tier_1.command exits non-zero
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "false"
    timeout_seconds: 30
EOF
}

write_timeout_command_config() {
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "sleep 30"
    timeout_seconds: 1
EOF
}

write_minimal_config_no_test_exec() {
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
EOF
}

# --- AC10: script exists and is executable -----------------------------

@test "AC10: qa-test-runner.sh exists and is executable" {
  [ -f "$QA_TEST_RUNNER" ]
  [ -x "$QA_TEST_RUNNER" ]
}

@test "AC10: --help prints usage and exits 0" {
  run --separate-stderr "$QA_TEST_RUNNER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--story-key"* ]]
  [[ "$output" == *"--workdir"* ]]
}

# --- AC3: tier resolution from GAIA_EXECUTION_CONTEXT -------------------

@test "AC3: local context runs tier_1 only when tier_1.placement=local" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/execution-evidence.json" ]
  jq -e '.suites | length == 1' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].name == "tier_1"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.context == "local"' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "AC3: ci_pre_merge context runs tier_2 only when tier_2.placement=ci-pre-merge" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=ci_pre_merge \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.suites | length == 1' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].name == "tier_2"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.context == "ci_pre_merge"' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "AC3: ci_pre_merge context runs both tier_1 and tier_2 if both placements match" {
  # When tier_1.placement and tier_2.placement both equal ci-pre-merge.
  write_config "$TEST_TMP/project-config.yaml" ci-pre-merge ci-pre-merge ci-post-merge
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=ci_pre_merge \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.suites | length == 2' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "AC3: default context is local when GAIA_EXECUTION_CONTEXT is unset" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env -u GAIA_EXECUTION_CONTEXT \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.context == "local"' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC4: execution evidence capture -----------------------------------

@test "AC4: execution-evidence.json contains required fields" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.tier' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.context' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.wall_clock_seconds | type == "number"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].name' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].command' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].exit_code | type == "number"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].duration_seconds | type == "number"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0] | has("pass_count") and has("fail_count")' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC5: required test failure -- runner exits non-zero ----------------

@test "AC5: tier_1 command failure produces evidence with exit_code != 0" {
  write_failing_command_config "$TEST_TMP/project-config.yaml"
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  # Runner itself returns 0 (evidence capture is its responsibility); the
  # verdict is derived later by verdict-resolver from the evidence.
  [ "$status" -eq 0 ]
  jq -e '.suites[0].exit_code != 0' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].timeout == false' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC6: timeout handling --------------------------------------------

@test "AC6: tier_1 command exceeding timeout_seconds is killed and recorded" {
  write_timeout_command_config "$TEST_TMP/project-config.yaml"
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.suites[0].timeout == true' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].duration_seconds | . < 5' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC7: graceful skip when test_execution absent ---------------------

@test "AC7: missing test_execution section -- skipped with INFO diagnostic" {
  write_minimal_config_no_test_exec "$TEST_TMP/project-config.yaml"
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/execution-evidence.json" ]
  jq -e '.skipped == true' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites | length == 0' "$WORKDIR/execution-evidence.json" >/dev/null
  [[ "$stderr" == *"test_execution not configured"* ]] || \
    [[ "$stderr" == *"INFO"* ]]
}

# --- AC10: required-flag handling --------------------------------------

@test "AC10: missing --story-key fails fast" {
  run --separate-stderr "$QA_TEST_RUNNER" --workdir "$WORKDIR"
  [ "$status" -ne 0 ]
}

@test "AC10: missing --workdir fails fast" {
  run --separate-stderr "$QA_TEST_RUNNER" --story-key "$STORY_KEY"
  [ "$status" -ne 0 ]
}

# --- story-scoped execution (single-story QA review) ---------------------

# Helper: write a story markdown file with a File List section pointing
# at known source files under TEST_TMP.
write_story_with_file_list() {
  local story_file="$1"; shift
  # remaining args are source paths (relative to project root)
  {
    printf '%s\n' '---'
    printf 'key: "%s"\n' "$STORY_KEY"
    printf '%s\n' 'status: in-progress'
    printf '%s\n' '---'
    printf '\n%s\n\n%s\n\n' '# Story' '## Acceptance Criteria'
    printf '%s\n\n' '### File List'
    for f in "$@"; do
      printf '%s\n' "- \`${f}\` (implementation)"
    done
    printf '\n%s\n' '## Test Scenarios'
  } > "$story_file"
}

# Helper: write a config whose tier_1 command is a bats full-suite glob
# simulating the large-project scenario. The glob points at an empty dir
# so it fails fast if not replaced by story-scoping, but because story-
# scoping substitutes the command the glob never actually runs.
write_slow_full_suite_config() {
  # Create the empty full-suite target dir so the glob is syntactically valid.
  mkdir -p "${TEST_TMP}/all-tests"
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "bats ${TEST_TMP}/all-tests/"
    timeout_seconds: 30
EOF
}

@test "story-scoped: local review with --story-file runs only story-relevant tests, not full suite (AC1)" {
  # Create a project layout with source files and adjacent test files.
  mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/widget.sh"
  # Create a passing bats test file adjacent to the source.
  cat > "$TEST_TMP/tests/widget.bats" <<'BATS'
#!/usr/bin/env bats
@test "widget works" { true; }
BATS

  # Write a story file whose File List references src/widget.sh.
  local story_file="$TEST_TMP/story.md"
  write_story_with_file_list "$story_file" "src/widget.sh"

  # Config whose full-suite command is "bats <dir>" (we want to prove the
  # runner does NOT execute the glob -- it should run only the scoped test).
  write_slow_full_suite_config "$TEST_TMP/project-config.yaml"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/execution-evidence.json" ]

  # The command in evidence must reference the scoped test file, not the
  # full-suite bats glob.
  local cmd
  cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  [[ "$cmd" != *"all-tests"* ]]
  [[ "$cmd" == *"widget.bats"* ]]

  # No timeout -- the scoped test runs fast.
  jq -e '.suites[0].timeout == false' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "story-scoped: full-suite timeout does not false-BLOCK when story tests pass (AC2)" {
  # This is the regression guard: a project whose full suite exceeds the
  # timeout (300s) but the story's own tests pass in milliseconds.
  mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/gadget.sh"
  cat > "$TEST_TMP/tests/gadget.bats" <<'BATS'
#!/usr/bin/env bats
@test "gadget works" { true; }
BATS

  local story_file="$TEST_TMP/story.md"
  write_story_with_file_list "$story_file" "src/gadget.sh"

  # Full-suite command = "bats <dir>" glob; scoped substitution narrows it.
  write_slow_full_suite_config "$TEST_TMP/project-config.yaml"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]

  # Evidence must NOT show timeout.
  jq -e '.suites[0].timeout == false' "$WORKDIR/execution-evidence.json" >/dev/null
  # Exit code must be 0 (tests pass).
  jq -e '.suites[0].exit_code == 0' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "story-scoped: CI context runs full-suite tier command unchanged (AC3)" {
  # Even with --story-file, a CI context must run the full-suite command.
  mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/thing.sh"
  cat > "$TEST_TMP/tests/thing.bats" <<'BATS'
#!/usr/bin/env bats
@test "thing works" { true; }
BATS

  local story_file="$TEST_TMP/story.md"
  write_story_with_file_list "$story_file" "src/thing.sh"

  # Config with ci_pre_merge tier that runs "true" (fast, full-suite).
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=ci_pre_merge \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]

  # In CI context, the command must be the tier command ("true"), not scoped.
  local cmd
  cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  [ "$cmd" = "true" ]
}

@test "story-scoped: no File List section falls back to full suite with warning (AC1)" {
  # Story file without a File List section.
  local story_file="$TEST_TMP/story-no-fl.md"
  {
    printf '%s\n' '---'
    printf 'key: "%s"\n' "$STORY_KEY"
    printf '%s\n' 'status: in-progress'
    printf '%s\n' '---'
    printf '\n%s\n\n%s\n\n' '# Story' '## Acceptance Criteria'
    printf '%s\n' '## Test Scenarios'
  } > "$story_file"

  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]

  # Falls back to full-suite tier command.
  local cmd
  cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  [ "$cmd" = "true" ]

  # Warning emitted about fallback.
  [[ "$stderr" == *"no story-scoped tests"* ]] || [[ "$stderr" == *"falling back"* ]] || \
    [[ "$stderr" == *"File List"* ]]
}

@test "story-scoped: File List with no matching tests falls back to full suite (AC1)" {
  # Source files exist but no adjacent test files.
  mkdir -p "$TEST_TMP/lib"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/lib/orphan.sh"

  local story_file="$TEST_TMP/story-orphan.md"
  write_story_with_file_list "$story_file" "lib/orphan.sh"

  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]

  # Falls back to full-suite tier command ("true").
  local cmd
  cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  [ "$cmd" = "true" ]
}

# --- multi-tier story-scoped substitution attribution ----------------------

# Helper: write a config with two local tiers — one bats full-suite glob
# and one non-bats (already-narrow) command.
write_two_local_tiers_config() {
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "bats ${TEST_TMP}/tests/"
    timeout_seconds: 30
  tier_2:
    placement: local
    command: "echo narrow-lint-check"
    timeout_seconds: 30
EOF
}

@test "story-scoped: multi-tier -- bats tier gets scoped cmd, non-bats tier keeps its own" {
  # Two local tiers: tier_1 = bats full-suite glob, tier_2 = non-bats narrow.
  # Story-scoping should replace only tier_1's command; tier_2 keeps its own.
  mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/multi.sh"
  cat > "$TEST_TMP/tests/multi.bats" <<'BATS'
#!/usr/bin/env bats
@test "multi works" { true; }
BATS

  local story_file="$TEST_TMP/story-multi.md"
  write_story_with_file_list "$story_file" "src/multi.sh"

  write_two_local_tiers_config "$TEST_TMP/project-config.yaml"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/execution-evidence.json" ]

  # Two suites must be recorded (both local tiers ran).
  jq -e '.suites | length == 2' "$WORKDIR/execution-evidence.json" >/dev/null

  # tier_1 (bats full-suite) must have been replaced with the scoped command.
  local cmd_t1
  cmd_t1="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  [[ "$cmd_t1" == bats*multi.bats* ]]
  [[ "$cmd_t1" != *"${TEST_TMP}/tests/"* ]] || [[ "$cmd_t1" == *"multi.bats"* ]]

  # tier_2 (non-bats) must keep its original command unchanged.
  local cmd_t2
  cmd_t2="$(jq -r '.suites[1].command' "$WORKDIR/execution-evidence.json")"
  [ "$cmd_t2" = "echo narrow-lint-check" ]
}
