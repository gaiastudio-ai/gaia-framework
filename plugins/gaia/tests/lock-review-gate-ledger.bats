#!/usr/bin/env bats
# lock-review-gate-ledger.bats — concurrent ledger stress tests for
# review-gate.sh locking.
#
# Drives the REAL review-gate.sh update path. The ledger_write path is
# taken when --plan-id is present (review-gate.sh:1232-1233). The cmd_update
# path is taken when --plan-id is absent (review-gate.sh:1235), with
# REVIEW_GATE_PROOF_OF_EXECUTION=off to bypass the proof gate (line 1167).

load 'test_helper.bash'

setup() {
  common_setup
  REVIEW_GATE="$SCRIPTS_DIR/review-gate.sh"
  HELPER="$SCRIPTS_DIR/lib/acquire-lock.sh"
  [ -f "$REVIEW_GATE" ] || skip "review-gate.sh not found"
  [ -f "$HELPER" ] || skip "acquire-lock.sh not found"
  # Build a scratch PATH excluding flock (works on both macOS and Ubuntu CI).
  NOFLOCK_BIN="$TEST_TMP/noflock-bin"
  mkdir -p "$NOFLOCK_BIN"
  local tool
  for tool in bash sh env awk sed grep sort cat mv rm cp mkdir ln sleep \
              date stat ps kill head tail wc tr printf touch mktemp \
              dirname basename readlink id tee yq jq git chmod perl find xargs cut od uname getconf rmdir mkfifo timeout; do
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
  # Build a scratch project with a story file.
  PROJ="$TEST_TMP/project"
  STATE="$PROJ/.gaia/state"
  IMPL="$PROJ/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$STATE" "$IMPL/epic-test/stories"
  export PROJECT_ROOT="$PROJ"
  export PROJECT_PATH="$PROJ"
}

teardown() {
  jobs -p 2>/dev/null | xargs kill -9 2>/dev/null || true
  wait 2>/dev/null || true
  # Clear any immutability flag before the tree is removed. The
  # immutable-story test clears its own flag inline, but an assertion
  # aborting in between would leave it set — and rm -rf cannot unlink a
  # uchg/+i file, so common_teardown would fail and the litter would
  # accumulate across failing runs. Restore write permission for the same
  # reason.
  if [ -n "${PROJ:-}" ] && [ -d "${PROJ:-}" ]; then
    chflags -R nouchg "$PROJ" 2>/dev/null || true
    if command -v chattr >/dev/null 2>&1; then
      find "$PROJ" -type f -exec chattr -i {} + 2>/dev/null || true
    fi
    chmod -R u+w "$PROJ" 2>/dev/null || true
  fi
  common_teardown
}

# Helper: expose a real flock(1) through a private bin dir, or fail when the
# host has none (macOS default). Mirrors lock-helper.bats.
_real_flock_bin() {
  local real
  real="$(command -v flock 2>/dev/null || true)"
  [ -n "$real" ] || return 1
  local dir="$TEST_TMP/real-flock-bin"
  mkdir -p "$dir"
  [ -e "$dir/flock" ] || ln -s "$real" "$dir/flock"
  printf '%s' "$dir"
}

# Helper: create a story file for review-gate tests.
_mk_rg_story() {
  local key="$1"
  local story_dir="$IMPL/epic-test/stories"
  local sf="$story_dir/${key}-test.md"
  cat > "$sf" << STORYEOF
---
template: 'story'
key: "${key}"
title: "Test ${key}"
epic: "ETEST"
stack: "bash-dev"
status: in-progress
priority: "P1"
size: "S"
points: 1
risk: "low"
sprint_id: "test-sprint"
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

# Story: ${key}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
STORYEOF
  printf '%s' "$sf"
}

# ============================================================
# AC4: N=5 concurrent ledger writers produce exactly 5 entries
# ============================================================

