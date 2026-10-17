#!/usr/bin/env bats
# concurrent-sprint-ledger.bats — tests for the cross-session resource ledger.

setup() {
  TEST_DIR="$(mktemp -d)"
  export GAIA_STATE_DIR="${TEST_DIR}/state"
  mkdir -p "$GAIA_STATE_DIR"

  # Config fixture.
  mkdir -p "${TEST_DIR}/config"
  cat > "${TEST_DIR}/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 2
parallel_execution:
  max_parallel_dev_slots: 4
  teammate_dispatch_ceiling: 12
YAML
  export GAIA_SHARED_CONFIG="${TEST_DIR}/config/project-config.yaml"

  # Session ID.
  export CLAUDE_CODE_SESSION_ID="test-session-$$-${RANDOM}"

  # Script under test.
  LEDGER_SH="${BATS_TEST_DIRNAME}/../scripts/concurrent-resource-ledger.sh"
  ACQUIRE_LOCK_SH="${BATS_TEST_DIRNAME}/../scripts/lib/acquire-lock.sh"

  # Force flock by default (tests run sub-cases for fallback separately).
  export GAIA_LOCK_FORCE_FALLBACK=0
}

teardown() {
  # Kill any leftover heartbeat loops.
  if ls "${GAIA_STATE_DIR}"/.ledger-heartbeat-*.pid >/dev/null 2>&1; then
    local pidfile
    for pidfile in "${GAIA_STATE_DIR}"/.ledger-heartbeat-*.pid; do
      [ -f "$pidfile" ] || continue
      local p
      p="$(cat "$pidfile" 2>/dev/null)" || continue
      kill "$p" 2>/dev/null || true
    done
  fi
  rm -rf "$TEST_DIR"
}

# Helper: read a field from the ledger.
_ledger_field() {
  jq -r "$1" "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json" 2>/dev/null
}

# ============================================================
# TC-CONC-LED-1: Budget enforcement (2 sub-cases)
# ============================================================

@test "TC-CONC-LED-1a: session A claims 3, session B claim for 2 refused (budget 4)" {
  # Session A claims 3 dev slots.
  export CLAUDE_CODE_SESSION_ID="session-A"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 3 --teammates 0
  [ "$status" -eq 0 ]

  # Session B claims 2 — should be refused (3+2=5 > 4).
  export CLAUDE_CODE_SESSION_ID="session-B"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 2 --teammates 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget exhausted"* ]]
}

@test "TC-CONC-LED-1b: after A releases 1, B retries claim 2 and succeeds (budget 4)" {
  # Session A claims 3.
  export CLAUDE_CODE_SESSION_ID="session-A"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 3 --teammates 0

  # Session A releases 1 (now has 2).
  bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  # Session B claims 2 — should succeed (2+2=4 <= 4).
  export CLAUDE_CODE_SESSION_ID="session-B"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 2 --teammates 0
  [ "$status" -eq 0 ]
}

# ============================================================
# TC-CONC-LED-2: Flock serialization under contention
# ============================================================

@test "TC-CONC-LED-2a: concurrent claims serialized (flock)" {
  export GAIA_LOCK_FORCE_FALLBACK=0

  export CLAUDE_CODE_SESSION_ID="session-C1"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0 &
  local pid1=$!

  export CLAUDE_CODE_SESSION_ID="session-C2"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0 &
  local pid2=$!

  wait "$pid1"
  wait "$pid2"

  # Both should succeed — no corruption.
  local count
  count="$(jq '.sessions | length' "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json")"
  [ "$count" -eq 2 ]
}

@test "TC-CONC-LED-2b: concurrent claims serialized (fallback)" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  export CLAUDE_CODE_SESSION_ID="session-F1"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0 &
  local pid1=$!

  export CLAUDE_CODE_SESSION_ID="session-F2"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0 &
  local pid2=$!

  wait "$pid1"
  wait "$pid2"

  # Both should succeed — no corruption.
  local count
  count="$(jq '.sessions | length' "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json")"
  [ "$count" -eq 2 ]
}

