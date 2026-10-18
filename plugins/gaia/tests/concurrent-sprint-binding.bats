#!/usr/bin/env bats
# concurrent-sprint-binding.bats — session-to-sprint binding lifecycle,
# cross-validation, closed-sprint guard, binding-dir provisioning, back-compat,
# --sprint override, and compatibility tests.

# shellcheck disable=SC2030,SC2031

setup() {
  # bats setup — clear project/root env vars per repo-wide lint.
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH
  unset GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  unset _GAIA_MAX_CONCURRENT _GAIA_CONCURRENT_MODE

  TEST_DIR="$(mktemp -d)"
  STATE_DIR="$TEST_DIR/.gaia/state"
  IMPL_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_DIR/.gaia/config"
  SESSION_DIR="$TEST_DIR/.gaia/state/sessions"
  mkdir -p "$STATE_DIR" "$IMPL_DIR" "$CONFIG_DIR" "$SESSION_DIR"

  # Minimal sprint-status.yaml for testing.
  cat > "$STATE_DIR/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-900"
status: active
total_points: 10
goals: []
stories:
  - key: "E900-S1"
    title: "Test story"
    status: "in-progress"
    points: 5
    risk: "medium"
YAML

  # Minimal project-config.yaml (single-sprint default).
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "test-project"
stacks:
  - name: bash
    path: "."
YAML

  # Export variables for sprint-state.sh.
  export PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status.yaml"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  # Locate scripts under test.
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  SPRINT_STATE="$BATS_TEST_SCRIPT_DIR/scripts/sprint-state.sh"
  SESSION_BINDING="$BATS_TEST_SCRIPT_DIR/scripts/lib/session-binding.sh"
  BIND_SCRIPT="$BATS_TEST_SCRIPT_DIR/skills/gaia-run-sprint/scripts/bind.sh"
  export SPRINT_STATE_SCRIPT_DIR="$BATS_TEST_SCRIPT_DIR/scripts"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ---------- Helpers ----------

# Set max_concurrent_active in project-config.yaml.
set_max_concurrent() {
  local val="$1"
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
sprint:
  max_concurrent_active: $val
stacks:
  - name: bash
    path: "."
YAML
}

# Seed a per-sprint file for a given sprint.
seed_per_sprint_file() {
  local sid="$1" status="${2:-active}"
  cat > "$STATE_DIR/sprint-status-${sid}.yaml" <<YAML
sprint_id: "${sid}"
status: ${status}
total_points: 0
goals: []
stories:
  - key: "E900-S1"
    title: "Test story"
    status: "in-progress"
    points: 5
    risk: "medium"
YAML
}

# Provision a binding for tests by sourcing session-binding.sh.
setup_binding() {
  local sid="${1:-test-session-001}"
  local sprint="${2:-sprint-900}"
  export CLAUDE_CODE_SESSION_ID="$sid"
  # shellcheck source=../scripts/lib/session-binding.sh
  source "$SESSION_BINDING"
  provision_binding_dir
  if [ -n "$sprint" ]; then
    write_binding "$sprint" "$STATE_DIR"
  fi
}

# =========================================================================
# Session binding with validation and re-entry
# =========================================================================

@test "session binds to sprint via write_binding and read_binding returns it" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac1-bind"
  source "$SESSION_BINDING"
  provision_binding_dir

  # Write binding.
  write_binding "sprint-900" "$STATE_DIR"

  # Verify binding file content.
  local content
  content="$(cat "$GAIA_BINDING_DIR/bound_sprint_id")"
  [ "$content" = "sprint-900" ]

  # read_binding returns the sprint ID.
  local result
  result="$(read_binding)"
  [ "$result" = "sprint-900" ]
}

@test "re-entry with same sprint is idempotent" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac1-reentry"
  source "$SESSION_BINDING"
  provision_binding_dir

  write_binding "sprint-900" "$STATE_DIR"
  # Re-entry: same sprint.
  write_binding "sprint-900" "$STATE_DIR"

  local content
  content="$(cat "$GAIA_BINDING_DIR/bound_sprint_id")"
  [ "$content" = "sprint-900" ]
}

