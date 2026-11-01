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

  # Use the REAL bind.sh writer to bind to sprint-900 (not hand-written files).
  local bind_sh="$BATS_TEST_DIRNAME/../skills/gaia-run-sprint/scripts/bind.sh"
  [ -f "$bind_sh" ] || skip "bind.sh not found at $bind_sh"
  export CLAUDE_CODE_SESSION_ID="bats-close-test-$$"
  bash "$bind_sh" --sprint sprint-900

  # Unset any pre-exported GAIA_BINDING_DIR so close.sh must provision it.
  unset GAIA_BINDING_DIR

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
  # via here-string + grep to avoid bash-4-only ${,,} and racy pipe).
  /usr/bin/grep -iq 'conflict' <<<"$output"
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

# ---------- Fail-open guards ----------

@test "ambiguous sprints with no binding refuses and changes nothing" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"
  unset GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID

  # Snapshot per-sprint files before.
  local s900_before s901_before main_before
  s900_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"
  main_before="$(cat "$TEST_TMP/.gaia/state/sprint-status.yaml")"

  run bash "$CLOSE_SH"

  [ "$status" -ne 0 ]
  # The resolver's "specify --sprint" diagnostic must surface.
  [[ "$output" == *"--sprint"* ]]
  # All state files must be byte-identical (no sprint closed).
  [ "$s900_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")" ]
  [ "$s901_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")" ]
  [ "$main_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status.yaml")" ]
  # No archive created.
  local arc
  arc="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$arc" -eq 0 ]
  # No lifecycle event.
  [ ! -f "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl" ] || \
    [ "$(wc -l < "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl" | tr -d ' ')" -eq 0 ]
}

@test "stale binding to missing sprint refuses and changes nothing" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Bind to a non-existent sprint.
  local bind_dir="$TEST_TMP/.gaia/state/sessions/stale-session"
  mkdir -p "$bind_dir"
  printf 'sprint-777' > "$bind_dir/bound_sprint_id"
  export GAIA_BINDING_DIR="$bind_dir"

  # Snapshot per-sprint files before.
  local s900_before s901_before
  s900_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"

  run bash "$CLOSE_SH"

  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint-777"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"spoofing"* ]]
  # Per-sprint files must be byte-identical.
  [ "$s900_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")" ]
  [ "$s901_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")" ]
}

@test "empty --sprint= value is rejected" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run bash "$CLOSE_SH" --sprint=

  [ "$status" -ne 0 ]
  [[ "$output" == *"non-empty"* ]]
}

# ---------- Positional-only ----------

@test "positional-only sprint ID closes the named sprint" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run bash "$CLOSE_SH" sprint-900

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"closed"* ]]

  # sprint-901 must still be active.
  local s901_status
  s901_status="$(yq '.status' "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"
  [ "$s901_status" = "active" ]
}

# ---------- Resolved-ID vs state-file mismatch ----------

@test "resolver ID vs state-file mismatch is refused with no state change" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Corrupt the per-sprint file so its sprint_id disagrees with the filename.
  # Use sprint-901 (which has valid retro/sentinel/triage) so the mismatch
  # check is the ONLY guard that stops the close — not a downstream check.
  yq -i '.sprint_id = "sprint-901"' "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml"

  # Snapshot state files before.
  local s900_before s901_before
  s900_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"

  run bash "$CLOSE_SH" --sprint sprint-900

  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatch"* ]]
  # Must NOT contain "closed" — the mismatch must die, not warn and continue.
  [[ "$output" != *"closed at"* ]]
  # State files must be byte-identical (nothing mutated).
  [ "$s900_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")" ]
  [ "$s901_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")" ]
  # No archive created.
  local arc
  arc="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$arc" -eq 0 ]
}

# ---------- Stronger assertions on happy-path ----------

@test "explicit --sprint leaves the other sprint byte-identical and writes correct archive and event" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Snapshot sprint-901 state file before close.
  local s901_before
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"

  run bash "$CLOSE_SH" --sprint sprint-900

  [ "$status" -eq 0 ]

  # sprint-901 file is byte-identical.
  local s901_after
  s901_after="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"
  [ "$s901_before" = "$s901_after" ]

  # Archive filename contains the target sprint ID.
  local archive
  archive="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" -name 'sprint-900-closed-*.yaml' 2>/dev/null | head -1)"
  [ -n "$archive" ]

  # Lifecycle event names the correct sprint.
  local event_file="$TEST_TMP/.gaia/memory/lifecycle-events.jsonl"
  [ -f "$event_file" ]
  /usr/bin/grep -q '"sprint-900"' "$event_file"
  # Must NOT contain sprint-901 in the event.
  ! /usr/bin/grep -q '"sprint-901"' "$event_file"
}

# ---------- Repeated --sprint ----------

@test "repeated --sprint with different values is refused" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run bash "$CLOSE_SH" --sprint sprint-900 --sprint sprint-901

  [ "$status" -ne 0 ]
  [[ "$output" == *"repeated"* ]]
}

# ---------- --sprint "" (two-arg empty) ----------

@test "--sprint with empty string argument is rejected" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  run bash "$CLOSE_SH" --sprint ""

  [ "$status" -ne 0 ]
  [[ "$output" == *"non-empty"* ]]
}

# ---------- SKILL invocation safety ----------

@test "SKILL.md Action section is safe: no shell splice, has allow-list and refused metacharacters" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"

  # No !-prefixed shell line may contain $ARGUMENTS, ${ARGUMENTS}, or
  # positional placeholders ($0, $1, ${N}) alongside close.sh.
  run /usr/bin/grep -E '^\!.*(\$ARGUMENTS|\$\{ARGUMENTS\})' "$skill_md"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -E '^\!.*close\.sh.*(\$[0-9]|\$\{[0-9])' "$skill_md"
  [ "$status" -ne 0 ]

  # The refused-metacharacter list must include semicolons.
  /usr/bin/grep -q '`;`' "$skill_md"

  # The allow-list must name the accepted flags.
  /usr/bin/grep -q '\-\-sprint' "$skill_md"
  /usr/bin/grep -q '\-\-force' "$skill_md"
  /usr/bin/grep -q '\-\-help' "$skill_md"

  # The ID pattern must be documented.
  /usr/bin/grep -q 'A-Za-z0-9' "$skill_md"
}

