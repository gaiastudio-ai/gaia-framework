#!/usr/bin/env bats
# gaia-doctor-stray-snapshots.bats — verify the stray-snapshot detector.
#
# Covers:
#   - Seeded strays are reported with removal commands
#   - Canonical root snapshot is NOT reported as stray
#   - .gaia-worktrees/ snapshots are excluded (pruned)
#   - JSON output carries paths array and count
#   - Nothing is deleted by the scan
#   - No-stray project reports clean

load '../test_helper.bash'

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  CHECKER="$REPO_ROOT/plugins/gaia/skills/gaia-doctor/scripts/check-stray-snapshots.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/stray-doc-$$"
  # Build a project tree with canonical .gaia/memory/ at root.
  mkdir -p "$TEST_TMP/project/.gaia/config"
  touch "$TEST_TMP/project/.gaia/config/project-config.yaml"
  mkdir -p "$TEST_TMP/project/.gaia/memory"
  printf '{"input_tokens":100}' > "$TEST_TMP/project/.gaia/memory/.context-window-snapshot.json"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ---------- Scenario: seeded strays are reported ----------

@test "seeded stray snapshots are reported with removal commands" {
  # Seed two stray snapshots in subdirectories.
  mkdir -p "$TEST_TMP/project/src/.gaia/memory"
  printf '{"input_tokens":1}' > "$TEST_TMP/project/src/.gaia/memory/.context-window-snapshot.json"
  mkdir -p "$TEST_TMP/project/docs/.gaia/memory"
  printf '{"input_tokens":2}' > "$TEST_TMP/project/docs/.gaia/memory/.context-window-snapshot.json"

  run bash "$CHECKER" --project-root "$TEST_TMP/project"
  [ "$status" -eq 0 ]
  # Must mention both stray paths.
  grep -qF "src/.gaia/memory/.context-window-snapshot.json" <<< "$output" \
    || { echo "stray in src/ not reported" >&2; echo "$output" >&2; false; }
  grep -qF "docs/.gaia/memory/.context-window-snapshot.json" <<< "$output" \
    || { echo "stray in docs/ not reported" >&2; echo "$output" >&2; false; }
  # Must print removal commands.
  grep -qF "rm -f" <<< "$output" \
    || { echo "removal command not printed" >&2; echo "$output" >&2; false; }
  # Files must still exist (nothing deleted).
  [ -f "$TEST_TMP/project/src/.gaia/memory/.context-window-snapshot.json" ] \
    || { echo "stray file was deleted!" >&2; false; }
  [ -f "$TEST_TMP/project/docs/.gaia/memory/.context-window-snapshot.json" ] \
    || { echo "stray file was deleted!" >&2; false; }
}

# ---------- Scenario: canonical root NOT reported ----------

@test "canonical root snapshot is not reported as stray" {
  run bash "$CHECKER" --project-root "$TEST_TMP/project"
  [ "$status" -eq 0 ]
  grep -qF "No stray" <<< "$output" \
    || { echo "expected clean report" >&2; echo "$output" >&2; false; }
}

# ---------- Scenario: .gaia-worktrees/ excluded ----------

@test "worktree snapshots are excluded from stray scan" {
  mkdir -p "$TEST_TMP/project/.gaia-worktrees/E99-S1/.gaia/memory"
  printf '{"input_tokens":99}' > "$TEST_TMP/project/.gaia-worktrees/E99-S1/.gaia/memory/.context-window-snapshot.json"
  run bash "$CHECKER" --project-root "$TEST_TMP/project"
  [ "$status" -eq 0 ]
  grep -qF "No stray" <<< "$output" \
    || { echo "worktree snapshot incorrectly reported as stray" >&2; echo "$output" >&2; false; }
}

# ---------- Scenario: JSON output ----------

@test "JSON output carries stray_snapshots with paths and count" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  mkdir -p "$TEST_TMP/project/sub/.gaia/memory"
  printf '{"input_tokens":1}' > "$TEST_TMP/project/sub/.gaia/memory/.context-window-snapshot.json"

  run bash "$CHECKER" --json --project-root "$TEST_TMP/project"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.stray_snapshots.count == 1' >/dev/null \
    || { echo "count mismatch" >&2; echo "$output" >&2; false; }
  echo "$output" | jq -e '.stray_snapshots.paths[0] | test("sub/")' >/dev/null \
    || { echo "path not in JSON" >&2; echo "$output" >&2; false; }
}

# ---------- Scenario: no strays -> clean report ----------

@test "clean project with no strays reports zero" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  run bash "$CHECKER" --json --project-root "$TEST_TMP/project"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.stray_snapshots.count == 0' >/dev/null \
    || { echo "expected count 0" >&2; echo "$output" >&2; false; }
}
