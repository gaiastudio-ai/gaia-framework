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
  # NOTE: the fixture's @test line is printf-appended AFTER the heredoc so that
  # bats' outer pre-scanner (bats <=1.10) does not count it toward the TAP plan.
  cat > "$TEST_TMP/tests/widget.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "widget works" { true; }' >> "$TEST_TMP/tests/widget.bats"

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
  # NOTE: printf-append avoids bats <=1.10 heredoc @test plan-inflation.
  cat > "$TEST_TMP/tests/gadget.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "gadget works" { true; }' >> "$TEST_TMP/tests/gadget.bats"

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
  # NOTE: printf-append avoids bats <=1.10 heredoc @test plan-inflation.
  cat > "$TEST_TMP/tests/thing.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "thing works" { true; }' >> "$TEST_TMP/tests/thing.bats"

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
  # NOTE: printf-append avoids bats <=1.10 heredoc @test plan-inflation.
  cat > "$TEST_TMP/tests/multi.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "multi works" { true; }' >> "$TEST_TMP/tests/multi.bats"

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

# --- clean child environment ---------------------------------------------
#
# A caller session that exports project-root variables must not leak them
# into the spawned suite: a suite asserting canonical-path resolution would
# otherwise see the caller's ambient root instead of its own fixture root.

# Helper: config whose tier_1 command writes the observed root variables to a
# file the test can read after the run.
write_env_probe_file_config() {
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
    command: "${TEST_TMP}/probe-env.sh"
    timeout_seconds: 30
EOF
}

write_env_probe_script() {
  cat > "${TEST_TMP}/probe-env.sh" <<'PROBE'
#!/usr/bin/env bash
{
  printf 'PROJECT_ROOT=[%s]\n' "${PROJECT_ROOT:-}"
  printf 'CLAUDE_PROJECT_ROOT=[%s]\n' "${CLAUDE_PROJECT_ROOT:-}"
  printf 'PROJECT_PATH=[%s]\n' "${PROJECT_PATH:-}"
  printf 'CLAUDE_PLUGIN_ROOT=[%s]\n' "${CLAUDE_PLUGIN_ROOT:-}"
} > "$PROBE_OUT"
exit 0
PROBE
  chmod +x "${TEST_TMP}/probe-env.sh"
}

@test "child environment: tier command sees empty project-root variables when the caller exports them" {
  write_env_probe_script
  write_env_probe_file_config "$TEST_TMP/project-config.yaml"

  run --separate-stderr env \
    GAIA_EXECUTION_CONTEXT=local \
    PROBE_OUT="${TEST_TMP}/child-env.txt" \
    PROJECT_ROOT=/ambient/leaked-root \
    CLAUDE_PROJECT_ROOT=/ambient/leaked-claude-root \
    PROJECT_PATH=/ambient/leaked-path \
    CLAUDE_PLUGIN_ROOT=/ambient/leaked-plugin-root \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "${TEST_TMP}/child-env.txt" ]

  local observed
  observed="$(cat "${TEST_TMP}/child-env.txt")"
  [ "$(printf '%s\n' "$observed" | grep -c 'ambient')" -eq 0 ]
  [[ "$observed" == *"PROJECT_ROOT=[]"* ]]
  [[ "$observed" == *"CLAUDE_PROJECT_ROOT=[]"* ]]
  [[ "$observed" == *"PROJECT_PATH=[]"* ]]
  [[ "$observed" == *"CLAUDE_PLUGIN_ROOT=[]"* ]]
}

