#!/usr/bin/env bats
# lock-sprint-state.bats — integration and concurrent stress tests for
# sprint-state.sh locking.

load 'test_helper.bash'

setup() {
  common_setup
  SPRINT_STATE="$SCRIPTS_DIR/sprint-state.sh"
  [ -f "$SPRINT_STATE" ] || skip "sprint-state.sh not found"
  HELPER="$SCRIPTS_DIR/lib/acquire-lock.sh"
  [ -f "$HELPER" ] || skip "acquire-lock.sh not found"
  # Build a scratch PATH excluding flock (works on both macOS and Ubuntu CI).
  NOFLOCK_BIN="$TEST_TMP/noflock-bin"
  mkdir -p "$NOFLOCK_BIN"
  local tool
  for tool in bash sh env awk sed grep sort cat mv rm cp mkdir ln sleep \
              date stat ps kill head tail wc tr printf touch mktemp \
              dirname basename readlink id tee yq jq git chmod perl find xargs cut od uname getconf; do
    local p
    p="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$p" ] && [ ! -e "$NOFLOCK_BIN/$tool" ]; then
      ln -s "$p" "$NOFLOCK_BIN/$tool" 2>/dev/null || true
    fi
  done
  SAFE_PATH="$NOFLOCK_BIN"
  # Sanity: flock must NOT be reachable through the scratch PATH.
  if PATH="$NOFLOCK_BIN" command -v flock >/dev/null 2>&1; then
    echo "FATAL: flock still reachable via scratch bin — test setup broken" >&2
    return 1
  fi
  PROJ="$TEST_TMP/project"
  STATE="$PROJ/.gaia/state"
  IMPL="$PROJ/.gaia/artifacts/implementation-artifacts"
  PLAN="$PROJ/.gaia/artifacts/planning-artifacts"
  mkdir -p "$STATE" "$IMPL" "$PLAN"
  cat > "$STATE/sprint-status.yaml" << 'YAMLEOF'
sprint_id: "test-sprint"
status: active
total_points: 0
goals: []
items: []
YAMLEOF
  # Epics heading uses the em-dash form that resolve-epic-slug.sh accepts.
  cat > "$PLAN/epics-and-stories.md" << 'EOFEPIC'
# Epics and Stories

## ETEST — Test Epic

| Key | Title | Status | Points |
|-----|-------|--------|--------|
EOFEPIC
  export SPRINT_STATUS_YAML="$STATE/sprint-status.yaml"
  export PROJECT_ROOT="$PROJ"
  export PROJECT_PATH="$PROJ"
  export GAIA_SKIP_ORPHAN_SWEEP=1
}

teardown() {
  jobs -p 2>/dev/null | xargs kill -9 2>/dev/null || true
  wait 2>/dev/null || true
  common_teardown
}

# Helper: create a story file. Includes the body > **Status:** line that
# sprint-state.sh requires for locate_story_file.
_create_story() {
  local key="$1" status="${2:-backlog}" sprint_id="${3:-test-sprint}"
  local story_dir="$IMPL/epic-test/stories"
  mkdir -p "$story_dir"
  cat > "$story_dir/${key}-test-story.md" << STORYEOF
---
template: 'story'
key: "${key}"
title: "Test story ${key}"
epic: "ETEST"
stack: "bash-dev"
status: ${status}
priority: "P1"
size: "S"
points: 1
risk: "low"
sprint_id: ${sprint_id}
priority_flag: null
delivered: false
deferred_implementation: false
manual_verification: false
origin: "manual"
origin_ref: "test"
depends_on: []
blocks: []
traces_to: []
date: "2026-01-01"
author: "test"
---

# Story: Test ${key}

> **Epic:** ETEST
> **Priority:** P1
> **Status:** ${status}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | --- |
| QA Tests | UNVERIFIED | --- |
| Security Review | UNVERIFIED | --- |
| Test Automation | UNVERIFIED | --- |
| Test Review | UNVERIFIED | --- |
| Performance Review | UNVERIFIED | --- |
STORYEOF
}

_wait_for_file() {
  local path="$1" tries=0
  while [ ! -f "$path" ] && [ "$tries" -lt 50 ]; do
    sleep 0.2 2>/dev/null || sleep 1
    tries=$((tries + 1))
  done
  [ -f "$path" ]
}

# ============================================================
# AC6: N=5 concurrent writers, no lost update
# ============================================================