@test "close.sh invoked directly with valid --sprint closes the right sprint" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Invoke close.sh the way the SKILL instructs the model to: via bash
  # with each argument single-quoted.
  run bash "$CLOSE_SH" '--sprint' 'sprint-900'

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"closed"* ]]

  local s901_status
  s901_status="$(yq '.status' "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"
  [ "$s901_status" = "active" ]
}

# ---------- Injection payloads rejected by close.sh ----------

@test "injection payloads are rejected by close.sh and never execute" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  local pwn="$TEST_TMP/pwned"

  # Each payload: close.sh must exit non-zero and the sentinel must not exist.
  local payload
  for payload in \
    "x; touch $pwn" \
    "\$(touch $pwn)" \
    "\`touch $pwn\`" \
    "sprint-900 && touch $pwn"; do
    run bash "$CLOSE_SH" "$payload"
    [ "$status" -ne 0 ]
    [ ! -f "$pwn" ]
  done
}

# ---------- Binding spoofing refused ----------

@test "foreign GAIA_BINDING_DIR is refused when provision detects spoofing" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Set up a real binding to sprint-900 via bind.sh.
  local bind_sh="$BATS_TEST_DIRNAME/../skills/gaia-run-sprint/scripts/bind.sh"
  [ -f "$bind_sh" ] || skip "bind.sh not found"
  export CLAUDE_CODE_SESSION_ID="bats-spoof-test-$$"
  bash "$bind_sh" --sprint sprint-900

  # Now inject a foreign GAIA_BINDING_DIR pointing at a different binding.
  local foreign_dir="$TEST_TMP/.gaia/state/sessions/foreign"
  mkdir -p "$foreign_dir"
  printf 'sprint-901' > "$foreign_dir/bound_sprint_id"
  export GAIA_BINDING_DIR="$foreign_dir"

  # Snapshot state.
  local s900_before s901_before
  s900_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"

  run bash "$CLOSE_SH"

  # Must exit non-zero (spoofing detected or ambiguous).
  [ "$status" -ne 0 ]
  # Neither sprint must have been closed.
  [ "$s900_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")" ]
  [ "$s901_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")" ]
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

# ---------- Binding shape validation (story AC1) ----------

@test "invalid binding ID from env is refused with diagnostic" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  export GAIA_BOUND_SPRINT_ID='x/../y'
  unset GAIA_BINDING_DIR

  run bash "$CLOSE_SH"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]]
}

@test "invalid binding ID from binding file is refused by resolver" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  local sb_sh="$BATS_TEST_DIRNAME/../scripts/lib/session-binding.sh"
  source "$sb_sh"

  local bind_dir="$TEST_TMP/.gaia/state/sessions/bad-shape-session"
  mkdir -p "$bind_dir"
  printf 'x/../y' > "$bind_dir/bound_sprint_id"
  export GAIA_BINDING_DIR="$bind_dir"
  unset GAIA_BOUND_SPRINT_ID

  run resolve_sprint_arg --command sprint-close

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]]
}

@test "multi-line binding ID from env is refused (newline-safe shape check)" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  local sb_sh="$BATS_TEST_DIRNAME/../scripts/lib/session-binding.sh"
  source "$sb_sh"

  # Multi-line value: first line valid, second line is a traversal attempt.
  export GAIA_BOUND_SPRINT_ID=$'sprint-1\n../x'
  unset GAIA_BINDING_DIR

  run resolve_sprint_arg --command sprint-close

  [ "$status" -eq 16 ]
  [[ "$output" == *"invalid"* ]]
}

# ---------- SPRINT_STATUS_YAML cross-check (story AC2) ----------

@test "SPRINT_STATUS_YAML override logs bypass WARNING when set" {
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Point at the real file, no binding -> no cross-check, just the bypass WARNING.
  export SPRINT_STATUS_YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  unset GAIA_BOUND_SPRINT_ID GAIA_BINDING_DIR

  run bash "$CLOSE_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"SPRINT_STATUS_YAML"* ]]
}

@test "SPRINT_STATUS_YAML mismatch with env binding refuses with no state change" {
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  export SPRINT_STATUS_YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  export GAIA_BOUND_SPRINT_ID="sprint-999"

  local before
  before="$(cat "$TEST_TMP/.gaia/state/sprint-status.yaml")"

  run bash "$CLOSE_SH"

  [ "$status" -ne 0 ]
  [[ "$output" == *"binding mismatch"* ]]
  [[ "$output" == *"sprint-999"* ]]
  # State file must be unchanged.
  [ "$before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status.yaml")" ]
}

@test "SPRINT_STATUS_YAML mismatch with binding file refuses with no state change" {
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  export SPRINT_STATUS_YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  unset GAIA_BOUND_SPRINT_ID
  # Use a session ID whose derived binding dir we control.
  local sid="mismatch-session-$$"
  export CLAUDE_CODE_SESSION_ID="$sid"
  local bind_dir="$TEST_TMP/.gaia/state/sessions/$sid"
  mkdir -p "$bind_dir"
  chmod 0700 "$bind_dir"
  printf 'sprint-999' > "$bind_dir/bound_sprint_id"

  local before
  before="$(cat "$TEST_TMP/.gaia/state/sprint-status.yaml")"

  run bash "$CLOSE_SH"

  [ "$status" -ne 0 ]
  [[ "$output" == *"binding mismatch"* ]]
  # State file must be unchanged.
  [ "$before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status.yaml")" ]
  # No archive must have been created.
  local archive_count
  archive_count="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$archive_count" -eq 0 ]
}

