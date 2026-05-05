#!/usr/bin/env bats
# E53-S245 — H3 sharder extraction.
#
# Verifies AC1, AC2, AC3 of E53-S245:
#   AC1 — script lives at scripts/h3-shard.sh with correct shebang + set flags.
#   AC2 — flag CLI (`--input <file> --output-dir <dir>`) produces H3-level shards.
#   AC3 — happy path + idempotency + zero-H3-headings edge case.

setup() {
  SKILL_DIR="${BATS_TEST_DIRNAME}/.."
  SCRIPT="${SKILL_DIR}/scripts/h3-shard.sh"
  HAPPY_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/mixed-h3-fixture.md"
  EMPTY_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/no-h3-fixture.md"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "AC1: h3-shard.sh exists at scripts/h3-shard.sh" {
  [ -f "$SCRIPT" ]
}

@test "AC1: h3-shard.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "AC1: h3-shard.sh declares bash shebang" {
  head -n1 "$SCRIPT" | grep -q '^#!/usr/bin/env bash$'
}

@test "AC1: h3-shard.sh sets set -euo pipefail" {
  grep -q '^set -euo pipefail$' "$SCRIPT"
}

@test "AC2: flag-style invocation produces shards + index.md" {
  out_dir="${TMP_DIR}/out"
  run "$SCRIPT" --input "$HAPPY_FIXTURE" --output-dir "$out_dir"
  [ "$status" -eq 0 ]
  [ -f "${out_dir}/index.md" ]
  # Three H3 sections in the fixture -> three shards.
  shard_count=$(find "$out_dir" -maxdepth 1 -name '*.md' ! -name 'index.md' ! -name '_preamble.md' | wc -l | tr -d '[:space:]')
  [ "$shard_count" -eq 3 ]
}

@test "AC2: flag-style emits one shard per H3 with section heading preserved" {
  out_dir="${TMP_DIR}/out"
  run "$SCRIPT" --input "$HAPPY_FIXTURE" --output-dir "$out_dir"
  [ "$status" -eq 0 ]
  # Each shard must contain its `### ` heading on the first body line.
  alpha_shard=$(find "$out_dir" -maxdepth 1 -name '*alpha*.md' | head -n1)
  beta_shard=$(find "$out_dir" -maxdepth 1 -name '*beta*.md' | head -n1)
  gamma_shard=$(find "$out_dir" -maxdepth 1 -name '*gamma*.md' | head -n1)
  [ -n "$alpha_shard" ]
  [ -n "$beta_shard" ]
  [ -n "$gamma_shard" ]
  head -n1 "$alpha_shard" | grep -q '^### Alpha Section$'
  head -n1 "$beta_shard"  | grep -q '^### Beta Section$'
  head -n1 "$gamma_shard" | grep -q '^### Gamma Section$'
}

@test "AC2: preamble lines above the first H3 land in _preamble.md" {
  out_dir="${TMP_DIR}/out"
  run "$SCRIPT" --input "$HAPPY_FIXTURE" --output-dir "$out_dir"
  [ "$status" -eq 0 ]
  [ -f "${out_dir}/_preamble.md" ]
  # The preamble should contain the H1 line and the Section A H2 line.
  grep -q '^# Top-level Document$' "${out_dir}/_preamble.md"
  grep -q '^## Section A' "${out_dir}/_preamble.md"
  # The preamble must NOT contain any H3 heading.
  ! grep -q '^### ' "${out_dir}/_preamble.md"
}

@test "AC3: idempotency — repeated runs produce byte-identical output" {
  run_a="${TMP_DIR}/runA"
  run_b="${TMP_DIR}/runB"
  run "$SCRIPT" --input "$HAPPY_FIXTURE" --output-dir "$run_a"
  [ "$status" -eq 0 ]
  run "$SCRIPT" --input "$HAPPY_FIXTURE" --output-dir "$run_b"
  [ "$status" -eq 0 ]
  diff -r "$run_a" "$run_b"
}

@test "AC3: zero-H3-headings edge case fails with clear error" {
  out_dir="${TMP_DIR}/empty-out"
  run "$SCRIPT" --input "$EMPTY_FIXTURE" --output-dir "$out_dir"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi 'no h3 boundaries'
}

@test "AC3: positional invocation (back-compat) matches flag-style output" {
  flag_out="${TMP_DIR}/flag-out"
  pos_out="${TMP_DIR}/pos-out"
  run "$SCRIPT" --input "$HAPPY_FIXTURE" --output-dir "$flag_out"
  [ "$status" -eq 0 ]
  run "$SCRIPT" "$HAPPY_FIXTURE" "$pos_out"
  [ "$status" -eq 0 ]
  diff -r "$flag_out" "$pos_out"
}
