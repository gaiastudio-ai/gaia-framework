#!/usr/bin/env bats

# phase-parallel-orchestrator-next-fix.bats — targeted tests for the five
# defects in the orchestrator's `next` command (session dir fallback, literal
# slug, admission-failure handling, flock guidance, orphan cleanup).
#
# These tests exercise the REAL phase-parallel-orchestrator.sh with real git
# repos and real sprint yaml. The only stub is the agent dispatch (the substrate
# cannot run inside bats). Session env (GAIA_SESSION_DIR) is deliberately UNSET
# in end-to-end tests to reproduce the original bug.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  ORCH="$PLUGIN_ROOT/scripts/phase-parallel-orchestrator.sh"

  export GAIA_PARALLEL_EXECUTION=1
  export GAIA_WORKTREE_MODE=1
  export GAIA_MODE_B_SUBSTRATE=available
  export GAIA_WORKTREE_PRUNE_ON_CREATE=0
}

teardown() {
  # Kill any stray processes under our TEST_TMP
  if [ -n "${TEST_TMP:-}" ] && command -v pgrep >/dev/null 2>&1; then
    local survivors
    survivors="$(pgrep -f "$TEST_TMP" 2>/dev/null || true)"
    if [ -n "$survivors" ]; then
      local pid
      for pid in $survivors; do
        kill -KILL "$pid" 2>/dev/null || true
      done
    fi
  fi
  common_teardown
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

_source_orch() {
  [ -f "$ORCH" ] || return 1
  # shellcheck disable=SC1090
  . "$ORCH"
}

# _mk_repo <dir> — a throwaway repo with one commit and a remote.
_mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b staging .
  git -C "$dir" config user.email "test@example.invalid"
  git -C "$dir" config user.name "Test User"
  printf '.gaia/\ncoverage/\n' > "$dir/.gitignore"
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add .gitignore seed.txt
  git -C "$dir" commit -qm "initial commit"
  git init -q --bare "${dir}-remote.git"
  git -C "$dir" remote add origin "${dir}-remote.git"
  git -C "$dir" push -q -u origin HEAD
  ( cd "$dir" && pwd )
}

# _mk_yaml_with_titles <path> <spec...> — sprint yaml with custom titles.
# Each spec is KEY:PHASE:TITLE (title words joined with spaces).
_mk_yaml_with_titles() {
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  {
    printf 'sprint_id: test-sprint\n'
    printf 'status: active\n'
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'items:\n'
    local spec key phase title rest
    for spec in "$@"; do
      key="${spec%%:*}"
      rest="${spec#*:}"
      phase="${rest%%:*}"
      title="${rest#*:}"
      printf '  - key: %s\n' "$key"
      printf "    title: '%s'\n" "$title"
      printf '    status: ready-for-dev\n'
      printf '    points: 1\n'
      printf '    risk_level: low\n'
      printf '    phase: %s\n' "$phase"
    done
  } > "$out"
  printf '%s' "$out"
}

# _ensure_flock — put a real flock binary on PATH (python shim on macOS).
_ensure_flock() {
  if command -v flock >/dev/null 2>&1; then
    printf '%s' "$(dirname "$(command -v flock)")"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  local dir="$TEST_TMP/flock-bin"
  mkdir -p "$dir"
  cat > "$dir/flock" <<'FLOCKSHIM'
#!/usr/bin/env python3
"""Minimal flock(1) for tests."""
import sys, fcntl, time
args = sys.argv[1:]
unlock = False; wait = None; fd = None; i = 0
while i < len(args):
    a = args[i]
    if a == "-u": unlock = True
    elif a == "-x": pass
    elif a == "-w": i += 1; wait = float(args[i])
    elif a.lstrip("-").isdigit():
        fd = int(a.lstrip("-")) if not a.startswith("-") else int(a)
    i += 1
if fd is None: sys.exit(2)
try:
    if unlock: fcntl.flock(fd, fcntl.LOCK_UN); sys.exit(0)
    deadline = time.time() + (wait if wait is not None else 0)
    while True:
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); sys.exit(0)
        except OSError:
            if wait is None or time.time() >= deadline: sys.exit(1)
            time.sleep(0.02)
except OSError: sys.exit(1)
FLOCKSHIM
  chmod +x "$dir/flock"
  printf '%s' "$dir"
}

