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
  grep -q "bats-file-timing.tsv" "$WORKFLOW"
}

# ---------------------------------------------------------------------------
# Baseline file structural tests
# ---------------------------------------------------------------------------

@test "committed baseline bats-file-timing.tsv exists and has a header" {
  [ -f "$BASELINE" ]
  local header
  header=$(head -1 "$BASELINE")
  [[ "$header" == '#file'* ]]
  [[ "$header" == *wall_seconds* ]]
}

@test "committed baseline has data rows with numeric wall_seconds" {
  [ -f "$BASELINE" ]
  local data_lines
  data_lines=$(tail -n +2 "$BASELINE" | wc -l | tr -d ' ')
  [ "$data_lines" -gt 0 ]
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
  printf '#file\twall_seconds\n' > "$tmpbl"
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
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'cheap.bats\t5\n' >> "$tmpbl"
  printf 'medium.bats\t15\n' >> "$tmpbl"
  printf 'expensive.bats\t200\n' >> "$tmpbl"

  local result
  result=$(printf 'plugins/gaia/tests/cheap.bats\nplugins/gaia/tests/medium.bats\nplugins/gaia/tests/expensive.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 25 2>/dev/null)
  rm -f "$tmpbl"

  grep -q 'cheap.bats' <<< "$result"
  grep -q 'medium.bats' <<< "$result"
  ! grep -q 'expensive.bats' <<< "$result"
}

@test "cost-select: unknown files get fallback estimate (median, floor 4s)" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'known1.bats\t2\n' >> "$tmpbl"
  printf 'known2.bats\t6\n' >> "$tmpbl"
  printf 'known3.bats\t10\n' >> "$tmpbl"

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
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'fast1.bats\t1\n' >> "$tmpbl"
  printf 'fast2.bats\t2\n' >> "$tmpbl"
  printf 'fast3.bats\t1\n' >> "$tmpbl"

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
  printf '#file\twall_seconds\n' > "$tmpbl"
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
  printf '#file\twall_seconds\n' > "$tmpbl"
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
  printf '#file\twall_seconds\n' > "$tmpbl"

  local result
  result=$(printf '' | bash "$COST_SELECT" "$tmpbl" 240 2>/dev/null)
  rm -f "$tmpbl"

  [ -z "$result" ]
}

@test "cost-select: logs include/drop counts and fallback on stderr" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
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
  printf '#file\twall_seconds\n' > "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  local result
  result=$(printf 'plugins/gaia/tests/new1.bats\nplugins/gaia/tests/new2.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 100 2>"$stderr_out")
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  local count
  count=$(grep -c '.bats' <<< "$result")
  [ "$count" -eq 2 ]
  grep -q 'FALLBACK: 4s' <<< "$log"
}

