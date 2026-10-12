#!/usr/bin/env bats
# sprint-progress-snapshot-hook.bats — tests for the post-mutation snapshot hook
# in sprint-state.sh: failure isolation, disable/active guards, byte identity,
# plugin-root probe from both copies, detached execution, reconcile dry-run
# gating, stdout-release, and timeout-absent PATH fallback.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-state.sh"
  SNAPSHOT_SCRIPT="$SCRIPTS_DIR/sprint-progress-snapshot.sh"
  DEVSTORY_SCRIPT="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/sprint-state.sh"

  export PROJECT_ROOT="$TEST_TMP/project"
  export PROJECT_PATH="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/state"
  mkdir -p "$PROJECT_ROOT/.gaia/config"
  mkdir -p "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"

  IMPL="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  CACHE="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json"
  export SPRINT_STATUS_YAML="$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
  export MEMORY_PATH="$TEST_TMP/_memory"
  mkdir -p "$MEMORY_PATH"

  # Disable the hook by default in this file — individual tests re-enable it
  export GAIA_SNAPSHOT_HOOK_DISABLE=1
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

_seed_sprint() {
  cat > "$SPRINT_STATUS_YAML" <<'EOF'
sprint_id: "sprint-hook"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 5
goals: []
stories:
  - key: "E900-S1"
    title: "Hook test story"
    status: "in-progress"
    points: 5
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
EOF
}

_seed_story() {
  local key="${1:-E900-S1}" status="${2:-in-progress}"
  local slug
  slug="$(echo "$key" | tr '[:upper:]' '[:lower:]')-hook"
  local dir="$IMPL/epic-hook/${key}-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Hook test story"
status: ${status}
points: 5
manual_verification: false
depends_on: []
sprint_id: "sprint-hook"
---

# Story: ${key}

> **Status:** ${status}

## Tasks / Subtasks

- [x] Task 1: Done

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | --- |
| QA Tests | PASSED | --- |
| Security Review | PASSED | --- |
| Test Automation | PASSED | --- |
| Test Review | PASSED | --- |
| Performance Review | PASSED | --- |

## Definition of Done

- [x] All done
EOF
}

# _copy_plugin_tree — copies the plugin scripts tree into BATS_TEST_TMPDIR
# so tests can install fake snapshot scripts without modifying the repo.
# Returns the path to the copied sprint-state.sh via stdout.
_copy_plugin_tree() {
  local dst="$TEST_TMP/plugin-copy"
  mkdir -p "$dst/scripts/lib"
  # Copy sprint-state.sh and its essential dependencies
  cp "$SCRIPTS_DIR/sprint-state.sh" "$dst/scripts/sprint-state.sh"
  chmod +x "$dst/scripts/sprint-state.sh"
  # Copy libs needed by sprint-state.sh
  local lib
  for lib in story-state-machine.sh acquire-lock.sh exec-with-timeout.sh \
             gaia-paths.sh resolve-artifact-path.sh; do
    [ -f "$SCRIPTS_DIR/lib/$lib" ] && cp "$SCRIPTS_DIR/lib/$lib" "$dst/scripts/lib/"
  done
  # Copy sibling scripts used by sprint-state.sh
  for sib in review-gate.sh lifecycle-event.sh; do
    [ -f "$SCRIPTS_DIR/$sib" ] && cp "$SCRIPTS_DIR/$sib" "$dst/scripts/"
  done
  # Copy the real snapshot script (tests replace it with fakes)
  cp "$SNAPSHOT_SCRIPT" "$dst/scripts/sprint-progress-snapshot.sh"
  chmod +x "$dst/scripts/sprint-progress-snapshot.sh"
  printf '%s' "$dst/scripts/sprint-state.sh"
}

# ---------------------------------------------------------------------------
# Hook isolation tests
# ---------------------------------------------------------------------------

