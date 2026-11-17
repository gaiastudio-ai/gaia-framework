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
  SLUGIFY="$PLUGIN_ROOT/skills/gaia-create-story/scripts/slugify.sh"

  export GAIA_PARALLEL_EXECUTION=1
  export GAIA_WORKTREE_MODE=1
  export GAIA_MODE_B_SUBSTRATE=available
  export GAIA_WORKTREE_PRUNE_ON_CREATE=0

  # Clean up any stale breadcrumb from a previous test
  rm -f "${TMPDIR:-/tmp}/.gaia-ppo-active" 2>/dev/null || true
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
  rm -f "${TMPDIR:-/tmp}/.gaia-ppo-active" 2>/dev/null || true
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
# Each spec is KEY:PHASE:TITLE or KEY:PHASE:TITLE:STATUS (status defaults to
# ready-for-dev). Titles must not contain colons (the last colon delimits the
# optional status field).
_mk_yaml_with_titles() {
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  {
    printf 'sprint_id: test-sprint\n'
    printf 'status: active\n'
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'items:\n'
    local spec key phase title status rest rest2
    for spec in "$@"; do
      key="${spec%%:*}"
      rest="${spec#*:}"
      phase="${rest%%:*}"
      rest2="${rest#*:}"
      # If rest2 contains another colon, the part after the last colon is status.
      case "$rest2" in
        *:*) title="${rest2%:*}"; status="${rest2##*:}" ;;
        *)   title="$rest2"; status="ready-for-dev" ;;
      esac
      printf '  - key: %s\n' "$key"
      printf "    title: '%s'\n" "$title"
      printf '    status: %s\n' "$status"
      printf '    points: 1\n'
      printf '    risk_level: low\n'
      printf '    phase: %s\n' "$phase"
    done
  } > "$out"
  printf '%s' "$out"
}

# _mk_yaml_no_phases <path> <spec...> — sprint yaml with NO phase fields.
# Each spec is KEY:TITLE or KEY:TITLE:STATUS (status defaults to ready-for-dev).
# Titles must not contain colons (the last colon delimits the optional status).
_mk_yaml_no_phases() {
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  {
    printf 'sprint_id: test-sprint\n'
    printf 'status: active\n'
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'items:\n'
    local spec key title status rest
    for spec in "$@"; do
      key="${spec%%:*}"
      rest="${spec#*:}"
      case "$rest" in
        *:*) title="${rest%:*}"; status="${rest##*:}" ;;
        *)   title="$rest"; status="ready-for-dev" ;;
      esac
      printf '  - key: %s\n' "$key"
      printf "    title: '%s'\n" "$title"
      printf '    status: %s\n' "$status"
      printf '    points: 1\n'
      printf '    risk_level: low\n'
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

# ---------------------------------------------------------------------------
# AC1: branch slug derived from story title, not literal "slug"
# ---------------------------------------------------------------------------