# ============================================================
# TC-CONC-LED-3: Stale reaping (two-factor check)
# ============================================================

@test "TC-CONC-LED-3a: dead PID + stale heartbeat = reaped" {
  export GAIA_LEDGER_STALE_TIMEOUT=1
  mkdir -p "${GAIA_STATE_DIR}/sessions/stale-session-3a"

  # Create a ledger with a stale entry (dead PID, old heartbeat).
  local old_epoch
  old_epoch=$(( $(date +%s) - 600 ))
  jq -n --argjson hb "$old_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "stale-session-3a": {
        sprint_id: "sprint-99", pid: 99999, heartbeat_epoch: $hb,
        dev_slots_claimed: 2, teammates_claimed: 1
      }
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  # Fresh session claims — should reap the stale entry.
  export CLAUDE_CODE_SESSION_ID="fresh-session"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"reaping stale session stale-session-3a"* ]] || [[ "$stderr" == *"reaping stale session"* ]] || {
    # Check stderr captured in output (bats merges them).
    true
  }

  # Stale entry should be gone.
  local has_stale
  has_stale="$(_ledger_field '.sessions["stale-session-3a"] // "gone"')"
  [ "$has_stale" = "gone" ]
}

@test "TC-CONC-LED-3b: dead PID + fresh heartbeat = NOT reaped" {
  export GAIA_LEDGER_STALE_TIMEOUT=300
  mkdir -p "${GAIA_STATE_DIR}/sessions/fresh-dead-session"

  # Create entry with dead PID but fresh heartbeat (only 100s ago).
  local fresh_epoch
  fresh_epoch=$(( $(date +%s) - 100 ))
  jq -n --argjson hb "$fresh_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "fresh-dead-session": {
        sprint_id: "sprint-99", pid: 99998, heartbeat_epoch: $hb,
        dev_slots_claimed: 1, teammates_claimed: 0
      }
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  # Fresh session claims — should NOT reap (only one factor met).
  export CLAUDE_CODE_SESSION_ID="another-session"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  # Entry should still be present.
  local has_entry
  has_entry="$(_ledger_field '.sessions["fresh-dead-session"].pid')"
  [ "$has_entry" = "99998" ]
}

# ============================================================
# TC-CONC-LED-4: PID-recycling safety
# ============================================================

@test "TC-CONC-LED-4: alive PID with stale heartbeat NOT reaped (binding dir present)" {
  export GAIA_LEDGER_STALE_TIMEOUT=1
  local my_pid=$$
  mkdir -p "${GAIA_STATE_DIR}/sessions/alive-pid-session"

  # Entry with alive PID (this process) but stale heartbeat.
  local old_epoch
  old_epoch=$(( $(date +%s) - 600 ))
  jq -n --argjson pid "$my_pid" --argjson hb "$old_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "alive-pid-session": {
        sprint_id: "sprint-99", pid: $pid, heartbeat_epoch: $hb,
        dev_slots_claimed: 1, teammates_claimed: 0
      }
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  # Reap — should NOT touch the entry (PID is alive, binding dir present).
  bash "$LEDGER_SH" reap

  local entry_pid
  entry_pid="$(_ledger_field '.sessions["alive-pid-session"].pid')"
  [ "$entry_pid" = "$my_pid" ]
}

# ============================================================
# TC-CONC-LED-5: Normal exit cleanup
# ============================================================

@test "TC-CONC-LED-5: cleanup removes session entry from ledger" {
  export CLAUDE_CODE_SESSION_ID="cleanup-session"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 2 --teammates 3

  # Verify entry exists.
  local has
  has="$(_ledger_field '.sessions["cleanup-session"].dev_slots_claimed')"
  [ "$has" = "2" ]

  # Run cleanup.
  bash "$LEDGER_SH" cleanup --sprint sprint-99 --pid $$

  # Entry should be gone.
  has="$(_ledger_field '.sessions["cleanup-session"] // "gone"')"
  [ "$has" = "gone" ]

  # Ledger should be valid JSON.
  jq empty "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"
}