@test "N=5 concurrent ledger writers produce exactly 5 entries (AC4)" {
  local sf
  sf="$(_mk_rg_story "ETEST-RG1")"
  # Set ledger path to scratch state dir.
  export REVIEW_GATE_LEDGER="$STATE/.review-gate-ledger"
  local pids=()
  local rc_files=()
  for i in 1 2 3 4 5; do
    local rcf="$TEST_TMP/rc-$i"
    rc_files+=("$rcf")
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
      export REVIEW_GATE_LEDGER="$STATE/.review-gate-ledger"
      bash "$REVIEW_GATE" update \
        --story ETEST-RG1 \
        --gate "Code Review" \
        --verdict PASSED \
        --plan-id "plan-$i"
      echo $? > "$rcf"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  # All 5 writers must exit 0: the lock serialises them, so none is lost
  # and none fails. Unlocking ledger_write reddens this via the entry count.
  for i in 1 2 3 4 5; do
    local rcf="$TEST_TMP/rc-$i"
    [ -f "$rcf" ] || { echo "rc file missing for writer $i" >&2; false; }
    local rc
    rc="$(cat "$rcf")"
    [ "$rc" = "0" ] || { echo "writer $i exited $rc" >&2; false; }
  done
  # Ledger file must exist and contain exactly 5 rows.
  [ -f "$STATE/.review-gate-ledger" ]
  local count
  count=$(wc -l < "$STATE/.review-gate-ledger" | tr -d ' ')
  [ "$count" -eq 5 ] || { echo "expected 5 ledger rows, got $count" >&2; false; }
  # Each plan-id must be present.
  for i in 1 2 3 4 5; do
    grep -qF "plan-$i" "$STATE/.review-gate-ledger" || {
      echo "plan-$i MISSING from ledger (lost update)" >&2; false
    }
  done
}

# ============================================================
# AC4: cmd_update branch produces correct final state
# ============================================================

@test "concurrent cmd_update writers produce correct final state (AC4)" {
  local sf
  sf="$(_mk_rg_story "ETEST-RG2")"
  # Drive 3 updates on 3 different gates without --plan-id (cmd_update path,
  # review-gate.sh:1235). REVIEW_GATE_PROOF_OF_EXECUTION=off bypasses the
  # proof gate at line 1167.
  local gates=("Code Review" "QA Tests" "Security Review")
  local pids=()
  local rc_files=()
  for i in 0 1 2; do
    local rcf="$TEST_TMP/rcu-$i"
    rc_files+=("$rcf")
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
      export REVIEW_GATE_PROOF_OF_EXECUTION=off
      bash "$REVIEW_GATE" update \
        --story ETEST-RG2 \
        --gate "${gates[$i]}" \
        --verdict PASSED
      echo $? > "$rcf"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  # All 3 writers must exit 0 and all 3 gates must land: concurrent updates
  # on distinct gates must not lose each other's rewrites.
  for i in 0 1 2; do
    local rcf="$TEST_TMP/rcu-$i"
    [ -f "$rcf" ] || { echo "rc file missing for writer $i" >&2; false; }
    local rc
    rc="$(cat "$rcf")"
    [ "$rc" = "0" ] || { echo "writer $i exited $rc" >&2; false; }
  done
  # The story file must show PASSED for all 3 gates.
  for g in "Code Review" "QA Tests" "Security Review"; do
    grep -q "| $g | PASSED |" "$sf" || {
      echo "gate '$g' not PASSED in story file" >&2
      cat "$sf" >&2
      false
    }
  done
}

# ============================================================
# AC4: ledger_write releases its lock when the critical section dies
# ============================================================

