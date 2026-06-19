#!/usr/bin/env bats
# lib-transcript-writer.bats — TDD red-phase tests for scripts/lib/transcript-writer.sh
#
# Story: E93-S4. Traces to AC5, T-SGR-7, SR-65, SR-67.

setup() {
  HELPER="${BATS_TEST_DIRNAME}/../scripts/lib/transcript-writer.sh"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "helper exists at canonical path" {
  [ -f "$HELPER" ]
}

@test "helper exports the 3 required functions when sourced" {
  source "$HELPER"
  type write_transcript >/dev/null 2>&1
  type transcript_path_for >/dev/null 2>&1
  type assert_gitignored >/dev/null 2>&1
}

@test "transcript_path_for emits canonical path under .gaia/memory/checkpoints/" {
  source "$HELPER"
  out=$(transcript_path_for "sprint-47" "node")
  echo "$out" | grep -q ".gaia/memory/checkpoints/sprint-review-sprint-47/node.log"
}

@test "write_transcript creates file with mode 0600" {
  source "$HELPER"
  fpath="$TMPDIR_TEST/test-transcript.log"
  printf "hello\n" | write_transcript "$fpath"
  [ -f "$fpath" ]
  # macOS: stat -f '%Lp'; Linux: stat -c '%a'. Detect by OS.
  if [ "$(uname)" = "Darwin" ]; then
    mode=$(stat -f '%Lp' "$fpath")
  else
    mode=$(stat -c '%a' "$fpath")
  fi
  [ "$mode" = "600" ]
}

@test "write_transcript writes stdin content to file" {
  source "$HELPER"
  fpath="$TMPDIR_TEST/test-transcript.log"
  printf "line-one\nline-two\n" | write_transcript "$fpath"
  grep -q "line-one" "$fpath"
  grep -q "line-two" "$fpath"
}

@test "assert_gitignored passes when pattern is covered" {
  source "$HELPER"
  cd "$TMPDIR_TEST"
  cat >.gitignore <<'EOF'
.gaia/memory/checkpoints/sprint-review-*
EOF
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "assert_gitignored HALTs when pattern is missing" {
  source "$HELPER"
  cd "$TMPDIR_TEST"
  echo "# empty" >.gitignore
  run assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "HALT" || echo "$output" | grep -qi "gitignore"
}

@test "assert_gitignored HALT message names the required pattern" {
  source "$HELPER"
  cd "$TMPDIR_TEST"
  echo "" >.gitignore
  run assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
  echo "$output" | grep -q ".gaia/memory/checkpoints/sprint-review"
}