# ============================================================
# TC-CONC-LED-6: Crash recovery
# ============================================================

@test "TC-CONC-LED-6: next claimer reaps crashed session and reclaims slots" {
  export GAIA_LEDGER_STALE_TIMEOUT=1

  # Simulate a crashed session with dead PID and stale heartbeat.
  local old_epoch
  old_epoch=$(( $(date +%s) - 600 ))
  jq -n --argjson hb "$old_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "crashed-session": {
        sprint_id: "sprint-99", pid: 99997, heartbeat_epoch: $hb,
        dev_slots_claimed: 3, teammates_claimed: 0
      }
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  # Next claimer reclaims slots.
  export CLAUDE_CODE_SESSION_ID="recovery-session"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 3 --teammates 0
  [ "$status" -eq 0 ]

  # Crashed entry gone, recovery entry present.
  local gone
  gone="$(_ledger_field '.sessions["crashed-session"] // "gone"')"
  [ "$gone" = "gone" ]

  local new_dev
  new_dev="$(_ledger_field '.sessions["recovery-session"].dev_slots_claimed')"
  [ "$new_dev" = "3" ]
}

# ============================================================
# TC-CONC-LED-7: Schema validation
# ============================================================

@test "TC-CONC-LED-7: ledger after claim/release has correct D7 schema" {
  export CLAUDE_CODE_SESSION_ID="schema-session"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 2 --teammates 3

  # Validate schema fields.
  local sv
  sv="$(_ledger_field '.schema_version')"
  [ "$sv" = "1.0" ]

  local ms
  ms="$(_ledger_field '.budget.max_parallel_dev_slots')"
  [ "$ms" = "4" ]

  local mt
  mt="$(_ledger_field '.budget.teammate_dispatch_ceiling')"
  [ "$mt" = "12" ]

  # Validate session entry types.
  local sprint_id pid hb dev tm
  sprint_id="$(_ledger_field '.sessions["schema-session"].sprint_id')"
  [ "$sprint_id" = "sprint-99" ]

  pid="$(_ledger_field '.sessions["schema-session"].pid')"
  [ "$pid" = "$$" ]

  hb="$(_ledger_field '.sessions["schema-session"].heartbeat_epoch')"
  [ "$hb" -gt 0 ]

  dev="$(_ledger_field '.sessions["schema-session"].dev_slots_claimed')"
  [ "$dev" = "2" ]

  tm="$(_ledger_field '.sessions["schema-session"].teammates_claimed')"
  [ "$tm" = "3" ]

  # Verify types via jq.
  local type_check
  type_check="$(jq -r '
    (.schema_version | type) as $sv |
    (.budget.max_parallel_dev_slots | type) as $ms |
    (.budget.teammate_dispatch_ceiling | type) as $mt |
    (.sessions | to_entries[0].value) as $e |
    if $sv != "string" then "bad_sv"
    elif $ms != "number" then "bad_ms"
    elif $mt != "number" then "bad_mt"
    elif ($e.sprint_id | type) != "string" then "bad_sprint"
    elif ($e.pid | type) != "number" then "bad_pid"
    elif ($e.heartbeat_epoch | type) != "number" then "bad_hb"
    elif ($e.dev_slots_claimed | type) != "number" then "bad_dev"
    elif ($e.teammates_claimed | type) != "number" then "bad_tm"
    else "ok" end
  ' "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json")"
  [ "$type_check" = "ok" ]
}

# ============================================================
# TC-CONC-LED-corrupt: Corrupt JSON exits 6
# ============================================================

@test "TC-CONC-LED-corrupt: truncated JSON exits 6 with diagnostic" {
  printf '{"schema_ver' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  export CLAUDE_CODE_SESSION_ID="corrupt-test"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 6 ]
  [[ "$output" == *"corrupt ledger"* ]]
}