@test "snapshot failure does not fail parent transition" {
  grep -q '_run_snapshot_hook' "$SCRIPT"

  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE

  # Copy the plugin tree and install a failing snapshot
  local copied_ss
  copied_ss="$(_copy_plugin_tree)"
  local copied_dir
  copied_dir="$(dirname "$copied_ss")"
  local invoked_marker="$TEST_TMP/snapshot-invoked"
  cat > "$copied_dir/sprint-progress-snapshot.sh" <<SH
#!/usr/bin/env bash
echo "invoked" > "$invoked_marker"
exit 1
SH
  chmod +x "$copied_dir/sprint-progress-snapshot.sh"

  run env SPRINT_STATE_SCRIPT_DIR="$copied_dir" \
      PROJECT_ROOT="$PROJECT_ROOT" \
      SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
      MEMORY_PATH="$MEMORY_PATH" \
      "$copied_ss" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$invoked_marker" ]
}

@test "GAIA_SNAPSHOT_HOOK_DISABLE suppresses hook" {
  grep -q 'GAIA_SNAPSHOT_HOOK_DISABLE' "$SCRIPT"
  grep -q '_run_snapshot_hook' "$SCRIPT"

  _seed_sprint
  _seed_story E900-S1 in-progress
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  run "$SCRIPT" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]
  sleep 0.5
  [ ! -f "$CACHE" ]
}

@test "GAIA_SNAPSHOT_HOOK_ACTIVE prevents re-entry" {
  grep -q 'GAIA_SNAPSHOT_HOOK_ACTIVE' "$SCRIPT"
  grep -q '_run_snapshot_hook' "$SCRIPT"

  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE
  export GAIA_SNAPSHOT_HOOK_ACTIVE=1

  run "$SCRIPT" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]
  sleep 0.5
  [ ! -f "$CACHE" ]
  unset GAIA_SNAPSHOT_HOOK_ACTIVE
}

@test "sprint-state.sh wrapper copy is byte-identical and contains hook" {
  local canon="$SCRIPTS_DIR/sprint-state.sh"
  local wrapper
  wrapper="$(cd "$SCRIPTS_DIR/../skills/gaia-dev-story/scripts" && pwd)/sprint-state.sh"
  [ -r "$canon" ]
  [ -r "$wrapper" ]
  grep -q '_run_snapshot_hook' "$canon"
  grep -q '_run_snapshot_hook' "$wrapper"
  run diff -q "$canon" "$wrapper"
  [ "$status" -eq 0 ]
}

@test "hook resolves snapshot from canonical scripts copy" {
  [ -f "$SCRIPT" ]
  [ -x "$SNAPSHOT_SCRIPT" ]
  grep -q 'sprint-progress-snapshot.sh' "$SCRIPT"

  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE

  run "$SCRIPT" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$CACHE" ]
  jq -e '.' "$CACHE"
}

@test "hook resolves snapshot from dev-story copy via plugin root probe" {
  _seed_sprint
  _seed_story E900-S1 in-progress
  [ -f "$DEVSTORY_SCRIPT" ]

  local devstory_dir
  devstory_dir="$(cd "$(dirname "$DEVSTORY_SCRIPT")" && pwd)"
  [ ! -f "${devstory_dir}/sprint-progress-snapshot.sh" ]

  unset GAIA_SNAPSHOT_HOOK_DISABLE
  export SPRINT_STATE_SCRIPT_DIR="$SCRIPTS_DIR"
  run "$DEVSTORY_SCRIPT" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$CACHE" ]
  jq -e '.' "$CACHE"
}

