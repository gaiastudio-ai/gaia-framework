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
  # Restore write permission before the tree is removed: tests that chmod a
  # fixture directory read-only restore it inline, but an assertion aborting
  # in between would leave common_teardown's rm -rf unable to unlink through
  # it, and the litter accumulates across failing runs.
  chmod -R u+w "$IMPL" 2>/dev/null || true
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
  # Contention-observable: with the lock held, rollover must time out rather
  # than proceed. Deleting its acquire_lock call makes this succeed instead.
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
  # The nested rollover -> inject sequence must complete without deadlock.
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

@test "set-story-sprint rc capture: failing critical section reaches the die path (AC2)" {
  # Fault injection that does NOT disable the lock: a story whose frontmatter
  # carries no sprint_id line at all. The awk rewrite has nothing to match, so
  # the post-rewrite sanity grep fails and _rewrite_sprint_id returns 1 from
  # INSIDE the critical section, with the story directory fully writable and
  # the lock genuinely taken. (Making the directory read-only instead would
  # make acquire_lock fail first — the body under test would never run.)
  _create_story "ETEST-S3" "backlog" "null"
  local story_file="$IMPL/epic-test/stories/ETEST-S3-test-story.md"
  # Drop the sprint_id line from the frontmatter.
  grep -v '^sprint_id:' "$story_file" > "$story_file.new"
  mv "$story_file.new" "$story_file"
  local before_sum
  before_sum="$(cksum < "$story_file")"
  cat > "$SPRINT_STATUS_YAML" << 'YAMLEOF'
sprint_id: "new-sprint"
status: active
total_points: 0
goals: []
items: []
YAMLEOF
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" set-story-sprint --story ETEST-S3 --sprint new-sprint
  '
  # The failure must surface. A trailing release_lock as the subshell's last
  # statement would overwrite the critical section's rc with 0, and the script
  # would print success while having written nothing.
  [ "$status" -ne 0 ] || {
    echo "set-story-sprint reported SUCCESS while the rewrite failed: $output" >&2
    false
  }
  [[ "$output" == *"failed to rewrite sprint_id"* ]] || {
    echo "expected the 'failed to rewrite sprint_id' diagnostic, got: $output" >&2
    false
  }
  # The success line must NOT be printed.
  if echo "$output" | grep -qF "sprint_id bound to"; then
    echo "printed the success line despite the failure: $output" >&2
    false
  fi
  # And the story file must be untouched.
  [ "$(cksum < "$story_file")" = "$before_sum" ] || {
    echo "story file was modified despite the reported failure" >&2
    false
  }
  # The acquisition itself must have succeeded — otherwise this test would be
  # asserting on a lock timeout rather than on the critical section.
  if echo "$output" | grep -qF "lock timeout"; then
    echo "the run failed at lock acquisition, not in the critical section: $output" >&2
    false
  fi
}

# ============================================================
# AC2: every migrated site actually takes its lock —
# contention-observable coverage for inject / reconcile / set-story-sprint
# ============================================================

@test "inject blocks when the sprint-status lock is held (AC2)" {
  # Deleting the acquire/release/trap at the inject site must break this:
  # with a live-PID lock file in place, inject has to fail rather than
  # proceed into the critical section.
  _create_story "ETEST-S10" "backlog" "\"test-sprint\""
  local holder_done="$TEST_TMP/inject-holder-done"
  rm -f "$holder_done"
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s\n' "$holder_pid" "$(date +%s)" > "${SPRINT_STATUS_YAML}.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" inject --story ETEST-S10
  '
  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || {
    echo "inject succeeded while the sprint-status lock was held — site is unlocked" >&2
    echo "$output" >&2
    false
  }
  # It must have failed at ACQUISITION, not for some unrelated reason.
  [[ "$output" == *"lock timeout"* ]] || {
    echo "inject failed, but not at lock acquisition: $output" >&2
    false
  }
}