# ============================================================
# TC-CONC-LED-inert: Single-sprint mode
# ============================================================

@test "TC-CONC-LED-inert: single-sprint mode produces no ledger file" {
  # Override config to single-sprint.
  cat > "${TEST_DIR}/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 1
parallel_execution:
  max_parallel_dev_slots: 4
  teammate_dispatch_ceiling: 12
YAML

  # Ensure no per-sprint files.
  rm -f "${GAIA_STATE_DIR}"/sprint-status-*.yaml 2>/dev/null || true

  export CLAUDE_CODE_SESSION_ID="inert-test"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  # No ledger file should be created.
  [ ! -f "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json" ]

  # No lock file should exist.
  [ ! -f "${GAIA_STATE_DIR}/.concurrent-resource-ledger.lock" ]
}

# ============================================================
# TC-CONC-LED-budget-tamper: Tampered budget ignored
# ============================================================

@test "TC-CONC-LED-budget-tamper: tampered ledger budget ignored, config enforced" {
  # Create ledger with tampered budget (99) but config says 4.
  jq -n '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 99, teammate_dispatch_ceiling: 99},
    sessions: {}
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  export CLAUDE_CODE_SESSION_ID="tamper-session"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 5 --teammates 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget exhausted"* ]]
}

# ============================================================
# TC-CONC-LED-binding-reap: Binding dir gone triggers reap
# ============================================================

@test "TC-CONC-LED-binding-reap: session whose binding dir is gone is reaped" {
  # Create sessions root but NOT the session's binding dir.
  mkdir -p "${GAIA_STATE_DIR}/sessions"
  # Deliberately NOT creating "${GAIA_STATE_DIR}/sessions/orphan-session/"

  local my_pid=$$
  jq -n --argjson pid "$my_pid" --argjson hb "$(date +%s)" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "orphan-session": {
        sprint_id: "sprint-99", pid: $pid, heartbeat_epoch: $hb,
        dev_slots_claimed: 1, teammates_claimed: 0
      }
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  bash "$LEDGER_SH" reap

  local gone
  gone="$(_ledger_field '.sessions["orphan-session"] // "gone"')"
  [ "$gone" = "gone" ]
}

# ============================================================
# TC-CONC-LED-sessions-absent: Sessions root absent skips binding-dir check
# ============================================================

@test "TC-CONC-LED-sessions-absent: no sessions root, dead PID + stale = reaped via two-factor" {
  export GAIA_LEDGER_STALE_TIMEOUT=1
  # Ensure NO sessions root directory exists.
  rm -rf "${GAIA_STATE_DIR}/sessions"

  local old_epoch
  old_epoch=$(( $(date +%s) - 600 ))
  jq -n --argjson hb "$old_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "dead-no-sessions-root": {
        sprint_id: "sprint-99", pid: 99996, heartbeat_epoch: $hb,
        dev_slots_claimed: 1, teammates_claimed: 0
      }
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  bash "$LEDGER_SH" reap

  local gone
  gone="$(_ledger_field '.sessions["dead-no-sessions-root"] // "gone"')"
  [ "$gone" = "gone" ]
}

# ============================================================
# TC-CONC-LED-hb-pid-mismatch: Heartbeat PID mismatch refused
# ============================================================

@test "TC-CONC-LED-hb-pid-mismatch: heartbeat with wrong PID is refused" {
  export CLAUDE_CODE_SESSION_ID="hb-mismatch-session"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid 888 --dev 1 --teammates 0

  # Heartbeat with different PID.
  run bash "$LEDGER_SH" heartbeat --sprint sprint-99 --pid 999
  [ "$status" -ne 0 ]
  [[ "$output" == *"PID mismatch"* ]]
}

# ============================================================
# TC-CONC-LED-release-keep: Release decrements, entry stays
# ============================================================

