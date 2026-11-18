#!/usr/bin/env bats
# qa-test-runner.bats — bats coverage for qa-test-runner.sh.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  # Isolate the semaphore state so tests never take real slots in the
  # checkout's .gaia/state directory.
  export GAIA_STATE_DIR="$TEST_TMP/.gaia/state"
  mkdir -p "$GAIA_STATE_DIR"
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

# --- script exists and is executable ------------------------------------

@test "qa-test-runner.sh exists and is executable" {
  [ -f "$QA_TEST_RUNNER" ]
  [ -x "$QA_TEST_RUNNER" ]
}

@test "--help prints usage and exits 0" {
  run --separate-stderr "$QA_TEST_RUNNER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--story-key"* ]]
  [[ "$output" == *"--workdir"* ]]
}

# --- tier resolution from GAIA_EXECUTION_CONTEXT -------------------------

@test "local context runs tier_1 only when tier_1.placement=local" {
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

@test "ci_pre_merge context runs tier_2 only when tier_2.placement=ci-pre-merge" {
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

@test "ci_pre_merge context runs both tier_1 and tier_2 if both placements match" {
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

@test "default context is local when GAIA_EXECUTION_CONTEXT is unset" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env -u GAIA_EXECUTION_CONTEXT \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.context == "local"' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- execution evidence capture ------------------------------------------

@test "execution-evidence.json contains required fields" {
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

# --- required test failure — runner exits non-zero -----------------------

@test "tier_1 command failure produces evidence with exit_code != 0" {
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

# --- timeout handling ----------------------------------------------------

@test "tier_1 command exceeding timeout_seconds is killed and recorded" {
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

# --- graceful skip when test_execution absent ----------------------------

@test "missing test_execution section -- skipped with INFO diagnostic" {
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

# --- required-flag handling -----------------------------------------------

@test "missing --story-key fails fast" {
  run --separate-stderr "$QA_TEST_RUNNER" --workdir "$WORKDIR"
  [ "$status" -ne 0 ]
}

@test "missing --workdir fails fast" {
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

@test "story-scoped: local review with --story-file runs only story-relevant tests, not full suite" {
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

@test "story-scoped: full-suite timeout does not false-BLOCK when story tests pass" {
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

@test "story-scoped: CI context runs full-suite tier command unchanged" {
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

@test "story-scoped: no File List section falls back to full suite with warning" {
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

@test "story-scoped: File List with no matching tests falls back to full suite" {
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

# --- code-tree option -------------------------------------------------------

@test "code-tree pointing at a non-existent path dies with a clear message" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr "$QA_TEST_RUNNER" \
    --story-key "$STORY_KEY" \
    --workdir "$WORKDIR" \
    --config "$TEST_TMP/project-config.yaml" \
    --code-tree "$TEST_TMP/no-such-dir"
  [ "$status" -ne 0 ]
  local combined
  combined="${output}${stderr}"
  [[ "$combined" == *"no-such-dir"* ]]
  [[ "$combined" == *"not a directory"* ]] || [[ "$combined" == *"does not exist"* ]]
}

# Helper: config whose tier_1 command emits pwd and lists a marker file.
write_cwd_probe_config() {
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
    command: "pwd && ls marker.txt"
    timeout_seconds: 30
EOF
}

@test "code-tree option runs tier commands inside the given tree" {
  # --code-tree <path> sets cwd for tier commands.
  local tree="$TEST_TMP/code-tree-target"
  mkdir -p "$tree"
  touch "$tree/marker.txt"

  write_cwd_probe_config "$TEST_TMP/project-config.yaml"

  # Run from a DIFFERENT directory (TEST_TMP), but specify --code-tree.
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --code-tree "$tree"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/execution-evidence.json" ]
  jq -e '.suites[0].exit_code == 0' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "without code-tree, tier commands run in the caller cwd" {
  # Backward-compatible — no --code-tree means current cwd.
  # This is a green-on-entry regression guard.
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/execution-evidence.json" ]
  jq -e '.suites[0].exit_code == 0' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- tier output log preserved -----------------------------------------------

@test "tier output log is kept after the run" {
  # The tier output log must survive at a known path after the run.
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]

  # A tier output log matching qa-tier-output-*.log must exist in WORKDIR.
  local log_found=false
  local f
  for f in "$WORKDIR"/qa-tier-output-*.log; do
    if [ -f "$f" ]; then log_found=true; break; fi
  done
  [ "$log_found" = "true" ]
}

# --- whole-stream tally over summary-tail ------------------------------------

@test "whole-stream bats tally is authoritative over summary tail" {
  # When both a whole-stream tally and a summary-tail parse are present,
  # the whole-stream tally (10 ok, 2 not ok) must win over the misleading
  # summary tail ("5 passed, 0 failed").
  cat > "${TEST_TMP}/mixed-tap.sh" <<'SCRIPT'
#!/usr/bin/env bash
i=1
while [ "$i" -le 10 ]; do
  printf 'ok %d passing test\n' "$i"
  i=$((i + 1))
done
j=11
while [ "$j" -le 12 ]; do
  printf 'not ok %d failing test\n' "$j"
  j=$((j + 1))
done
printf '5 passed, 0 failed in 1.00s\n'
exit 1
SCRIPT
  chmod +x "${TEST_TMP}/mixed-tap.sh"
  write_custom_command_config "$TEST_TMP/project-config.yaml" "${TEST_TMP}/mixed-tap.sh"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]

  # The whole-stream tally (10/2) must be recorded, not the summary (5/0).
  jq -e '.suites[0].pass_count == 10' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].fail_count == 2' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- tally/exit-code contradiction ------------------------------------------

# Helper: config pointing tier_1 at a custom local command.
write_custom_command_config() {
  local config_path="$1" cmd="$2"
  cat > "$config_path" <<EOF
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
    command: "${cmd}"
    timeout_seconds: 30
EOF
}

@test "tally and exit code disagreement is a failure with a discrepancy note" {
  # 0 failures in tally but exit code 1 must be treated as failure, and
  # the evidence diagnostics must contain "tally/exit-code discrepancy".
  cat > "${TEST_TMP}/ok-exit1.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'ok 1 test A\n'
printf 'ok 2 test B\n'
printf 'ok 3 test C\n'
exit 1
SCRIPT
  chmod +x "${TEST_TMP}/ok-exit1.sh"
  write_custom_command_config "$TEST_TMP/project-config.yaml" "${TEST_TMP}/ok-exit1.sh"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]

  # The diagnostics array must mention the discrepancy.
  jq -e '.diagnostics | length > 0' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.diagnostics[] | select(test("tally/exit-code discrepancy"))' \
    "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "reverse discrepancy: failures tallied but exit code 0 is flagged" {
  # Reverse: not-ok lines present but exit code 0 must also be flagged.
  cat > "${TEST_TMP}/fail-exit0.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'ok 1 test A\n'
printf 'not ok 2 test B\n'
printf 'not ok 3 test C\n'
exit 0
SCRIPT
  chmod +x "${TEST_TMP}/fail-exit0.sh"
  write_custom_command_config "$TEST_TMP/project-config.yaml" "${TEST_TMP}/fail-exit0.sh"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]

  # The diagnostics array must mention the discrepancy.
  jq -e '.diagnostics | length > 0' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.diagnostics[] | select(test("tally/exit-code discrepancy"))' \
    "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "timed-out suite is not flagged as a tally discrepancy" {
  # Boundary: a timed-out suite exits non-zero with 0 failures in the
  # tally, but that is not a contradiction — it is a timeout, not a tally
  # error. This is a green-on-entry regression guard.
  write_timeout_command_config "$TEST_TMP/project-config.yaml"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]

  jq -e '.suites[0].timeout == true' "$WORKDIR/execution-evidence.json" >/dev/null
  # Diagnostics must be empty — no tally discrepancy for a timeout.
  jq -e '.diagnostics | length == 0' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- check-evidence mode ----------------------------------------------------

# Helper: create a temp git repo with one empty commit.
_make_git_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed"
}

# Helper: set up a git repo and evidence directory for check-evidence tests.
# Sets shell vars: _CE_REPO, _CE_DIR, _CE_SHA.
# Optional flags (after the tag arg):
#   --log    plant a qa-tier-output-<sha>.log
#   --json   plant an execution-evidence.json
_make_evidence_fixture() {
  local tag="$1"; shift
  _CE_REPO="$TEST_TMP/repo-${tag}"
  _CE_DIR="$TEST_TMP/evidence-dir-${tag}"
  _make_git_repo "$_CE_REPO"
  _CE_SHA="$(git -C "$_CE_REPO" rev-parse HEAD)"
  mkdir -p "$_CE_DIR"
  while [ $# -gt 0 ]; do
    case "$1" in
      --log)  touch "$_CE_DIR/qa-tier-output-${_CE_SHA}.log" ;;
      --json) printf '{"tier":"tier_1"}\n' > "$_CE_DIR/execution-evidence.json" ;;
    esac
    shift
  done
}

@test "check-evidence refuses when tier log is missing for current HEAD" {
  _make_evidence_fixture no-log --json

  run --separate-stderr "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$_CE_DIR" --code-tree "$_CE_REPO"
  [ "$status" -ne 0 ]
  local combined="${output}${stderr}"
  [[ "$combined" == *"qa-tier-output-${_CE_SHA}.log"* ]]
}

@test "check-evidence refuses when only an older SHA log exists" {
  # Plant evidence for the first commit, then advance HEAD.
  _make_evidence_fixture old-sha --log --json
  local old_sha="$_CE_SHA"

  git -C "$_CE_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "advance"
  local new_sha
  new_sha="$(git -C "$_CE_REPO" rev-parse HEAD)"
  [ "$old_sha" != "$new_sha" ]

  run --separate-stderr "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$_CE_DIR" --code-tree "$_CE_REPO"
  [ "$status" -ne 0 ]
  local combined="${output}${stderr}"
  [[ "$combined" == *"qa-tier-output-${new_sha}.log"* ]]
}

@test "check-evidence refuses when evidence JSON is missing" {
  _make_evidence_fixture no-json --log

  run --separate-stderr "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$_CE_DIR" --code-tree "$_CE_REPO"
  [ "$status" -ne 0 ]
  local combined="${output}${stderr}"
  [[ "$combined" == *"execution-evidence.json"* ]]
}

@test "check-evidence accepts when both files exist for current HEAD" {
  _make_evidence_fixture happy --log --json

  run --separate-stderr "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$_CE_DIR" --code-tree "$_CE_REPO"
  [ "$status" -eq 0 ]
}

@test "check-evidence refuses when code tree is not a git repo" {
  local plain_dir="$TEST_TMP/not-a-git-repo"
  mkdir -p "$plain_dir"
  local edir="$TEST_TMP/evidence-dir-nogit"
  mkdir -p "$edir"

  run --separate-stderr "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$edir" --code-tree "$plain_dir"
  [ "$status" -ne 0 ]
  local combined="${output}${stderr}"
  [[ "$combined" == *"not a git repository"* ]]
}

@test "check-evidence refuses when workdir does not exist" {
  _make_git_repo "$TEST_TMP/repo-noworkdir"

  run --separate-stderr "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$TEST_TMP/does-not-exist" --code-tree "$TEST_TMP/repo-noworkdir"
  [ "$status" -ne 0 ]
  local combined="${output}${stderr}"
  [[ "$combined" == *"does-not-exist"* ]]
}

# --- awk portability (mawk interval quantifier regression) ----------------

@test "File List heading regex uses no awk interval quantifier" {
  # Part (a): when mawk is available, run the runner with a story whose
  # File List heading must be recognized. mawk does not support {N,} or
  # {N,M}, so an awk regex using those silently fails to match and the
  # runner falls back to the full suite even when narrowing should apply.
  # On hosts without mawk, this branch is simply not exercised.
  if command -v mawk >/dev/null 2>&1; then
    mkdir -p "$TEST_TMP/src" "$TEST_TMP/tests" "$TEST_TMP/all-tests"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/src/mawktest.sh"
    cat > "$TEST_TMP/tests/mawktest.bats" <<'BATS'
#!/usr/bin/env bats
BATS
    printf '%s\n' '@test "mawktest works" { true; }' >> "$TEST_TMP/tests/mawktest.bats"

    local story_file="$TEST_TMP/story-mawktest.md"
    write_story_with_file_list "$story_file" "src/mawktest.sh"

    write_slow_full_suite_config "$TEST_TMP/project-config.yaml"

    # Shim awk -> mawk so the runner's awk calls go through mawk.
    local shim_dir="$TEST_TMP/mawk-shim"
    mkdir -p "$shim_dir"
    ln -sf "$(command -v mawk)" "$shim_dir/awk"

    # Prepend the shim dir so the runner finds mawk as "awk".
    run --separate-stderr env \
      GAIA_EXECUTION_CONTEXT=local \
      PATH="${shim_dir}:${PATH}" \
      "$QA_TEST_RUNNER" \
        --story-key "$STORY_KEY" \
        --workdir "$WORKDIR" \
        --config "$TEST_TMP/project-config.yaml" \
        --story-file "$story_file"
    [ "$status" -eq 0 ]

    # The command must reference the scoped test, not the full-suite glob.
    local cmd
    cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
    [[ "$cmd" == *"mawktest.bats"* ]]
    [[ "$cmd" != *"all-tests"* ]]
    # Stderr must NOT contain a "no File List" / fallback message.
    [[ "$stderr" != *"no story-scoped tests"* ]]
    [[ "$stderr" != *"falling back"* ]]
  fi

  # Part (b): host-independent — the awk programs in qa-test-runner.sh must
  # not use {N,} or {N,M} interval quantifiers. These are ERE extensions
  # that mawk does not support. If the script contains any, this assertion
  # fails on every host (including gawk-only CI runners).
  local interval_hits
  interval_hits="$(grep -cE '\{[0-9]+,([0-9]*)?\}' "$QA_TEST_RUNNER" || true)"
  [ "$interval_hits" -eq 0 ]
}

# --- RF-1: code-tree governs story-scoped test discovery --------------------

@test "story-scoped narrowing discovers tests from the code tree, not the config project_path" {
  # Two distinct trees: "main" (config's project_path) and "tree" (--code-tree).
  # Both contain src/widget.sh and tests/widget.bats, but we assert the
  # recorded command uses tree's path, not main's.
  local main_dir="$TEST_TMP/main-tree"
  local code_dir="$TEST_TMP/code-tree"
  mkdir -p "$main_dir/src" "$main_dir/tests"
  mkdir -p "$code_dir/src" "$code_dir/tests"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$main_dir/src/widget.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$code_dir/src/widget.sh"

  cat > "$main_dir/tests/widget.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "main widget" { true; }' >> "$main_dir/tests/widget.bats"

  cat > "$code_dir/tests/widget.bats" <<'BATS'
#!/usr/bin/env bats
BATS
  printf '%s\n' '@test "code-tree widget" { true; }' >> "$code_dir/tests/widget.bats"

  local story_file="$TEST_TMP/story-two-tree.md"
  write_story_with_file_list "$story_file" "src/widget.sh"

  # Config's project_path points at main_dir; --code-tree at code_dir.
  mkdir -p "${TEST_TMP}/all-tests"
  cat > "$TEST_TMP/project-config.yaml" <<EOF
project_root: ${main_dir}
project_path: ${main_dir}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "bats ${main_dir}/all-tests/"
    timeout_seconds: 30
EOF

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml" \
      --story-file "$story_file" \
      --code-tree "$code_dir"
  [ "$status" -eq 0 ]

  # The recorded command must reference the code tree's test file.
  local cmd
  cmd="$(jq -r '.suites[0].command' "$WORKDIR/execution-evidence.json")"
  [[ "$cmd" == *"${code_dir}/tests/widget.bats"* ]]
  [[ "$cmd" != *"${main_dir}"* ]]
}

# --- RF-2: bridge path writes tier output log --------------------------------

# Helper: write a bridge-enabled config with a stub bridge script.
_write_bridge_config_with_stub() {
  local config_path="$1" bridge_script="$2"
  cat > "$config_path" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution_bridge:
  bridge_enabled: true
  run_tests_path: ${bridge_script}
test_execution:
  tier_1:
    placement: local
    command: "true"
    timeout_seconds: 30
EOF
}

@test "bridge path preserves tier output log" {
  # A bridge-enabled run must write qa-tier-output-<sha>.log.
  local bridge_script="${TEST_TMP}/stub-bridge.sh"
  cat > "$bridge_script" <<'STUB'
#!/usr/bin/env bash
printf 'bridge output line 1\n'
cat <<JSON
{"suites":[{"name":"bridge","exit_code":0,"pass_count":1,"fail_count":0,"duration_seconds":0.01}]}
JSON
exit 0
STUB
  chmod +x "$bridge_script"

  _write_bridge_config_with_stub "$TEST_TMP/project-config.yaml" "$bridge_script"

  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]

  # A tier output log must exist in WORKDIR.
  local log_found=false
  local f
  for f in "$WORKDIR"/qa-tier-output-*.log; do
    if [ -f "$f" ]; then log_found=true; break; fi
  done
  [ "$log_found" = "true" ]
}

# --- RF-3: check-evidence refuses skipped evidence ---------------------------

@test "check-evidence refuses when evidence JSON is a skipped run" {
  # A skipped run (e.g. no matching tier) writes skipped:true evidence.
  # Even with a valid tier log for the current SHA, the gate must refuse
  # because a skipped run is not real execution evidence.
  _make_evidence_fixture skipped-json --log
  cat > "$_CE_DIR/execution-evidence.json" <<'JSON'
{
  "tier": "none",
  "context": "local",
  "wall_clock_seconds": 0,
  "skipped": true,
  "bridge_used": false,
  "suites": [],
  "diagnostics": ["test_execution not configured; skipping test execution"]
}
JSON

  run --separate-stderr "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$_CE_DIR" --code-tree "$_CE_REPO"
  [ "$status" -ne 0 ]
  local combined="${output}${stderr}"
  [[ "$combined" == *"skipped"* ]]
}

@test "check-evidence refuses skipped evidence even without jq on PATH" {
  # The skipped-run check must not fail open when jq is absent. Build a
  # shim PATH with every tool the check-evidence path needs except jq.
  _make_evidence_fixture skipped-nojq --log
  cat > "$_CE_DIR/execution-evidence.json" <<'JSON'
{
  "tier": "none",
  "context": "local",
  "wall_clock_seconds": 0,
  "skipped": true,
  "bridge_used": false,
  "suites": [],
  "diagnostics": ["test_execution not configured; skipping test execution"]
}
JSON

  local shim_bin="$TEST_TMP/no-jq-bin"
  mkdir -p "$shim_bin"
  local tool tool_path
  for tool in sh bash env git grep sed awk cat printf rm mkdir dirname basename \
              head tail tr cut readlink stat; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$tool_path" "$shim_bin/$tool"
  done
  # Verify the premise: jq must not be reachable through the shim PATH.
  PATH="$shim_bin" command -v jq >/dev/null 2>&1 && \
    { echo "shim PATH still resolves jq"; false; }

  run --separate-stderr env \
    PATH="$shim_bin" \
    "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$_CE_DIR" --code-tree "$_CE_REPO"
  [ "$status" -ne 0 ]
  local combined="${output}${stderr}"
  [[ "$combined" == *"skipped"* ]]
}

@test "check-evidence refuses when evidence file is invalid JSON" {
  # Malformed JSON must not be accepted — the gate must fail closed.
  _make_evidence_fixture bad-json --log
  printf 'THIS IS NOT JSON {{{' > "$_CE_DIR/execution-evidence.json"

  run --separate-stderr "$QA_TEST_RUNNER" \
    --check-evidence --workdir "$_CE_DIR" --code-tree "$_CE_REPO"
  [ "$status" -ne 0 ]
  local combined="${output}${stderr}"
  [[ "$combined" == *"not valid JSON"* ]]
}