@test "re-entry without --sprint reuses binding" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac1-no-sprint"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"

  # read_binding without any sprint arg still returns the bound sprint.
  local result
  result="$(read_binding)"
  [ "$result" = "sprint-900" ]
}

@test "different sprint refused with 'already bound to'" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  seed_per_sprint_file "sprint-901" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac1-diff"
  source "$SESSION_BINDING"
  provision_binding_dir

  write_binding "sprint-900" "$STATE_DIR"
  run write_binding "sprint-901" "$STATE_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already bound to sprint-900"* ]]
}

@test "sprint ID validation rejects invalid characters" {
  set_max_concurrent 3
  export CLAUDE_CODE_SESSION_ID="sess-ac1-invalid"
  source "$SESSION_BINDING"
  provision_binding_dir

  run write_binding "sprint/bad" "$STATE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid characters"* ]]
}

# =========================================================================
# Auto-bind rules for zero, one, and multiple active sprints
# =========================================================================

@test "zero active sprints — no binding written" {
  set_max_concurrent 3
  # No per-sprint files with active status.
  seed_per_sprint_file "sprint-900" "closed"
  export CLAUDE_CODE_SESSION_ID="sess-ac2-zero"
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"

  run bash "$BIND_SCRIPT"
  [ "$status" -eq 0 ]
  # No binding file should exist.
  [ ! -f "$SESSION_DIR/sess-ac2-zero/bound_sprint_id" ]
}

@test "one active sprint — auto-binds" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac2-one"
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"

  run bash "$BIND_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
}

@test "multiple active sprints without --sprint — refuses with listing" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  seed_per_sprint_file "sprint-901" "active"
  seed_per_sprint_file "sprint-902" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac2-multi"
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"

  run bash "$BIND_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"multiple active sprints"* ]] || [[ "$output" == *"Multiple active sprints"* ]]
}

# =========================================================================
# Cross-validation of env var against binding file
# =========================================================================

@test "cross-validation passes when env var matches binding file" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac3-match"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  run validate_binding
  [ "$status" -eq 0 ]
}

@test "cross-validation halts with binding_mismatch when env var differs" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac3-mismatch"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-901"

  run validate_binding
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding_mismatch"* ]]
}

@test "read-only subcommands skip binding validation" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac3-readonly"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  # Intentionally set a mismatching env var.
  export GAIA_BOUND_SPRINT_ID="sprint-wrong"

  # Read-only subcommand should not be blocked by cross-validation.
  run bash "$SPRINT_STATE" get --story E900-S1
  # The get command may fail for other reasons (e.g. story not found in yaml)
  # but it should NOT fail with binding_mismatch.
  [[ "$output" != *"binding_mismatch"* ]]
}

@test "mutating subcommand halts on env/binding mismatch" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac3-mutate"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-wrong"

  run bash "$SPRINT_STATE" transition --story E900-S1 --to review
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding_mismatch"* ]]
}

# =========================================================================
# Binding file is sole authority over env var
# =========================================================================

@test "env var alone cannot redirect sprint operations" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  seed_per_sprint_file "sprint-999" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac4-auth"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  # Set env var to a different sprint.
  export GAIA_BOUND_SPRINT_ID="sprint-999"

  # Should halt with mismatch — binding file says sprint-900.
  run bash "$SPRINT_STATE" transition --story E900-S1 --to review
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding_mismatch"* ]]
}

# =========================================================================
# Closed-sprint guard refuses planning subcommands
# =========================================================================