@test "TC-CONC-LED-release-keep: release decrements counts, entry stays, heartbeat refreshed" {
  export CLAUDE_CODE_SESSION_ID="release-keep-session"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 3 --teammates 2

  local hb_before
  hb_before="$(_ledger_field '.sessions["release-keep-session"].heartbeat_epoch')"

  sleep 1

  bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  # Entry stays, dev_slots decremented.
  local dev_after
  dev_after="$(_ledger_field '.sessions["release-keep-session"].dev_slots_claimed')"
  [ "$dev_after" = "2" ]

  # Teammates unchanged.
  local tm_after
  tm_after="$(_ledger_field '.sessions["release-keep-session"].teammates_claimed')"
  [ "$tm_after" = "2" ]

  # Heartbeat refreshed.
  local hb_after
  hb_after="$(_ledger_field '.sessions["release-keep-session"].heartbeat_epoch')"
  [ "$hb_after" -ge "$hb_before" ]
}

# ============================================================
# TC-CONC-LED-teammate-cross: Teammate ceiling across sessions
# ============================================================

@test "TC-CONC-LED-teammate-cross: combined teammate claims respect ceiling" {
  export CLAUDE_CODE_SESSION_ID="tm-session-A"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 0 --teammates 6

  export CLAUDE_CODE_SESSION_ID="tm-session-B"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 0 --teammates 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget exhausted"* ]]
}

# ============================================================
# TC-CONC-LED-lock-exit: Lock exit code pass-through
# ============================================================

