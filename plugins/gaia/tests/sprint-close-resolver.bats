#!/usr/bin/env bats
# sprint-close-resolver.bats — tests for sprint-close resolver wiring.
#
# Drives the REAL close.sh entry point (not sprint-state.sh close directly)
# to verify that close.sh wires through resolve_sprint_arg for --sprint,
# session binding, and single-sprint default resolution.
#
# Every test builds a throwaway project under BATS_TEST_TMPDIR with real
# per-sprint state files and preconditions; SPRINT_STATUS_YAML is NOT set
# so close.sh must resolve the path itself.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close"
CLOSE_SH="$SKILL_DIR/scripts/close.sh"

# ---------- Fixture helpers ----------

# Build a concurrent-mode project with two active sprints.
# sprint-900 and sprint-901, both with all stories done.
# The main sprint-status.yaml points at sprint-901 (last-activated).
_build_concurrent_fixture() {
  local root="$1"
  mkdir -p "$root/.gaia/config"
  mkdir -p "$root/.gaia/state"
  mkdir -p "$root/.gaia/memory/checkpoints"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/sprint-archive"

  # Concurrent config.
  cat > "$root/.gaia/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 2
YAML

  # Per-sprint state files.
  cat > "$root/.gaia/state/sprint-status-sprint-900.yaml" <<'YAML'
sprint_id: sprint-900
status: active
total_points: 5
stories:
  - key: DEMO-S1
    status: done
YAML
  cat > "$root/.gaia/state/sprint-status-sprint-901.yaml" <<'YAML'
sprint_id: sprint-901
status: active
total_points: 5
stories:
  - key: DEMO-S2
    status: done
YAML

  # Main file points at sprint-901 (last-activated).
  cat > "$root/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: sprint-901
status: active
total_points: 5
stories:
  - key: DEMO-S2
    status: done
YAML

  # Retro docs for both sprints.
  touch "$root/.gaia/artifacts/implementation-artifacts/retrospective-sprint-900-2026-10-21.md"
  touch "$root/.gaia/artifacts/implementation-artifacts/retrospective-sprint-901-2026-10-21.md"

  # Sprint-review sentinels for both.
  cat > "$root/.gaia/memory/checkpoints/sprint-review-sprint-900-val-dispatched.json" <<'JSON'
{"agent":"val","status":"PASSED","summary":"test","findings":[]}
JSON
  cat > "$root/.gaia/memory/checkpoints/sprint-review-sprint-901-val-dispatched.json" <<'JSON'
{"agent":"val","status":"PASSED","summary":"test","findings":[]}
JSON

  # Triage sentinels for both.
  cat > "$root/.gaia/memory/checkpoints/triage-findings-sprint-900-completed.json" <<'JSON'
{"sprint_id":"sprint-900","completed_at":"2026-10-21T00:00:00Z"}
JSON
  cat > "$root/.gaia/memory/checkpoints/triage-findings-sprint-901-completed.json" <<'JSON'
{"sprint_id":"sprint-901","completed_at":"2026-10-21T00:00:00Z"}
JSON
}

# Build a single-sprint project with sprint-200 active.
_build_single_fixture() {
  local root="$1"
  mkdir -p "$root/.gaia/config"
  mkdir -p "$root/.gaia/state"
  mkdir -p "$root/.gaia/memory/checkpoints"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/sprint-archive"

  # No concurrent config (single-sprint mode).
  cat > "$root/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: test-project
YAML

  cat > "$root/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: sprint-200
status: active
total_points: 10
stories:
  - key: DEMO-S1
    status: done
YAML

  touch "$root/.gaia/artifacts/implementation-artifacts/retrospective-sprint-200-2026-10-21.md"
  cat > "$root/.gaia/memory/checkpoints/sprint-review-sprint-200-val-dispatched.json" <<'JSON'
{"agent":"val","status":"PASSED","summary":"test","findings":[]}
JSON
  cat > "$root/.gaia/memory/checkpoints/triage-findings-sprint-200-completed.json" <<'JSON'
{"sprint_id":"sprint-200","completed_at":"2026-10-21T00:00:00Z"}
JSON
}

setup() {
  common_setup
  # Do NOT set SPRINT_STATUS_YAML — close.sh must resolve it from PROJECT_ROOT.
  unset SPRINT_STATUS_YAML
  # Stable close date for predictable archive filenames.
  export GAIA_SPRINT_CLOSE_DATE="2026-10-21"
}