@test "N=5 concurrent record-escalation-override writers produce all 5 overrides (AC6)" {
  # Use override item-ids OV-1..OV-5 that do NOT appear in the seed.
  local yaml="$SPRINT_STATUS_YAML"
  cat > "$yaml" << 'YAMLEOF'
sprint_id: "test-sprint"
status: active
total_points: 5
goals: []
items:
  - key: "TS-1"
    status: "in-progress"
    points: 1
  - key: "TS-2"
    status: "in-progress"
    points: 1
  - key: "TS-3"
    status: "in-progress"
    points: 1
  - key: "TS-4"
    status: "in-progress"
    points: 1
  - key: "TS-5"
    status: "in-progress"
    points: 1
YAMLEOF
  for i in 1 2 3 4 5; do
    _create_story "TS-$i" "in-progress" "\"test-sprint\""
  done
  local pids=()
  for i in 1 2 3 4 5; do
    local rcf="$TEST_TMP/rc-$i"
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export SPRINT_STATUS_YAML="$yaml"
      export PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
      export GAIA_SKIP_ORPHAN_SWEEP=1
      bash "$SPRINT_STATE" record-escalation-override \
        --item-ids "OV-$i" --user "writer-$i" --reason "override-test-$i"
      echo $? > "$rcf"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  # All 5 must exit 0.
  for i in 1 2 3 4 5; do
    local rcf="$TEST_TMP/rc-$i"
    [ -f "$rcf" ] || { echo "rc file missing for writer $i" >&2; false; }
    local rc
    rc="$(cat "$rcf")"
    [ "$rc" = "0" ] || { echo "writer $i exited $rc (expected 0)" >&2; false; }
  done
  # Assert on the OVERRIDE records, not the items list.
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  # YAML must be well-formed.
  yq eval '.' "$yaml" > /dev/null || { echo "YAML malformed" >&2; false; }
  # Must have exactly 5 override entries.
  local override_count
  override_count="$(yq eval '.overrides | length' "$yaml")"
  [ "$override_count" -eq 5 ] || {
    echo "expected 5 overrides, got $override_count (lost update)" >&2
    yq eval '.overrides' "$yaml" >&2
    false
  }
  # Each OV-N must appear in an override's overridden_item_ids.
  # Avoid grep -q in pipeline (SIGPIPE risk under pipefail).
  for i in 1 2 3 4 5; do
    local ov_check
    ov_check="$(yq eval '.overrides[].overridden_item_ids' "$yaml")"
    echo "$ov_check" | grep -F "OV-$i" >/dev/null || {
      echo "OV-$i MISSING from overrides (lost update)" >&2; false
    }
  done
}

# ============================================================
# AC2: rollover flock-absent branch acquires lock — contention-observable
# ============================================================

@test "rollover flock-absent branch blocks a second writer under contention (AC2)" {
  _create_story "ETEST-S1" "done" "\"old-sprint\""
  cat > "$SPRINT_STATUS_YAML" << 'YAMLEOF'
sprint_id: "new-sprint"
status: active
total_points: 0
goals: []
items: []
YAMLEOF
  # Background: hold the rollover lock file while the real rollover runs.
  local lock_file="$IMPL/epic-test/stories/ETEST-S1-test-story.md.rollover.lock"
  printf '%s %s\n' "$$" "$(date +%s)" > "$lock_file"
  # The contender should time out because we hold the lock.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" rollover --from old-sprint --to new-sprint --keys ETEST-S1
  '
  # RED: the current code runs UNLOCKED in flock-absent mode, so it ignores
  # the lock file and succeeds. After migration, it will time out.
  [ "$status" -ne 0 ] || {
    echo "rollover succeeded despite held lock — no contention (flock-absent branch is unlocked)" >&2
    false
  }
}

# ============================================================
# AC-EC4: nested lock — no deadlock, no double-acquire
# ============================================================