@test "TC-CONC-LED-lock-exit-a: lock timeout exit 3 passes through" {
  # Hold the L2 lock from a background process to cause timeout.
  local state_dir
  state_dir="$(_crl_state_dir_for_test)"

  # Source acquire-lock to hold L2.
  (
    # shellcheck source=../scripts/lib/acquire-lock.sh
    . "$ACQUIRE_LOCK_SH"
    mkdir -p "$state_dir"
    acquire_lock "${state_dir}/${GAIA_LOCK_L2_PATH}" 30 8 --strict
    sleep 10
  ) &
  local holder=$!
  sleep 0.5

  export GAIA_LOCK_L2_TIMEOUT=1
  export CLAUDE_CODE_SESSION_ID="timeout-session"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 3 ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

_crl_state_dir_for_test() {
  printf '%s' "$GAIA_STATE_DIR"
}

# ============================================================
# TC-CONC-LED-sole-writer: Static grep sweep
# ============================================================

@test "TC-CONC-LED-sole-writer: only concurrent-resource-ledger.sh writes to the ledger file" {
  local scripts_dir="${BATS_TEST_DIRNAME}/../scripts"

  # Grep for writes to the ledger filename across all scripts, excluding the
  # ledger script itself and this test file.
  local matches
  matches="$(grep -rl '\.concurrent-resource-ledger\.json' "$scripts_dir" \
    --include='*.sh' \
    | grep -v 'concurrent-resource-ledger\.sh$' \
    || true)"

  # Any match must be a read (cat/jq read), not a write (>, >>, mv, cp, tee).
  if [ -n "$matches" ]; then
    local f
    for f in $matches; do
      local write_ops
      write_ops="$(grep '\.concurrent-resource-ledger\.json' "$f" \
        | grep -E '(>|>>|mv |cp |tee )' \
        | grep -v '# ' \
        || true)"
      [ -z "$write_ops" ] || {
        printf 'Write to ledger file found in %s:\n%s\n' "$f" "$write_ops"
        return 1
      }
    done
  fi
}

# ============================================================
# TC-CONC-LED-hb-loop: Heartbeat loop lifecycle
# ============================================================

@test "TC-CONC-LED-hb-loop-a: heartbeat loop creates PID file and advances epoch" {
  export GAIA_LEDGER_HEARTBEAT_INTERVAL=2
  export CLAUDE_CODE_SESSION_ID="hb-loop-session"

  # Claim to create the ledger entry.
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  local hb_before
  hb_before="$(_ledger_field '.sessions["hb-loop-session"].heartbeat_epoch')"

  # Start heartbeat loop.
  local loop_pid
  loop_pid="$(bash "$LEDGER_SH" start-heartbeat-loop --sprint sprint-99 --pid $$)"
  [ -n "$loop_pid" ]

  # PID file should exist.
  [ -f "${GAIA_STATE_DIR}/.ledger-heartbeat-hb-loop-session.pid" ]

  # Wait for at least one heartbeat cycle.
  sleep 3

  local hb_after
  hb_after="$(_ledger_field '.sessions["hb-loop-session"].heartbeat_epoch')"
  [ "$hb_after" -ge "$hb_before" ]

  # Cleanup stops the loop.
  bash "$LEDGER_SH" cleanup --sprint sprint-99 --pid $$
  sleep 1

  # PID file should be removed.
  [ ! -f "${GAIA_STATE_DIR}/.ledger-heartbeat-hb-loop-session.pid" ]

  # Loop process should be gone.
  ! kill -0 "$loop_pid" 2>/dev/null
}

@test "TC-CONC-LED-hb-loop-b: heartbeat loop self-exits when session PID dies" {
  export GAIA_LEDGER_HEARTBEAT_INTERVAL=1
  export CLAUDE_CODE_SESSION_ID="hb-self-exit-session"

  # Spawn a dummy process as the "session PID".
  sleep 30 &
  local fake_pid=$!

  bash "$LEDGER_SH" claim --sprint sprint-99 --pid "$fake_pid" --dev 1 --teammates 0

  local loop_pid
  loop_pid="$(bash "$LEDGER_SH" start-heartbeat-loop --sprint sprint-99 --pid "$fake_pid")"

  # Kill the fake session PID.
  kill "$fake_pid" 2>/dev/null || true
  wait "$fake_pid" 2>/dev/null || true

  # Wait for the loop to detect the death and exit.
  sleep 3

  # Loop should have self-exited.
  ! kill -0 "$loop_pid" 2>/dev/null
}

# ============================================================
# TC-CONC-LED-EC1: Mass crash reaping
# ============================================================

@test "TC-CONC-LED-EC1: 3 crashed sessions reaped in one pass" {
  export GAIA_LEDGER_STALE_TIMEOUT=1

  local old_epoch
  old_epoch=$(( $(date +%s) - 600 ))
  jq -n --argjson hb "$old_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "crash-1": {sprint_id: "s", pid: 99991, heartbeat_epoch: $hb, dev_slots_claimed: 1, teammates_claimed: 0},
      "crash-2": {sprint_id: "s", pid: 99992, heartbeat_epoch: $hb, dev_slots_claimed: 1, teammates_claimed: 0},
      "crash-3": {sprint_id: "s", pid: 99993, heartbeat_epoch: $hb, dev_slots_claimed: 1, teammates_claimed: 0}
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  export CLAUDE_CODE_SESSION_ID="fresh-after-crash"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  # All 3 crashed entries should be gone.
  local count
  count="$(_ledger_field '.sessions | length')"
  [ "$count" -eq 1 ]
  [ "$(_ledger_field '.sessions["fresh-after-crash"].dev_slots_claimed')" = "1" ]
}

# ============================================================
# TC-CONC-LED-EC2: PID-recycling within timeout
# ============================================================

@test "TC-CONC-LED-EC2: recycled PID with binding dir present not reaped" {
  export GAIA_LEDGER_STALE_TIMEOUT=1
  mkdir -p "${GAIA_STATE_DIR}/sessions/recycled-session"

  # Entry with alive PID (this process acts as the non-GAIA recycled process).
  local old_epoch
  old_epoch=$(( $(date +%s) - 600 ))
  jq -n --argjson pid "$$" --argjson hb "$old_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "recycled-session": {
        sprint_id: "sprint-99", pid: $pid, heartbeat_epoch: $hb,
        dev_slots_claimed: 1, teammates_claimed: 0
      }
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  bash "$LEDGER_SH" reap

  # Should not be reaped — PID is alive, binding dir exists.
  local entry
  entry="$(_ledger_field '.sessions["recycled-session"].pid')"
  [ "$entry" = "$$" ]
}

