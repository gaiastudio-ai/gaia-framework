#!/usr/bin/env bats
# brain-capstone.bats — coverage aggregation for the brain knowledge layer.
#
# This is a TRACEABILITY gate, not a behavioural suite. The actual schema,
# harvest, reindex, query, MOC, health, and perf behaviours are exercised by
# the nine brain-*.bats files in this directory. This file proves, in a single
# data-driven gap-detector, that every catalogued brain test case still maps to
# a present, named assertion in one of those files — so a covered behaviour
# cannot be silently deleted or renamed without turning this gate red.
#
# The catalogue lives in fixtures/brain-capstone/coverage-map.tsv as opaque
# map data (one row per case: <case-id> <bats-file> <test-name-substring>).
# Paths derive from $BATS_TEST_DIRNAME via test_helper.bash — no hardcoded
# source-layout prefix — so the gate runs identically from a flattened cache.

load 'test_helper.bash'

setup() {
  common_setup
  MAP="$BATS_TEST_DIRNAME/fixtures/brain-capstone/coverage-map.tsv"
}

teardown() {
  common_teardown
}

@test "every catalogued brain test case maps to a present named assertion" {
  [ -f "$MAP" ]
  local rc=0 case_id file name target
  while IFS=$'\t' read -r case_id file name; do
    [ -n "$case_id" ] || continue
    target="$BATS_TEST_DIRNAME/$file"
    if [ ! -f "$target" ]; then
      printf 'MISSING FILE  %s -> %s\n' "$case_id" "$file" >&2
      rc=1
      continue
    fi
    if ! grep -qF "$name" "$target"; then
      printf 'MISSING TEST  %s -> %s :: %s\n' "$case_id" "$file" "$name" >&2
      rc=1
    fi
  done < "$MAP"
  [ "$rc" -eq 0 ]
}

@test "the brain coverage map enumerates the full catalogued case range with no duplicates" {
  [ -f "$MAP" ]
  local total unique
  total="$(grep -c . "$MAP")"
  unique="$(cut -f1 "$MAP" | sort | uniq | grep -c .)"
  [ "$total" -eq 33 ]
  [ "$unique" -eq 33 ]
}

@test "every brain bats file referenced by the coverage map exists in the suite" {
  [ -f "$MAP" ]
  local file
  for file in $(cut -f2 "$MAP" | sort -u); do
    [ -f "$BATS_TEST_DIRNAME/$file" ] || {
      printf 'REFERENCED FILE ABSENT: %s\n' "$file" >&2
      return 1
    }
  done
}