# _mk_dispatch_shim <dir> — a dispatch shim that succeeds immediately.
_mk_dispatch_shim() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gaia-dispatch-story" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
key="${1:-}"
printf '%s dispatched\n' "$key" >&2
exit 0
SHIM
  chmod +x "$dir/gaia-dispatch-story"
}

# _mk_failing_dispatch <dir> — a dispatch shim that always fails (exit 42).
_mk_failing_dispatch() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gaia-dispatch-story" <<'SHIM'
#!/usr/bin/env bash
exit 42
SHIM
  chmod +x "$dir/gaia-dispatch-story"
}

# ---------------------------------------------------------------------------
# AC1: branch slug derived from story title, not literal "slug"
# ---------------------------------------------------------------------------

@test "AC1: worktree_create receives real title slug, not literal slug" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac1")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac1.yaml" \
    "E900-S1:1:Fix the run-sprint orchestrator next command")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac1"
  mkdir -p "$GAIA_SESSION_DIR"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  # Install dispatch shim
  local shim_dir="$TEST_TMP/bin-ac1"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"

  run bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2 && ppo_next"

  # Dispatch line must be present (story admitted)
  [[ "$output" == *"dispatch story=E900-S1"* ]] \
    || { printf 'story not dispatched:\n%s\n' "$output" >&2; return 1; }

  # The git branch in the repo must use the real slug, not literal "slug"
  run git -C "$repo" branch --list
  [[ "$output" == *"fix-the-run-sprint-orchestrator-next-command"* ]] \
    || { printf 'expected real slug branch, got:\n%s\n' "$output" >&2; return 1; }
  [[ "$output" != *"E900-S1-slug"* ]] \
    || { printf 'found literal -slug branch:\n%s\n' "$output" >&2; return 1; }
}