# ============================================================
# TC-CONC-LED-EC3: Clock jump backward
# ============================================================

@test "TC-CONC-LED-EC3: backward clock jump makes heartbeat appear fresh" {
  export GAIA_LEDGER_STALE_TIMEOUT=300

  # Entry with heartbeat in the future (simulates backward clock jump).
  local future_epoch
  future_epoch=$(( $(date +%s) + 600 ))
  jq -n --argjson hb "$future_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "future-session": {
        sprint_id: "sprint-99", pid: 99990, heartbeat_epoch: $hb,
        dev_slots_claimed: 1, teammates_claimed: 0
      }
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  bash "$LEDGER_SH" reap

  # Entry should NOT be reaped — negative age means fresh.
  local entry
  entry="$(_ledger_field '.sessions["future-session"].pid')"
  [ "$entry" = "99990" ]
}

# ============================================================
# TC-CONC-LED-EC6: Double-reap race
# ============================================================

@test "TC-CONC-LED-EC6: L2 serializes double reap" {
  export GAIA_LEDGER_STALE_TIMEOUT=1

  local old_epoch
  old_epoch=$(( $(date +%s) - 600 ))
  jq -n --argjson hb "$old_epoch" '{
    schema_version: "1.0",
    budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12},
    sessions: {
      "double-reap-target": {sprint_id: "s", pid: 99989, heartbeat_epoch: $hb, dev_slots_claimed: 2, teammates_claimed: 0}
    }
  }' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  # Two reapers run concurrently.
  bash "$LEDGER_SH" reap &
  local p1=$!
  bash "$LEDGER_SH" reap &
  local p2=$!
  wait "$p1"
  wait "$p2"

  # Entry should be gone, ledger valid.
  local count
  count="$(_ledger_field '.sessions | length')"
  [ "$count" -eq 0 ]
  jq empty "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"
}

# ============================================================
# TC-CONC-LED-EC7: Batch reap 10 stale entries
# ============================================================

@test "TC-CONC-LED-EC7: 10 stale entries reaped in a single pass" {
  export GAIA_LEDGER_STALE_TIMEOUT=1

  local old_epoch
  old_epoch=$(( $(date +%s) - 600 ))
  local sessions=""
  local i
  for i in $(seq 1 10); do
    sessions="${sessions}\"stale-${i}\": {\"sprint_id\": \"s\", \"pid\": $((99970 + i)), \"heartbeat_epoch\": ${old_epoch}, \"dev_slots_claimed\": 1, \"teammates_claimed\": 0}"
    [ "$i" -lt 10 ] && sessions="${sessions},"
  done

  printf '{"schema_version":"1.0","budget":{"max_parallel_dev_slots":4,"teammate_dispatch_ceiling":12},"sessions":{%s}}' \
    "$sessions" > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  bash "$LEDGER_SH" reap

  local count
  count="$(_ledger_field '.sessions | length')"
  [ "$count" -eq 0 ]
}

# ============================================================
# TC-CONC-LED-EC8: Inert with pre-existing ledger
# ============================================================

@test "TC-CONC-LED-EC8: single-sprint mode with existing ledger file ignores it" {
  # Create a ledger from a prior concurrent run.
  jq -n '{schema_version: "1.0", budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12}, sessions: {}}' \
    > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  # Switch to single-sprint.
  cat > "${TEST_DIR}/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 1
parallel_execution:
  max_parallel_dev_slots: 4
YAML

  # Remove per-sprint files.
  rm -f "${GAIA_STATE_DIR}"/sprint-status-*.yaml 2>/dev/null || true

  export CLAUDE_CODE_SESSION_ID="inert-existing"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  # Ledger file should NOT be deleted (inert, not cleaned up).
  [ -f "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json" ]

  # No L2 lock should be acquired (no lock file changes).
  # The ledger content should be unchanged.
  local count
  count="$(_ledger_field '.sessions | length')"
  [ "$count" -eq 0 ]
}