@test "worktree_create receives real title slug, not literal slug" {
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

@test "worktree_branch_state uses real slug for re-entry detection" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac1r")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac1r.yaml" \
    "E900-S3:1:Alpha feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac1r"
  mkdir -p "$GAIA_SESSION_DIR"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  local shim_dir="$TEST_TMP/bin-ac1r"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"

  # Pre-create a worktree on the REAL slug branch (simulating a crashed run
  # that used the fixed orchestrator). The re-entry detection must find it.
  # shellcheck disable=SC1090
  . "$PLUGIN_ROOT/scripts/lib/story-worktree.sh"
  worktree_create "$repo" "E900-S3" "alpha-feature" >/dev/null 2>&1

  run bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2 && ppo_next"

  # Must detect the existing worktree as attached
  [[ "$output" == *"event=attached story=E900-S3"* ]] \
    || { printf 'expected attach event, got:\n%s\n' "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC1 slugify: cross-check with canonical, non-ASCII, >60 chars
# ---------------------------------------------------------------------------

@test "inline slugify matches canonical slugify.sh on plain ASCII" {
  _source_orch
  local inline canonical
  inline="$(_ppo_slugify "Fix the run-sprint orchestrator next command")"
  canonical="$(bash "$SLUGIFY" --title "Fix the run-sprint orchestrator next command")"
  # The inline result must match the canonical (before cap)
  [ "${inline}" = "$(printf '%s' "$canonical" | cut -c 1-60)" ] \
    || { printf 'mismatch: inline=%s canonical=%s\n' "$inline" "$canonical" >&2; return 1; }
}

@test "inline slugify handles non-ASCII (UTF-8 accents become hyphens)" {
  _source_orch
  local inline canonical
  inline="$(_ppo_slugify "café résumé")"
  canonical="$(bash "$SLUGIFY" --title "café résumé")"
  [ "${inline}" = "$(printf '%s' "$canonical" | cut -c 1-60)" ] \
    || { printf 'non-ASCII mismatch: inline=%s canonical=%s\n' "$inline" "$canonical" >&2; return 1; }
  # The non-ASCII bytes must be replaced with hyphens
  [[ "$inline" == *"caf"* ]] \
    || { printf 'expected partial "caf" in slug: %s\n' "$inline" >&2; return 1; }
}

@test "inline slugify caps at 60 chars for long titles" {
  _source_orch
  local long_title="This is a very long story title that exceeds sixty characters when slugified to test the cap"
  local inline
  inline="$(_ppo_slugify "$long_title")"
  local len="${#inline}"
  [ "$len" -le 60 ] \
    || { printf 'slug length %d exceeds 60-char cap: %s\n' "$len" "$inline" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC2: session dir fallback when GAIA_SESSION_DIR is unset
# ---------------------------------------------------------------------------

@test "ppo_slot_scratch_for falls back to writable temp dir when session dir unset" {
  unset GAIA_SESSION_DIR

  _source_orch

  local result
  result="$(ppo_slot_scratch_for "E900-S1")"

  # Must NOT start with /slots/ (the bug)
  [[ "$result" != /slots/* ]] \
    || { printf 'got unwritable root path: %s\n' "$result" >&2; return 1; }

  # Must contain gaia-ppo- and end with slots/key
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

@test "ppo_session_dir_for returns writable fallback when session dir unset" {
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

@test "plan writes breadcrumb so next finds the same session dir" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac2b")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac2b.yaml" \
    "E900-S1:1:Alpha feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  unset GAIA_SESSION_DIR
  export PATH="${flock_dir}:$PATH"

  local shim_dir="$TEST_TMP/bin-ac2b"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  # Run plan as a SEPARATE process (exactly as the SKILL.md does)
  bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" >/dev/null 2>&1

  # The breadcrumb must exist and point to a writable directory
  local breadcrumb="${TMPDIR:-/tmp}/.gaia-ppo-active"
  [ -f "$breadcrumb" ] \
    || { printf 'breadcrumb not written at %s\n' "$breadcrumb" >&2; return 1; }

  local session_dir
  session_dir="$(cat "$breadcrumb")"
  [ -d "$session_dir" ] \
    || { printf 'breadcrumb dir does not exist: %s\n' "$session_dir" >&2; return 1; }

  # Run next as a SEPARATE process — it must find the engine state
  local next_out
  next_out="$(bash -c ". '$ORCH' && ppo_next" 2>&1)"

  # Must not refuse with "no plan"
  [[ "$next_out" != *"no-plan"* ]] \
    || { printf 'next refused with no-plan:\n%s\n' "$next_out" >&2; return 1; }

  # Must have dispatched the story
  [[ "$next_out" == *"dispatch story=E900-S1"* ]] || [[ "$next_out" == *"story=E900-S1"* ]] \
    || { printf 'story not dispatched:\n%s\n' "$next_out" >&2; return 1; }
}

@test "no /slots/ path in output when plan+next runs without session dir" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac2c")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac2c.yaml" \
    "E900-S1:1:Alpha feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  unset GAIA_SESSION_DIR
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  local shim_dir="$TEST_TMP/bin-ac2c"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"

  # plan then next as SEPARATE processes
  bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" >/dev/null 2>&1
  run bash -c ". '$ORCH' && ppo_next" 2>&1

  # No path starting with /slots/ (the unwritable root-relative bug)
  [[ "$output" != */slots/* ]] \
    || { printf 'found /slots/ path in output:\n%s\n' "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC3: admission failure degrades to sequential, no sprint_complete
# ---------------------------------------------------------------------------

@test "admission failure emits admission_failure and degrades to sequential" {
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

@test "flock-unavailable reason includes brew install flock" {
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

@test "run-sprint SKILL.md mentions flock prerequisite" {
  local skillmd="$PLUGIN_ROOT/skills/gaia-run-sprint/SKILL.md"
  [ -f "$skillmd" ] \
    || { printf 'SKILL.md not found at %s\n' "$skillmd" >&2; return 1; }

  /usr/bin/grep -q 'brew install flock' "$skillmd" \
    || { printf 'SKILL.md does not mention brew install flock\n' >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC5: orphaned worktree cleaned on admission failure and on next plan
# ---------------------------------------------------------------------------

@test "admission failure cleans up worktree created on admission fail" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac5")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac5.yaml" \
    "E900-S1:1:Alpha feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac5"
  mkdir -p "$GAIA_SESSION_DIR"
  export PATH="${flock_dir}:$PATH"

  run bash -c "
    . '$ORCH'
    _ppo_load_dispatch_lib() {
      spawn_teammate() { return 42; }
      return 0
    }
    ppo_plan --repo '$repo' --yaml '$yaml' --slots 2 && ppo_next
  "

  local wt_parent wt_dir
  wt_parent="$(git -C "$repo" rev-parse --show-toplevel)/../.gaia-worktrees"
  wt_dir="$wt_parent/E900-S1"

  [ ! -d "$wt_dir" ] \
    || { printf 'worktree dir still exists: %s\n' "$wt_dir" >&2; return 1; }
}

@test "plan prunes worktrees on bogus -slug branches" {
  _source_orch

  local repo flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac5b")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac5b"
  mkdir -p "$GAIA_SESSION_DIR"
  export PATH="${flock_dir}:$PATH"

  local parent
  parent="$(git -C "$repo" rev-parse --show-toplevel)/../.gaia-worktrees"
  mkdir -p "$parent"
  git -C "$repo" worktree add "$parent/E900-S1" -b "feat/E900-S1-slug" 2>/dev/null || true

  run git -C "$repo" worktree list
  [[ "$output" == *"feat/E900-S1-slug"* ]] \
    || { printf 'bogus worktree not created\n' >&2; return 1; }

  local yaml shim_dir
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac5b.yaml" \
    "E900-S1:1:Alpha feature")"

  shim_dir="$TEST_TMP/bin-ac5b"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  run bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2"

  run git -C "$repo" worktree list
  [[ "$output" != *"feat/E900-S1-slug"* ]] \
    || { printf 'bogus -slug worktree still exists after plan:\n%s\n' "$output" >&2; return 1; }
}

@test "prune does NOT remove real slug ending in -slug substring" {
  _source_orch

  local repo flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac5c")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  export GAIA_SESSION_DIR="$TEST_TMP/session-ac5c"
  mkdir -p "$GAIA_SESSION_DIR"
  export PATH="${flock_dir}:$PATH"

  local parent
  parent="$(git -C "$repo" rev-parse --show-toplevel)/../.gaia-worktrees"
  mkdir -p "$parent"
  # A real slug "handle-a-slug" from a title "Handle a slug" — must NOT be pruned
  git -C "$repo" worktree add "$parent/E900-S4" -b "feat/E900-S4-handle-a-slug" 2>/dev/null || true

  run git -C "$repo" worktree list
  [[ "$output" == *"feat/E900-S4-handle-a-slug"* ]] \
    || { printf 'real-slug worktree not created\n' >&2; return 1; }

  local yaml shim_dir
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac5c.yaml" \
    "E900-S4:1:Handle a slug")"

  shim_dir="$TEST_TMP/bin-ac5c"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  run bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2"

  # The real-slug worktree must survive — only literal feat/<KEY>-slug is pruned
  run git -C "$repo" worktree list
  [[ "$output" == *"feat/E900-S4-handle-a-slug"* ]] \
    || { printf 'real-slug worktree was incorrectly pruned:\n%s\n' "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC6: two-phase sprint end-to-end with no session env (separate processes)
# ---------------------------------------------------------------------------

@test "plan then next as separate processes, no session env, real slugs" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ac6")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ac6.yaml" \
    "E99-S1:1:Alpha feature" "E99-S2:2:Beta feature")"
  flock_dir="$(_ensure_flock)" || skip "no flock available"

  # Deliberately unset GAIA_SESSION_DIR — the original bug
  unset GAIA_SESSION_DIR
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"
  export PATH="${flock_dir}:$PATH"

  # Step 1: plan as a SEPARATE bash process (exactly as the SKILL.md does)
  local plan_out
  plan_out="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" 2>&1)"

  # Plan must select parallel mode
  [[ "$plan_out" == *"mode=parallel"* ]] \
    || { printf 'expected parallel mode, got:\n%s\n' "$plan_out" >&2; return 1; }

  # Step 2: next as a SEPARATE bash process (different PID).
  # Override the dispatch lib so spawn_teammate succeeds in the test env
  # (the real substrate is unavailable inside bats).
  local next_out
  next_out="$(bash -c "
    . '$ORCH'
    _ppo_load_dispatch_lib() {
      spawn_teammate() {
        local p=bash-dev k=''
        while [ \$# -gt 0 ]; do
          case \"\$1\" in --story-key) k=\"\$2\"; shift 2 ;; *) p=\"\$1\"; shift ;; esac
        done
        printf 'tm-%s-%s\n' \"\$p\" \"\$k\"
      }
      return 0
    }
    ppo_next
  " 2>&1)"

  # Must not refuse with "no plan"
  [[ "$next_out" != *"no-plan"* ]] \
    || { printf 'next refused with no-plan — breadcrumb broken:\n%s\n' "$next_out" >&2; return 1; }

  # Phase 1 story must be dispatched
  [[ "$next_out" == *"story=E99-S1"* ]] \
    || { printf 'phase 1 story not dispatched:\n%s\n' "$next_out" >&2; return 1; }

  # Phase 1 story must use real slug, not literal "slug"
  [[ "$next_out" != *"E99-S1-slug"* ]] \
    || { printf 'found literal -slug branch:\n%s\n' "$next_out" >&2; return 1; }

  # No /slots/ paths (session dir bug)
  [[ "$next_out" != */slots/* ]] \
    || { printf 'found /slots/ path in next output:\n%s\n' "$next_out" >&2; return 1; }

  # Real slug "alpha-feature" must appear in the git branch
  run git -C "$repo" branch --list
  [[ "$output" == *"alpha-feature"* ]] \
    || { printf 'expected alpha-feature branch, got:\n%s\n' "$output" >&2; return 1; }

  # Barrier or dispatch — no premature sprint_complete (phase 2 still pending)
  [[ "$next_out" == *"barrier"* ]] || [[ "$next_out" == *"dispatch"* ]] \
    || { printf 'expected barrier or dispatch, got:\n%s\n' "$next_out" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Session event emission and concurrent-sprint isolation
# ---------------------------------------------------------------------------

# _spawn_stub — a reusable inline spawn_teammate override for tests that
# need admission to succeed without the real substrate.
_spawn_stub='
  _ppo_load_dispatch_lib() {
    spawn_teammate() {
      local p=bash-dev k=""
      while [ $# -gt 0 ]; do
        case "$1" in --story-key) k="$2"; shift 2 ;; *) p="$1"; shift ;; esac
      done
      printf "tm-%s-%s\n" "$p" "$k"
    }
    return 0
  }
'

@test "plan emits session event line with the resolved path" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-se1")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-se1.yaml" "K1:1:Alpha")"
  flock_dir="$(_ensure_flock)" || { printf 'no flock provider (flock binary or python3 shim) available\n' >&2; return 1; }

  export GAIA_SESSION_DIR="$TEST_TMP/session-se1"
  mkdir -p "$GAIA_SESSION_DIR"
  export PATH="${flock_dir}:$PATH"
  local shim_dir="$TEST_TMP/bin-se1"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  local plan_out
  plan_out="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" 2>&1)"

  [[ "$plan_out" == *"session=${GAIA_SESSION_DIR}"* ]] \
    || { printf 'missing session= event line in plan output:\n%s\n' "$plan_out" >&2; return 1; }
}

@test "plan emits session event matching breadcrumb fallback when session dir unset" {
  _source_orch
  unset GAIA_SESSION_DIR

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-se2")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-se2.yaml" "K1:1:Alpha")"
  flock_dir="$(_ensure_flock)" || { printf 'no flock provider (flock binary or python3 shim) available\n' >&2; return 1; }
  export PATH="${flock_dir}:$PATH"
  local shim_dir="$TEST_TMP/bin-se2"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  local plan_out
  plan_out="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" 2>&1)"

  local emitted_session
  emitted_session="$(printf '%s\n' "$plan_out" | sed -n 's/^session=//p' | head -n1)"
  [ -n "$emitted_session" ] \
    || { printf 'no session= event in plan output:\n%s\n' "$plan_out" >&2; return 1; }

  local breadcrumb_session
  breadcrumb_session="$(cat "${TMPDIR:-/tmp}/.gaia-ppo-active" 2>/dev/null)"
  [ "$emitted_session" = "$breadcrumb_session" ] \
    || { printf 'session mismatch: event=%s breadcrumb=%s\n' "$emitted_session" "$breadcrumb_session" >&2; return 1; }
}

@test "next/status/record resolve via session dir in separate processes" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-se3")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-se3.yaml" "K1:1:Alpha")"
  flock_dir="$(_ensure_flock)" || { printf 'no flock provider (flock binary or python3 shim) available\n' >&2; return 1; }

  export GAIA_SESSION_DIR="$TEST_TMP/session-se3"
  mkdir -p "$GAIA_SESSION_DIR"
  local shim_dir="$TEST_TMP/bin-se3"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  # Plan in one process
  bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" >/dev/null 2>&1

  # Next in a SEPARATE process — must not refuse with "no plan"
  local next_out
  next_out="$(GAIA_SESSION_DIR="$GAIA_SESSION_DIR" bash -c "
    . '$ORCH'
    ${_spawn_stub}
    ppo_next
  " 2>&1)"
  [[ "$next_out" != *"no-plan"* ]] \
    || { printf 'next refused with no-plan:\n%s\n' "$next_out" >&2; return 1; }
  [[ "$next_out" == *"story=K1"* ]] \
    || { printf 'story not dispatched in next:\n%s\n' "$next_out" >&2; return 1; }

  # Status in a SEPARATE process — must not refuse
  local status_out
  status_out="$(GAIA_SESSION_DIR="$GAIA_SESSION_DIR" bash -c ". '$ORCH' && ppo_status" 2>&1)"
  [[ "$status_out" != *"no-plan"* ]] \
    || { printf 'status refused with no-plan:\n%s\n' "$status_out" >&2; return 1; }

  # Record in a SEPARATE process — must not refuse
  local record_out
  record_out="$(GAIA_SESSION_DIR="$GAIA_SESSION_DIR" bash -c ". '$ORCH' && ppo_record_outcome K1 done" 2>&1)"
  [[ "$record_out" == *"outcome=done"* ]] \
    || { printf 'record did not produce done outcome:\n%s\n' "$record_out" >&2; return 1; }
}

@test "concurrent sprints under one tmpdir resolve separate sessions" {
  _source_orch

  local repo flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-cs")"
  flock_dir="$(_ensure_flock)" || { printf 'no flock provider (flock binary or python3 shim) available\n' >&2; return 1; }
  local shim_dir="$TEST_TMP/bin-cs"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  # Sprint A with story K1
  local yaml_a
  yaml_a="$(_mk_yaml_with_titles "$TEST_TMP/sprint-cs-a.yaml" "K1:1:Alpha")"
  # Sprint B with story K2
  local yaml_b
  yaml_b="$(_mk_yaml_with_titles "$TEST_TMP/sprint-cs-b.yaml" "K2:1:Beta")"

  unset GAIA_SESSION_DIR

  # Plan sprint A, capture session
  local plan_a
  plan_a="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml_a' --slots 2" 2>&1)"
  local session_a
  session_a="$(printf '%s\n' "$plan_a" | sed -n 's/^session=//p' | head -n1)"

  # Plan sprint B (overwrites the breadcrumb), capture session
  local plan_b
  plan_b="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml_b' --slots 2" 2>&1)"
  local session_b
  session_b="$(printf '%s\n' "$plan_b" | sed -n 's/^session=//p' | head -n1)"

  # Sessions must differ
  [ -n "$session_a" ] && [ -n "$session_b" ] \
    || { printf 'one or both sessions empty: a=%s b=%s\n' "$session_a" "$session_b" >&2; return 1; }
  [ "$session_a" != "$session_b" ] \
    || { printf 'sessions are identical: %s\n' "$session_a" >&2; return 1; }

  # Next for sprint A with its own session dir must dispatch K1 (not K2)
  local next_a
  next_a="$(GAIA_SESSION_DIR="$session_a" bash -c "
    . '$ORCH'
    ${_spawn_stub}
    ppo_next
  " 2>&1)"
  [[ "$next_a" == *"story=K1"* ]] \
    || { printf 'sprint A next did not dispatch K1:\n%s\n' "$next_a" >&2; return 1; }
  [[ "$next_a" != *"story=K2"* ]] \
    || { printf 'sprint A next dispatched K2 (wrong sprint):\n%s\n' "$next_a" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Done-story exclusion
# ---------------------------------------------------------------------------

@test "done story excluded from plan queue" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ds1")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ds1.yaml" \
    "K1:1:Alpha:done" "K2:1:Beta")"
  flock_dir="$(_ensure_flock)" || { printf 'no flock provider (flock binary or python3 shim) available\n' >&2; return 1; }

  export GAIA_SESSION_DIR="$TEST_TMP/session-ds1"
  mkdir -p "$GAIA_SESSION_DIR"
  local shim_dir="$TEST_TMP/bin-ds1"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  # Plan — assert done story is skipped in plan output
  local plan_out
  plan_out="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" 2>&1)"
  [[ "$plan_out" == *"event=story_skipped story=K1 reason=already-done"* ]] \
    || { printf 'plan did not emit story_skipped for K1:\n%s\n' "$plan_out" >&2; return 1; }

  # Next — assert K1 not dispatched, K2 dispatched
  local next_out
  next_out="$(GAIA_SESSION_DIR="$GAIA_SESSION_DIR" bash -c "
    . '$ORCH'
    ${_spawn_stub}
    ppo_next
  " 2>&1)"
  [[ "$next_out" != *"dispatch story=K1"* ]] \
    || { printf 'K1 (done) was dispatched:\n%s\n' "$next_out" >&2; return 1; }
  [[ "$next_out" == *"dispatch story=K2"* ]] \
    || { printf 'K2 (live) was not dispatched:\n%s\n' "$next_out" >&2; return 1; }
}

@test "done story skipped in next emits event when status changes mid-run" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ds2")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ds2.yaml" \
    "K1:1:Alpha" "K2:1:Beta")"
  flock_dir="$(_ensure_flock)" || { printf 'no flock provider (flock binary or python3 shim) available\n' >&2; return 1; }

  export GAIA_SESSION_DIR="$TEST_TMP/session-ds2"
  mkdir -p "$GAIA_SESSION_DIR"
  local shim_dir="$TEST_TMP/bin-ds2"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  # Plan with both stories as ready-for-dev
  bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" >/dev/null 2>&1

  # Modify yaml: set K1 to done using key-scoped awk (not global sed)
  awk -v key="K1" '
    /key:/ { cur=$NF }
    cur==key && /status:/ { sub(/ready-for-dev/, "done") }
    {print}
  ' "$yaml" > "${yaml}.tmp" && mv "${yaml}.tmp" "$yaml"

  # Next — K1 should be skipped with event, K2 should dispatch
  local next_out
  next_out="$(GAIA_SESSION_DIR="$GAIA_SESSION_DIR" bash -c "
    . '$ORCH'
    ${_spawn_stub}
    ppo_next
  " 2>&1)"
  [[ "$next_out" == *"event=story_skipped story=K1 reason=already-done"* ]] \
    || { printf 'next did not emit story_skipped for K1:\n%s\n' "$next_out" >&2; return 1; }
  [[ "$next_out" != *"dispatch story=K1"* ]] \
    || { printf 'K1 (now done) was dispatched:\n%s\n' "$next_out" >&2; return 1; }
}

@test "merged-not-done story is still admitted by the done guard" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-mnd")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-mnd.yaml" \
    "K1:1:Alpha:review")"
  flock_dir="$(_ensure_flock)" || { printf 'no flock provider (flock binary or python3 shim) available\n' >&2; return 1; }

  export GAIA_SESSION_DIR="$TEST_TMP/session-mnd"
  mkdir -p "$GAIA_SESSION_DIR"
  local shim_dir="$TEST_TMP/bin-mnd"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  local plan_out
  plan_out="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" 2>&1)"

  # Must NOT be skipped — review is not done
  [[ "$plan_out" != *"event=story_skipped story=K1"* ]] \
    || { printf 'K1 (review) was incorrectly skipped:\n%s\n' "$plan_out" >&2; return 1; }

  local next_out
  next_out="$(GAIA_SESSION_DIR="$GAIA_SESSION_DIR" bash -c "
    . '$ORCH'
    ${_spawn_stub}
    ppo_next
  " 2>&1)"

  # Must be dispatched — review status is not done
  [[ "$next_out" == *"dispatch story=K1"* ]] || [[ "$next_out" == *"story=K1"* ]] \
    || { printf 'K1 (review) was not dispatched:\n%s\n' "$next_out" >&2; return 1; }
}

@test "sequential worklist excludes done story in phases branch" {
  _source_orch

  local yaml
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-sq1.yaml" \
    "K1:1:Alpha:done" "K2:1:Beta" "K3:2:Gamma")"

  local worklist
  worklist="$(ppo_plan_sequential --repo /dev/null --yaml "$yaml")"

  [[ "$worklist" != *"K1"* ]] \
    || { printf 'done story K1 in sequential worklist:\n%s\n' "$worklist" >&2; return 1; }
  [[ "$worklist" == *"K2"* ]] \
    || { printf 'live story K2 missing from sequential worklist:\n%s\n' "$worklist" >&2; return 1; }
  [[ "$worklist" == *"K3"* ]] \
    || { printf 'live story K3 missing from sequential worklist:\n%s\n' "$worklist" >&2; return 1; }
}

@test "sequential worklist excludes done story in fallback branch" {
  _source_orch

  local yaml
  yaml="$(_mk_yaml_no_phases "$TEST_TMP/sprint-sq2.yaml" \
    "K1:Alpha:done" "K2:Beta")"

  local worklist
  worklist="$(ppo_plan_sequential --repo /dev/null --yaml "$yaml")"

  [[ "$worklist" != *"K1"* ]] \
    || { printf 'done story K1 in fallback worklist:\n%s\n' "$worklist" >&2; return 1; }
  [[ "$worklist" == *"K2"* ]] \
    || { printf 'live story K2 missing from fallback worklist:\n%s\n' "$worklist" >&2; return 1; }
}

@test "all stories done emits sprint_complete with no dispatch" {
  _source_orch

  local repo yaml flock_dir
  repo="$(_mk_repo "$TEST_TMP/repo-ad")"
  yaml="$(_mk_yaml_with_titles "$TEST_TMP/sprint-ad.yaml" \
    "K1:1:Alpha:done" "K2:1:Beta:done")"
  flock_dir="$(_ensure_flock)" || { printf 'no flock provider (flock binary or python3 shim) available\n' >&2; return 1; }

  export GAIA_SESSION_DIR="$TEST_TMP/session-ad"
  mkdir -p "$GAIA_SESSION_DIR"
  local shim_dir="$TEST_TMP/bin-ad"
  _mk_dispatch_shim "$shim_dir"
  export PATH="${flock_dir}:${shim_dir}:$PATH"
  export GAIA_PPO_DISPATCH_CMD="true"
  export BATS_TEST_FILENAME="${BATS_TEST_FILENAME}"

  # Plan — assert both stories skipped
  local plan_out
  plan_out="$(bash -c ". '$ORCH' && ppo_plan --repo '$repo' --yaml '$yaml' --slots 2" 2>&1)"
  [[ "$plan_out" == *"event=story_skipped story=K1"* ]] \
    || { printf 'plan did not skip K1:\n%s\n' "$plan_out" >&2; return 1; }
  [[ "$plan_out" == *"event=story_skipped story=K2"* ]] \
    || { printf 'plan did not skip K2:\n%s\n' "$plan_out" >&2; return 1; }
  [[ "$plan_out" != *"dispatch story="* ]] \
    || { printf 'plan output contains a dispatch line:\n%s\n' "$plan_out" >&2; return 1; }

  # Next — assert sprint_complete, no dispatch
  local next_out
  next_out="$(GAIA_SESSION_DIR="$GAIA_SESSION_DIR" bash -c "
    . '$ORCH'
    ${_spawn_stub}
    ppo_next
  " 2>&1)"
  [[ "$next_out" == *"sprint_complete"* ]] \
    || { printf 'next did not emit sprint_complete:\n%s\n' "$next_out" >&2; return 1; }
  [[ "$next_out" != *"dispatch story="* ]] \
    || { printf 'next dispatched a story when all are done:\n%s\n' "$next_out" >&2; return 1; }
}
