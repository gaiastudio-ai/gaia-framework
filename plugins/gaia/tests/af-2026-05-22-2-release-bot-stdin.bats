#!/usr/bin/env bats
# AF-2026-05-22-2: release-bot ARG_MAX (E_2BIG) fix.
# Closes the bug where the release workflow failed with "Argument list too
# long" on the sprint-52 staging→main merge (PR #877, 45+ commits). The
# release.yml workflow now pipes commit blobs to classify-commits.js via
# stdin instead of argv.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
}

teardown() { common_teardown; }

# --- Script CLI surface ---

@test "AF-2026-05-22-2: classify-commits.js supports --stdin flag" {
  printf 'feat(x): one\\n---COMMIT---\\nfix(y): two\\n---COMMIT---\\n' \
    | node "$REPO_ROOT/scripts/classify-commits.js" --stdin > "$BATS_TEST_TMPDIR/out"
  grep -q '^bump_size=minor$' "$BATS_TEST_TMPDIR/out"
  grep -q '^has_commits=true$' "$BATS_TEST_TMPDIR/out"
}

@test "AF-2026-05-22-2: classify-commits.js argv mode still works (backward compat)" {
  node "$REPO_ROOT/scripts/classify-commits.js" "feat(x): one\n---COMMIT---\nfix(y): two\n---COMMIT---\n" > "$BATS_TEST_TMPDIR/out"
  grep -q '^bump_size=minor$' "$BATS_TEST_TMPDIR/out"
}

@test "AF-2026-05-22-2: classify-commits.js --stdin handles a 60-commit blob without ARG_MAX failure" {
  # Bloated 60-commit blob (simulates the sprint-52 staging→main merge that failed).
  local blob
  blob=""
  for i in $(seq 1 60); do
    blob+="feat(scope-${i}): commit ${i}\\nbody line for commit ${i} with extra padding to inflate size\\n---COMMIT---\\n"
  done
  printf '%s' "$blob" | node "$REPO_ROOT/scripts/classify-commits.js" --stdin > "$BATS_TEST_TMPDIR/out"
  grep -q '^bump_size=minor$' "$BATS_TEST_TMPDIR/out"
}

@test "AF-2026-05-22-2: classify-commits.js usage message documents --stdin" {
  run node "$REPO_ROOT/scripts/classify-commits.js"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qFe '--stdin'
}

# --- Workflow wiring ---

@test "AF-2026-05-22-2: release.yml Classify step pipes via stdin (not argv)" {
  grep -qE 'printf .* \| node scripts/classify-commits\.js --stdin' "$REPO_ROOT/.github/workflows/release.yml"
}

@test "AF-2026-05-22-2: release.yml Update CHANGELOG step pipes via stdin (not argv)" {
  # The node -e block must read from fd 0 via fs.readFileSync(0, ...) not process.argv
  grep -qF "readFileSync(0, 'utf8')" "$REPO_ROOT/.github/workflows/release.yml"
}

@test "AF-2026-05-22-2: release.yml no longer passes large blob via argv to classify-commits.js" {
  # Regression guard against the old pattern "node scripts/classify-commits.js \"$ESCAPED\""
  ! grep -qE 'node scripts/classify-commits\.js "\$ESCAPED"' "$REPO_ROOT/.github/workflows/release.yml"
}