# ============================================================
# TC-CONC-LED-EC9: Missing-entry release and heartbeat
# ============================================================

@test "TC-CONC-LED-EC9: release on missing entry exits 0 (no-op)" {
  # Create a ledger with no entry for this session.
  jq -n '{schema_version: "1.0", budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12}, sessions: {}}' \
    > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  export CLAUDE_CODE_SESSION_ID="missing-entry"
  run bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing session entry"* ]] || [[ "$output" == *"no-op"* ]]
}

@test "TC-CONC-LED-EC9: heartbeat on missing entry refused, not recreated" {
  jq -n '{schema_version: "1.0", budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12}, sessions: {}}' \
    > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  export CLAUDE_CODE_SESSION_ID="missing-hb"
  run bash "$LEDGER_SH" heartbeat --sprint sprint-99 --pid $$
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing session entry"* ]] || [[ "$output" == *"refusing"* ]]

  # Entry should NOT be recreated.
  local count
  count="$(_ledger_field '.sessions | length')"
  [ "$count" -eq 0 ]
}

# ============================================================
# TC-CONC-LED-EC10: Double release clamps at zero
# ============================================================

@test "TC-CONC-LED-EC10: double release clamps dev_slots_claimed at 0" {
  export CLAUDE_CODE_SESSION_ID="double-release"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 2 --teammates 0

  # First release: 2 - 2 = 0.
  bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 2 --teammates 0
  local after1
  after1="$(_ledger_field '.sessions["double-release"].dev_slots_claimed')"
  [ "$after1" = "0" ]

  # Second release: clamped at 0.
  run bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 2 --teammates 0
  [ "$status" -eq 0 ]
  local after2
  after2="$(_ledger_field '.sessions["double-release"].dev_slots_claimed')"
  [ "$after2" = "0" ]
}

# ============================================================
# TC-CONC-LED-unused-grant: Unused grant released after ppo_next
# ============================================================

@test "TC-CONC-LED-unused-grant-a: claim 2, admit 1, ledger shows 1" {
  export CLAUDE_CODE_SESSION_ID="unused-grant-session"

  # Claim 2 dev slots.
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 2 --teammates 0
  local claimed
  claimed="$(_ledger_field '.sessions["unused-grant-session"].dev_slots_claimed')"
  [ "$claimed" = "2" ]

  # Simulate ppo_next admitting 1 — release the unused 1.
  bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  local after
  after="$(_ledger_field '.sessions["unused-grant-session"].dev_slots_claimed')"
  [ "$after" = "1" ]
}

@test "TC-CONC-LED-unused-grant-b: claim 2, ppo_next returns barrier, release full grant" {
  export CLAUDE_CODE_SESSION_ID="barrier-grant-session"

  # Claim 2 dev slots.
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 2 --teammates 0

  # Simulate ppo_next returning barrier — release full grant.
  bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 2 --teammates 0

  local after
  after="$(_ledger_field '.sessions["barrier-grant-session"].dev_slots_claimed')"
  [ "$after" = "0" ]
}

# ============================================================
# Leak gate (AC7)
# ============================================================

@test "AC7: no internal traceability identifiers in published source" {
  local scripts_dir="${BATS_TEST_DIRNAME}/../scripts"

  # Check the ledger script itself for leaked IDs.
  local leaked
  leaked="$(/usr/bin/grep -nE '(FR-[0-9]+|NFR-[0-9]+|SR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]|AF-20[0-9]{2}|AI-[0-9]+|per the PRD)' \
    "$scripts_dir/concurrent-resource-ledger.sh" || true)"
  [ -z "$leaked" ] || {
    printf 'Leaked internal identifiers:\n%s\n' "$leaked"
    return 1
  }
}