@test "init refused when bound sprint is closed" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "closed"
  # Seed target sprint as closed so init would normally re-seed over it.
  # This isolates the closed-guard: without it, init would succeed (re-seed
  # a closed sprint). With it, the guard fires before init runs.
  seed_per_sprint_file "sprint-901" "closed"
  export CLAUDE_CODE_SESSION_ID="sess-ac5-init"
  source "$SESSION_BINDING"
  provision_binding_dir
  # Manually write binding to closed sprint (simulating it was closed after binding).
  printf 'sprint-900' > "$GAIA_BINDING_DIR/bound_sprint_id"

  # Capture stderr separately to assert the specific guard message.
  local stderr_file="$TEST_DIR/ac5-init-stderr.txt"
  run bash -c "bash '$SPRINT_STATE' init --sprint-id sprint-901 2>'$stderr_file'"
  [ "$status" -ne 0 ]
  local captured_stderr
  captured_stderr="$(cat "$stderr_file" 2>/dev/null)" || captured_stderr=""
  [[ "$captured_stderr" == *"your bound sprint is closed"* ]]
  # The guard must prevent init from re-seeding: sprint-901 status stays closed.
  local after_status
  after_status="$(yq '.status' "$STATE_DIR/sprint-status-sprint-901.yaml" 2>/dev/null)" || after_status=""
  [ "$after_status" = "closed" ]
}

@test "non-planning mutating subcommand not refused by closed guard" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "closed"
  export CLAUDE_CODE_SESSION_ID="sess-ac5-nonplan"
  source "$SESSION_BINDING"
  provision_binding_dir
  printf 'sprint-900' > "$GAIA_BINDING_DIR/bound_sprint_id"

  # transition is a non-planning mutating subcommand.
  # It should NOT be blocked by S3's guard. It may fail for other reasons
  # (story not in yaml, etc.) but NOT with "your bound sprint is closed".
  run bash "$SPRINT_STATE" transition --story E900-S1 --to review
  [[ "$output" != *"your bound sprint is closed"* ]]
}

@test "read-only subcommand succeeds when bound sprint is closed" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "closed"
  export CLAUDE_CODE_SESSION_ID="sess-ac5-ro"
  source "$SESSION_BINDING"
  provision_binding_dir
  printf 'sprint-900' > "$GAIA_BINDING_DIR/bound_sprint_id"

  # Read-only should work regardless.
  run bash "$SPRINT_STATE" get --story E900-S1
  [[ "$output" != *"your bound sprint is closed"* ]]
}

# =========================================================================
# No session identity produces controlled diagnostic
# =========================================================================

@test "no session identity fails with diagnostic naming expected variables" {
  unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  source "$SESSION_BINDING"

  run provision_binding_dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_CODE_SESSION_ID"* ]]
  [[ "$output" == *"CLAUDE_SESSION_ID"* ]]
}

# =========================================================================
# Byte-identical mirrors
# =========================================================================

@test "session-binding.sh mirrors are byte-identical" {
  diff "$BATS_TEST_SCRIPT_DIR/scripts/lib/session-binding.sh" \
       "$BATS_TEST_SCRIPT_DIR/skills/gaia-dev-story/scripts/lib/session-binding.sh"
}

@test "sprint-state.sh mirrors are byte-identical" {
  diff "$BATS_TEST_SCRIPT_DIR/scripts/sprint-state.sh" \
       "$BATS_TEST_SCRIPT_DIR/skills/gaia-dev-story/scripts/sprint-state.sh"
}

# =========================================================================
# No internal identifiers in published files
# =========================================================================

@test "no internal traceability identifiers in published session-binding files" {
  local files_to_scan=(
    "$BATS_TEST_SCRIPT_DIR/scripts/lib/session-binding.sh"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-run-sprint/scripts/bind.sh"
  )
  local count=0
  for f in "${files_to_scan[@]}"; do
    [ -f "$f" ] || continue
    # Count matches excluding test fixtures (E900-*), regex patterns, and
    # comment lines that are legitimate.
    local hits
    hits=$(/usr/bin/grep -cE '(FR-[0-9]+|NFR-[0-9]+|SR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[A-Z]+-[0-9]+|AF-[0-9]{4}-[0-9]{2}-[0-9]{2}-)' "$f" 2>/dev/null || true)
    count=$((count + ${hits:-0}))
  done
  [ "$count" -eq 0 ]
}