@test "ledger_write releases the lock when its critical section dies (AC4)" {
  # Drives the REAL review-gate.sh ledger_write path. Its only in-section
  # fault is the `! mv` handler, which exits non-zero WITHOUT releasing the
  # lock explicitly — the EXIT trap on the locked subshell is the sole
  # release, and `|| die "failed to write ledger"` is what turns the
  # subshell's non-zero status into the command's failure. Make the ledger
  # file immutable: the lock file next to it is still creatable
  # (acquisition succeeds) and the tmpfile still writes, but the final
  # rename onto the ledger cannot succeed. Without the trap that die leaves
  # a PID-bearing lock that blocks every later ledger write for this
  # project until it ages past the reap floor. A trailing `release_lock 8`
  # as the subshell's last statement would ALSO break this: its always-zero
  # status would become the subshell's, so the `|| die` would never fire
  # and the write would be reported as successful.
  local sf
  sf="$(_mk_rg_story "ETEST-RG8")"
  local ledger="$STATE/.review-gate-ledger"
  local lock_file="${ledger}.lock"
  printf 'SEED\tSeed Gate\tseed-plan\tPASSED\n' > "$ledger"

  local immutable=""
  if chflags uchg "$ledger" 2>/dev/null; then
    immutable="chflags"
  elif chattr +i "$ledger" 2>/dev/null; then
    immutable="chattr"
  else
    skip "cannot make a file immutable on this host (need chflags or chattr)"
  fi

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export REVIEW_GATE_LEDGER="'"$ledger"'"
    bash "'"$REVIEW_GATE"'" update \
      --story ETEST-RG8 \
      --gate "Code Review" \
      --verdict PASSED \
      --plan-id plan-die
  '
  local write_status="$status"
  local write_output="$output"

  # Clear the flag so the rest of the test (and teardown) can write.
  if [ "$immutable" = "chflags" ]; then
    chflags nouchg "$ledger" 2>/dev/null || true
  else
    chattr -i "$ledger" 2>/dev/null || true
  fi

  # The in-section fault must surface as a FAILURE, not a silent success.
  # A trailing release_lock inside the subshell masks the rc and reddens
  # exactly here.
  [ "$write_status" -ne 0 ] || {
    echo "ledger write reported success against an immutable ledger: $write_output" >&2
    false
  }
  [[ "$write_output" == *"failed to write ledger"* ]] || {
    echo "did not take the ledger-write failure die path: $write_output" >&2
    false
  }
  # It must have failed in the rename, not at acquisition — otherwise the
  # critical section never ran and this asserts nothing about the trap.
  if echo "$write_output" | grep -qF "lock timeout"; then
    echo "failed at acquisition, not inside the critical section: $write_output" >&2
    false
  fi
  # The seeded ledger content must be intact (the rename never landed).
  grep -qF "SEED" "$ledger" || {
    echo "the ledger was mutated despite the failed write" >&2
    false
  }

  # No PID-bearing lock may survive the died critical section.
  if [ -f "$lock_file" ] && [ -s "$lock_file" ]; then
    local content
    content="$(cat "$lock_file")"
    if echo "$content" | grep -qE '^[0-9]+ [0-9]+$'; then
      echo "ledger_write leaked a PID-bearing lock after die: $content" >&2
      false
    fi
  fi
  # Decisive check: a subsequent ledger write must succeed at once rather
  # than block on the leaked lock.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export REVIEW_GATE_LEDGER="'"$ledger"'"
    bash "'"$REVIEW_GATE"'" update \
      --story ETEST-RG8 \
      --gate "QA Tests" \
      --verdict PASSED \
      --plan-id plan-after
  '
  [ "$status" -eq 0 ] || {
    echo "the write after a died ledger_write failed — leaked lock (status=$status): $output" >&2
    false
  }
  grep -qF "plan-after" "$ledger" || {
    echo "follow-up ledger write did not land" >&2
    false
  }
}

# ============================================================
# AC4: cmd_update releases its lock when the critical section dies
# ============================================================

