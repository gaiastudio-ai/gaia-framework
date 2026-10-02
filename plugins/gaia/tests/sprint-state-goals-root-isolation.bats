#!/usr/bin/env bats
# Nested run: the full goals suite must not touch a sentinel project's yaml.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

_sanitize_child_env() {
  if [ -n "${BATS_SAVED_PATH:-}" ]; then
    export PATH="$BATS_SAVED_PATH"
  elif [ -n "${BATS_LIBEXEC:-}" ]; then
    local _cleaned
    _cleaned="$(printf '%s' "$PATH" | awk -v drop="$BATS_LIBEXEC" '
      BEGIN { RS=":"; ORS="" }
      { if ($0 != drop) { if (NR>1 && printed) printf ":"; printf "%s", $0; printed=1 } }
    ')"
    export PATH="$_cleaned"
  fi
  unset BATS_FILTER_TAGS BATS_JOBS BATS_RUN_TMPDIR
}

@test "goals suite does not touch a sentinel project yaml" {
  local sentinel="$TEST_TMP/sentinel"
  mkdir -p "$sentinel/.gaia/state"
  printf 'sprint_id: "sprint-sentinel"\nstatus: active\ngoals:\n  - "do not touch"\nstories: []\n' \
    > "$sentinel/.gaia/state/sprint-status.yaml"
  local before after
  before="$(cksum < "$sentinel/.gaia/state/sprint-status.yaml")"

  _sanitize_child_env
  export PROJECT_ROOT="$sentinel" CLAUDE_PROJECT_ROOT="$sentinel"
  local suite="$BATS_TEST_DIRNAME/sprint-state-goals-and-state-machine.bats"

  run bats --tap "$suite" </dev/null

  # Sentinel file must be byte-identical
  after="$(cksum < "$sentinel/.gaia/state/sprint-status.yaml")"
  [ "$before" = "$after" ]

  # The nested run must have passed
  [ "$status" -eq 0 ]

  # TAP plan line must match exactly: 1..<N> where N = @test count
  local expected_count
  expected_count="$(grep -c '^@test ' "$suite")"
  printf '%s\n' "$output" | grep -qE "^1\\.\\.$expected_count\$"

  # No skipped tests
  local skip_count
  skip_count="$(printf '%s\n' "$output" | grep -c '# skip' || true)"
  [ "$skip_count" -eq 0 ]
}