@test "child environment: the no-timeout-binary fallback also clears project-root variables" {
  write_env_probe_script
  write_env_probe_file_config "$TEST_TMP/project-config.yaml"

  # Force the alarm-based fallback spawn path by handing the runner a PATH
  # that has every tool it needs EXCEPT a timeout binary.
  #
  # Deliberately a shim directory rather than filtering the real PATH: on
  # Linux `timeout` lives in /usr/bin alongside perl, sh and the coreutils
  # the runner and the probe both need, so dropping every directory that
  # contains `timeout` also strips the interpreter the fallback runs on.
  # That narrowing passes on a host where timeout sits in its own directory
  # and fails everywhere else.
  local shim_bin="$TEST_TMP/no-timeout-bin"
  mkdir -p "$shim_bin"
  local tool tool_path
  for tool in sh bash env perl python3 jq seq awk sed grep cat printf mktemp rm mkdir \
             dirname basename find tail head sort uniq wc date tr cut tee stat readlink sleep; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$tool_path" "$shim_bin/$tool"
  done
  # Guard the premise: the fallback needs perl, and the path must have no
  # timeout binary for this test to exercise what it claims to.
  [ -x "$shim_bin/perl" ] || skip "perl not available to exercise the fallback spawn path"
  local filtered_path="$shim_bin"
  PATH="$filtered_path" command -v timeout >/dev/null 2>&1 && \
    { echo "shim PATH still resolves a timeout binary"; false; }

  # The runner restores PATH from BATS_SAVED_PATH (and strips BATS_LIBEXEC
  # from it) before spawning, so under bats the shim would be replaced by the
  # full path -- which has a timeout binary on it, and the fallback branch
  # would never run. Clearing both makes the shim the PATH the spawn actually
  # sees; without this the test passes whatever the fallback does.
  run --separate-stderr env \
    -u BATS_SAVED_PATH \
    -u BATS_LIBEXEC \
    PATH="$filtered_path" \
    GAIA_EXECUTION_CONTEXT=local \
    PROBE_OUT="${TEST_TMP}/child-env.txt" \
    PROJECT_ROOT=/ambient/leaked-root \
    CLAUDE_PROJECT_ROOT=/ambient/leaked-claude-root \
    PROJECT_PATH=/ambient/leaked-path \
    CLAUDE_PLUGIN_ROOT=/ambient/leaked-plugin-root \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "${TEST_TMP}/child-env.txt" ]

  local observed
  observed="$(cat "${TEST_TMP}/child-env.txt")"
  [ "$(printf '%s\n' "$observed" | grep -c 'ambient')" -eq 0 ]
}

# --- whole-stream case tally ----------------------------------------------
#
# A large suite prints thousands of result lines and then a trailing report.
# Tallying a fixed tail window counts the report, not the results.

write_long_tap_config() {
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
    command: "${TEST_TMP}/long-tap.sh"
    timeout_seconds: 60
EOF
}