# =========================================================================
# Binding-dir provisioning from session ID with spoofing detection
# =========================================================================

@test "binding dir provisioned from CLAUDE_CODE_SESSION_ID" {
  export CLAUDE_CODE_SESSION_ID="abc123"
  source "$SESSION_BINDING"
  provision_binding_dir
  [ -d "$SESSION_DIR/abc123" ]
  [ -n "$GAIA_BINDING_DIR" ]
  [[ "$GAIA_BINDING_DIR" == *"/abc123" ]]
}

@test "fallback to CLAUDE_SESSION_ID when CLAUDE_CODE_SESSION_ID unset" {
  unset CLAUDE_CODE_SESSION_ID
  export CLAUDE_SESSION_ID="def456"
  source "$SESSION_BINDING"
  provision_binding_dir
  [ -d "$SESSION_DIR/def456" ]
  [[ "$GAIA_BINDING_DIR" == *"/def456" ]]
}

@test "inherited GAIA_BINDING_DIR mismatching derived path refused as spoofing" {
  export CLAUDE_CODE_SESSION_ID="abc123"
  export GAIA_BINDING_DIR="/tmp/evil-dir"
  source "$SESSION_BINDING"

  run provision_binding_dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"spoofing"* ]]
}

@test "inherited GAIA_BINDING_DIR matching derived path accepted" {
  export CLAUDE_CODE_SESSION_ID="abc123"
  source "$SESSION_BINDING"
  provision_binding_dir
  local correct_dir="$GAIA_BINDING_DIR"

  # Re-provision with the correct dir pre-set.
  export GAIA_BINDING_DIR="$correct_dir"
  run provision_binding_dir
  [ "$status" -eq 0 ]
}

# =========================================================================
# Single-sprint mode skips binding entirely
# =========================================================================

@test "single-sprint mode skips binding entirely" {
  # Default config: no max_concurrent_active, no per-sprint files.
  export CLAUDE_CODE_SESSION_ID="sess-ac10-single"
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"

  run bash "$BIND_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$SESSION_DIR/sess-ac10-single/bound_sprint_id" ]
}

@test "transitional state keeps validating when per-sprint files remain with limit 1" {
  # max=1 but per-sprint files exist.
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "test-project"
sprint:
  max_concurrent_active: 1
stacks:
  - name: bash
    path: "."
YAML
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac10-trans"
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"

  run bash "$BIND_SCRIPT"
  [ "$status" -eq 0 ]
  # In transitional mode, binding should be attempted.
  [[ "$output" == *"sprint-900"* ]]
}

# =========================================================================
# Per-subcommand --sprint override semantics
# =========================================================================

@test "explicit --sprint override on transition logged" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  seed_per_sprint_file "sprint-901" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac11-override"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  # Transition with --sprint sprint-901 (override).
  # Capture stderr to a file so we can assert the override log line.
  local stderr_file="$TEST_DIR/override-stderr.txt"
  run bash -c "bash '$SPRINT_STATE' transition --story E900-S1 --to review --sprint sprint-901 2>'$stderr_file'"
  local captured_stderr
  captured_stderr="$(cat "$stderr_file" 2>/dev/null)" || captured_stderr=""
  [[ "$captured_stderr" == *"sprint override: bound=sprint-900 target=sprint-901 command=transition"* ]]
}

@test "set-story-sprint --sprint is destination not override" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  seed_per_sprint_file "sprint-901" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac11-dest"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  # set-story-sprint --sprint is a destination, NOT an override. No override log.
  run bash "$SPRINT_STATE" set-story-sprint --story E900-S1 --sprint sprint-901
  [[ "$output" != *"sprint override:"* ]]
}

@test "env/binding mismatch halts even with explicit --sprint" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  seed_per_sprint_file "sprint-901" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac11-mismatch"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-999"

  run bash "$SPRINT_STATE" transition --story E900-S1 --to review --sprint sprint-901
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding_mismatch"* ]]
}

