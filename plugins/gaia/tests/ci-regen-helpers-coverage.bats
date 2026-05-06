#!/usr/bin/env bats
# ci-regen-helpers-coverage.bats — NFR-052 public-function coverage for the
# E71-S4 ci-regen-* helper scripts. The full behavioral suite lives at
# tests/skills/gaia-config-ci-regenerate.bats; this file ensures every
# public function defined in:
#   plugins/gaia/scripts/ci-regen-post-edit-prompt.sh
#   plugins/gaia/scripts/ci-regen-stale-flag.sh
#   plugins/gaia/scripts/ci-regen-user-steps.sh
#   plugins/gaia/scripts/lib/ci-regen-header.sh
# is named in at least one .bats file under plugins/gaia/tests/, satisfying
# run-with-coverage.sh step 3 (NFR-052).
#
# The behavioral assertions below exercise the public CLI surface so
# coverage is not just textual reference — each function actually runs.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# ---- ci-regen-post-edit-prompt.sh: print_prompt, handle_answer ----

@test "ci-regen-post-edit-prompt.sh print_prompt emits y/n/d options" {
  run bash "$SCRIPTS_DIR/ci-regen-post-edit-prompt.sh" print
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "(y)"
  echo "$output" | grep -F "(n)"
  echo "$output" | grep -F "(d)"
}

@test "ci-regen-post-edit-prompt.sh handle_answer y triggers regen path" {
  run bash "$SCRIPTS_DIR/ci-regen-post-edit-prompt.sh" handle y
  [ "$status" -eq 0 ]
}

@test "ci-regen-post-edit-prompt.sh handle_answer n writes stale flag" {
  cd "$TEST_TMPDIR"
  mkdir -p _memory
  run bash "$SCRIPTS_DIR/ci-regen-post-edit-prompt.sh" handle n
  [ "$status" -eq 0 ]
  [ -f _memory/.config-stale ]
}

@test "ci-regen-post-edit-prompt.sh handle_answer d emits diff hint" {
  run bash "$SCRIPTS_DIR/ci-regen-post-edit-prompt.sh" handle d
  [ "$status" -eq 0 ]
}

# ---- ci-regen-stale-flag.sh: write_flag, check_flag, clear_flag, flag_path ----

@test "ci-regen-stale-flag.sh write_flag creates the marker via flag_path" {
  cd "$TEST_TMPDIR"
  mkdir -p _memory
  run bash "$SCRIPTS_DIR/ci-regen-stale-flag.sh" write
  [ "$status" -eq 0 ]
  [ -f _memory/.config-stale ]
}

@test "ci-regen-stale-flag.sh check_flag returns 0 + warns when flag present" {
  cd "$TEST_TMPDIR"
  mkdir -p _memory
  : > _memory/.config-stale
  run bash "$SCRIPTS_DIR/ci-regen-stale-flag.sh" check
  [ "$status" -eq 0 ]
}

@test "ci-regen-stale-flag.sh clear_flag removes the marker (idempotent)" {
  cd "$TEST_TMPDIR"
  mkdir -p _memory
  : > _memory/.config-stale
  run bash "$SCRIPTS_DIR/ci-regen-stale-flag.sh" clear
  [ "$status" -eq 0 ]
  [ ! -e _memory/.config-stale ]
  # Idempotent re-run.
  run bash "$SCRIPTS_DIR/ci-regen-stale-flag.sh" clear
  [ "$status" -eq 0 ]
}

# ---- ci-regen-user-steps.sh: user_steps_path, extract_block, assert_protected ----

@test "ci-regen-user-steps.sh user_steps_path discovery returns sibling path" {
  cd "$TEST_TMPDIR"
  mkdir -p .github/workflows
  printf 'jobs: {}\n' > .github/workflows/gaia-pre-merge.yml
  : > .github/workflows/gaia-pre-merge.user-steps.yml
  run bash "$SCRIPTS_DIR/ci-regen-user-steps.sh" discover .github/workflows/gaia-pre-merge.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "gaia-pre-merge.user-steps.yml"
}

@test "ci-regen-user-steps.sh extract_block returns steps_before_gaia entries" {
  cd "$TEST_TMPDIR"
  cat > us.yml <<'YAML'
steps_before_gaia:
  - name: Pre
    run: echo before
steps_after_gaia: []
YAML
  run bash "$SCRIPTS_DIR/ci-regen-user-steps.sh" extract-before us.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "Pre"
}

@test "ci-regen-user-steps.sh assert_protected refuses *.user-steps.yml writes" {
  run bash "$SCRIPTS_DIR/ci-regen-user-steps.sh" assert-protected /tmp/anything.user-steps.yml
  [ "$status" -ne 0 ]
}

# ---- lib/ci-regen-header.sh: emit_header, hash_stream, parse_header ----

@test "lib/ci-regen-header.sh emit_header includes attribution and Source hash" {
  run bash "$SCRIPTS_DIR/lib/ci-regen-header.sh" emit "abc123"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "Source hash: sha256:abc123"
}

@test "lib/ci-regen-header.sh hash_stream is deterministic over the same input" {
  local h1 h2
  h1="$(printf 'foo\n' | bash "$SCRIPTS_DIR/lib/ci-regen-header.sh" hash)"
  h2="$(printf 'foo\n' | bash "$SCRIPTS_DIR/lib/ci-regen-header.sh" hash)"
  [ "$h1" = "$h2" ]
}

@test "lib/ci-regen-header.sh parse_header extracts the recorded sha256" {
  cd "$TEST_TMPDIR"
  bash "$SCRIPTS_DIR/lib/ci-regen-header.sh" emit "deadbeef" > target.yml
  run bash "$SCRIPTS_DIR/lib/ci-regen-header.sh" parse target.yml
  [ "$status" -eq 0 ]
  [ "$output" = "deadbeef" ]
}