@test "stale env matching file but disagreeing with binding file refuses" {
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Env matches the file (sprint-200) but binding file says sprint-999.
  export SPRINT_STATUS_YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  export GAIA_BOUND_SPRINT_ID="sprint-200"
  local sid="stale-env-session-$$"
  export CLAUDE_CODE_SESSION_ID="$sid"
  local bind_dir="$TEST_TMP/.gaia/state/sessions/$sid"
  mkdir -p "$bind_dir"
  chmod 0700 "$bind_dir"
  printf 'sprint-999' > "$bind_dir/bound_sprint_id"

  local before
  before="$(cat "$TEST_TMP/.gaia/state/sprint-status.yaml")"

  run bash "$CLOSE_SH"

  # Must refuse: binding file (authoritative) disagrees with the sprint.
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding mismatch"* ]]
  [[ "$output" == *"sprint-999"* ]]
  # State file must be unchanged.
  [ "$before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status.yaml")" ]
  # No archive must have been created.
  local archive_count
  archive_count="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$archive_count" -eq 0 ]
}

@test "SPRINT_STATUS_YAML matching binding closes normally" {
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Binding matches the file's sprint-200.
  export SPRINT_STATUS_YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  export GAIA_BOUND_SPRINT_ID="sprint-200"

  run bash "$CLOSE_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-200"* ]]
  [[ "$output" == *"closed"* ]]
}

# ---------- SKILL.md scoped tests (story AC3, AC4, AC5) ----------

@test "accept ONLY sentence mutant in SKILL.md Action section is caught" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"

  local action_section
  action_section="$(awk '/^## Action/{found=1;next} /^## /{if(found)exit} found' "$skill_md")"

  /usr/bin/grep -q 'accept ONLY' <<<"$action_section"
}

@test "close-then-finalize order is enforced in SKILL.md" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"

  # Extract the Finalize section.
  local finalize_section
  finalize_section="$(awk '/^## Finalize/{found=1;next} /^## /{if(found)exit} found' "$skill_md")"

  # The Finalize instruction must say close.sh runs first (catches
  # rewording that reverses the close-then-finalize ordering).
  /usr/bin/grep -q 'After close\.sh exits 0.*finalize' <<<"$finalize_section"

  # No invocation of finalize.sh may appear outside ## Finalize.
  # Matches bang-prefixed lines AND bash invocation lines (catches a
  # finalize.sh call placed in Action before the close.sh block).
  # Prose mentions (backtick-quoted references in Mission) are not invocations.
  local invocation_outside
  invocation_outside="$(awk '
    /^## Finalize/{in_fin=1; next}
    /^## /{in_fin=0}
    !in_fin && /^!.*finalize\.sh/ {print NR": "$0}
    !in_fin && /bash.*finalize\.sh/ {print NR": "$0}
  ' "$skill_md")"
  [ -z "$invocation_outside" ]

  # The exact Do-NOT sentence must be anchored at both start and end.
  /usr/bin/grep -qx 'Do NOT run finalize before close\.sh succeeds — the checkpoint and brain reindex must see the archive\.' <<<"$finalize_section"

  # No line outside ## Finalize pairs "finalize" with "before close".
  local bad_order
  bad_order="$(awk '
    /^## Finalize/{in_fin=1; next}
    /^## /{in_fin=0}
    !in_fin && /finalize/ && /before close/ {print NR": "$0}
  ' "$skill_md")"
  [ -z "$bad_order" ]

  # Section ordering: ## Action before ## Finalize.
  local action_line finalize_line
  action_line="$(/usr/bin/grep -n '^## Action' "$skill_md" | head -1 | cut -d: -f1)"
  finalize_line="$(/usr/bin/grep -n '^## Finalize' "$skill_md" | head -1 | cut -d: -f1)"
  [ -n "$action_line" ]
  [ -n "$finalize_line" ]
  [ "$action_line" -lt "$finalize_line" ]
}

@test "quote-character refusal appears on the metacharacter line in SKILL.md Action section" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"

  # Extract the Action section.
  local action_section
  action_section="$(awk '/^## Action/{found=1;next} /^## /{if(found)exit} found' "$skill_md")"

  # Find the single "Refuse any word containing shell metacharacters" line.
  local refuse_line
  refuse_line="$(/usr/bin/grep 'Refuse any word containing shell metacharacters' <<<"$action_section")"
  [ -n "$refuse_line" ]

  # That line must contain both single-quote and double-quote backtick-escaped.
  [[ "$refuse_line" == *"\`'\`"* ]]
  [[ "$refuse_line" == *'`"`'* ]]
}

# ---------- Triage snippet quoting (story AC6) ----------

@test "triage-sentinel snippet has quoted sprint_id placeholder" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"
  /usr/bin/grep -q "'{sprint_id}'" "$skill_md"
}

# ---------- Triage SKILL.md wording (story AC8) ----------

@test "SKILL.md says active or review sprint for triage sentinel" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"
  /usr/bin/grep -q 'active or review sprint' "$skill_md"
}

# ---------- yaml_top_scalar trimming (story AC9) ----------

@test "yaml_top_scalar trims trailing whitespace and inline comments end-to-end" {
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Write a state file with trailing spaces, an inline comment, and CRLF.
  printf 'sprint_id: sprint-200\r\nstatus: review   # pending close\r\ntotal_points: 10\r\nstories:\r\n  - key: DEMO-S1\r\n    status: done\r\n' \
    > "$TEST_TMP/.gaia/state/sprint-status.yaml"

  touch "$TEST_TMP/.gaia/artifacts/implementation-artifacts/retrospective-sprint-200-2026-10-21.md"

  # close.sh must see "review" (not "review   # pending close") and proceed
  # to close the sprint (all preconditions are met).
  run bash "$CLOSE_SH" --sprint sprint-200

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-200"* ]]
  [[ "$output" == *"closed"* ]]
}