@test "cmd_update releases the lock when its critical section dies (AC4)" {
  # The fault must fire INSIDE the critical section. Of cmd_update's two die
  # paths, the missing-row case is rejected by load_canonical_rows before the
  # lock is taken, so the reachable one is the failed rename. Make the story
  # file immutable: it stays readable (pre-lock validation passes) and its
  # lock file is still creatable (acquisition succeeds), but the final mv
  # onto it cannot succeed. Without a releasing EXIT trap on the locked
  # subshell, that die leaves a PID-bearing lock behind that blocks later
  # updates for this story until it ages past the reap floor.
  local sf
  sf="$(_mk_rg_story "ETEST-RG9")"
  local lock_file="${sf}.lock"

  # Make the story file immutable (BSD chflags / Linux chattr).
  local immutable=""
  if chflags uchg "$sf" 2>/dev/null; then
    immutable="chflags"
  elif chattr +i "$sf" 2>/dev/null; then
    immutable="chattr"
  else
    skip "cannot make a file immutable on this host (need chflags or chattr)"
  fi

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export REVIEW_GATE_PROOF_OF_EXECUTION=off
    bash "'"$REVIEW_GATE"'" update \
      --story ETEST-RG9 \
      --gate "QA Tests" \
      --verdict PASSED
  '
  local update_status="$status"
  local update_output="$output"

  # Clear the flag so the rest of the test (and teardown) can write.
  if [ "$immutable" = "chflags" ]; then
    chflags nouchg "$sf" 2>/dev/null || true
  else
    chattr -i "$sf" 2>/dev/null || true
  fi

  [ "$update_status" -ne 0 ] || {
    echo "update succeeded against an immutable story file: $update_output" >&2
    false
  }
  # It must have failed in the rename, not at acquisition — otherwise the
  # critical section never ran and this asserts nothing about the trap.
  if echo "$update_output" | grep -qF "lock timeout"; then
    echo "failed at acquisition, not inside the critical section: $update_output" >&2
    false
  fi
  [[ "$update_output" == *"failed to mv tempfile"* ]] || {
    echo "did not take the in-section rename-failure die path: $update_output" >&2
    false
  }

  # No PID-bearing lock may survive the died critical section.
  if [ -f "$lock_file" ] && [ -s "$lock_file" ]; then
    local content
    content="$(cat "$lock_file")"
    if echo "$content" | grep -qE '^[0-9]+ [0-9]+$'; then
      echo "cmd_update leaked a PID-bearing lock after die: $content" >&2
      false
    fi
  fi
  # Decisive check: a subsequent update on this story must succeed at once
  # rather than block on the leaked lock.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export REVIEW_GATE_PROOF_OF_EXECUTION=off
    bash "'"$REVIEW_GATE"'" update \
      --story ETEST-RG9 \
      --gate "Code Review" \
      --verdict PASSED
  '
  [ "$status" -eq 0 ] || {
    echo "the update after a died cmd_update failed — leaked lock (status=$status): $output" >&2
    false
  }
  grep -qF "| Code Review | PASSED |" "$sf" || {
    echo "follow-up update did not land in the story file" >&2
    false
  }
}

# ============================================================
# AC4: the flock fast path must actually WORK end-to-end
# ============================================================

@test "review-gate ledger and story writes succeed on the flock fast path (AC4)" {
  # Every other flock-mode assertion in this story asserts a REFUSAL (a
  # symlink, a directory, a swapped path) or a released lock. A change that
  # made the fast path fail-closed for everyone therefore left them all
  # green while breaking every real write on the platform where flock is
  # present — which is the CI and production path on Linux. This is the
  # positive control that closes that hole: drive the REAL review-gate.sh
  # with flock genuinely on PATH and require the writes to land.
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local sf
  sf="$(_mk_rg_story "ETEST-RG7")"
  local ledger="$STATE/.review-gate-ledger"

  # Ledger path (--plan-id present).
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export REVIEW_GATE_LEDGER="'"$ledger"'"
    bash "'"$REVIEW_GATE"'" update \
      --story ETEST-RG7 \
      --gate "Code Review" \
      --verdict PASSED \
      --plan-id plan-flock
  '
  [ "$status" -eq 0 ] || {
    echo "ledger write FAILED on the flock fast path (status=$status): $output" >&2
    echo "— the fast path is fail-closed; every write on a flock host breaks" >&2
    false
  }
  if echo "$output" | grep -qF "changed identity during open"; then
    echo "the post-open identity check rejected a legitimate open: $output" >&2
    false
  fi
  grep -qF "plan-flock" "$ledger" || {
    echo "the ledger row did not land: $(cat "$ledger" 2>/dev/null)" >&2
    false
  }

  # Story-file path (cmd_update, no --plan-id).
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export REVIEW_GATE_PROOF_OF_EXECUTION=off
    bash "'"$REVIEW_GATE"'" update \
      --story ETEST-RG7 \
      --gate "QA Tests" \
      --verdict PASSED
  '
  [ "$status" -eq 0 ] || {
    echo "cmd_update FAILED on the flock fast path (status=$status): $output" >&2
    false
  }
  grep -qF "| QA Tests | PASSED |" "$sf" || {
    echo "the story-file update did not land on the flock fast path" >&2
    false
  }

  # A second write must still get the lock — the first release worked.
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export REVIEW_GATE_LEDGER="'"$ledger"'"
    bash "'"$REVIEW_GATE"'" update \
      --story ETEST-RG7 \
      --gate "Security Review" \
      --verdict PASSED \
      --plan-id plan-flock-2
  '
  [ "$status" -eq 0 ] || {
    echo "the second flock-path write failed — the lock was not released: $output" >&2
    false
  }
  grep -qF "plan-flock-2" "$ledger" || { echo "second ledger row missing" >&2; false; }
}