@test "nested rollover-inject completes and helper emits acquire/release trace (AC-EC4)" {
  _create_story "ETEST-S2" "done" "\"sprint-a\""
  cat > "$SPRINT_STATUS_YAML" << 'YAMLEOF'
sprint_id: "sprint-b"
status: active
total_points: 0
goals: []
items: []
YAMLEOF
  local debug_log="$TEST_TMP/lock-debug.log"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    export ACQUIRE_LOCK_DEBUG=1
    export ACQUIRE_LOCK_DEBUG_LOG="'"$debug_log"'"
    bash "'"$SPRINT_STATE"'" rollover --from sprint-a --to sprint-b --keys ETEST-S2
  '
  # RED: with the stub, acquire_lock returns 1 so rollover dies.
  [ "$status" -eq 0 ] || { echo "rollover failed (status=$status): $output" >&2; false; }
  # The debug log MUST exist (the helper is required to emit it).
  [ -f "$debug_log" ] || { echo "no debug log — helper did not emit trace" >&2; false; }
  # Verify no double-acquire on the same lock file without intervening release.
  local doubles
  doubles=$(awk '/^acquire / { if (seen[$2]++) print $2 }
                 /^release / { delete seen[$2] }' "$debug_log" | wc -l | tr -d ' ')
  [ "$doubles" -eq 0 ] || {
    echo "double-acquire detected:" >&2
    cat "$debug_log" >&2
    false
  }
}

# ============================================================
# AC2: site 6 rc capture under set -e (folded review finding)
# ============================================================

@test "set-story-sprint rc capture: failing body reaches die path under set -e (AC2)" {
  # Seed a story whose frontmatter has a sprint_id value the awk cannot match
  # (already set to a quoted string, not null/""). This makes _rewrite_sprint_id
  # fail its sanity check and return 1. The set +e / rc=$? / set -e wrapper
  # must capture that rc and route to the die path with the diagnostic message.
  # Without the rc capture, the script would abort silently under set -e.
  # Make the story file's directory unwritable so _rewrite_sprint_id's mktemp
  # fails (it creates a sibling tempfile). The set +e / rc=$? / set -e
  # wrapper must capture the non-zero rc and route to the die path with the
  # "failed to rewrite sprint_id" diagnostic.
  _create_story "ETEST-S3" "backlog" "null"
  cat > "$SPRINT_STATUS_YAML" << 'YAMLEOF'
sprint_id: "new-sprint"
status: active
total_points: 0
goals: []
items: []
YAMLEOF
  local story_dir="$IMPL/epic-test/stories"
  chmod 555 "$story_dir"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" set-story-sprint --story ETEST-S3 --sprint new-sprint
  '
  # Restore permissions for teardown.
  chmod 755 "$story_dir"
  # The body fails because mktemp cannot create the sibling tempfile.
  # Without the set +e / rc=$? wrapper, the script would abort silently
  # under set -e without reaching the die diagnostic.
  [ "$status" -ne 0 ] || { echo "expected die path, but set-story-sprint succeeded: $output" >&2; false; }
  [[ "$output" == *"failed to rewrite sprint_id"* ]] || {
    echo "expected 'failed to rewrite sprint_id' diagnostic, got: $output" >&2
    false
  }
}

# ============================================================
# AC5: fail-closed parallel refusal
# ============================================================

@test "GAIA_PARALLEL_EXECUTION=1 refuses without flock via sprint-state.sh (AC5)" {
  _create_story "ETEST-S4" "backlog" "\"test-sprint\""
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  # Add ETEST-S4 to the sprint-status items list AND the epics table.
  yq eval '.items += [{"key": "ETEST-S4", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S4 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_PARALLEL_EXECUTION=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" transition --story ETEST-S4 --to in-progress
  '
  # RED: the GAIA_PARALLEL_EXECUTION guard does not exist in production code,
  # so the transition succeeds. With the guard wired, it must refuse with
  # a "util-linux" diagnostic.
  [ "$status" -ne 0 ] || { echo "expected refusal, but transition succeeded: $output" >&2; false; }
  [[ "$output" == *"util-linux"* ]] || { echo "expected util-linux refusal, got: $output" >&2; false; }
}

@test "sequential mode unaffected without GAIA_PARALLEL_EXECUTION (AC5)" {
  _create_story "ETEST-S5" "backlog" "\"test-sprint\""
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S5", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S5 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    unset GAIA_PARALLEL_EXECUTION
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" transition --story ETEST-S5 --to in-progress
  '
  [ "$status" -eq 0 ] || { echo "sequential transition failed (status=$status): $output" >&2; false; }
}

# ============================================================
# Lock released on die() inside subshell (fallback path)
# ============================================================

@test "die inside locked subshell releases the lock via EXIT trap (AC2)" {
  # Use cmd_transition (backlog -> in-progress) whose lock is
  # $SPRINT_STATUS_LOCK = ${SPRINT_STATUS_YAML}.lock in $STATE/ (writable).
  # Make the STORY directory read-only so rewrite_story_status's mktemp
  # fails AFTER acquire_lock has already succeeded — proving the EXIT trap
  # releases the fallback lock on a post-acquire die.
  _create_story "ETEST-S6" "backlog" "\"test-sprint\""
  yq eval '.items += [{"key": "ETEST-S6", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  local story_dir="$IMPL/epic-test/stories"
  local lock_file="${SPRINT_STATUS_YAML}.lock"
  # Make story directory read-only so mktemp inside rewrite_story_status
  # fails. The lock directory ($STATE/) stays writable.
  chmod 555 "$story_dir"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" transition --story ETEST-S6 --to in-progress
  '
  chmod 755 "$story_dir"
  # The command must have failed inside the locked section.
  [ "$status" -ne 0 ] || { echo "expected die inside locked subshell, but succeeded: $output" >&2; false; }
  # The failure must NOT be a lock-acquisition timeout — it must be the
  # post-acquire fault (mktemp/rewrite failure inside the critical section).
  echo "$output" | grep -v "lock timeout" >/dev/null 2>&1 \
    || { echo "failure was lock-timeout, not post-acquire fault: $output" >&2; false; }
  # The lock file must NOT contain a held PID (trap released it).
  if [ -f "$lock_file" ]; then
    local content
    content="$(cat "$lock_file")"
    if echo "$content" | grep -E '^[0-9]+ [0-9]+$' >/dev/null 2>&1; then
      echo "lock file still carries PID after die (trap did not fire): $content" >&2
      false
    fi
  fi
  # A follow-up acquire with a high reap threshold must succeed quickly
  # (proving the lock was released, not just reaped from a stale file).
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  [ "$status" -eq 0 ] || { echo "follow-up acquire blocked (lock leaked): $output" >&2; false; }
}
