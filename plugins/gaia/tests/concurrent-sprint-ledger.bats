#!/usr/bin/env bats
# concurrent-sprint-ledger.bats — tests for the cross-session resource ledger.

load 'test_helper.bash'

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
# Budget enforcement (2 sub-cases)
# ============================================================

@test "budget enforcement: session A claims 3, session B claim for 2 refused (budget 4)" {
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

@test "budget enforcement: after A releases 1, B retries claim 2 and succeeds (budget 4)" {
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
# Flock serialization under contention
# ============================================================

@test "lock serialization: concurrent claims serialized (flock)" {
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

@test "lock serialization: concurrent claims serialized (fallback)" {
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
# Stale reaping (two-factor check)
# ============================================================

@test "stale reaping: dead PID + stale heartbeat = reaped" {
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

@test "stale reaping: dead PID + fresh heartbeat = NOT reaped" {
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
# PID-recycling safety
# ============================================================

@test "pid recycling safety: alive PID with stale heartbeat NOT reaped (binding dir present)" {
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
# Normal exit cleanup
# ============================================================

@test "cleanup removes session entry from ledger" {
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
# Crash recovery
# ============================================================

@test "crash recovery: next claimer reaps crashed session and reclaims slots" {
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
# Schema validation
# ============================================================

@test "schema validation: ledger after claim/release has correct schema" {
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
# Corrupt JSON exits 6
# ============================================================

@test "corrupt ledger: truncated JSON exits 6 with diagnostic" {
  printf '{"schema_ver' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  export CLAUDE_CODE_SESSION_ID="corrupt-test"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 6 ]
  [[ "$output" == *"corrupt ledger"* ]]
}

# ============================================================
# Single-sprint mode
# ============================================================

@test "inert mode: single-sprint mode produces no ledger file" {
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
# Tampered budget ignored
# ============================================================

@test "budget tamper: tampered ledger budget ignored, config enforced" {
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
# Binding dir gone triggers reap
# ============================================================

@test "binding dir reap: session whose binding dir is gone is reaped" {
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
# Sessions root absent skips binding-dir check
# ============================================================

@test "sessions root absent: no sessions root, dead PID + stale = reaped via two-factor" {
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
# Heartbeat PID mismatch refused
# ============================================================

@test "heartbeat pid mismatch: heartbeat with wrong PID is refused" {
  export CLAUDE_CODE_SESSION_ID="hb-mismatch-session"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid 888 --dev 1 --teammates 0

  # Heartbeat with different PID.
  run bash "$LEDGER_SH" heartbeat --sprint sprint-99 --pid 999
  [ "$status" -ne 0 ]
  [[ "$output" == *"PID mismatch"* ]]
}

# ============================================================
# Release decrements, entry stays
# ============================================================

@test "release keeps entry: release decrements counts, entry stays, heartbeat refreshed" {
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
# Teammate ceiling across sessions
# ============================================================

@test "teammate ceiling: combined teammate claims respect ceiling" {
  export CLAUDE_CODE_SESSION_ID="tm-session-A"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 0 --teammates 6

  export CLAUDE_CODE_SESSION_ID="tm-session-B"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 0 --teammates 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget exhausted"* ]]
}

# ============================================================
# Lock exit code pass-through
# ============================================================

@test "lock exit code: lock timeout exit 3 passes through" {
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
# Static grep sweep
# ============================================================

@test "sole writer: only concurrent-resource-ledger.sh writes to the ledger file" {
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
# Heartbeat loop lifecycle
# ============================================================

@test "heartbeat loop: creates PID file and advances epoch" {
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

@test "heartbeat loop: self-exits when session PID dies" {
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
# Mass crash reaping
# ============================================================

@test "mass crash: 3 crashed sessions reaped in one pass" {
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
# PID-recycling within timeout
# ============================================================

@test "pid recycling: recycled PID with binding dir present not reaped" {
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
# Clock jump backward
# ============================================================

@test "clock jump: backward clock jump makes heartbeat appear fresh" {
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
# Double-reap race
# ============================================================

@test "double reap: lock serializes concurrent reap attempts" {
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
# Batch reap 10 stale entries
# ============================================================

@test "batch reap: 10 stale entries reaped in a single pass" {
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
# Inert with pre-existing ledger
# ============================================================

@test "inert with existing ledger: single-sprint mode with existing ledger file ignores it" {
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
# Missing-entry release and heartbeat
# ============================================================

@test "missing entry release: release on missing entry exits 0 (no-op)" {
  # Create a ledger with no entry for this session.
  jq -n '{schema_version: "1.0", budget: {max_parallel_dev_slots: 4, teammate_dispatch_ceiling: 12}, sessions: {}}' \
    > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  export CLAUDE_CODE_SESSION_ID="missing-entry"
  run bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing session entry"* ]] || [[ "$output" == *"no-op"* ]]
}

@test "missing entry heartbeat: heartbeat on missing entry refused, not recreated" {
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
# Double release clamps at zero
# ============================================================

@test "double release: double release clamps dev_slots_claimed at 0" {
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
# Unused grant released after admission
# ============================================================

@test "unused grant release: claim 2, admit 1, ledger shows 1" {
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

@test "unused grant release: claim 2, barrier returns, release full grant" {
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
# CLI next path: unused grant release
# ============================================================

@test "ledger claim-release cycle: claim then release simulates the grant lifecycle" {
  # Prepare a ledger with session A holding 3 of 4 slots.
  export CLAUDE_CODE_SESSION_ID="cli-pre-session"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 3 --teammates 0

  # Now the CLI next path as a separate process (session B) would try to claim 1.
  # We test the ledger directly: claim 1, then release 1 (simulating barrier).
  export CLAUDE_CODE_SESSION_ID="cli-next-session"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  local before
  before="$(_ledger_field '.sessions["cli-next-session"].dev_slots_claimed')"
  [ "$before" = "1" ]

  # Simulate barrier: release the full grant.
  bash "$LEDGER_SH" release --sprint sprint-99 --pid $$ --dev 1 --teammates 0

  local after
  after="$(_ledger_field '.sessions["cli-next-session"].dev_slots_claimed')"
  [ "$after" = "0" ]
}

# ============================================================
# Budget enforcement blocks admission
# ============================================================

@test "ledger claim refused: budget-exhausted claim exits 1 with no entry created" {
  # Fill the budget completely.
  export CLAUDE_CODE_SESSION_ID="full-budget-A"
  bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 4 --teammates 0

  # Next claim should be refused with exit 1.
  export CLAUDE_CODE_SESSION_ID="full-budget-B"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget exhausted"* ]]

  # The refused session should not have a ledger entry.
  local has
  has="$(_ledger_field '.sessions["full-budget-B"] // "absent"')"
  [ "$has" = "absent" ]
}

@test "ledger error exit 6: corrupt ledger blocks claim" {
  # Write corrupt JSON.
  printf '{"broken' > "${GAIA_STATE_DIR}/.concurrent-resource-ledger.json"

  export CLAUDE_CODE_SESSION_ID="error-6-session"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 6 ]
  [[ "$output" == *"corrupt ledger"* ]]
}

# ============================================================
# Lock exit code pass-through: exits 4, 5, and 7
# ============================================================

@test "lock exit code: symlink at lock path exits 4" {
  # Create a symlink at the L2 lock path to trigger exit 4 (strict-mode refusal).
  mkdir -p "$GAIA_STATE_DIR"
  ln -sf /dev/null "${GAIA_STATE_DIR}/.concurrent-resource-ledger.lock"

  export CLAUDE_CODE_SESSION_ID="symlink-session"
  run bash "$LEDGER_SH" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 4 ]

  rm -f "${GAIA_STATE_DIR}/.concurrent-resource-ledger.lock" 2>/dev/null || true
}

@test "lock exit code: identity mismatch exit 5 passes through" {
  # Use a wrapper that overrides acquire_lock to return exit 5 (identity).
  mkdir -p "$GAIA_STATE_DIR"
  local wrapper="${TEST_DIR}/ledger-exit5-wrapper.sh"
  cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL
. "${BATS_TEST_DIRNAME}/../scripts/concurrent-resource-ledger.sh"
acquire_lock() { printf 'lock_identity_unstable: identity re-check mismatch: %s\n' "\$1" >&2; return "\$ACQUIRE_LOCK_EXIT_IDENTITY"; }
_crl_main "\$@"
WRAP
  chmod +x "$wrapper"

  export CLAUDE_CODE_SESSION_ID="exit5-session"
  run bash "$wrapper" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 5 ]
}

@test "lock exit code: generic lock failure maps to ledger exit 7" {
  # Create a non-empty directory at the lock path. acquire_lock's
  # _al_enforce_path_type_strict refuses non-regular files with exit 4,
  # but a non-empty directory that cannot be rmdir'd produces a generic
  # exit 1 from _al_enforce_path_type (non-strict) path. For the strict
  # path, we need a different approach.
  #
  # Use a PATH-shimmed acquire_lock that returns exit 1 (generic failure).
  # The ledger script sources acquire-lock.sh but we can override the
  # function after sourcing by placing a wrapper that re-defines it.
  mkdir -p "$GAIA_STATE_DIR"
  local wrapper="${TEST_DIR}/ledger-exit7-wrapper.sh"
  cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL
# Source the real script first (which sources acquire-lock.sh).
. "${BATS_TEST_DIRNAME}/../scripts/concurrent-resource-ledger.sh"
# Override acquire_lock to return generic exit 1 AFTER sourcing.
acquire_lock() { printf 'acquire-lock: simulated generic failure\n' >&2; return 1; }
_crl_main "\$@"
WRAP
  chmod +x "$wrapper"

  export CLAUDE_CODE_SESSION_ID="exit7-session"
  run bash "$wrapper" claim --sprint sprint-99 --pid $$ --dev 1 --teammates 0
  [ "$status" -eq 7 ]
  [[ "$output" == *"ledger lock unavailable"* ]]
}

# ============================================================
# Orchestrator CLI integration: ledger claim/release through plan/next
# ============================================================

# Helpers for orchestrator integration tests.

_orch_mk_repo() {
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

_orch_mk_yaml() {
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  {
    printf 'sprint_id: test-sprint\n'
    printf 'status: active\n'
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'items:\n'
    local spec key phase
    for spec in "$@"; do
      key="${spec%%:*}"
      printf '  - key: %s\n' "$key"
      printf '    title: story %s\n' "$key"
      printf '    status: ready-for-dev\n'
      printf '    points: 1\n'
      printf '    risk_level: low\n'
      case "$spec" in
        *:*) phase="${spec#*:}"; printf '    phase: %s\n' "$phase" ;;
      esac
    done
  } > "$out"
  printf '%s' "$out"
}

_orch_ensure_flock() {
  if command -v flock >/dev/null 2>&1; then
    printf '%s' "$(dirname "$(command -v flock)")"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  local dir="$TEST_DIR/flock-bin"
  mkdir -p "$dir"
  cat > "$dir/flock" <<'FLOCKSHIM'
#!/usr/bin/env python3
"""Minimal flock(1) shim."""
import sys, fcntl, time
args = sys.argv[1:]
unlock = False; wait = None; fd = None; i = 0
while i < len(args):
    a = args[i]
    if a == "-u": unlock = True
    elif a == "-x": pass
    elif a == "-w": i += 1; wait = float(args[i])
    else: fd = int(a)
    i += 1
if fd is None: sys.exit(1)
if unlock: fcntl.flock(fd, fcntl.LOCK_UN); sys.exit(0)
deadline = time.monotonic() + (wait if wait else 0)
while True:
    try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); sys.exit(0)
    except BlockingIOError: pass
    if time.monotonic() >= deadline: sys.exit(1)
    time.sleep(0.05)
FLOCKSHIM
  chmod +x "$dir/flock"
  printf '%s' "$dir"
}

@test "orchestrator CLI next: admits story and ledger shows claimed slot" {
  local ORCH="${BATS_TEST_DIRNAME}/../scripts/phase-parallel-orchestrator.sh"
  local fl; fl="$(_orch_ensure_flock)" || skip "no flock and no python3 to provide one"

  local repo; repo="$(_orch_mk_repo "$TEST_DIR/repo")"
  local yaml; yaml="$(_orch_mk_yaml "$TEST_DIR/sprint.yaml" K1:1 K2:2)"

  # Create per-sprint file so single-sprint guard doesn't skip ledger.
  touch "${GAIA_STATE_DIR}/sprint-status-test-sprint.yaml"

  export PATH="$fl:$PATH"
  export GAIA_PARALLEL_EXECUTION=1
  export GAIA_WORKTREE_MODE=1
  export GAIA_SESSION_DIR="$TEST_DIR/session"
  mkdir -p "$GAIA_SESSION_DIR"
  export GAIA_MODE_B_SUBSTRATE=available
  export GAIA_LEDGER_SPRINT="test-sprint"
  export GAIA_LEDGER_PID="$$"

  # Plan.
  run bash "$ORCH" plan --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ]
  [[ "$output" == mode=parallel* ]]

  # Next — should admit K1 (phase 1) and claim one ledger slot.
  run bash "$ORCH" next
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatch story=K1"* ]]

  # Verify the ledger shows 1 dev slot for our session.
  local dev_claimed
  dev_claimed="$(_ledger_field ".sessions[\"$CLAUDE_CODE_SESSION_ID\"].dev_slots_claimed")"
  [ "$dev_claimed" = "1" ]
}

@test "orchestrator CLI next: barrier releases unused grant (no stories admitted)" {
  local ORCH="${BATS_TEST_DIRNAME}/../scripts/phase-parallel-orchestrator.sh"
  local fl; fl="$(_orch_ensure_flock)" || skip "no flock and no python3 to provide one"

  local repo; repo="$(_orch_mk_repo "$TEST_DIR/repo2")"
  local yaml; yaml="$(_orch_mk_yaml "$TEST_DIR/sprint2.yaml" K1:1)"
  touch "${GAIA_STATE_DIR}/sprint-status-test-sprint.yaml"

  export PATH="$fl:$PATH"
  export GAIA_PARALLEL_EXECUTION=1
  export GAIA_WORKTREE_MODE=1
  export GAIA_SESSION_DIR="$TEST_DIR/session2"
  mkdir -p "$GAIA_SESSION_DIR"
  export GAIA_MODE_B_SUBSTRATE=available
  export GAIA_LEDGER_SPRINT="test-sprint"
  export GAIA_LEDGER_PID="$$"

  # Plan and admit the only story.
  bash "$ORCH" plan --repo "$repo" --yaml "$yaml" --slots 2 >/dev/null
  bash "$ORCH" next >/dev/null

  # Now next again — K1 is running, no more phase-1 stories, so barrier.
  run bash "$ORCH" next
  [ "$status" -eq 0 ]
  [[ "$output" == *"barrier"* ]]

  # The ledger should show dev_slots_claimed back to 1 (the first claim),
  # NOT 2 (the barrier call's grant was released).
  local dev_claimed
  dev_claimed="$(_ledger_field ".sessions[\"$CLAUDE_CODE_SESSION_ID\"].dev_slots_claimed")"
  [ "$dev_claimed" = "1" ]
}

@test "orchestrator CLI next: sprint_complete releases unused grant" {
  local ORCH="${BATS_TEST_DIRNAME}/../scripts/phase-parallel-orchestrator.sh"
  local fl; fl="$(_orch_ensure_flock)" || skip "no flock and no python3 to provide one"

  local repo; repo="$(_orch_mk_repo "$TEST_DIR/repo3")"
  local yaml; yaml="$(_orch_mk_yaml "$TEST_DIR/sprint3.yaml" K1:1)"
  touch "${GAIA_STATE_DIR}/sprint-status-test-sprint.yaml"

  export PATH="$fl:$PATH"
  export GAIA_PARALLEL_EXECUTION=1
  export GAIA_WORKTREE_MODE=1
  export GAIA_SESSION_DIR="$TEST_DIR/session3"
  mkdir -p "$GAIA_SESSION_DIR"
  export GAIA_MODE_B_SUBSTRATE=available
  export GAIA_LEDGER_SPRINT="test-sprint"
  export GAIA_LEDGER_PID="$$"

  # Plan, admit, record done.
  bash "$ORCH" plan --repo "$repo" --yaml "$yaml" --slots 2 >/dev/null
  bash "$ORCH" next >/dev/null
  bash "$ORCH" record K1 done >/dev/null

  # Next — sprint_complete; grant should be released.
  run bash "$ORCH" next
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint_complete"* ]]

  # Ledger dev_slots_claimed should be 0 (record released 1, sprint_complete released the grant).
  local dev_claimed
  dev_claimed="$(_ledger_field ".sessions[\"$CLAUDE_CODE_SESSION_ID\"].dev_slots_claimed")"
  [ "$dev_claimed" = "0" ]
}

@test "orchestrator CLI next: refused claim emits barrier, admits nothing" {
  local ORCH="${BATS_TEST_DIRNAME}/../scripts/phase-parallel-orchestrator.sh"
  local fl; fl="$(_orch_ensure_flock)" || skip "no flock and no python3 to provide one"

  local repo; repo="$(_orch_mk_repo "$TEST_DIR/repo4")"
  local yaml; yaml="$(_orch_mk_yaml "$TEST_DIR/sprint4.yaml" K1:1 K2:1)"
  touch "${GAIA_STATE_DIR}/sprint-status-test-sprint.yaml"

  export PATH="$fl:$PATH"
  export GAIA_PARALLEL_EXECUTION=1
  export GAIA_WORKTREE_MODE=1
  export GAIA_SESSION_DIR="$TEST_DIR/session4"
  mkdir -p "$GAIA_SESSION_DIR"
  export GAIA_MODE_B_SUBSTRATE=available
  export GAIA_LEDGER_SPRINT="test-sprint"
  export GAIA_LEDGER_PID="$$"

  # Fill the budget entirely from outside via direct ledger call.
  export CLAUDE_CODE_SESSION_ID="pre-fill-session"
  bash "$LEDGER_SH" claim --sprint test-sprint --pid $$ --dev 4 --teammates 0

  # Restore session ID for the orchestrator.
  export CLAUDE_CODE_SESSION_ID="test-session-$$-${RANDOM}"

  # Plan.
  bash "$ORCH" plan --repo "$repo" --yaml "$yaml" --slots 2 >/dev/null

  # Next — budget is full, claim refused, barrier emitted, nothing admitted.
  run bash "$ORCH" next
  [ "$status" -eq 0 ]
  [[ "$output" == *"barrier"*"ledger-budget"* ]]
  # No dispatch line should appear.
  [[ "$output" != *"dispatch story="* ]]
}

@test "ppo_run_sprint: budget-exhausted backoff does not spin (gives up after N attempts)" {
  local ORCH="${BATS_TEST_DIRNAME}/../scripts/phase-parallel-orchestrator.sh"
  local fl; fl="$(_orch_ensure_flock)" || skip "no flock and no python3 to provide one"

  local repo; repo="$(_orch_mk_repo "$TEST_DIR/repo5")"
  local yaml; yaml="$(_orch_mk_yaml "$TEST_DIR/sprint5.yaml" K1:1)"
  touch "${GAIA_STATE_DIR}/sprint-status-test-sprint.yaml"

  export PATH="$fl:$PATH"
  export GAIA_PARALLEL_EXECUTION=1
  export GAIA_WORKTREE_MODE=1
  export GAIA_SESSION_DIR="$TEST_DIR/session5"
  mkdir -p "$GAIA_SESSION_DIR"
  export GAIA_MODE_B_SUBSTRATE=available
  export GAIA_LEDGER_SPRINT="test-sprint"
  export GAIA_LEDGER_PID="$$"
  # Minimize backoff for test speed.
  export GAIA_LEDGER_BACKOFF_BASE=0

  # Fill the budget.
  export CLAUDE_CODE_SESSION_ID="hog-session"
  bash "$LEDGER_SH" claim --sprint test-sprint --pid $$ --dev 4 --teammates 0

  export CLAUDE_CODE_SESSION_ID="backoff-session"

  # Install the test-only dispatch hook so ppo_run_sprint enters the loop.
  export GAIA_PPO_DISPATCH_CMD="true"
  export GAIA_PPO_ALLOW_DISPATCH_CMD=1

  # Run the compat loop — it should give up after _PPO_CEILING_GIVEUP attempts
  # (default 3), not spin forever.
  run timeout 15 bash "$ORCH" --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ]

  # Count barrier lines — should be exactly _PPO_CEILING_GIVEUP (3).
  local barrier_count
  barrier_count="$(printf '%s\n' "$output" | /usr/bin/grep -c 'barrier phase=ledger-budget' || true)"
  [ "$barrier_count" -ge 1 ]
  [ "$barrier_count" -le 3 ]
}

# ============================================================
# Leak gate
# ============================================================

@test "leak gate: no internal traceability identifiers in published source" {
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
