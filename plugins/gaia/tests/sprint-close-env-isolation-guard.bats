#!/usr/bin/env bats
# sprint-close-env-isolation-guard.bats
#
# Guards that running sprint-close tests with ambient PROJECT_ROOT /
# CLAUDE_PROJECT_ROOT exports never writes outside each test's temp
# directory. Also verifies that common_setup strips these variables.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close"
CLOSE_SH="$SKILL_DIR/scripts/close.sh"

# The three close.sh-executing test files (absolute paths).
CLOSE_FILE_1="$BATS_TEST_DIRNAME/gaia-sprint-close.bats"
CLOSE_FILE_2="$BATS_TEST_DIRNAME/sprint-close-sentinel-unconditional.bats"
CLOSE_FILE_3="$BATS_TEST_DIRNAME/sprint-close-yq-fallback-and-dual-event.bats"

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# ---- helpers ----

# Sanitize the bats environment for a nested child invocation.
# Mirrors _sanitize_bats_env in qa-test-runner.sh.
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

# Take a dual snapshot of a directory: tree listing + file content checksums.
# Args: <dir> <tree_outfile> <content_outfile>
_snapshot() {
  local dir="$1" tree_out="$2" content_out="$3"
  find "$dir" -print | LC_ALL=C sort > "$tree_out"
  find "$dir" -type f -exec cksum {} + | LC_ALL=C sort > "$content_out"
}

# Seed a project-shaped sentinel directory that close.sh will recognise.
# Includes a pre-existing close-summary to exercise the close-summary append path.
_seed_sentinel() {
  local sentinel="$1"
  mkdir -p "$sentinel/.gaia/artifacts/implementation-artifacts/sprint-archive"
  touch "$sentinel/.gaia/artifacts/implementation-artifacts/.marker"
  printf '# Existing close summary\n' \
    > "$sentinel/.gaia/artifacts/implementation-artifacts/sprint-archive/sprint-70-closed-2026-06-24-close-summary.md"
}

# ---- variables unset after common_setup ----

@test "common_setup unsets PROJECT_ROOT and CLAUDE_PROJECT_ROOT from the environment" {
  # Simulate an ambient GAIA session that exports both variables.
  export PROJECT_ROOT="/fake/project/root"
  export CLAUDE_PROJECT_ROOT="/fake/claude/root"

  # common_setup was already called in setup(); call it again after exporting.
  common_setup

  # Assert both variables are truly unset (not merely empty).
  # The ${VAR+x} form is safe under set -u: expands to "" when unset, "x" when set.
  [ -z "${PROJECT_ROOT+x}" ]
  [ -z "${CLAUDE_PROJECT_ROOT+x}" ]
}

# ---- preservation: explicit set after common_setup drives close.sh ----

@test "explicit PROJECT_ROOT set after common_setup directs close.sh archive" {
  # Preservation test: proves that an explicit PROJECT_ROOT set after
  # common_setup survives and drives close.sh's archive path. PROJECT_PATH
  # points elsewhere so the archive landing under PROJECT_ROOT proves the
  # explicit value won the resolution.
  export PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP/decoy"
  export MEMORY_PATH="$TEST_TMP/.gaia/memory"
  export GAIA_SPRINT_CLOSE_DATE="2026-06-24"
  export SPRINT_STATE_SH="/nonexistent/sprint-state.sh"

  # Seed a minimal project fixture under TEST_TMP (where PROJECT_ROOT points).
  local art="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local ckpt="$TEST_TMP/.gaia/memory/checkpoints"
  local yaml="$TEST_TMP/.gaia/state/sprint-status.yaml"
  mkdir -p "$art/sprint-archive" "$ckpt" "$(dirname "$yaml")" "$MEMORY_PATH"
  export SPRINT_STATUS_YAML="$yaml"

  # Sprint-status YAML.
  cat > "$yaml" <<'YAML'
sprint_id: "sprint-70"
status: active
total_points: 6
stories:
  - key: "S1"
    status: done
    points: 3
    risk: medium
  - key: "S2"
    status: done
    points: 3
    risk: medium
YAML

  # Retro doc (required by close.sh precondition).
  touch "$art/retrospective-sprint-70-2026-06-24.md"

  # Sprint-review sentinel.
  printf '{"agent":"val","status":"PASSED","summary":"ok","findings":[]}\n' \
    > "$ckpt/sprint-review-sprint-70-val-dispatched.json"

  run bash "$CLOSE_SH" --force
  [ "$status" -eq 0 ]

  # Archive must land under PROJECT_ROOT (TEST_TMP), not under PROJECT_PATH.
  [ -f "$art/sprint-archive/sprint-70-closed-2026-06-24.yaml" ]
}

