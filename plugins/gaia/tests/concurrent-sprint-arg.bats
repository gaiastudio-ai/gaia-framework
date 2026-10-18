#!/usr/bin/env bats
# concurrent-sprint-arg.bats — integration tests for --sprint argument
# resolution across all 8 sprint-scoped commands via resolve_sprint_arg().

# shellcheck disable=SC2030,SC2031

setup() {
  # Clear project/root env vars per repo-wide lint.
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH
  unset GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  unset _GAIA_MAX_CONCURRENT _GAIA_CONCURRENT_MODE

  TEST_DIR="$(mktemp -d)"
  STATE_DIR="$TEST_DIR/.gaia/state"
  IMPL_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_DIR/.gaia/config"
  SESSION_DIR="$TEST_DIR/.gaia/state/sessions"
  ARCHIVE_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts/sprint-archive"
  mkdir -p "$STATE_DIR" "$IMPL_DIR" "$CONFIG_DIR" "$SESSION_DIR" "$ARCHIVE_DIR"

  # Per-sprint state files for concurrent mode.
  cat > "$STATE_DIR/sprint-status-sprint-900.yaml" <<'YAML'
sprint_id: "sprint-900"
status: active
total_points: 10
goals: []
stories:
  - key: "E900-S1"
    title: "Test story A"
    status: "in-progress"
    points: 5
    risk: "medium"
YAML

  cat > "$STATE_DIR/sprint-status-sprint-901.yaml" <<'YAML'
sprint_id: "sprint-901"
status: active
total_points: 8
goals: []
stories:
  - key: "E901-S1"
    title: "Test story B"
    status: "in-progress"
    points: 4
    risk: "low"
YAML

  # Concurrent-mode config.
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "test-project"
sprint:
  max_concurrent_active: 3
stacks:
  - name: bash
    path: "."
YAML

  export PROJECT_ROOT="$TEST_DIR"
  export CLAUDE_PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  # Locate scripts under test.
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  SESSION_BINDING="$BATS_TEST_SCRIPT_DIR/scripts/lib/session-binding.sh"
  DASHBOARD="$BATS_TEST_SCRIPT_DIR/scripts/sprint-status-dashboard.sh"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ---------- Helper ----------

_resolve() {
  # Source session-binding.sh and call resolve_sprint_arg with the given args.
  # Inherits env from the caller (PROJECT_ROOT, GAIA_BOUND_SPRINT_ID, etc.)
  bash -c '
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg "$@"
  ' -- "$@"
}

_setup_binding() {
  # Create a binding directory and file for the given sprint.
  local sid="$1"
  local session_id="${2:-test-session}"
  local binding_dir="$SESSION_DIR/$session_id"
  mkdir -p "$binding_dir"
  printf '%s' "$sid" > "$binding_dir/bound_sprint_id"
  GAIA_BINDING_DIR="$binding_dir"
  export GAIA_BINDING_DIR
}

_setup_closed_sprint() {
  # Create a closed sprint state file and optionally an archive.
  local sid="$1"
  local archive="${2:-yes}"
  cat > "$STATE_DIR/sprint-status-${sid}.yaml" <<YAML
sprint_id: "${sid}"
status: closed
closed_at: "2026-10-01T00:00:00Z"
total_points: 10
goals: []
stories: []
YAML
  if [ "$archive" = "yes" ]; then
    cp "$STATE_DIR/sprint-status-${sid}.yaml" \
       "$ARCHIVE_DIR/${sid}-closed-2026-10-01.yaml"
  fi
}

# ---------- TC-CONC-ARG-1: all commands accept --sprint ----------

@test "resolve_sprint_arg: sprint-status accepts --sprint sprint-900" {
  run _resolve --command sprint-status --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: sprint-close accepts --sprint sprint-900" {
  run _resolve --command sprint-close --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: sprint-review accepts --sprint sprint-900" {
  run _resolve --command sprint-review --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: retro accepts --sprint sprint-900" {
  run _resolve --command retro --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: correct-course accepts --sprint sprint-900" {
  run _resolve --command correct-course --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: sprint-plan accepts --sprint sprint-900" {
  run _resolve --command sprint-plan --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: run-sprint accepts --sprint sprint-900 when bound to sprint-900" {
  _setup_binding sprint-900
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command run-sprint --sprint sprint-900
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: action-items accepts --sprint sprint-900" {
  run _resolve --command action-items --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

# ---------- TC-CONC-ARG-2: bound session defaults to bound sprint ----------

@test "resolve_sprint_arg: retro defaults to bound sprint" {
  _setup_binding sprint-900
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command retro
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: sprint-status without --sprint returns empty (no default)" {
  _setup_binding sprint-900
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command sprint-status
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- TC-CONC-ARG-3: nonexistent sprint ID rejected ----------

@test "resolve_sprint_arg: nonexistent sprint-999 rejected" {
  run _resolve --command sprint-status --sprint sprint-999
  [ "$status" -eq 10 ]
  [[ "$output" == *"sprint-999"* ]]
  [[ "$output" == *"not found"* ]]
}

# ---------- TC-CONC-ARG-4 / TC-CONC-COMPAT-4: --sprint optional with max=1 ----------

@test "resolve_sprint_arg: single-sprint mode succeeds without --sprint" {
  # Remove one sprint file so only sprint-900 is active.
  rm -f "$STATE_DIR/sprint-status-sprint-901.yaml"
  run _resolve --command retro
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: single-sprint mode succeeds with --sprint sprint-900" {
  rm -f "$STATE_DIR/sprint-status-sprint-901.yaml"
  run _resolve --command retro --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

@test "resolve_sprint_arg: 4 commands succeed without --sprint in single-sprint mode" {
  rm -f "$STATE_DIR/sprint-status-sprint-901.yaml"
  local cmds="retro correct-course sprint-plan sprint-close"
  for cmd in $cmds; do
    run _resolve --command "$cmd"
    [ "$status" -eq 0 ]
    [ "$output" = "sprint-900" ]
  done
}

# ---------- TC-CONC-ARG-CLOSED: closed sprint read-only ok, mutating refused ----------

@test "resolve_sprint_arg: read-only accepts closed sprint" {
  _setup_closed_sprint sprint-closed
  run _resolve --command sprint-status --sprint sprint-closed
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-closed" ]
}

@test "resolve_sprint_arg: mutating refuses closed sprint" {
  _setup_closed_sprint sprint-closed
  run _resolve --command retro --sprint sprint-closed
  [ "$status" -eq 11 ]
  [[ "$output" == *"sprint is closed"* ]]
}

# ---------- TC-CONC-ARG-LISTING: unbound multi-sprint listing ----------

@test "resolve_sprint_arg: unbound multi-sprint refuses retro with listing" {
  run _resolve --command retro
  [ "$status" -eq 12 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"sprint-901"* ]]
  [[ "$output" == *"specify --sprint"* ]]
}

# ---------- TC-CONC-ARG-IDSCAN: published file ID scan ----------

@test "published files contain no internal traceability IDs" {
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  # Scan files this story creates or modifies.
  local files_to_check=(
    "$BATS_TEST_SCRIPT_DIR/scripts/lib/session-binding.sh"
    "$BATS_TEST_SCRIPT_DIR/scripts/sprint-status-dashboard.sh"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-sprint-status/SKILL.md"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-sprint-close/SKILL.md"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-sprint-review/SKILL.md"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-retro/SKILL.md"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-correct-course/SKILL.md"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-sprint-plan/SKILL.md"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-run-sprint/SKILL.md"
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-action-items/SKILL.md"
  )
  local found=0
  for f in "${files_to_check[@]}"; do
    [ -f "$f" ] || continue
    # Internal IDs: FR-nnn, NFR-nnn, ADR-nnn, E##-S##, TC-..., AF-2026, AI-20nn, SR-nnn
    local hits=""
    hits="$(/usr/bin/grep -nE '(FR-[0-9]{2,}|NFR-[0-9]{2,}|SR-[0-9]{2,}|ADR-[0-9]{2,}|E[0-9]+-S[0-9]+|AF-20[0-9]{2}|AI-20[0-9]{2}|TC-CONC)' "$f" 2>/dev/null | /usr/bin/grep -v '^[[:space:]]*#' | /usr/bin/grep -v 'E900-S\|E901-S' || true)"
    if [ -n "$hits" ]; then
      printf 'LEAKED in %s:\n%s\n' "$f" "$hits" >&2
      found=$((found + 1))
    fi
  done
  [ "$found" -eq 0 ]
}

# ---------- TC-CONC-ARG-OVERRIDE: cross-sprint mutation via --sprint ----------

@test "resolve_sprint_arg: cross-sprint override succeeds and logs" {
  _setup_binding sprint-900
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command correct-course --sprint sprint-901 2>&1
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint override: bound=sprint-900 target=sprint-901 command=correct-course"* ]]
  [[ "$output" == *"sprint-901"* ]]
}

# ---------- TC-CONC-ARG-RUNREFUSE: run-sprint refuses different --sprint ----------

@test "resolve_sprint_arg: run-sprint refuses --sprint different from binding" {
  _setup_binding sprint-900
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command run-sprint --sprint sprint-901
  '
  [ "$status" -eq 15 ]
  [[ "$output" == *"already bound to sprint-900"* ]]
}

# ---------- TC-CONC-ARG-EMPTY: empty --sprint value rejected ----------

@test "resolve_sprint_arg: empty --sprint rejected" {
  run _resolve --command sprint-status --sprint ""
  [ "$status" -eq 16 ]
  [[ "$output" == *"non-empty"* ]]
}

# ---------- TC-CONC-ARG-REPEAT: repeated --sprint refused ----------

@test "resolve_sprint_arg: repeated --sprint flags refused" {
  run _resolve --command sprint-status --sprint sprint-900 --sprint sprint-901
  [ "$status" -eq 13 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"sprint-901"* ]]
}

# ---------- TC-CONC-ARG-WRONGID: wrong ID in single-sprint mode ----------

@test "resolve_sprint_arg: wrong ID sprint-999 in single-sprint mode" {
  rm -f "$STATE_DIR/sprint-status-sprint-901.yaml"
  run _resolve --command sprint-status --sprint sprint-999
  [ "$status" -eq 10 ]
  [[ "$output" == *"sprint-999"* ]]
}

# ---------- TC-CONC-ARG-MATCH: --sprint matches binding ----------

@test "resolve_sprint_arg: --sprint matching binding succeeds" {
  _setup_binding sprint-900
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command retro --sprint sprint-900
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

# ---------- TC-CONC-ARG-POSITIONAL: positional + different --sprint refused ----------

@test "resolve_sprint_arg: positional sprint-900 + --sprint sprint-901 refused" {
  run _resolve --command retro sprint-900 --sprint sprint-901
  [ "$status" -eq 14 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"sprint-901"* ]]
}

# ---------- TC-CONC-ARG-POSONLY: positional sprint-id alone works ----------

@test "resolve_sprint_arg: positional sprint-900 on sprint-review works" {
  run _resolve --command sprint-review sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

# ---------- TC-CONC-ARG-UNBOUND: --sprint from unbound session ----------

@test "resolve_sprint_arg: --sprint from unbound session succeeds" {
  # Ensure no binding exists.
  unset GAIA_BINDING_DIR GAIA_BOUND_SPRINT_ID
  run _resolve --command retro --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

# ---------- TC-CONC-ARG-CLOSEDMUT: closed vs unknown on mutating ----------

@test "resolve_sprint_arg: closed sprint refused by mutating retro" {
  _setup_closed_sprint sprint-closed
  run _resolve --command retro --sprint sprint-closed
  [ "$status" -eq 11 ]
  [[ "$output" == *"sprint is closed"* ]]
}

@test "resolve_sprint_arg: unknown sprint refused by retro" {
  run _resolve --command retro --sprint sprint-unknown
  [ "$status" -eq 10 ]
  [[ "$output" == *"not found"* ]]
}

# ---------- TC-CONC-ARG-RESUME: closed sprint-close resume ----------

@test "resolve_sprint_arg: sprint-close allows closed sprint without archive (resume)" {
  _setup_closed_sprint sprint-closed no
  run _resolve --command sprint-close --sprint sprint-closed
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-closed" ]
}

# ---------- TC-CONC-ARG-IDEMPOTENT: closed sprint-close idempotent ----------

@test "resolve_sprint_arg: sprint-close allows closed sprint with archive (idempotent)" {
  _setup_closed_sprint sprint-closed yes
  run _resolve --command sprint-close --sprint sprint-closed
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-closed" ]
}

# ---------- TC-CONC-ARG-5: sprint-plan --new-sprint ----------

@test "resolve_sprint_arg: sprint-plan --new-sprint succeeds for unused ID" {
  run _resolve --command sprint-plan --new-sprint sprint-902
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-902" ]
}

@test "resolve_sprint_arg: sprint-plan --new-sprint refuses existing ID" {
  run _resolve --command sprint-plan --new-sprint sprint-900
  [ "$status" -eq 16 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"already exists"* ]]
}

@test "resolve_sprint_arg: sprint-plan --new-sprint refuses invalid shape" {
  run _resolve --command sprint-plan --new-sprint ".invalid"
  [ "$status" -eq 16 ]
  [[ "$output" == *"invalid sprint ID shape"* ]]
}

# ---------- TC-CONC-ARG-6: action-items sprint-optional ----------

@test "resolve_sprint_arg: action-items accepts closed sprint" {
  _setup_closed_sprint sprint-closed
  run _resolve --command action-items --sprint sprint-closed
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-closed" ]
}

@test "resolve_sprint_arg: action-items succeeds with no active sprint" {
  rm -f "$STATE_DIR"/sprint-status-sprint-900.yaml "$STATE_DIR"/sprint-status-sprint-901.yaml
  run _resolve --command action-items
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve_sprint_arg: action-items with --sprint filters" {
  run _resolve --command action-items --sprint sprint-900
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

# ---------- TC-CONC-ARG-7: re-close idempotent and resume ----------

@test "resolve_sprint_arg: sprint-close resolver on closed+archive exits 0" {
  _setup_closed_sprint sprint-closed yes
  run _resolve --command sprint-close --sprint sprint-closed
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-closed" ]
}

@test "resolve_sprint_arg: sprint-close resolver on closed+no-archive exits 0 (resume)" {
  _setup_closed_sprint sprint-closed no
  run _resolve --command sprint-close --sprint sprint-closed
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-closed" ]
}

# ---------- TC-CONC-ARG-8: repeated and positional conflict diagnostics ----------

@test "resolve_sprint_arg: repeated --sprint diagnostic names both values" {
  run _resolve --command retro --sprint sprint-900 --sprint sprint-901
  [ "$status" -eq 13 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"sprint-901"* ]]
}

@test "resolve_sprint_arg: positional+--sprint conflict diagnostic names both values" {
  run _resolve --command retro sprint-900 --sprint sprint-901
  [ "$status" -eq 14 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"sprint-901"* ]]
}

# ---------- TC-CONC-ARG-ARCHIVED: archived-only sprint on read-only vs mutating ----------

@test "resolve_sprint_arg: archived-only sprint accepted by read-only" {
  # Sprint exists only in archive, not in state files.
  cp "$STATE_DIR/sprint-status-sprint-900.yaml" "$ARCHIVE_DIR/sprint-archived-closed-2026-10-01.yaml"
  run _resolve --command sprint-status --sprint sprint-archived
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-archived" ]
}

@test "resolve_sprint_arg: archived-only sprint refused by mutating" {
  cp "$STATE_DIR/sprint-status-sprint-900.yaml" "$ARCHIVE_DIR/sprint-archived-closed-2026-10-01.yaml"
  run _resolve --command retro --sprint sprint-archived
  [ "$status" -eq 11 ]
  [[ "$output" == *"sprint is closed"* ]]
}

# ---------- TC-CONC-ARG-BOUNDCLOSED: bound sprint closed, mutating refused ----------

@test "resolve_sprint_arg: bound-closed refuses mutating with --sprint to active sprint" {
  _setup_binding sprint-900
  _setup_closed_sprint sprint-900 yes
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command correct-course --sprint sprint-901
  '
  [ "$status" -eq 17 ]
  [[ "$output" == *"bound sprint sprint-900 is closed"* ]]
}

@test "resolve_sprint_arg: bound-closed allows read-only with --sprint to active sprint" {
  _setup_binding sprint-900
  _setup_closed_sprint sprint-900 yes
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command sprint-status --sprint sprint-901 2>/dev/null
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-901" ]
}

# ---------- TC-CONC-ARG-BOUNDCLOSED-ACTITEMS: action-items in closed-bound session ----------

@test "resolve_sprint_arg: action-items allowed in closed-bound session" {
  _setup_binding sprint-900
  _setup_closed_sprint sprint-900 yes
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command action-items
  '
  [ "$status" -eq 0 ]
}

# ---------- TC-CONC-ARG-BOUNDCLOSED-CLOSE-RESUME: sprint-close resume in closed-bound ----------

@test "resolve_sprint_arg: sprint-close resume allowed in closed-bound session (archive missing)" {
  _setup_binding sprint-900
  _setup_closed_sprint sprint-900 no
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command sprint-close --sprint sprint-900
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

# ---------- TC-CONC-ARG-BOUNDCLOSED-REVIEW-HIST: sprint-review historical in closed-bound ----------

@test "resolve_sprint_arg: sprint-review historical allowed in closed-bound session" {
  _setup_binding sprint-900
  _setup_closed_sprint sprint-900 yes
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command sprint-review --sprint sprint-900
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}

# ---------- TC-CONC-ARG-LOGLINE: cross-sprint override log line ----------

@test "resolve_sprint_arg: override log line format" {
  _setup_binding sprint-900
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command correct-course --sprint sprint-901 2>&1
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint override: bound=sprint-900 target=sprint-901 command=correct-course"* ]]
}

# ---------- TC-CONC-ARG-REVIEWHIST: sprint-review historical on closed sprint ----------

@test "resolve_sprint_arg: sprint-review historical on closed sprint succeeds" {
  _setup_closed_sprint sprint-closed yes
  run _resolve --command sprint-review --sprint sprint-closed
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-closed" ]
}

# ---------- TC-CONC-ARG-BOUNDCLOSED-EXIT: bound-closed exit code 17 ----------

@test "resolve_sprint_arg: bound-closed returns exit 17" {
  _setup_binding sprint-900
  _setup_closed_sprint sprint-900 yes
  run bash -c '
    export GAIA_BINDING_DIR="'"$GAIA_BINDING_DIR"'"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command correct-course --sprint sprint-901
  '
  [ "$status" -eq 17 ]
}

# ---------- Task 5.10: per-SKILL.md call-site assertions ----------

@test "retro SKILL.md calls resolve_sprint_arg with --command retro" {
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  run /usr/bin/grep -c 'resolve_sprint_arg.*--command retro' \
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-retro/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "correct-course SKILL.md calls resolve_sprint_arg with --command correct-course" {
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  run /usr/bin/grep -c 'resolve_sprint_arg.*--command correct-course' \
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-correct-course/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "sprint-plan SKILL.md calls resolve_sprint_arg with --command sprint-plan" {
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  run /usr/bin/grep -c 'resolve_sprint_arg.*--command sprint-plan' \
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-sprint-plan/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "action-items SKILL.md calls resolve_sprint_arg with --command action-items" {
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  run /usr/bin/grep -c 'resolve_sprint_arg.*--command action-items' \
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-action-items/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "sprint-review SKILL.md calls resolve_sprint_arg with --command sprint-review" {
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  run /usr/bin/grep -c 'resolve_sprint_arg.*--command sprint-review' \
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-sprint-review/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "run-sprint SKILL.md calls resolve_sprint_arg with --command run-sprint" {
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  run /usr/bin/grep -c 'resolve_sprint_arg.*--command run-sprint' \
    "$BATS_TEST_SCRIPT_DIR/skills/gaia-run-sprint/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ---------- TC-CONC-ARG-5: new-sprint archived ID collision ----------

@test "resolve_sprint_arg: --new-sprint refuses archived ID" {
  cp "$STATE_DIR/sprint-status-sprint-900.yaml" "$ARCHIVE_DIR/sprint-902-closed-2026-10-01.yaml"
  run _resolve --command sprint-plan --new-sprint sprint-902
  [ "$status" -eq 16 ]
  [[ "$output" == *"sprint-902"* ]]
  [[ "$output" == *"already exists"* ]]
}

# ---------- Dashboard --sprint integration ----------

@test "dashboard --sprint resolves to per-sprint file" {
  # Verify the dashboard script accepts --sprint without error.
  run bash -c '
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export PROJECT_PATH="'"$PROJECT_PATH"'"
    export GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash "'"$DASHBOARD"'" --sprint sprint-900 2>&1
  '
  # We just check it does not fail with "unknown argument" — the full dashboard
  # rendering requires the progress cache which is out of scope.
  [[ "$output" != *"unknown argument"* ]]
}

@test "dashboard --sprint refuses nonexistent sprint" {
  run bash -c '
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export PROJECT_PATH="'"$PROJECT_PATH"'"
    export GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash "'"$DASHBOARD"'" --sprint sprint-999 2>&1
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"sprint-999"* ]]
  [[ "$output" == *"not found"* ]]
}

# ---------- Parseable listing format (AC6) ----------

@test "resolve_sprint_arg: ambiguous refusal lists IDs one per line" {
  run _resolve --command retro 2>&1
  [ "$status" -eq 12 ]
  # Each sprint ID should appear on its own line
  local sprint_lines
  sprint_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c '^sprint-')"
  [ "$sprint_lines" -ge 2 ]
}

# ---------- GAIA_BOUND_SPRINT_ID env var path ----------

@test "resolve_sprint_arg: GAIA_BOUND_SPRINT_ID env var resolves binding" {
  run bash -c '
    export GAIA_BOUND_SPRINT_ID="sprint-900"
    export PROJECT_ROOT="'"$PROJECT_ROOT"'"
    export CLAUDE_PROJECT_ROOT="'"$CLAUDE_PROJECT_ROOT"'"
    source "'"$SESSION_BINDING"'"
    resolve_sprint_arg --command retro
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sprint-900" ]
}