@test "reconcile blocks when the sprint-status lock is held, honouring its 10s timeout (AC2)" {
  # reconcile is the only site with a 10s (not 5s) timeout, so this also
  # pins the per-site timeout value reaching the helper.
  _create_story "ETEST-S11" "backlog" "\"test-sprint\""
  local holder_done="$TEST_TMP/reconcile-holder-done"
  rm -f "$holder_done"
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s\n' "$holder_pid" "$(date +%s)" > "${SPRINT_STATUS_YAML}.lock"
  local start_s
  start_s=$(date +%s)
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" reconcile
  '
  local elapsed=$(( $(date +%s) - start_s ))
  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || {
    echo "reconcile succeeded while the sprint-status lock was held — site is unlocked" >&2
    echo "$output" >&2
    false
  }
  # It blocked for the site's own 10s budget, not the 5s used elsewhere.
  [ "$elapsed" -ge 9 ] || {
    echo "reconcile gave up after ${elapsed}s — its 10s timeout did not reach the helper" >&2
    false
  }
}

@test "set-story-sprint blocks when its per-story lock is held (AC2)" {
  _create_story "ETEST-S12" "backlog" "null"
  local story_file="$IMPL/epic-test/stories/ETEST-S12-test-story.md"
  local holder_done="$TEST_TMP/sss-holder-done"
  rm -f "$holder_done"
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s\n' "$holder_pid" "$(date +%s)" > "${story_file}.set-sprint.lock"
  local before_sum
  before_sum="$(cksum < "$story_file")"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" set-story-sprint --story ETEST-S12 --sprint test-sprint
  '
  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || {
    echo "set-story-sprint succeeded while its per-story lock was held — site is unlocked" >&2
    echo "$output" >&2
    false
  }
  # It must have failed at ACQUISITION. Without this the test would pass on
  # any pre-lock rejection (a sprint-id mismatch, say) and would assert
  # nothing at all about whether the site takes its lock.
  [[ "$output" == *"lock timeout"* ]] || {
    echo "set-story-sprint failed, but not at lock acquisition: $output" >&2
    false
  }
  # And it wrote nothing.
  [ "$(cksum < "$story_file")" = "$before_sum" ] || {
    echo "story file modified while the lock was held by another owner" >&2
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
  # Parallel mode is fail-closed without flock: the transition must refuse
  # with a "util-linux" diagnostic rather than run on the fallback path.
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

# ============================================================
# AC2: the critical section's exit status must survive the release
# ============================================================

@test "rollover reports a failed inject as failed, not succeeded (AC2)" {
  # _rollover_one runs its critical section in a subshell whose status is the
  # per-key verdict. A trailing release_lock as that subshell's LAST statement
  # overwrites the status with its own always-zero one, so a key whose inject
  # failed (and whose story file was rolled back) still gets listed under
  # "succeeded" and the command exits 0.
  _create_story "ETEST-S30" "done" "\"old-sprint\""
  # Target sprint yaml that inject cannot write: not a mapping, so the
  # injection step fails while the story-file rewrite before it succeeds.
  printf 'this is not a sprint yaml mapping\n' > "$SPRINT_STATUS_YAML"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" rollover --from old-sprint --to new-sprint --keys ETEST-S30
  '
  [ "$status" -ne 0 ] || {
    echo "rollover exited 0 despite a failed inject: $output" >&2
    false
  }
  # The key must be listed as failed, not succeeded.
  echo "$output" | grep -E '^sprint-state\.sh rollover: failed:.*ETEST-S30' >/dev/null || {
    echo "ETEST-S30 not listed under failed: $output" >&2
    false
  }
  if echo "$output" | grep -E '^sprint-state\.sh rollover: succeeded:.*ETEST-S30' >/dev/null; then
    echo "a failed key was reported as succeeded — the critical section rc was masked" >&2
    echo "$output" >&2
    false
  fi
}