teardown() {
  common_teardown
}

# ---------- AC1: Explicit --sprint flag ----------

@test "explicit --sprint resolves via the shared resolver and closes the target sprint" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run bash "$CLOSE_SH" --sprint sprint-900

  [ "$status" -eq 0 ]
  # The close confirmation must name sprint-900.
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"closed"* ]]

  # sprint-901 must still be active (not closed).
  local s901_status
  s901_status="$(yq '.status' "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"
  [ "$s901_status" = "active" ]
}

# ---------- AC2: Session binding ----------

@test "session-bound sprint is closed when no --sprint is passed" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Bind session to sprint-900.
  export GAIA_SESSION_DIR="$TEST_TMP/.gaia/state/sessions/test-session"
  mkdir -p "$GAIA_SESSION_DIR"
  printf 'sprint-900' > "$GAIA_SESSION_DIR/bound_sprint_id"
  export GAIA_BINDING_DIR="$GAIA_SESSION_DIR"

  run bash "$CLOSE_SH"

  [ "$status" -eq 0 ]
  # Sprint-900 (bound) must be closed.
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"closed"* ]]

  # Sprint-901 must still be active.
  local s901_status
  s901_status="$(yq '.status' "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"
  [ "$s901_status" = "active" ]
}

# ---------- AC3: Single-sprint default ----------

@test "single-sprint default closes the single active sprint without --sprint" {
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run bash "$CLOSE_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-200"* ]]
  [[ "$output" == *"closed"* ]]
}

# ---------- AC4: Positional/flag conflict ----------

@test "positional and --sprint flag with different values produce conflict error" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run bash "$CLOSE_SH" sprint-900 --sprint sprint-901

  [ "$status" -ne 0 ]
  # The error must come from the resolver (conflict), not "unknown argument".
  [[ "$output" != *"unknown argument"* ]]
  # The resolver emits "conflicts with" or "conflict" (case-insensitive check
  # via grep to avoid bash-4-only ${,,}).
  printf '%s' "$output" | /usr/bin/grep -iq 'conflict'
}

# ---------- AC5: Unknown sprint ID ----------

@test "--sprint with unknown ID exits with resolver not-found error" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run bash "$CLOSE_SH" --sprint unknown-sprint-999

  [ "$status" -ne 0 ]
  # Error must reference the bad sprint ID.
  [[ "$output" == *"unknown-sprint-999"* ]]
  # Must NOT be the old "unknown argument" error.
  [[ "$output" != *"unknown argument"* ]]
}

# ---------- AC6: Resume exception with --sprint ----------

@test "resume exception works when --sprint targets a closed sprint with missing archive" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Mark sprint-900 as closed but remove any archive.
  yq -i '.status = "closed" | .closed_at = "2026-10-20T12:00:00Z"' \
    "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml"
  rm -f "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive/sprint-900-closed-"*.yaml

  run bash "$CLOSE_SH" --sprint sprint-900

  [ "$status" -eq 0 ]
  # Must mention sprint-900 and close (or resume).
  [[ "$output" == *"sprint-900"* ]]
  # Archive must now exist.
  local archive_count
  archive_count="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" -name 'sprint-900-closed-*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$archive_count" -ge 1 ]
}

# ---------- AC7: Bash 3.2 compatibility ----------

@test "close.sh runs without syntax errors under /bin/bash 3.2" {
  # Skip on Linux CI where /bin/bash is v5+.
  local bash_ver
  bash_ver="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')"
  if [ "${bash_ver:-5}" -ge 5 ]; then
    skip "/bin/bash is version ${bash_ver} on this host; 3.2 compat is macOS-specific"
  fi

  # Run the single-sprint default case under /bin/bash 3.2 to get a real
  # behavioral run, not just a syntax check.
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run /bin/bash "$CLOSE_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-200"* ]]
  [[ "$output" == *"closed"* ]]
}

# ---------- AC8: No leaked internal identifiers ----------

@test "no internal traceability identifiers in published close.sh" {
  # Scan close.sh for leaked internal IDs.
  run /usr/bin/grep -EnH \
    '(FR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[0-9]+|NFR-[0-9]+|SR-[0-9]+)' \
    "$CLOSE_SH"

  # grep exit 1 = no match = pass.
  [ "$status" -eq 1 ]
}