@test "case tally: result lines beyond a fixed tail window are still counted" {
  # 500 passing result lines, 3 failing, then a 400-line trailing report that
  # entirely fills any 200-line tail window.
  cat > "${TEST_TMP}/long-tap.sh" <<'GEN'
#!/usr/bin/env bash
i=1
while [ "$i" -le 500 ]; do
  printf 'ok %d passing case\n' "$i"
  i=$((i + 1))
done
j=501
while [ "$j" -le 503 ]; do
  printf 'not ok %d failing case\n' "$j"
  j=$((j + 1))
done
k=1
while [ "$k" -le 400 ]; do
  printf 'coverage report line %d ................ covered\n' "$k"
  k=$((k + 1))
done
exit 1
GEN
  chmod +x "${TEST_TMP}/long-tap.sh"
  write_long_tap_config "$TEST_TMP/project-config.yaml"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]

  jq -e '.suites[0].pass_count == 500' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].fail_count == 3' "$WORKDIR/execution-evidence.json" >/dev/null
  # Counts and exit code must tell the same story.
  jq -e '.suites[0].exit_code != 0' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "case tally: a summary-line runner keeps reporting its own summary numbers" {
  cat > "${TEST_TMP}/summary-runner.sh" <<'GEN'
#!/usr/bin/env bash
printf 'collecting ...\n'
printf 'tests/sample.py ..........\n'
printf '83 passed, 0 failed in 1.20s\n'
exit 0
GEN
  chmod +x "${TEST_TMP}/summary-runner.sh"
  cat > "$TEST_TMP/project-config.yaml" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "${TEST_TMP}/summary-runner.sh"
    timeout_seconds: 30
EOF

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.suites[0].pass_count == 83' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].fail_count == 0' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "case tally: a runner emitting neither shape keeps the one-per-suite fallback" {
  cat > "$TEST_TMP/project-config.yaml" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "printf 'PASS\\\\n'"
    timeout_seconds: 30
EOF

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.suites[0].pass_count == 1' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].fail_count == 0' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- scoped narrowing of a compound same-runner command --------------------

@test "story-scoped: a compound command that ultimately runs the same runner is narrowed" {
  mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests" "$TEST_TMP/all-tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/compound.sh"
  cat > "$TEST_TMP/tests/compound.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "compound works" { true; }' >> "$TEST_TMP/tests/compound.bats"

  local story_file="$TEST_TMP/story-compound.md"
  write_story_with_file_list "$story_file" "src/compound.sh"

  # A cd-prefixed, env-prefixed invocation of a project runner script whose
  # name marks it as the same runner. It would run the whole tree if executed.
  cat > "$TEST_TMP/run-with-coverage.sh" <<'RUNNER'
#!/usr/bin/env bash
printf 'FULL SUITE RAN\n' > "$SENTINEL_FILE"
bats "$@"
RUNNER
  chmod +x "$TEST_TMP/run-with-coverage.sh"

  cat > "$TEST_TMP/project-config.yaml" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "cd ${TEST_TMP} && BATS_JOBS=2 bash ${TEST_TMP}/run-with-coverage.sh ${TEST_TMP}/all-tests"
    timeout_seconds: 60
EOF

  run --separate-stderr env \
    GAIA_EXECUTION_CONTEXT=local \
    SENTINEL_FILE="${TEST_TMP}/full-suite-ran.txt" \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]

  # The recorded command must name the scoped test file, not the full tree.
  local cmd
  cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  [[ "$cmd" == *"compound.bats"* ]]
  [[ "$cmd" != *"all-tests"* ]]
  jq -e '.suites[0].exit_code == 0' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "story-scoped: a genuinely different runner keeps its own command and is not narrowed" {
  mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/other.sh"
  cat > "$TEST_TMP/tests/other.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "other works" { true; }' >> "$TEST_TMP/tests/other.bats"

  local story_file="$TEST_TMP/story-other.md"
  write_story_with_file_list "$story_file" "src/other.sh"

  cat > "$TEST_TMP/project-config.yaml" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "echo pytest tests/"
    timeout_seconds: 30
EOF

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]

  local cmd
  cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  [ "$cmd" = "echo pytest tests/" ]
  [[ "$cmd" != *"other.bats"* ]]
}

# --- announcement matches what ran ----------------------------------------

@test "story-scoped: a tier that falls back to its own command is not announced as scoped" {
  mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/announce.sh"
  cat > "$TEST_TMP/tests/announce.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "announce works" { true; }' >> "$TEST_TMP/tests/announce.bats"

  local story_file="$TEST_TMP/story-announce.md"
  write_story_with_file_list "$story_file" "src/announce.sh"

  cat > "$TEST_TMP/project-config.yaml" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "echo pytest tests/"
    timeout_seconds: 30
EOF

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]

  # No tier ran the scoped command, so no scoped announcement may appear.
  [[ "$stderr" != *"story-scoped test execution:"* ]]
  # The fallback must be stated instead.
  [[ "$stderr" == *"keeps its own command"* ]] || [[ "$stderr" == *"falling back"* ]]
}

@test "story-scoped: the announced scoped command matches the command recorded as executed" {
  mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests" "$TEST_TMP/all-tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/agree.sh"
  cat > "$TEST_TMP/tests/agree.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "agree works" { true; }' >> "$TEST_TMP/tests/agree.bats"

  local story_file="$TEST_TMP/story-agree.md"
  write_story_with_file_list "$story_file" "src/agree.sh"
  write_slow_full_suite_config "$TEST_TMP/project-config.yaml"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file"
  [ "$status" -eq 0 ]

  local cmd announced
  cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  announced="$(printf '%s\n' "$stderr" \
    | sed -n 's/.*story-scoped test execution: //p' | tail -1)"
  [ -n "$announced" ]
  [ "$announced" = "$cmd" ]
}