@test "AC1: worktree_branch_state also uses real slug, not literal" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac1b")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac1b.yaml" \
    "E900-S2:1:Alpha feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac1b"
  mkdir -p "$GAIA_SESSION_DIR"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  local shim_dir="$TEST_TMP/bin-ac1b"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"

  run bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2 && ppo_next"

  # Story must be dispatched
  [[ "$output" == *"dispatch story=E900-S2"* ]] \
    || { printf 'story not dispatched:\n%s\n' "$output" >&2; return 1; }

  # The git branch must use the real slug "alpha-feature"
  run git -C "$repo" branch --list
  [[ "$output" == *"alpha-feature"* ]] \
    || { printf 'expected alpha-feature branch, got:\n%s\n' "$output" >&2; return 1; }
  # No branch with literal "-slug" suffix
  [[ "$output" != *"E900-S2-slug"* ]] \
    || { printf 'found literal -slug branch:\n%s\n' "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC2: session dir fallback when GAIA_SESSION_DIR is unset
# ---------------------------------------------------------------------------

@test "AC2: ppo_slot_scratch_for falls back to writable temp dir when session dir unset" {
  unset GAIA_SESSION_DIR

  _source_orch

  local result
  result="$(ppo_slot_scratch_for "E900-S1")"

  # Must NOT start with /slots/ (the bug)
  [[ "$result" != /slots/* ]] \
    || { printf 'got unwritable root path: %s\n' "$result" >&2; return 1; }

  # Must contain gaia-ppo- and the PID
  [[ "$result" == *"gaia-ppo-"* ]] \
    || { printf 'missing gaia-ppo- prefix: %s\n' "$result" >&2; return 1; }
  [[ "$result" == *"/slots/E900-S1" ]] \
    || { printf 'missing /slots/E900-S1 suffix: %s\n' "$result" >&2; return 1; }

  # Must be writable
  mkdir -p "$result"
  touch "$result/test-write"
  [ -f "$result/test-write" ]
  rm -rf "$(dirname "$(dirname "$result")")"
}

@test "AC2: ppo_session_dir_for returns writable fallback when session dir unset" {
  unset GAIA_SESSION_DIR

  _source_orch

  local result
  result="$(ppo_session_dir_for)"

  # Must NOT be empty (the bug)
  [ -n "$result" ] \
    || { printf 'ppo_session_dir_for returned empty string\n' >&2; return 1; }

  # Must contain gaia-ppo- and be writable
  [[ "$result" == *"gaia-ppo-"* ]] \
    || { printf 'missing gaia-ppo- prefix: %s\n' "$result" >&2; return 1; }
  mkdir -p "$result"
  [ -d "$result" ]
  rm -rf "$result"
}

@test "AC2: engine dir falls back to PID-scoped temp dir when session dir unset" {
  unset GAIA_SESSION_DIR

  _source_orch

  local result
  result="$(_ppo_engine_dir)"

  # Must be under gaia-ppo-$$ not bare /tmp/ppo
  [[ "$result" == *"gaia-ppo-"*"/ppo" ]] \
    || { printf 'expected PID-scoped engine dir, got: %s\n' "$result" >&2; return 1; }
}

@test "AC2: state dir falls back to PID-scoped temp dir when session dir unset" {
  unset GAIA_SESSION_DIR

  _source_orch

  local result
  result="$(_ppo_state_dir)"

  # Must be under gaia-ppo-$$ not bare /tmp/ppo-state
  [[ "$result" == *"gaia-ppo-"*"/ppo-state" ]] \
    || { printf 'expected PID-scoped state dir, got: %s\n' "$result" >&2; return 1; }
}

@test "AC2: no /slots/ path in output when plan+next runs without session dir" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac2")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac2.yaml" \
    "E900-S1:1:Alpha feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  # Deliberately unset GAIA_SESSION_DIR
  unset GAIA_SESSION_DIR
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  local shim_dir="$TEST_TMP/bin-ac2"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"

  run bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2 && ppo_next" 2>&1

  # No path starting with /slots/ (the unwritable root-relative bug)
  [[ "$output" != */slots/* ]] \
    || { printf 'found /slots/ path in output:\n%s\n' "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC3: admission failure degrades to sequential, no sprint_complete
# ---------------------------------------------------------------------------

@test "AC3: admission failure emits admission_failure and degrades to sequential" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac3")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac3.yaml" \
    "E900-S1:1:Alpha feature" "E900-S2:1:Beta feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac3"
  mkdir -p "$GAIA_SESSION_DIR"
  export PATH="${flock_dir}:$PATH"

  # Override the dispatch lib loader so spawn_teammate always fails with an
  # unclassified error (exit 42). The real _ppo_load_dispatch_lib sources the
  # dispatch library, defining spawn_teammate — by replacing the loader we
  # ensure the override persists through the admission path.
  run bash -c "
    . '$ORCH'
    _ppo_load_dispatch_lib() {
      spawn_teammate() { return 42; }
      return 0
    }
    ppo_plan --repo '$repo' --yaml '$yaml' --slots 2 && ppo_next
  "

  # Must emit admission_failure, not outcome=failed
  [[ "$output" == *"event=admission_failure"* ]] \
    || { printf 'missing event=admission_failure in output:\n%s\n' "$output" >&2; return 1; }
  [[ "$output" != *"outcome=failed"* ]] \
    || { printf 'found outcome=failed (old bug) in output:\n%s\n' "$output" >&2; return 1; }

  # Must degrade to sequential
  [[ "$output" == *"mode=sequential reason=admission-error"* ]] \
    || { printf 'missing sequential degradation in output:\n%s\n' "$output" >&2; return 1; }

  # Must NOT emit sprint_complete
  [[ "$output" != *"sprint_complete"* ]] \
    || { printf 'found premature sprint_complete in output:\n%s\n' "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC4: flock-unavailable message includes brew install flock
# ---------------------------------------------------------------------------

@test "AC4: flock-unavailable reason includes brew install flock" {
  _source_orch

  local repo yaml
  repo="$(_mk_repo "$TEST_TMP/repo-ac4")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac4.yaml" \
    "E900-S1:1:Alpha feature")"

  # Force flock absence
  export GAIA_LOCK_FORCE_FALLBACK=1

  run bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2"

  [[ "$output" == *"reason=flock-unavailable"* ]] \
    || { printf 'missing flock-unavailable reason:\n%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"brew install flock"* ]] \
    || { printf 'missing brew install flock guidance:\n%s\n' "$output" >&2; return 1; }
}

@test "AC4: run-sprint SKILL.md mentions flock prerequisite" {
  local skillmd="$PLUGIN_ROOT/skills/gaia-run-sprint/SKILL.md"
  [ -f "$skillmd" ] \
    || { printf 'SKILL.md not found at %s\n' "$skillmd" >&2; return 1; }

  /usr/bin/grep -q 'brew install flock' "$skillmd" \
    || { printf 'SKILL.md does not mention brew install flock\n' >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC5: orphaned worktree cleaned on admission failure and on next plan
# ---------------------------------------------------------------------------

@test "AC5: admission failure cleans up worktree created on admission fail" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac5")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac5.yaml" \
    "E900-S1:1:Alpha feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac5"
  mkdir -p "$GAIA_SESSION_DIR"
  export PATH="${flock_dir}:$PATH"

  # Override the dispatch lib loader so spawn_teammate fails after worktree
  # is created — worktree_create happens BEFORE _ppo_admit_bookkeeping.
  run bash -c "
    . '$ORCH'
    _ppo_load_dispatch_lib() {
      spawn_teammate() { return 42; }
      return 0
    }
    ppo_plan --repo '$repo' --yaml '$yaml' --slots 2 && ppo_next
  "

  # Worktree must be cleaned up after the admission failure
  local wt_parent wt_dir
  wt_parent="$(git -C "$repo" rev-parse --show-toplevel)/../.gaia-worktrees"
  wt_dir="$wt_parent/E900-S1"

  # The worktree directory should not exist (cleaned up)
  [ ! -d "$wt_dir" ] \
    || { printf 'worktree dir still exists: %s\n' "$wt_dir" >&2; return 1; }
}

@test "AC5: next plan prunes worktrees on bogus -slug branches" {
  _source_orch

  local repo flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac5b")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac5b"
  mkdir -p "$GAIA_SESSION_DIR"
  export PATH="${flock_dir}:$PATH"

  # Manually create a bogus worktree on a -slug branch
  local parent
  parent="$(git -C "$repo" rev-parse --show-toplevel)/../.gaia-worktrees"
  mkdir -p "$parent"
  git -C "$repo" worktree add "$parent/E900-S1" -b "feat/E900-S1-slug" 2>/dev/null || true

  # Verify the bogus worktree exists
  run git -C "$repo" worktree list
  [[ "$output" == *"feat/E900-S1-slug"* ]] \
    || { printf 'bogus worktree not created\n' >&2; return 1; }

  # Run plan — it should prune the stale worktree
  local yaml shim_dir
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac5b.yaml" \
    "E900-S1:1:Alpha feature")"

  shim_dir="$TEST_TMP/bin-ac5b"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  run bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2"

  # After plan, the bogus branch worktree should be gone
  run git -C "$repo" worktree list
  [[ "$output" != *"feat/E900-S1-slug"* ]] \
    || { printf 'bogus -slug worktree still exists after plan:\n%s\n' "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC6: two-phase sprint end-to-end with no session env
# ---------------------------------------------------------------------------

@test "AC6: two-phase sprint: real slugs, writable session, no premature sprint_complete" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac6")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac6.yaml" \
    "E99-S1:1:Alpha feature" "E99-S2:2:Beta feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  # Deliberately unset GAIA_SESSION_DIR — the original bug
  unset GAIA_SESSION_DIR
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  local shim_dir="$TEST_TMP/bin-ac6"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"

  # Plan + next in the same process (the PID-based session fallback must be
  # consistent within a single orchestrator run)
  local combined_out
  combined_out="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2 && ppo_next" 2>&1)"

  # Plan must select parallel mode
  [[ "$combined_out" == *"mode=parallel"* ]] \
    || { printf 'expected parallel mode, got:\n%s\n' "$combined_out" >&2; return 1; }

  # Phase 1 story must use real slug, not literal "slug"
  [[ "$combined_out" != *"E99-S1-slug"* ]] \
    || { printf 'found literal -slug branch:\n%s\n' "$combined_out" >&2; return 1; }

  # No /slots/ paths (session dir bug)
  [[ "$combined_out" != */slots/* ]] \
    || { printf 'found /slots/ path in output:\n%s\n' "$combined_out" >&2; return 1; }

  # Must have dispatched at least one story from phase 1
  [[ "$combined_out" == *"story=E99-S1"* ]] \
    || { printf 'phase 1 story not dispatched:\n%s\n' "$combined_out" >&2; return 1; }

  # Real slug "alpha-feature" must appear in the git branch
  run git -C "$repo" branch --list
  [[ "$output" == *"alpha-feature"* ]] \
    || { printf 'expected alpha-feature branch, got:\n%s\n' "$output" >&2; return 1; }

  # No premature sprint_complete while phase 2 stories are still pending
  # (barrier should be emitted, not sprint_complete)
  [[ "$combined_out" == *"barrier"* ]] || [[ "$combined_out" != *"sprint_complete"* ]] \
    || { printf 'premature sprint_complete:\n%s\n' "$combined_out" >&2; return 1; }
}
