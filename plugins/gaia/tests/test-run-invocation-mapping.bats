#!/usr/bin/env bats
# test-run-invocation-mapping.bats — AF-2026-05-17-4 regression guard
#
# Three runner-invocation defects closed by this AF:
#
# A) --tag NAME was forwarded verbatim as `--tag` to all providers.
#    bats has no --tag flag; vitest expects -t; pytest expects -m;
#    go expects -run. /gaia-test-run --tag X exited with runner help.
#
# B) --story KEY was forwarded verbatim. SKILL.md prescribed
#    filename-glob expansion (*${KEY}*) which was never implemented.
#
# C) Empty TARGET_ARGS invoked the runner bare. bats prints help; go
#    needs ./... . Vitest/pytest auto-discover at PWD so they tolerate.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/skills/gaia-test-run/scripts/run-tests.sh"
  export LC_ALL=C
}

# Defect A — per-runner --tag mapping
@test "compose_target_args maps --tag to bats --filter" {
  run grep -E 'bats\)[[:space:]]+TARGET_ARGS\+=\("--filter"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "compose_target_args maps --tag to vitest -t" {
  run grep -E 'vitest\)[[:space:]]+TARGET_ARGS\+=\("-t"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "compose_target_args maps --tag to pytest -m" {
  run grep -E 'pytest\)[[:space:]]+TARGET_ARGS\+=\("-m"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "compose_target_args maps --tag to go -run" {
  run grep -E 'go\)[[:space:]]+TARGET_ARGS\+=\("-run"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# Defect B — --story filename-glob expansion
@test "compose_target_args expands --story to filename matches via find" {
  run grep -E 'find \. -maxdepth 4 -type f -name "\*\$\{STORY\}\*"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "compose_target_args FAILED-exits when --story matches zero files" {
  # Must log a clear message AND emit FAILED verdict before exit 3
  run grep -E 'no test files matched story key' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# Defect C — empty-args default invocation
@test "compose_target_args appends default bats dir when no positional arg" {
  # Must detect has_positional==0 AND select a maxdepth-4 highest-density dir
  run grep -E 'has_positional=0' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E 'sort -rn \| head -1' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "compose_target_args appends ./... for go when no positional arg" {
  run grep -F 'TARGET_ARGS+=("./...")' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# Wiring — compose_target_args must be called AFTER detection block
@test "compose_target_args is invoked AFTER provider detection" {
  # The function call line must come AFTER the detection block close
  detect_close=$(grep -nE 'no test runner configured and no detection match' "$SCRIPT" | head -1 | cut -d: -f1)
  compose_call=$(grep -nE '^compose_target_args$' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$detect_close" ]
  [ -n "$compose_call" ]
  [ "$compose_call" -gt "$detect_close" ]
}

