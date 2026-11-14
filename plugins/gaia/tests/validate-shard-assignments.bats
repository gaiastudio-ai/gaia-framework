#!/usr/bin/env bats
# validate-shard-assignments.bats — tests for the shard-assignment validator
# script (.github/scripts/validate-shard-assignments.sh).
#
# Covers the membership check (unassigned / stale files) and the empty-shard
# check that reads the shard count from the workflow matrix.

load 'test_helper.bash'

setup() {
  common_setup

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  VALIDATOR="$REPO_ROOT/.github/scripts/validate-shard-assignments.sh"

  # Build a minimal fake repo tree inside the per-test temp dir.
  FAKE_ROOT="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$FAKE_ROOT/.github/scripts"
  mkdir -p "$FAKE_ROOT/.github/workflows"
  mkdir -p "$FAKE_ROOT/plugins/gaia/tests"

  export REPO_ROOT VALIDATOR FAKE_ROOT
}

teardown() { common_teardown; }

# --- helpers ---

_write_workflow() {
  # Write a minimal workflow file with the given shard array.
  local shard_array="${1:-[1, 2, 3, 4, 5]}"
  cat > "$FAKE_ROOT/.github/workflows/plugin-ci.yml" <<EOF
jobs:
  bats-shard:
    strategy:
      matrix:
        shard: ${shard_array}
EOF
}

_write_tsv() {
  # Write a shard assignment TSV with the given lines (shard<TAB>file<TAB>weight).
  {
    printf '# shard\tfile\ttests\n'
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$FAKE_ROOT/.github/bats-shard-assignments.tsv"
}

_create_bats_file() {
  # Create an empty .bats file in the fake test directory.
  touch "$FAKE_ROOT/plugins/gaia/tests/$1"
}

# --- real-repo smoke tests ---

@test "validator: real repo passes validation" {
  run bash "$VALIDATOR" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "validator: real TSV has no empty shards" {
  run bash "$VALIDATOR" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # Should NOT contain any empty-shard error.
  ! grep -qF 'has no files assigned' <<< "$output"
}

# --- synthetic tests: membership ---

@test "validator: passes when all files are assigned and no extras" {
  _create_bats_file "foo.bats"
  _create_bats_file "bar.bats"
  _write_tsv "1	foo.bats	10" "2	bar.bats	5"
  _write_workflow "[1, 2]"

  run bash "$VALIDATOR" "$FAKE_ROOT"
  [ "$status" -eq 0 ]
  grep -qF 'OK' <<< "$output"
}

@test "validator: fails when a .bats file is unassigned" {
  _create_bats_file "foo.bats"
  _create_bats_file "bar.bats"
  _create_bats_file "new.bats"
  _write_tsv "1	foo.bats	10" "2	bar.bats	5"
  _write_workflow "[1, 2]"

  run bash "$VALIDATOR" "$FAKE_ROOT"
  [ "$status" -eq 1 ]
  grep -qF 'new.bats' <<< "$output"
}

@test "validator: fails when assignment references a stale file" {
  _create_bats_file "foo.bats"
  _write_tsv "1	foo.bats	10" "2	gone.bats	5"
  _write_workflow "[1, 2]"

  run bash "$VALIDATOR" "$FAKE_ROOT"
  [ "$status" -eq 1 ]
  grep -qF 'gone.bats' <<< "$output"
}

# --- synthetic tests: empty-shard check ---

@test "validator: fails when a shard has no files assigned" {
  _create_bats_file "a.bats"
  _create_bats_file "b.bats"
  # Both files assigned to shard 1; shard 2 is empty.
  _write_tsv "1	a.bats	10" "1	b.bats	5"
  _write_workflow "[1, 2]"

  run bash "$VALIDATOR" "$FAKE_ROOT"
  [ "$status" -eq 1 ]
  grep -qF 'shard 2 has no files assigned' <<< "$output"
}

@test "validator: empty-shard check works with five shards" {
  _create_bats_file "a.bats"
  _create_bats_file "b.bats"
  _create_bats_file "c.bats"
  _create_bats_file "d.bats"
  _create_bats_file "e.bats"
  _write_tsv "1	a.bats	10" "2	b.bats	5" "3	c.bats	5" "4	d.bats	5" "5	e.bats	5"
  _write_workflow "[1, 2, 3, 4, 5]"

  run bash "$VALIDATOR" "$FAKE_ROOT"
  [ "$status" -eq 0 ]
  grep -qF 'OK' <<< "$output"
}

@test "validator: empty-shard names the missing shard" {
  _create_bats_file "a.bats"
  _create_bats_file "b.bats"
  _create_bats_file "c.bats"
  # Shards 1 and 3 have files; shard 2 is empty.
  _write_tsv "1	a.bats	10" "1	b.bats	5" "3	c.bats	5"
  _write_workflow "[1, 2, 3]"

  run bash "$VALIDATOR" "$FAKE_ROOT"
  [ "$status" -eq 1 ]
  grep -qF 'shard 2 has no files assigned' <<< "$output"
}

@test "validator: gracefully skips empty-shard check when workflow is missing" {
  _create_bats_file "a.bats"
  _write_tsv "1	a.bats	10"
  # No workflow file at all.
  rm -f "$FAKE_ROOT/.github/workflows/plugin-ci.yml"

  run bash "$VALIDATOR" "$FAKE_ROOT"
  [ "$status" -eq 0 ]
  grep -qF 'OK' <<< "$output"
}