@test "yaml_top_scalar inline-comment strip matters for idempotent close detection" {
  _build_single_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Already-closed sprint with an inline comment on status.
  # yaml_top_scalar must strip "# done" to return "closed" so the idempotent
  # path fires. Removing only the inline-comment strip makes close.sh
  # see "closed   # done" which does NOT match "closed" — skipping the
  # idempotent exit and instead trying to close an already-closed sprint
  # through the normal path (which would not output "already closed").
  printf 'sprint_id: sprint-200\nstatus: closed   # done\nclosed_at: "2026-10-20T00:00:00Z"\ntotal_points: 10\nstories:\n  - key: DEMO-S1\n    status: done\n' \
    > "$TEST_TMP/.gaia/state/sprint-status.yaml"

  run bash "$CLOSE_SH" --sprint sprint-200

  [ "$status" -eq 0 ]
  [[ "$output" == *"already closed"* ]]
}

# ---------- read_binding atomic read (story AC7) ----------

@test "read_binding has no separate existence test before the read" {
  local sb_sh="$BATS_TEST_DIRNAME/../scripts/lib/session-binding.sh"

  # Extract the read_binding function body (between read_binding() { and the
  # closing } at column 0).
  local func_body
  func_body="$(awk '/^read_binding\(\)/{found=1} found{print} found && /^}$/{exit}' "$sb_sh")"

  # The function must NOT contain a -f or -e test on the binding file
  # before the cat that reads it. Scan line by line: any -f/-e on
  # "binding_file" before the first cat on "binding_file" is a failure.
  local saw_cat=0 found_pre=0
  while IFS= read -r line; do
    case "$line" in
      *cat*binding_file*|*cat*BINDING_FILENAME*) saw_cat=1 ;;
    esac
    if [ "$saw_cat" -eq 0 ]; then
      case "$line" in
        *'[ -f'*binding_file*|*'[ ! -f'*binding_file*|*'[ -e'*binding_file*)
          found_pre=1 ;;
      esac
    fi
  done <<<"$func_body"

  [ "$found_pre" -eq 0 ]
}

@test "read_binding returns error on unreadable binding file" {
  local sb_sh="$BATS_TEST_DIRNAME/../scripts/lib/session-binding.sh"
  source "$sb_sh"

  local bind_dir="$TEST_TMP/binding-ac7"
  mkdir -p "$bind_dir"
  printf 'sprint-200' > "$bind_dir/bound_sprint_id"
  chmod 000 "$bind_dir/bound_sprint_id"
  export GAIA_BINDING_DIR="$bind_dir"

  run read_binding

  # With the file unreadable, cat fails and the result is empty -> rc 1 (unbound).
  [ "$status" -eq 1 ]

  chmod 644 "$bind_dir/bound_sprint_id"
}

# ---------- Lazy session dir (story AC14) ----------

@test "refused close leaves no new session directory behind" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  local session_id="bats-cleanup-test-$$-$(date +%s)"
  export CLAUDE_CODE_SESSION_ID="$session_id"
  unset GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID

  local session_dir="$TEST_TMP/.gaia/state/sessions/$session_id"
  [ ! -d "$session_dir" ]

  run bash "$CLOSE_SH" --sprint nonexistent-sprint-888

  [ "$status" -ne 0 ]
  [ ! -d "$session_dir" ]
}

@test "pre-existing empty session dir is NOT removed on failure" {
  _build_concurrent_fixture "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Create the session dir BEFORE close.sh runs.
  local session_id="bats-preexist-test-$$-$(date +%s)"
  export CLAUDE_CODE_SESSION_ID="$session_id"
  unset GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID

  local session_dir="$TEST_TMP/.gaia/state/sessions/$session_id"
  mkdir -p "$session_dir"
  chmod 0700 "$session_dir"

  run bash "$CLOSE_SH" --sprint nonexistent-sprint-888

  [ "$status" -ne 0 ]
  # Pre-existing dir must NOT be removed.
  [ -d "$session_dir" ]
}

# ---------- Resolver binding-file-wins rule (no SPRINT_STATUS_YAML) ----------
#
# Verifies that resolve_sprint_arg reads the binding FILE first and
# uses it as the authoritative source.  When the env var disagrees
# with the file, the resolver refuses (rc 15).  Two active sprints
# are built via the real sprint-state.sh writer (inject + transition).

# Helper: concurrent fixture with two active sprints (sprint-900 and
# sprint-901), each with a single done story, built via the real writer.
# All close.sh preconditions (retro, sprint-review sentinel, triage
# sentinel) are satisfied for both sprints.
_build_concurrent_for_resolver() {
  local root="$1"
  local sprint_state_sh="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
  [ -f "$sprint_state_sh" ] || { echo "sprint-state.sh not found" >&2; return 1; }

  # Build each sprint in a separate root via the real single-mode writer.
  local aux1="$BATS_TEST_TMPDIR/rsa-aux1-$$"
  _build_sprint_with_inject "$aux1" sprint-900 DEMO-S1 done
  local aux2="$BATS_TEST_TMPDIR/rsa-aux2-$$"
  _build_sprint_with_inject "$aux2" sprint-901 DEMO-S2 done

  # Assemble the concurrent layout in $root.
  mkdir -p "$root/.gaia/config" "$root/.gaia/state"
  mkdir -p "$root/.gaia/memory/checkpoints"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/sprint-archive"

  cat > "$root/.gaia/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 2
YAML

  cp "$aux1/.gaia/state/sprint-status.yaml" \
    "$root/.gaia/state/sprint-status-sprint-900.yaml"
  cp "$aux2/.gaia/state/sprint-status.yaml" \
    "$root/.gaia/state/sprint-status-sprint-901.yaml"
  cp "$root/.gaia/state/sprint-status-sprint-901.yaml" \
    "$root/.gaia/state/sprint-status.yaml"

  # Close preconditions for both sprints.
  touch "$root/.gaia/artifacts/implementation-artifacts/retrospective-sprint-900-2026-10-21.md"
  touch "$root/.gaia/artifacts/implementation-artifacts/retrospective-sprint-901-2026-10-21.md"
  cat > "$root/.gaia/memory/checkpoints/sprint-review-sprint-900-val-dispatched.json" <<'JSON'
{"agent":"val","status":"PASSED","summary":"test","findings":[]}
JSON
  cat > "$root/.gaia/memory/checkpoints/sprint-review-sprint-901-val-dispatched.json" <<'JSON'
{"agent":"val","status":"PASSED","summary":"test","findings":[]}
JSON
  cat > "$root/.gaia/memory/checkpoints/triage-findings-sprint-900-completed.json" <<'JSON'
{"sprint_id":"sprint-900","completed_at":"2026-10-21T00:00:00Z"}
JSON
  cat > "$root/.gaia/memory/checkpoints/triage-findings-sprint-901-completed.json" <<'JSON'
{"sprint_id":"sprint-901","completed_at":"2026-10-21T00:00:00Z"}
JSON
}