@test "hook placed after mutating subcommand and after flock released" {
  [ -f "$SCRIPT" ]
  grep -q '_run_snapshot_hook' "$SCRIPT"
  grep -q 'GAIA_SNAPSHOT_HOOK_DISABLE' "$SCRIPT"
  grep -q 'GAIA_SNAPSHOT_HOOK_ACTIVE' "$SCRIPT"

  # Positional check: the hook block starts after the main dispatch esac
  local hook_line
  hook_line="$(grep -n '_run_snapshot_hook=0$' "$SCRIPT" | head -1 | cut -d: -f1)"
  [ -n "$hook_line" ]
  local dispatch_esac
  dispatch_esac="$(grep -n '^\s*esac' "$SCRIPT" | awk -F: -v hl="$hook_line" '$1 < hl { last=$1 } END { print last }')"
  [ -n "$dispatch_esac" ]
  [ "$hook_line" -gt "$dispatch_esac" ]

  # Behavioural: install a fake snapshot in a copied tree that checks lock freedom
  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE

  local copied_ss
  copied_ss="$(_copy_plugin_tree)"
  local copied_dir
  copied_dir="$(dirname "$copied_ss")"
  local lock_check_marker="$TEST_TMP/lock-free-marker"
  local lock_file="$PROJECT_ROOT/.gaia/state/sprint-status.yaml.lock"
  cat > "$copied_dir/sprint-progress-snapshot.sh" <<SNAP
#!/usr/bin/env bash
if [ -f "${lock_file}" ]; then
  if command -v flock >/dev/null 2>&1; then
    exec 8>>"${lock_file}"
    if flock -n 8 2>/dev/null; then
      flock -u 8 2>/dev/null || true
      echo "LOCK_FREE" > "${lock_check_marker}"
    else
      echo "LOCK_HELD" > "${lock_check_marker}"
    fi
    exec 8>&- 2>/dev/null || true
  else
    echo "LOCK_FREE" > "${lock_check_marker}"
  fi
else
  echo "LOCK_FREE" > "${lock_check_marker}"
fi
SNAP
  chmod +x "$copied_dir/sprint-progress-snapshot.sh"

  run env SPRINT_STATE_SCRIPT_DIR="$copied_dir" \
      PROJECT_ROOT="$PROJECT_ROOT" \
      SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
      MEMORY_PATH="$MEMORY_PATH" \
      "$copied_ss" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$lock_check_marker" ]
  [ "$(cat "$lock_check_marker")" = "LOCK_FREE" ]
}

@test "hook runs detached with timeout via exec_with_timeout" {
  [ -f "$SCRIPT" ]
  grep -q 'exec_with_timeout 10' "$SCRIPT"
  local non_comment
  non_comment="$(grep 'exec_with_timeout 10' "$SCRIPT" | grep -v '^[[:space:]]*#')"
  [ -n "$non_comment" ]

  # Behavioural: install a sleeping snapshot in a copied tree
  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE

  local copied_ss
  copied_ss="$(_copy_plugin_tree)"
  local copied_dir
  copied_dir="$(dirname "$copied_ss")"
  local sleeper_pid_file="$TEST_TMP/sleeper-pid"
  cat > "$copied_dir/sprint-progress-snapshot.sh" <<SH
#!/usr/bin/env bash
echo \$\$ > "$sleeper_pid_file"
sleep 30
SH
  chmod +x "$copied_dir/sprint-progress-snapshot.sh"

  run env SPRINT_STATE_SCRIPT_DIR="$copied_dir" \
      PROJECT_ROOT="$PROJECT_ROOT" \
      SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
      MEMORY_PATH="$MEMORY_PATH" \
      "$copied_ss" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]

  # Wait for timeout to kill the sleeper
  sleep 12
  if [ -f "$sleeper_pid_file" ]; then
    local spid
    spid="$(cat "$sleeper_pid_file")"
    ! kill -0 "$spid" 2>/dev/null || {
      kill "$spid" 2>/dev/null || true
      return 1
    }
  fi
}