# ---- sentinel guard: nested sprint-close run ----

@test "nested sprint-close tests do not write outside their temp directories" {
  # Verify bats is available.
  command -v bats >/dev/null 2>&1 || {
    printf 'bats not found on PATH\n' >&2
    return 1
  }

  # Verify the three close-file targets exist.
  [ -f "$CLOSE_FILE_1" ] || { printf 'missing: %s\n' "$CLOSE_FILE_1" >&2; return 1; }
  [ -f "$CLOSE_FILE_2" ] || { printf 'missing: %s\n' "$CLOSE_FILE_2" >&2; return 1; }
  [ -f "$CLOSE_FILE_3" ] || { printf 'missing: %s\n' "$CLOSE_FILE_3" >&2; return 1; }

  # Compute expected test count from the three files.
  local expected_count
  expected_count=$(cat "$CLOSE_FILE_1" "$CLOSE_FILE_2" "$CLOSE_FILE_3" \
    | grep -c '^@test')
  [ "$expected_count" -gt 0 ]

  # Build the sentinel.
  local sentinel="$TEST_TMP/sentinel"
  _seed_sentinel "$sentinel"

  # Pre-snapshots.
  _snapshot "$sentinel" "$TEST_TMP/tree-before.txt" "$TEST_TMP/content-before.txt"

  # Sanitize bats env for the nested child.
  _sanitize_child_env

  # Run the three files as a nested child with both vars pointing at sentinel.
  # Capture exit code safely — a failing child must not abort before snapshot
  # comparison.
  local child_rc=0
  env PROJECT_ROOT="$sentinel" CLAUDE_PROJECT_ROOT="$sentinel" \
    bats --tap "$CLOSE_FILE_1" "$CLOSE_FILE_2" "$CLOSE_FILE_3" \
    </dev/null > "$TEST_TMP/child-output.tap" 2>&1 || child_rc=$?

  # Post-snapshots.
  _snapshot "$sentinel" "$TEST_TMP/tree-after.txt" "$TEST_TMP/content-after.txt"

  # ---- Assert sentinel invariance FIRST ----

  # Tree comparison (new directories or files).
  if ! diff -q "$TEST_TMP/tree-before.txt" "$TEST_TMP/tree-after.txt" >/dev/null 2>&1; then
    printf 'SENTINEL TREE CHANGED — added/removed paths:\n' >&2
    diff "$TEST_TMP/tree-before.txt" "$TEST_TMP/tree-after.txt" >&2 || true
    printf '\nFull tree after:\n' >&2
    cat "$TEST_TMP/tree-after.txt" >&2
    return 1
  fi

  # Content comparison (modified files, e.g. appended close-summary).
  if ! diff -q "$TEST_TMP/content-before.txt" "$TEST_TMP/content-after.txt" >/dev/null 2>&1; then
    printf 'SENTINEL CONTENT CHANGED — modified files:\n' >&2
    diff "$TEST_TMP/content-before.txt" "$TEST_TMP/content-after.txt" >&2 || true
    return 1
  fi

  # ---- Assert child ran the expected plan and passed ----

  # Extract the plan line (1..N).
  local plan_line
  plan_line=$(grep -E '^1\.\.[0-9]+' "$TEST_TMP/child-output.tap" | head -1)
  [ -n "$plan_line" ] || {
    printf 'no TAP plan line found in child output\n' >&2
    cat "$TEST_TMP/child-output.tap" >&2
    return 1
  }

  local plan_count
  plan_count="${plan_line#1..}"
  [ "$plan_count" -eq "$expected_count" ] || {
    printf 'plan mismatch: expected %d, got %s\n' "$expected_count" "$plan_count" >&2
    return 1
  }

  # No failing tests.
  if grep -q '^not ok ' "$TEST_TMP/child-output.tap"; then
    printf 'child had failing tests:\n' >&2
    grep '^not ok ' "$TEST_TMP/child-output.tap" >&2
    return 1
  fi

  # Child must have exited cleanly.
  [ "$child_rc" -eq 0 ] || {
    printf 'child exited with status %d\n' "$child_rc" >&2
    return 1
  }
}