@test "cost-select: ascending sort selects cheapest files first" {
  # Mutant: if sort were descending (-k1,1nr), the expensive file would be
  # picked first, and the two cheap ones would be dropped.  Ascending order
  # should select a.bats (5) + b.bats (10) = 15 <= 35, dropping c.bats (30).
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'a.bats\t5\n' >> "$tmpbl"
  printf 'b.bats\t10\n' >> "$tmpbl"
  printf 'c.bats\t30\n' >> "$tmpbl"

  local result stderr_out
  stderr_out="$(mktemp)"
  result=$(printf 'plugins/gaia/tests/a.bats\nplugins/gaia/tests/b.bats\nplugins/gaia/tests/c.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 35 2>"$stderr_out")
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  # a.bats and b.bats must be included (ascending picks cheapest first).
  grep -q 'a.bats' <<< "$result"
  grep -q 'b.bats' <<< "$result"
  # c.bats must be dropped (5+10+30=45 > 35).
  ! grep -q 'c.bats' <<< "$result"
  # Report confirms 2 included, 1 dropped.
  grep -q 'SELECTED: 2' <<< "$log"
  grep -q 'DROPPED: 1' <<< "$log"
}

# ---------------------------------------------------------------------------
# Security: numeric validation prevents bash arithmetic injection
# ---------------------------------------------------------------------------

@test "cost-select: injection payload in baseline wall_seconds does not execute" {
  [ -x "$COST_SELECT" ]
  local tmpbl marker
  tmpbl="$(mktemp)"
  marker="$(mktemp -u)"  # path only, file must NOT be created

  # Craft a baseline with a bash arithmetic injection payload.
  # The pattern x[$(cmd)] triggers command substitution inside $((...))
  # when the variable x exists in scope.
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'safe.bats\t5\n' >> "$tmpbl"
  printf 'evil.bats\tx[$(touch %s)]\n' "$marker" >> "$tmpbl"

  local result stderr_out
  stderr_out="$(mktemp)"
  result=$(printf 'plugins/gaia/tests/safe.bats\nplugins/gaia/tests/evil.bats\n' \
    | x=0 bash "$COST_SELECT" "$tmpbl" 240 2>"$stderr_out") || true
  rm -f "$tmpbl" "$stderr_out"

  # The marker file must NOT exist — the injection must not have fired.
  [ ! -f "$marker" ]
  # safe.bats should still be selected (the script should not crash).
  grep -q 'safe.bats' <<< "$result"
}

@test "cost-select: negative wall_seconds treated as fallback (not budget bypass)" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'neg.bats\t-100\n' >> "$tmpbl"
  printf 'ok1.bats\t3\n' >> "$tmpbl"
  printf 'ok2.bats\t3\n' >> "$tmpbl"
  printf 'ok3.bats\t3\n' >> "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  local result
  # Budget is 10.  The three valid entries have median=3 < 4, so fallback=4.
  # neg.bats gets fallback=4.  4+3+3+3=13 > 10, so not all four fit.
  # A negative cost (-100) would have allowed all four (budget bypass).
  result=$(printf 'plugins/gaia/tests/neg.bats\nplugins/gaia/tests/ok1.bats\nplugins/gaia/tests/ok2.bats\nplugins/gaia/tests/ok3.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 10 2>"$stderr_out")
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  # Not all four should be selected (neg.bats with fallback=4 makes
  # the total exceed 10).
  local selected
  selected=$(grep -c '.bats' <<< "$result" || true)
  [ "$selected" -lt 4 ]
  # The report must show at least one dropped file.
  grep -q 'DROPPED: [1-9]' <<< "$log"
}

@test "cost-select: non-numeric wall_seconds treated as fallback" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'alpha.bats\tabc\n' >> "$tmpbl"
  printf 'float.bats\t3.14\n' >> "$tmpbl"
  printf 'expr.bats\t1+1\n' >> "$tmpbl"
  printf 'normal.bats\t5\n' >> "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  local result
  result=$(printf 'plugins/gaia/tests/alpha.bats\nplugins/gaia/tests/float.bats\nplugins/gaia/tests/expr.bats\nplugins/gaia/tests/normal.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 240 2>"$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  # All four should be selected (non-numeric ones get fallback=4,
  # normal gets 5; total = 4+4+4+5 = 17 < 240).
  local count
  count=$(grep -c '.bats' <<< "$result")
  [ "$count" -eq 4 ]
}

@test "cost-select: oversize wall_seconds value does not wrap or bypass budget" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'big.bats\t999999999\n' >> "$tmpbl"
  printf 'small.bats\t1\n' >> "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  local result
  result=$(printf 'plugins/gaia/tests/big.bats\nplugins/gaia/tests/small.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 240 2>"$stderr_out")
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  # small.bats (1s) fits, big.bats (999999999s) does not.
  grep -q 'small.bats' <<< "$result"
  ! grep -q 'big.bats' <<< "$result"
  # The dropped count should include big.bats.
  grep -q 'DROPPED: 1' <<< "$log"
}

@test "cost-select: invalid budget exits 0 with notice" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'a.bats\t5\n' >> "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  local result
  result=$(printf 'plugins/gaia/tests/a.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 'abc' 2>"$stderr_out")
  local rc=$?
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  [ "$rc" -eq 0 ]
  [ -z "$result" ]
  grep -q 'invalid budget' <<< "$log"
}

@test "cost-select: zero budget exits 0 with notice" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'a.bats\t5\n' >> "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  local result
  result=$(printf 'plugins/gaia/tests/a.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 0 2>"$stderr_out")
  local rc=$?
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  [ "$rc" -eq 0 ]
  [ -z "$result" ]
  grep -q 'invalid budget' <<< "$log"
}

@test "cost-select: negative budget exits 0 with notice" {
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'a.bats\t5\n' >> "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  local result
  result=$(printf 'plugins/gaia/tests/a.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" '-10' 2>"$stderr_out")
  local rc=$?
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  [ "$rc" -eq 0 ]
  [ -z "$result" ]
  grep -q 'invalid budget' <<< "$log"
}

# ---------------------------------------------------------------------------
# Generator script structural tests
# ---------------------------------------------------------------------------

@test "cost-select: fallback is median not mean (asymmetric distribution)" {
  # Fixture: wall_seconds 2, 3, 40.  Median = 3, mean = 15.
  # A median->mean mutant would produce fallback=15; median gives 4 (floor).
  [ -x "$COST_SELECT" ]
  local tmpbl
  tmpbl="$(mktemp)"
  printf '#file\twall_seconds\n' > "$tmpbl"
  printf 'fast.bats\t2\n' >> "$tmpbl"
  printf 'mid.bats\t3\n' >> "$tmpbl"
  printf 'slow.bats\t40\n' >> "$tmpbl"

  local stderr_out
  stderr_out="$(mktemp)"
  printf 'plugins/gaia/tests/unknown.bats\n' \
    | bash "$COST_SELECT" "$tmpbl" 100 2>"$stderr_out" >/dev/null
  local log
  log=$(cat "$stderr_out")
  rm -f "$tmpbl" "$stderr_out"

  # Median of [2,3,40] = 3, but floor is 4.  Fallback must be 4, not 15.
  grep -q 'FALLBACK: 4s' <<< "$log"
}

# ---------------------------------------------------------------------------
# Generator script tests
# ---------------------------------------------------------------------------

@test "refresh-bats-file-timing.sh exists and is executable" {
  [ -x "$REFRESH_SCRIPT" ]
}

@test "refresh-bats-file-timing.sh prints usage on missing argument" {
  local output
  output=$(bash "$REFRESH_SCRIPT" 2>&1 || true)
  grep -qi 'usage' <<< "$output"
}

@test "refresh-bats-file-timing.sh no --repo flag does not fail under bash 3.2 set -u" {
  local output
  output=$(/bin/bash "$REFRESH_SCRIPT" 99999 2>&1 || true)
  ! grep -qi 'unbound variable' <<< "$output"
}

@test "refresh-bats-file-timing.sh merges shards keeping max wall_seconds (column 3)" {
  # Two shard TSVs where a.bats appears in both with different wall_seconds.
  # The merge must keep max(5, 12) = 12, reading column 3 (wall_seconds),
  # not column 2 (tests).
  local fixture_dir output_file
  fixture_dir="$(mktemp -d)"
  output_file="$(mktemp)"

  mkdir -p "$fixture_dir/shard-1-timing"
  printf 'file\ttests\twall_seconds\n' > "$fixture_dir/shard-1-timing/shard-1-per-file-timing.tsv"
  printf 'a.bats\t10\t5\n' >> "$fixture_dir/shard-1-timing/shard-1-per-file-timing.tsv"
  printf 'b.bats\t20\t8\n' >> "$fixture_dir/shard-1-timing/shard-1-per-file-timing.tsv"

  mkdir -p "$fixture_dir/shard-2-timing"
  printf 'file\ttests\twall_seconds\n' > "$fixture_dir/shard-2-timing/shard-2-per-file-timing.tsv"
  printf 'a.bats\t8\t12\n' >> "$fixture_dir/shard-2-timing/shard-2-per-file-timing.tsv"
  printf 'c.bats\t15\t3\n' >> "$fixture_dir/shard-2-timing/shard-2-per-file-timing.tsv"

  bash "$REFRESH_SCRIPT" --local-dir "$fixture_dir" --output "$output_file" 2>/dev/null

  # Header row must be present.
  local header
  header=$(head -1 "$output_file")
  [[ "$header" == '#file'* ]]
  [[ "$header" == *"wall_seconds"* ]]

  # a.bats must have wall_seconds=12 (max of 5 and 12), not 10 or 8 (tests column).
  local a_secs
  a_secs=$(awk -F'\t' '$1 == "a.bats" { print $2 }' "$output_file")
  [ "$a_secs" = "12" ]

  # b.bats = 8, c.bats = 3
  local b_secs c_secs
  b_secs=$(awk -F'\t' '$1 == "b.bats" { print $2 }' "$output_file")
  c_secs=$(awk -F'\t' '$1 == "c.bats" { print $2 }' "$output_file")
  [ "$b_secs" = "8" ]
  [ "$c_secs" = "3" ]

  # Exactly 3 data rows + 1 header.
  local total_lines
  total_lines=$(wc -l < "$output_file" | tr -d ' ')
  [ "$total_lines" -eq 4 ]

  rm -rf "$fixture_dir" "$output_file"
}

@test "refresh-bats-file-timing.sh skips header rows from input TSVs" {
  # Two shard TSVs each with a header — the output must have exactly one
  # header row and no "file" or "tests" data rows.
  local fixture_dir output_file
  fixture_dir="$(mktemp -d)"
  output_file="$(mktemp)"

  mkdir -p "$fixture_dir/shard-1-timing"
  printf 'file\ttests\twall_seconds\n' > "$fixture_dir/shard-1-timing/shard-1-per-file-timing.tsv"
  printf 'x.bats\t5\t2\n' >> "$fixture_dir/shard-1-timing/shard-1-per-file-timing.tsv"

  mkdir -p "$fixture_dir/shard-2-timing"
  printf 'file\ttests\twall_seconds\n' > "$fixture_dir/shard-2-timing/shard-2-per-file-timing.tsv"
  printf 'y.bats\t3\t7\n' >> "$fixture_dir/shard-2-timing/shard-2-per-file-timing.tsv"

  bash "$REFRESH_SCRIPT" --local-dir "$fixture_dir" --output "$output_file" 2>/dev/null

  # Exactly one header row.
  local header_count
  header_count=$(grep -c '^#file' "$output_file")
  [ "$header_count" -eq 1 ]

  # Two data rows (x.bats and y.bats).
  local data_count
  data_count=$(tail -n +2 "$output_file" | wc -l | tr -d ' ')
  [ "$data_count" -eq 2 ]

  rm -rf "$fixture_dir" "$output_file"
}