@test "hook runs with timeout absent from PATH via fallback" {
  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE

  # Build a narrowed PATH with symlinks to needed tools, minus timeout
  local narrow_bin="$TEST_TMP/narrow-bin"
  mkdir -p "$narrow_bin"
  local tool
  for tool in bash stat awk sed grep find cat mkdir mktemp mv rm ln date \
              printf touch jq yq perl head tail wc tr cut sort uniq tee \
              readlink realpath dirname basename pwd id sleep flock git \
              env cp chmod diff expr test; do
    local tool_path
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$tool_path" ] && [ -x "$tool_path" ]; then
      ln -sf "$tool_path" "$narrow_bin/$tool"
    fi
  done
  rm -f "$narrow_bin/timeout" "$narrow_bin/gtimeout" 2>/dev/null || true

  run env PATH="$narrow_bin" bash -c 'command -v timeout'
  [ "$status" -ne 0 ]

  run env PATH="$narrow_bin" \
    PROJECT_ROOT="$PROJECT_ROOT" \
    PROJECT_PATH="$PROJECT_PATH" \
    SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
    MEMORY_PATH="$MEMORY_PATH" \
    SPRINT_STATE_SCRIPT_DIR="$SCRIPTS_DIR" \
    "$SCRIPT" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$CACHE" ]
  jq -e '.' "$CACHE"
}

# ---------------------------------------------------------------------------
# Reconcile dry-run gating
# ---------------------------------------------------------------------------

@test "reconcile dry-run does not trigger snapshot hook" {
  grep -q '_run_snapshot_hook' "$SCRIPT"
  grep -q 'reconcile_dry_run' "$SCRIPT"

  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE

  run "$SCRIPT" reconcile --dry-run
  sleep 0.5
  [ ! -f "$CACHE" ]
}

@test "reconcile without dry-run triggers snapshot hook" {
  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE

  # First run a transition (known-good trigger)
  run "$SCRIPT" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$CACHE" ]

  # Now verify reconcile also triggers it (remove old cache first)
  rm -f "$CACHE"
  run "$SCRIPT" reconcile
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$CACHE" ]
  jq -e '.' "$CACHE"
}

# ---------------------------------------------------------------------------
# Background hook stdout release
# ---------------------------------------------------------------------------

@test "hook does not hold caller stdout open beyond transition" {
  _seed_sprint
  _seed_story E900-S1 in-progress
  unset GAIA_SNAPSHOT_HOOK_DISABLE

  # Install a fake snapshot that sleeps 8 s in a copied tree
  local copied_ss
  copied_ss="$(_copy_plugin_tree)"
  local copied_dir
  copied_dir="$(dirname "$copied_ss")"
  cat > "$copied_dir/sprint-progress-snapshot.sh" <<'SH'
#!/usr/bin/env bash
sleep 8
SH
  chmod +x "$copied_dir/sprint-progress-snapshot.sh"

  # Time the transition: must return in under 2 s even though snapshot sleeps 8 s
  local t_start t_end elapsed
  t_start="$(date +%s)"
  out="$(env SPRINT_STATE_SCRIPT_DIR="$copied_dir" \
      PROJECT_ROOT="$PROJECT_ROOT" \
      SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
      MEMORY_PATH="$MEMORY_PATH" \
      "$copied_ss" transition --story E900-S1 --to review 2>&1)" || true
  t_end="$(date +%s)"
  elapsed=$((t_end - t_start))
  [ "$elapsed" -lt 3 ]
}

# ---------------------------------------------------------------------------
# errexit regression guard
# ---------------------------------------------------------------------------

@test "errexit remains active inside subcommand dispatch" {
  # A failing intermediate command inside a subcommand must cause the
  # dispatch to exit non-zero. This guards against the || exit $? pattern
  # disabling errexit inside the subshell.
  _seed_sprint
  _seed_story E900-S1 in-progress

  # Transition to a non-existent state should fail
  run "$SCRIPT" transition --story E900-S1 --to bogus-state
  [ "$status" -ne 0 ]

  # Transition to done without all gates passed should fail
  run "$SCRIPT" transition --story E900-S1 --to done
  [ "$status" -ne 0 ]
}