# =========================================================================
# init/advance with nonexistent --sprint-id refused in bound session
# =========================================================================

@test "init with nonexistent --sprint-id refused in bound session" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ac12-init"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  # sprint-new does not exist.
  run bash "$SPRINT_STATE" init --sprint-id sprint-new
  [ "$status" -ne 0 ]
  [[ "$output" == *"start a new session to plan the next sprint"* ]]
}

@test "init with nonexistent --sprint-id in unbound session proceeds" {
  set_max_concurrent 3
  # No binding, no session ID.
  unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID

  # sprint-new does not exist — init should proceed (creates it).
  # It may fail for other reasons but NOT with "start a new session".
  run bash "$SPRINT_STATE" init --sprint-id sprint-new
  [[ "$output" != *"start a new session to plan the next sprint"* ]]
}

# =========================================================================
# Unsafe session ID characters refused
# =========================================================================

@test "session ID with path separator refused" {
  export CLAUDE_CODE_SESSION_ID="../../../etc"
  source "$SESSION_BINDING"
  run provision_binding_dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"path separator"* ]]
}

@test "session ID with leading dot refused" {
  export CLAUDE_CODE_SESSION_ID=".hidden"
  source "$SESSION_BINDING"
  run provision_binding_dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"leading dot"* ]]
}

@test "session ID with whitespace refused" {
  export CLAUDE_CODE_SESSION_ID="has space"
  source "$SESSION_BINDING"
  run provision_binding_dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"whitespace"* ]]
}

# =========================================================================
# Partial binding file content detected
# =========================================================================

@test "partial content in binding file halts with diagnostic" {
  set_max_concurrent 3
  export CLAUDE_CODE_SESSION_ID="sess-ec2-partial"
  source "$SESSION_BINDING"
  provision_binding_dir
  # Write partial content directly (simulating interrupted write).
  printf 'sprin' > "$GAIA_BINDING_DIR/bound_sprint_id"

  # read_binding should return exit 3 (invalid) because "sprin" names no
  # existing sprint and will fail status lookup.
  run read_binding
  [ "$status" -ne 0 ]
}

# =========================================================================
# Env var without binding file halts in concurrent mode
# =========================================================================

@test "env var set without binding file halts with binding_mismatch" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ec3-nofile"
  export GAIA_BOUND_SPRINT_ID="sprint-900"
  source "$SESSION_BINDING"
  provision_binding_dir
  # No binding file written.

  run validate_binding
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding_mismatch"* ]]
}

@test "env var ignored in single-sprint mode" {
  # Single-sprint mode: no max_concurrent, no per-sprint files.
  export CLAUDE_CODE_SESSION_ID="sess-ec3-single"
  export GAIA_BOUND_SPRINT_ID="sprint-900"
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"

  # Should succeed — binding validation skipped in single-sprint mode.
  run bash "$SPRINT_STATE" get --story E900-S1
  [[ "$output" != *"binding_mismatch"* ]]
}

# =========================================================================
# External close triggers guard on next planning subcommand
# =========================================================================

@test "external close triggers closed-guard on init" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ec4-ext"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  # External process closes the sprint.
  yq -i '.status = "closed"' "$STATE_DIR/sprint-status-sprint-900.yaml"

  run bash "$SPRINT_STATE" init --sprint-id sprint-new
  [ "$status" -ne 0 ]
  [[ "$output" == *"your bound sprint is closed"* ]]
}

# =========================================================================
# NFS noclobber best-effort (documented limitation)
# =========================================================================

@test "noclobber and realpath containment are implemented" {
  # This test verifies the defense mechanisms exist in the source code,
  # not that NFS atomicity is enforced (documented limitation).
  /usr/bin/grep -q 'set -C' "$SESSION_BINDING"
  /usr/bin/grep -q 'realpath' "$SESSION_BINDING"
  /usr/bin/grep -q '_sb_check_containment' "$SESSION_BINDING"
}

# =========================================================================
# Long-running session detects mid-session sprint close
# =========================================================================