@test "resolver binding-file-wins: env-only closes the env-bound sprint" {
  _build_concurrent_for_resolver "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Use a session ID so provision_binding_dir creates the dir at the
  # derived path.  No binding file in the dir -> env-only path.
  local sid="rsa-env-only-$$"
  export CLAUDE_CODE_SESSION_ID="$sid"
  unset GAIA_BINDING_DIR
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  run bash "$CLOSE_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"closed"* ]]

  # sprint-901 must still be active.
  local s901_status
  s901_status="$(yq '.status' "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"
  [ "$s901_status" = "active" ]
}

@test "resolver binding-file-wins: file-only closes the file-bound sprint" {
  _build_concurrent_for_resolver "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Pre-create the binding dir at the derived path with a binding file.
  local sid="rsa-file-only-$$"
  export CLAUDE_CODE_SESSION_ID="$sid"
  unset GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID
  local bind_dir="$TEST_TMP/.gaia/state/sessions/$sid"
  mkdir -p "$bind_dir"
  chmod 0700 "$bind_dir"
  printf 'sprint-901' > "$bind_dir/bound_sprint_id"

  run bash "$CLOSE_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-901"* ]]
  [[ "$output" == *"closed"* ]]

  # sprint-900 must still be active.
  local s900_status
  s900_status="$(yq '.status' "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  [ "$s900_status" = "active" ]
}

@test "resolver binding-file-wins: env and file agree closes the bound sprint" {
  _build_concurrent_for_resolver "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Both env and file set to the same sprint.
  local sid="rsa-agree-$$"
  export CLAUDE_CODE_SESSION_ID="$sid"
  unset GAIA_BINDING_DIR
  export GAIA_BOUND_SPRINT_ID="sprint-900"
  local bind_dir="$TEST_TMP/.gaia/state/sessions/$sid"
  mkdir -p "$bind_dir"
  chmod 0700 "$bind_dir"
  printf 'sprint-900' > "$bind_dir/bound_sprint_id"

  run bash "$CLOSE_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"closed"* ]]

  # sprint-901 must still be active.
  local s901_status
  s901_status="$(yq '.status' "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"
  [ "$s901_status" = "active" ]
}

@test "resolver binding-file-wins: env disagrees with file refuses with no state change" {
  _build_concurrent_for_resolver "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # File says sprint-901; env says sprint-900.
  local sid="rsa-disagree-$$"
  export CLAUDE_CODE_SESSION_ID="$sid"
  unset GAIA_BINDING_DIR
  export GAIA_BOUND_SPRINT_ID="sprint-900"
  local bind_dir="$TEST_TMP/.gaia/state/sessions/$sid"
  mkdir -p "$bind_dir"
  chmod 0700 "$bind_dir"
  printf 'sprint-901' > "$bind_dir/bound_sprint_id"

  # Snapshot state files before.
  local s900_before s901_before
  s900_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"

  run bash "$CLOSE_SH"

  [ "$status" -eq 15 ]
  [[ "$output" == *"binding_mismatch"* ]]

  # Both sprints must still be unchanged.
  [ "$s900_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")" ]
  [ "$s901_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")" ]

  # No archive created.
  local arc
  arc="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" \
    -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$arc" -eq 0 ]
}

@test "resolver binding-file-wins: file disagrees with env refuses with no state change" {
  _build_concurrent_for_resolver "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # File says sprint-900; env says sprint-901 (reverse direction).
  local sid="rsa-disagree-rev-$$"
  export CLAUDE_CODE_SESSION_ID="$sid"
  unset GAIA_BINDING_DIR
  export GAIA_BOUND_SPRINT_ID="sprint-901"
  local bind_dir="$TEST_TMP/.gaia/state/sessions/$sid"
  mkdir -p "$bind_dir"
  chmod 0700 "$bind_dir"
  printf 'sprint-900' > "$bind_dir/bound_sprint_id"

  local s900_before s901_before
  s900_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"

  run bash "$CLOSE_SH"

  [ "$status" -eq 15 ]
  [[ "$output" == *"binding_mismatch"* ]]

  [ "$s900_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")" ]
  [ "$s901_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")" ]

  local arc
  arc="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" \
    -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$arc" -eq 0 ]
}

@test "resolver binding-file-wins: CRLF binding file refuses" {
  _build_concurrent_for_resolver "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # Binding file with CRLF, no env.
  local sid="rsa-crlf-$$"
  export CLAUDE_CODE_SESSION_ID="$sid"
  unset GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID
  local bind_dir="$TEST_TMP/.gaia/state/sessions/$sid"
  mkdir -p "$bind_dir"
  chmod 0700 "$bind_dir"
  printf 'sprint-900\r\n' > "$bind_dir/bound_sprint_id"

  local s900_before s901_before
  s900_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"

  run bash "$CLOSE_SH"

  [ "$status" -eq 16 ]
  [[ "$output" == *"invalid"* ]]

  [ "$s900_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")" ]
  [ "$s901_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")" ]
}

