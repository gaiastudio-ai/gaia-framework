#!/usr/bin/env bats
# ci-fast-feedback-cap.bats — structural tests for the fast-feedback cost-based
# selection in plugin-ci.yml and the cost-select-tests.sh helper.  Ensures a
# future refactor cannot silently remove the guards that prevent timeout on
# large diffs.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  REPO_ROOT="$( cd "$PLUGIN_DIR/../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  COST_SELECT="$REPO_ROOT/.github/scripts/cost-select-tests.sh"
  REFRESH_SCRIPT="$REPO_ROOT/.github/scripts/refresh-bats-file-timing.sh"
  BASELINE="$REPO_ROOT/.github/bats-file-timing.tsv"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Workflow structural tests
# ---------------------------------------------------------------------------

@test "plugin-ci.yml bats-fast-feedback skips when base branch is the release target" {
  [ -f "$WORKFLOW" ]
  grep -q 'PR_BASE_REF.*main\|main.*PR_BASE_REF' "$WORKFLOW"
  grep -q 'Skipped.*promotion' "$WORKFLOW"
}

@test "plugin-ci.yml bats-fast-feedback declares FAST_FEEDBACK_BUDGET_SECONDS env var" {
  [ -f "$WORKFLOW" ]
  grep -q 'FAST_FEEDBACK_BUDGET_SECONDS' "$WORKFLOW"
}

@test "plugin-ci.yml FAST_FEEDBACK_BUDGET_SECONDS default is at most 240" {
  [ -f "$WORKFLOW" ]
  local val
  val=$(grep 'FAST_FEEDBACK_BUDGET_SECONDS' "$WORKFLOW" \
    | head -1 | sed -E "s/.*FAST_FEEDBACK_BUDGET_SECONDS:[[:space:]]*['\"]?([0-9]+)['\"]?.*/\1/")
  [ -n "$val" ]
  [ "$val" -gt 0 ]
  [ "$val" -le 240 ]
}

@test "plugin-ci.yml bats-fast-feedback calls cost-select-tests.sh" {
  [ -f "$WORKFLOW" ]
  grep -q 'cost-select-tests\.sh' "$WORKFLOW"
}

@test "plugin-ci.yml bats-fast-feedback references the timing baseline" {
  [ -f "$WORKFLOW" ]
  grep -q 'bats-file-timing\.tsv' "$WORKFLOW"
}

@test "plugin-ci.yml path triggers include the timing baseline" {
  [ -f "$WORKFLOW" ]
  # The on.pull_request.paths list must include the baseline so that
  # changes to it trigger CI.
  grep -q "bats-file-timing.tsv" "$WORKFLOW"
}

# ---------------------------------------------------------------------------
# Baseline file structural tests
# ---------------------------------------------------------------------------

@test "committed baseline bats-file-timing.tsv exists and has a header" {
  [ -f "$BASELINE" ]
  local header
  header=$(head -1 "$BASELINE")
  [[ "$header" == *file* ]]
  [[ "$header" == *wall_seconds* ]]
}