@test "closed-sprint detection triggers regardless of session age" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ec6-long"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  # Simulate sprint closing mid-session.
  yq -i '.status = "closed"' "$STATE_DIR/sprint-status-sprint-900.yaml"

  # Planning subcommand should be refused.
  run bash "$SPRINT_STATE" init --sprint-id sprint-new
  [ "$status" -ne 0 ]
  [[ "$output" == *"your bound sprint is closed"* ]]

  # Non-planning mutating should NOT be refused by S3's guard.
  run bash "$SPRINT_STATE" transition --story E900-S1 --to review
  [[ "$output" != *"your bound sprint is closed"* ]]
}

# =========================================================================
# Same-session-ID race prevented by noclobber
# =========================================================================

@test "noclobber prevents overwrite when same session ID binds different sprints" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  seed_per_sprint_file "sprint-901" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ec7-race"
  source "$SESSION_BINDING"
  provision_binding_dir

  # First bind.
  write_binding "sprint-900" "$STATE_DIR"

  # Second bind to different sprint should fail.
  run write_binding "sprint-901" "$STATE_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already bound to sprint-900"* ]]

  # Same sprint should succeed (idempotent).
  run write_binding "sprint-900" "$STATE_DIR"
  [ "$status" -eq 0 ]
}

@test "different session IDs sharing GAIA_BINDING_DIR refused as spoofing" {
  set_max_concurrent 3
  export CLAUDE_CODE_SESSION_ID="session-x"
  source "$SESSION_BINDING"
  provision_binding_dir
  local x_dir="$GAIA_BINDING_DIR"

  # Session Y with a different session ID but same GAIA_BINDING_DIR.
  export CLAUDE_CODE_SESSION_ID="session-y"
  export GAIA_BINDING_DIR="$x_dir"
  run provision_binding_dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"spoofing"* ]]
}

# =========================================================================
# Symlink traversal detected by realpath containment
# =========================================================================

@test "symlink pointing outside binding dir is refused" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-ec8-symlink"
  source "$SESSION_BINDING"
  provision_binding_dir

  # Create a file OUTSIDE the binding dir with a valid sprint ID.
  local outside_file="$TEST_DIR/outside-binding.txt"
  printf 'sprint-900' > "$outside_file"

  # Symlink the binding file to the outside file.
  ln -sf "$outside_file" "$GAIA_BINDING_DIR/bound_sprint_id"

  run read_binding
  [ "$status" -ne 0 ]
  [[ "$output" == *"containment"* ]]
}

# =========================================================================
# Additional story-local test scenarios
# =========================================================================

@test "binding directory created with mode 0700" {
  export CLAUDE_CODE_SESSION_ID="sess-dir-0700"
  source "$SESSION_BINDING"
  provision_binding_dir

  [ -d "$GAIA_BINDING_DIR" ]
  local perms
  perms="$(stat -c '%a' "$GAIA_BINDING_DIR" 2>/dev/null || stat -f '%Lp' "$GAIA_BINDING_DIR" 2>/dev/null)"
  [ "$perms" = "700" ]
}

@test "sprint-state.sh works without binding in single-sprint mode" {
  # Single-sprint mode, no concurrent features.
  unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"

  # get (read-only) should work.
  run bash "$SPRINT_STATE" get --story E900-S1
  # Should not error with binding-related messages (both must hold).
  [[ "$output" != *"binding_mismatch"* ]]
  [[ "$output" != *"spoofing"* ]]
}

@test "review and correction remain valid binding" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="sess-bindable"
  source "$SESSION_BINDING"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"

  # Active: exit 0.
  run read_binding
  [ "$status" -eq 0 ]

  # Move to review: still valid.
  yq -i '.status = "review"' "$STATE_DIR/sprint-status-sprint-900.yaml"
  run read_binding
  [ "$status" -eq 0 ]

  # Move to correction: still valid.
  yq -i '.status = "correction"' "$STATE_DIR/sprint-status-sprint-900.yaml"
  run read_binding
  [ "$status" -eq 0 ]

  # Move to closed: exit 2.
  yq -i '.status = "closed"' "$STATE_DIR/sprint-status-sprint-900.yaml"
  run read_binding
  [ "$status" -eq 2 ]
}