@test "resolver binding-file-wins: manual GAIA_BINDING_DIR with stale env refuses" {
  _build_concurrent_for_resolver "$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"

  # No session id: provision_binding_dir exits 1 (non-fatal), so
  # the manually set GAIA_BINDING_DIR stays in effect.
  # File says sprint-901; stale env says sprint-900.
  unset CLAUDE_CODE_SESSION_ID
  export GAIA_BOUND_SPRINT_ID="sprint-900"
  local bind_dir="$TEST_TMP/.gaia/state/sessions/rsa-manual-$$"
  mkdir -p "$bind_dir"
  chmod 0700 "$bind_dir"
  printf 'sprint-901' > "$bind_dir/bound_sprint_id"
  export GAIA_BINDING_DIR="$bind_dir"

  local s900_before s901_before
  s900_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")"
  s901_before="$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")"

  run bash "$CLOSE_SH"

  [ "$status" -eq 15 ]
  [[ "$output" == *"binding_mismatch"* ]]

  [ "$s900_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-900.yaml")" ]
  [ "$s901_before" = "$(cat "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml")" ]

  local arc
  arc="$(find "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-archive" \
    -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$arc" -eq 0 ]
}

# ---------- Triage resolver concurrent-sprint support (story AC10) ----------

# Helper: build a single-sprint active state file via the real writer,
# then inject stories through sprint-state.sh inject (single mode, so
# the independence gate is not triggered). Story files are created under
# the implementation-artifacts tree with the frontmatter inject requires.
#
# Usage: _build_sprint_with_inject <root> <sprint_id> <key1> <status1> [<key2> <status2> ...]
_build_sprint_with_inject() {
  local root="$1" sid="$2"; shift 2
  local sprint_state_sh="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
  [ -f "$sprint_state_sh" ] || { echo "sprint-state.sh not found" >&2; return 1; }

  mkdir -p "$root/.gaia/config" "$root/.gaia/state" "$root/.gaia/memory/checkpoints"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts"

  cat > "$root/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: test-project
YAML

  (
    export PROJECT_ROOT="$root" CLAUDE_PROJECT_ROOT="$root" PROJECT_PATH="$root"
    export PROJECT_CONFIG="$root/.gaia/config/project-config.yaml"
    export GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash "$sprint_state_sh" init --sprint-id "$sid" 2>/dev/null
    bash "$sprint_state_sh" transition --sprint "$sid" --to active 2>/dev/null
  ) || { echo "sprint-state.sh init/transition failed for $sid" >&2; return 1; }

  local impl="$root/.gaia/artifacts/implementation-artifacts"
  while [ $# -ge 2 ]; do
    local key="$1" story_status="$2"; shift 2
    local slug
    slug="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    local story_dir="$impl/epic-test/${key}-${slug}-test"
    mkdir -p "$story_dir"
    printf -- '---\ntemplate: story\nkey: %s\ntitle: %s test story\nsprint_id: %s\nstatus: %s\npoints: 5\nrisk: medium\n---\n# %s\n' \
      "$key" "$key" "$sid" "$story_status" "$key" > "$story_dir/story.md"
    (
      export PROJECT_ROOT="$root" CLAUDE_PROJECT_ROOT="$root" PROJECT_PATH="$root"
      export PROJECT_CONFIG="$root/.gaia/config/project-config.yaml"
      export GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
      bash "$sprint_state_sh" inject --story "$key" --sprint-id "$sid" 2>/dev/null
    ) || { echo "inject failed for $key into $sid" >&2; return 1; }
  done
}

# Helper: close a sprint via the real sprint-state.sh close writer.
_close_sprint_real() {
  local root="$1" sid="$2"
  local sprint_state_sh="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
  (
    export PROJECT_ROOT="$root" CLAUDE_PROJECT_ROOT="$root" PROJECT_PATH="$root"
    export PROJECT_CONFIG="$root/.gaia/config/project-config.yaml"
    export GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash "$sprint_state_sh" close --sprint-id "$sid" --closed-at 2026-10-01T00:00:00Z 2>/dev/null
  ) || { echo "close failed for $sid" >&2; return 1; }
}

@test "resolve-sprint-stories.sh discovers per-sprint state files" {
  local resolve_sh="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  [ -f "$resolve_sh" ] || { echo "resolve-sprint-stories.sh not found at $resolve_sh" >&2; return 1; }

  # Build each sprint in its own single-mode root via the real writer,
  # then assemble the concurrent layout by copying per-sprint files.
  local aux1="$BATS_TEST_TMPDIR/aux1"
  _build_sprint_with_inject "$aux1" sprint-901 E900-S1 in-progress
  local aux2="$BATS_TEST_TMPDIR/aux2"
  _build_sprint_with_inject "$aux2" sprint-902 E900-S2 done

  mkdir -p "$TEST_TMP/.gaia/config" "$TEST_TMP/.gaia/state"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 3
YAML
  cp "$aux1/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml"
  cp "$aux2/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-902.yaml"
  cp "$TEST_TMP/.gaia/state/sprint-status-sprint-902.yaml" "$TEST_TMP/.gaia/state/sprint-status.yaml"

  mkdir -p "$TEST_TMP/impl/epic-a/E900-S1-test"
  printf -- '---\nkey: E900-S1\n---\n# Story A1\n' > "$TEST_TMP/impl/epic-a/E900-S1-test/story.md"
  mkdir -p "$TEST_TMP/impl/epic-b/E900-S2-test"
  printf -- '---\nkey: E900-S2\n---\n# Story B1\n' > "$TEST_TMP/impl/epic-b/E900-S2-test/story.md"

  export PROJECT_ROOT="$TEST_TMP"

  run bash "$resolve_sh" --impl-dir "$TEST_TMP/impl"

  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S2"* ]]
}

@test "resolve-sprint-stories.sh skips closed per-sprint files" {
  local resolve_sh="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  [ -f "$resolve_sh" ] || { echo "resolve-sprint-stories.sh not found at $resolve_sh" >&2; return 1; }

  # Build each sprint via the real writer, close sprint-902 via the real close path.
  local aux1="$BATS_TEST_TMPDIR/aux1"
  _build_sprint_with_inject "$aux1" sprint-901 E900-S1 in-progress
  local aux2="$BATS_TEST_TMPDIR/aux2"
  _build_sprint_with_inject "$aux2" sprint-902 E900-S2 done
  _close_sprint_real "$aux2" sprint-902

  mkdir -p "$TEST_TMP/.gaia/config" "$TEST_TMP/.gaia/state"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 3
YAML
  cp "$aux1/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml"
  cp "$aux2/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-902.yaml"

  mkdir -p "$TEST_TMP/impl/epic-a/E900-S1-test"
  printf -- '---\nkey: E900-S1\n---\n# Story A1\n' > "$TEST_TMP/impl/epic-a/E900-S1-test/story.md"
  mkdir -p "$TEST_TMP/impl/epic-b/E900-S2-test"
  printf -- '---\nkey: E900-S2\n---\n# Story B1\n' > "$TEST_TMP/impl/epic-b/E900-S2-test/story.md"

  export PROJECT_ROOT="$TEST_TMP"

  run bash "$resolve_sh" --impl-dir "$TEST_TMP/impl"

  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" != *"E900-S2"* ]]
}

@test "resolve-sprint-stories.sh reads main file when its sprint has no per-sprint file" {
  local resolve_sh="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  [ -f "$resolve_sh" ] || { echo "resolve-sprint-stories.sh not found at $resolve_sh" >&2; return 1; }

  # Build sprint-M (single mode) via the real writer — produces the main file.
  _build_sprint_with_inject "$TEST_TMP" sprint-M MAIN-S1 in-progress

  # Build sprint-P in a separate root via the real writer, then copy its state
  # file as a per-sprint file next to the main file.  This creates the state
  # where the main file's sprint (sprint-M) has NO per-sprint counterpart but
  # a different sprint (sprint-P) does.
  local aux="$BATS_TEST_TMPDIR/aux-p"
  _build_sprint_with_inject "$aux" sprint-P PER-S1 done
  cp "$aux/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-P.yaml"

  # Precondition: no per-sprint file for sprint-M must exist.
  [ ! -f "$TEST_TMP/.gaia/state/sprint-status-sprint-M.yaml" ]

  mkdir -p "$TEST_TMP/impl/epic-a/MAIN-S1-test"
  printf -- '---\nkey: MAIN-S1\n---\n# Story MAIN-S1\n' > "$TEST_TMP/impl/epic-a/MAIN-S1-test/story.md"
  mkdir -p "$TEST_TMP/impl/epic-b/PER-S1-test"
  printf -- '---\nkey: PER-S1\n---\n# Story PER-S1\n' > "$TEST_TMP/impl/epic-b/PER-S1-test/story.md"

  export PROJECT_ROOT="$TEST_TMP"

  run bash "$resolve_sh" --impl-dir "$TEST_TMP/impl"

  [ "$status" -eq 0 ]
  [[ "$output" == *"MAIN-S1"* ]]
  [[ "$output" == *"PER-S1"* ]]
}

@test "stale closed per-sprint file does not hide active main-file sprint" {
  local resolve_sh="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  [ -f "$resolve_sh" ] || { echo "resolve-sprint-stories.sh not found at $resolve_sh" >&2; return 1; }

  # Build sprint-M (single mode, main file) with a story.
  _build_sprint_with_inject "$TEST_TMP" sprint-M MAIN-S1 in-progress

  # Build sprint-old in a separate root, close it, then copy as a stale
  # per-sprint file.  The main file's sprint-M has no per-sprint counterpart.
  local aux="$BATS_TEST_TMPDIR/aux-old"
  _build_sprint_with_inject "$aux" sprint-old OLD-S1 done
  _close_sprint_real "$aux" sprint-old
  cp "$aux/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-old.yaml"

  mkdir -p "$TEST_TMP/impl/epic-a/MAIN-S1-test"
  printf -- '---\nkey: MAIN-S1\n---\n# Story MAIN-S1\n' > "$TEST_TMP/impl/epic-a/MAIN-S1-test/story.md"

  export PROJECT_ROOT="$TEST_TMP"

  run bash "$resolve_sh" --impl-dir "$TEST_TMP/impl"

  [ "$status" -eq 0 ]
  [[ "$output" == *"MAIN-S1"* ]]
}

@test "main file is skipped when its sprint already has a per-sprint file" {
  local resolve_sh="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  [ -f "$resolve_sh" ] || { echo "resolve-sprint-stories.sh not found at $resolve_sh" >&2; return 1; }

  # Build two sprints via the real writer: sprint-901 and sprint-902.
  local aux1="$BATS_TEST_TMPDIR/aux1"
  _build_sprint_with_inject "$aux1" sprint-901 E900-S3 in-progress
  local aux2="$BATS_TEST_TMPDIR/aux2"
  _build_sprint_with_inject "$aux2" sprint-902 E900-S4 done

  # Assemble concurrent layout.
  mkdir -p "$TEST_TMP/.gaia/config" "$TEST_TMP/.gaia/state"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 3
YAML
  cp "$aux1/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-901.yaml"
  cp "$aux2/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-902.yaml"

  # Build a third root for sprint-902 with an extra story, to serve as the
  # main proxy.  MAIN-ONLY-S1 exists only in the main file.  If the resolver
  # incorrectly reads the main file when sprint-902 already has a per-sprint
  # file, MAIN-ONLY-S1 would appear in the output.
  local aux3="$BATS_TEST_TMPDIR/aux3"
  _build_sprint_with_inject "$aux3" sprint-902 E900-S4 done MAIN-ONLY-S1 in-progress
  cp "$aux3/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status.yaml"

  mkdir -p "$TEST_TMP/impl/epic-a/E900-S3-test"
  printf -- '---\nkey: E900-S3\n---\n' > "$TEST_TMP/impl/epic-a/E900-S3-test/story.md"
  mkdir -p "$TEST_TMP/impl/epic-b/E900-S4-test"
  printf -- '---\nkey: E900-S4\n---\n' > "$TEST_TMP/impl/epic-b/E900-S4-test/story.md"
  mkdir -p "$TEST_TMP/impl/epic-c/MAIN-ONLY-S1-test"
  printf -- '---\nkey: MAIN-ONLY-S1\n---\n' > "$TEST_TMP/impl/epic-c/MAIN-ONLY-S1-test/story.md"

  export PROJECT_ROOT="$TEST_TMP"

  run bash "$resolve_sh" --impl-dir "$TEST_TMP/impl"

  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S3"* ]]
  [[ "$output" == *"E900-S4"* ]]
  # MAIN-ONLY-S1 must NOT appear — the main file should be skipped because
  # sprint-902 already has a per-sprint file.
  [[ "$output" != *"MAIN-ONLY-S1"* ]]
}

@test "resolve-sprint-stories.sh trims status with inline comments and whitespace" {
  local resolve_sh="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  [ -f "$resolve_sh" ] || { echo "resolve-sprint-stories.sh not found at $resolve_sh" >&2; return 1; }

  # Build a single-sprint file via the real writer, then inject a story
  # and add an inline comment on the status line.
  _build_sprint_with_inject "$TEST_TMP" sprint-T STORY-T1 in-progress

  # Add an inline comment on the status line (portable in-place edit).
  local _state="$TEST_TMP/.gaia/state/sprint-status.yaml"
  sed 's/^status: active$/status: active   # pending/' "$_state" > "$_state.tmp" \
    && mv "$_state.tmp" "$_state"

  mkdir -p "$TEST_TMP/impl/epic-a/STORY-T1-test"
  printf -- '---\nkey: STORY-T1\n---\n# Story T1\n' > "$TEST_TMP/impl/epic-a/STORY-T1-test/story.md"

  export PROJECT_ROOT="$TEST_TMP"

  run bash "$resolve_sh" --impl-dir "$TEST_TMP/impl"

  [ "$status" -eq 0 ]
  [[ "$output" == *"STORY-T1"* ]]
}

@test "main sprint_id comment strip prevents false per-sprint match" {
  local resolve_sh="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  [ -f "$resolve_sh" ] || { echo "resolve-sprint-stories.sh not found at $resolve_sh" >&2; return 1; }

  # Build sprint-M (single mode) with a story.
  _build_sprint_with_inject "$TEST_TMP" sprint-M MAIN-S1 in-progress

  # Add an inline comment on the main file's sprint_id line.
  # Without trimming, the resolver would look for
  # sprint-status-sprint-M   # current.yaml (no match) and always append
  # the main file — masking a real bug when a per-sprint sprint-M file exists.
  local _state="$TEST_TMP/.gaia/state/sprint-status.yaml"
  sed 's/^sprint_id: "sprint-M"$/sprint_id: "sprint-M"   # current/' "$_state" > "$_state.tmp" \
    && mv "$_state.tmp" "$_state"

  # Create a per-sprint file for sprint-M (same sprint as main).
  # The main file should be SKIPPED because sprint-M already has a per-sprint
  # file — but only if the comment is trimmed from the sprint_id.
  local aux="$BATS_TEST_TMPDIR/aux-m"
  _build_sprint_with_inject "$aux" sprint-M PER-M-S1 done
  cp "$aux/.gaia/state/sprint-status.yaml" "$TEST_TMP/.gaia/state/sprint-status-sprint-M.yaml"

  # Add a decoy story to the main file.  If the resolver reads the main file
  # despite sprint-M having a per-sprint file, DECOY-S1 appears in the output.
  local aux2="$BATS_TEST_TMPDIR/aux-m2"
  _build_sprint_with_inject "$aux2" sprint-M MAIN-S1 in-progress DECOY-S1 in-progress
  cp "$aux2/.gaia/state/sprint-status.yaml" "$_state"
  # Re-apply the comment on sprint_id.
  sed 's/^sprint_id: "sprint-M"$/sprint_id: "sprint-M"   # current/' "$_state" > "$_state.tmp" \
    && mv "$_state.tmp" "$_state"

  mkdir -p "$TEST_TMP/impl/epic-a/MAIN-S1-test"
  printf -- '---\nkey: MAIN-S1\n---\n' > "$TEST_TMP/impl/epic-a/MAIN-S1-test/story.md"
  mkdir -p "$TEST_TMP/impl/epic-b/PER-M-S1-test"
  printf -- '---\nkey: PER-M-S1\n---\n' > "$TEST_TMP/impl/epic-b/PER-M-S1-test/story.md"
  mkdir -p "$TEST_TMP/impl/epic-c/DECOY-S1-test"
  printf -- '---\nkey: DECOY-S1\n---\n' > "$TEST_TMP/impl/epic-c/DECOY-S1-test/story.md"

  export PROJECT_ROOT="$TEST_TMP"

  run bash "$resolve_sh" --impl-dir "$TEST_TMP/impl"

  [ "$status" -eq 0 ]
  # PER-M-S1 is in the per-sprint file and should be found.
  [[ "$output" == *"PER-M-S1"* ]]
  # DECOY-S1 exists only in the main file; the main file should be skipped
  # because sprint-M already has a per-sprint file.
  [[ "$output" != *"DECOY-S1"* ]]
}

# ---------- No leaked IDs in changed files (story AC11) ----------

@test "no internal traceability identifiers in published session-binding.sh" {
  local sb_sh="$BATS_TEST_DIRNAME/../scripts/lib/session-binding.sh"
  run /usr/bin/grep -EnH \
    '(FR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[0-9]+|NFR-[0-9]+|SR-[0-9]+)' \
    "$sb_sh"
  [ "$status" -eq 1 ]
}

@test "no internal traceability identifiers in published resolve-sprint-stories.sh" {
  local rs_sh="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  run /usr/bin/grep -EnH \
    '(FR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[0-9]+|NFR-[0-9]+|SR-[0-9]+)' \
    "$rs_sh"
  [ "$status" -eq 1 ]
}

@test "no internal traceability identifiers in published sprint-close SKILL.md" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"
  run /usr/bin/grep -EnH \
    '(FR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[0-9]+|NFR-[0-9]+|SR-[0-9]+)' \
    "$skill_md"
  [ "$status" -eq 1 ]
}