@test "committed baseline has data rows with numeric wall_seconds" {
  [ -f "$BASELINE" ]
  local data_lines
  data_lines=$(tail -n +2 "$BASELINE" | wc -l | tr -d ' ')
  [ "$data_lines" -gt 0 ]
  # Verify the first data row has a numeric second column.
  local first_secs
  first_secs=$(sed -n '2p' "$BASELINE" | cut -f2)
  [[ "$first_secs" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# cost-select-tests.sh functional tests
# ---------------------------------------------------------------------------

@test "cost-select: selects all files when total cost is within budget" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"
  printf 'a.bats\t10\n' >> "$tmpbl"
  printf 'b.bats\t20\n' >> "$tmpbl"
  printf 'c.bats\t30\n' >> "$tmpbl"

  local result
  result=$(printf 'plugins/gaia/tests/a.bats\nplugins/gaia/tests/b.bats\nplugins/gaia/tests/c.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 100 2>/dev/null)
  rm -f "$tmpbl"

  local count
  count=$(wc -l <<< "$result" | tr -d ' ')
  [ "$count" -eq 3 ]
}

@test "cost-select: drops expensive files that exceed the budget" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"
  printf 'cheap.bats\t5\n' >> "$tmpbl"
  printf 'medium.bats\t15\n' >> "$tmpbl"
  printf 'expensive.bats\t200\n' >> "$tmpbl"

  local result
  result=$(printf 'plugins/gaia/tests/cheap.bats\nplugins/gaia/tests/medium.bats\nplugins/gaia/tests/expensive.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 25 2>/dev/null)
  rm -f "$tmpbl"

  # cheap (5) + medium (15) = 20 <= 25, but expensive (200) would be 220 > 25
  grep -q 'cheap.bats' <<< "$result"
  grep -q 'medium.bats' <<< "$result"
  ! grep -q 'expensive.bats' <<< "$result"
}

@test "cost-select: unknown files get fallback estimate (median, floor 4s)" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"
  printf 'known1.bats\t2\n' >> "$tmpbl"
  printf 'known2.bats\t6\n' >> "$tmpbl"
  printf 'known3.bats\t10\n' >> "$tmpbl"

  # Median of [2, 6, 10] = 6.  unknown.bats should get fallback 6.
  local stderr_out
  stderr_out="$(mktemp)"
  printf 'plugins/gaia/tests/unknown.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 100 2>"$stderr_out" >/dev/null
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  grep -q 'FALLBACK: 6s' <<< "$log"
}

@test "cost-select: fallback has a floor of 4s when median is lower" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"
  printf 'fast1.bats\t1\n' >> "$tmpbl"
  printf 'fast2.bats\t2\n' >> "$tmpbl"
  printf 'fast3.bats\t1\n' >> "$tmpbl"

  # Median of [1, 1, 2] = 1, but floor is 4.
  local stderr_out
  stderr_out="$(mktemp)"
  printf 'plugins/gaia/tests/unknown.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 100 2>"$stderr_out" >/dev/null
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  grep -q 'FALLBACK: 4s' <<< "$log"
}

@test "cost-select: missing baseline exits 0 with notice" {
  [ -x "$COST_SELECT" ]
  local result stderr_out
  stderr_out="$(mktemp)"
  result=$(printf 'test.bats\n' | bash "$COST_SELECT" "/nonexistent/baseline.tsv" 240 2>"$stderr_out")
  local rc=$?
  local log
  log=$(cat "$stderr_out")
  rm -f "$stderr_out"

  [ "$rc" -eq 0 ]
  [ -z "$result" ]
  grep -q 'timing baseline unavailable' <<< "$log"
}

@test "cost-select: zero-fit exits 0 with notice" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"
  printf 'huge.bats\t500\n' >> "$tmpbl"

  local result stderr_out
  stderr_out="$(mktemp)"
  result=$(printf 'plugins/gaia/tests/huge.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 240 2>"$stderr_out")
  local rc=$?
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  [ "$rc" -eq 0 ]
  [ -z "$result" ]
  grep -q 'no files fit' <<< "$log"
}

@test "cost-select: file exactly at budget is included" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"
  printf 'exact.bats\t240\n' >> "$tmpbl"

  local result
  result=$(printf 'plugins/gaia/tests/exact.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 240 2>/dev/null)
  rm -f "$tmpbl"

  grep -q 'exact.bats' <<< "$result"
}

@test "cost-select: empty candidates produce no output" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"

  local result
  result=$(printf '' | bash "$COST_SELECT" "$tmpbl" 240 2>/dev/null)
  rm -f "$tmpbl"

  [ -z "$result" ]
}

@test "cost-select: logs include/drop counts and fallback on stderr" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"
  printf 'a.bats\t100\n' >> "$tmpbl"
  printf 'b.bats\t100\n' >> "$tmpbl"
  printf 'c.bats\t100\n' >> "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  printf 'plugins/gaia/tests/a.bats\nplugins/gaia/tests/b.bats\nplugins/gaia/tests/c.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 200 2>"$stderr_out" >/dev/null
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  grep -q 'SELECTED:' <<< "$log"
  grep -q 'DROPPED:' <<< "$log"
  grep -q 'FALLBACK:' <<< "$log"
}

@test "cost-select: empty baseline (header only) assigns fallback to all candidates" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf 'file\twall_seconds\n' > "$tmpbl"
  # No data rows -- all candidates get fallback (floor 4s).

  local stderr_out
  stderr_out="$(mktemp)"
  local result
  result=$(printf 'plugins/gaia/tests/new1.bats\nplugins/gaia/tests/new2.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 100 2>"$stderr_out")
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  # Both files should be included (2 * 4s = 8s < 100s).
  local count
  count=$(grep -c '.bats' <<< "$result")
  [ "$count" -eq 2 ]
  grep -q 'FALLBACK: 4s' <<< "$log"
}

# ---------------------------------------------------------------------------
# Generator script structural tests
# ---------------------------------------------------------------------------

@test "refresh-bats-file-timing.sh exists and is executable" {
  [ -x "$REFRESH_SCRIPT" ]
}

@test "refresh-bats-file-timing.sh prints usage on missing argument" {
  local output
  output=$(bash "$REFRESH_SCRIPT" 2>&1 || true)
  grep -qi 'usage' <<< "$output"
}