@test "planned sprint cannot be bound" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "planned"
  export CLAUDE_CODE_SESSION_ID="sess-planned"
  source "$SESSION_BINDING"
  provision_binding_dir

  run write_binding "sprint-900" "$STATE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planned"* ]]
}

@test "read_binding exit codes match binding state" {
  set_max_concurrent 3
  export CLAUDE_CODE_SESSION_ID="sess-exit-codes"
  source "$SESSION_BINDING"
  provision_binding_dir

  # Exit 1: unbound.
  run read_binding
  [ "$status" -eq 1 ]

  # Exit 0: bound to active sprint.
  seed_per_sprint_file "sprint-900" "active"
  write_binding "sprint-900" "$STATE_DIR"
  run read_binding
  [ "$status" -eq 0 ]
  [[ "$output" == "sprint-900" ]]

  # Exit 2: closed sprint.
  yq -i '.status = "closed"' "$STATE_DIR/sprint-status-sprint-900.yaml"
  run read_binding
  [ "$status" -eq 2 ]
  [[ "$output" == *"sprint-900"* ]]
}

@test "session-binding.sh read with explicit --session-id and --project-root" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  # Pre-provision the binding.
  mkdir -p "$SESSION_DIR/cli-test-id"
  printf 'sprint-900' > "$SESSION_DIR/cli-test-id/bound_sprint_id"

  run bash "$SESSION_BINDING" read --session-id cli-test-id --project-root "$TEST_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == "sprint-900" ]]
}

@test "closed-bound blocks explicit --sprint on init" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "closed"
  seed_per_sprint_file "sprint-901" "active"
  export CLAUDE_CODE_SESSION_ID="sess-closed-override"
  source "$SESSION_BINDING"
  provision_binding_dir
  printf 'sprint-900' > "$GAIA_BINDING_DIR/bound_sprint_id"
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  # init with --sprint-id to an active sprint: AC5 takes precedence.
  run bash "$SPRINT_STATE" init --sprint-id sprint-901
  [ "$status" -ne 0 ]
  [[ "$output" == *"your bound sprint is closed"* ]]
}

@test "non-planning override to non-closed sprint proceeds" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "closed"
  seed_per_sprint_file "sprint-901" "active"
  export CLAUDE_CODE_SESSION_ID="sess-closed-nonplan"
  source "$SESSION_BINDING"
  provision_binding_dir
  printf 'sprint-900' > "$GAIA_BINDING_DIR/bound_sprint_id"
  export GAIA_BOUND_SPRINT_ID="sprint-900"

  # transition (non-planning) with --sprint to a non-closed sprint.
  # Should NOT be blocked by S3's closed guard.
  run bash "$SPRINT_STATE" transition --story E900-S1 --to review --sprint sprint-901
  [[ "$output" != *"your bound sprint is closed"* ]]
}

@test "mirrors verified byte-identical" {
  diff "$BATS_TEST_SCRIPT_DIR/scripts/lib/session-binding.sh" \
       "$BATS_TEST_SCRIPT_DIR/skills/gaia-dev-story/scripts/lib/session-binding.sh"
  diff "$BATS_TEST_SCRIPT_DIR/scripts/sprint-state.sh" \
       "$BATS_TEST_SCRIPT_DIR/skills/gaia-dev-story/scripts/sprint-state.sh"
}

@test "child inherits env var but has no binding file" {
  set_max_concurrent 3
  seed_per_sprint_file "sprint-900" "active"
  export CLAUDE_CODE_SESSION_ID="child-different-session"
  export GAIA_BOUND_SPRINT_ID="sprint-900"
  source "$SESSION_BINDING"
  provision_binding_dir
  # No binding file in child's dir.

  run validate_binding
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding_mismatch"* ]]
}
