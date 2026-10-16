#!/usr/bin/env bats
# concurrent-sprint-lock.bats — lock architecture tests.
#
# Covers: five independent non-nested locks, timeout exit 3, strict mode,
# lock constants, close-lock predicate, hardened mkdir, flock/fallback
# parity, trap chaining, back-compat, and edge cases.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."
  LOCK_LIB="${PLUGIN_ROOT}/scripts/lib/acquire-lock.sh"

  TEST_TMP="${BATS_TEST_TMPDIR}/lock-test-$$-${BATS_TEST_NUMBER}"
  mkdir -p "$TEST_TMP/.gaia/state"

  # Source the lock library carefully: restore set +u after sourcing
  # because bats internals depend on unset variable tolerance.
  source "$LOCK_LIB"
  set +u
}

teardown() {
  # Clean up any background processes.
  if [ -n "${_HOLDER_PID:-}" ] && kill -0 "$_HOLDER_PID" 2>/dev/null; then
    kill "$_HOLDER_PID" 2>/dev/null || true
    wait "$_HOLDER_PID" 2>/dev/null || true
  fi
  # Unset the identity hook in case a test set it.
  unset -f _al_identity_hook 2>/dev/null || true
  rm -rf "${TEST_TMP:-}" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────
# AC1: Five independent locks, at-most-one per operation
# ──────────────────────────────────────────────────────────────

@test "ac1 — five lock path constants defined and distinct" {
  [ -n "${GAIA_LOCK_L1_TEMPLATE:-}" ]
  [ -n "${GAIA_LOCK_L2_PATH:-}" ]
  [ -n "${GAIA_LOCK_L3_PATH:-}" ]
  [ -n "${GAIA_LOCK_L4_PATH:-}" ]
  [ -n "${GAIA_LOCK_L5_PATH:-}" ]

  local count
  count=$(printf '%s\n' "$GAIA_LOCK_L1_TEMPLATE" "$GAIA_LOCK_L2_PATH" "$GAIA_LOCK_L3_PATH" "$GAIA_LOCK_L4_PATH" "$GAIA_LOCK_L5_PATH" | sort -u | wc -l | tr -d ' ')
  [ "$count" -eq 5 ]
}

@test "ac1 — no nested acquire_lock in concurrent-sprint lock sites" {
  local files=(
    "${PLUGIN_ROOT}/scripts/sprint-state.sh"
    "${PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh"
    "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/merge.sh"
    "${PLUGIN_ROOT}/skills/gaia-sprint-close/scripts/close.sh"
  )
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    local nested
    nested=$(awk '
      /^\s*\(/ { depth++; lcount=0 }
      /acquire_lock/ && depth>0 { lcount++ }
      /^\s*\)/ { if(lcount>1) n++; depth--; lcount=0 }
      END { print n+0 }
    ' "$f")
    [ "$nested" -eq 0 ]
  done
}

@test "ac1 — no direct flock/ln in concurrent-sprint lock sites" {
  local files=(
    "${PLUGIN_ROOT}/scripts/sprint-state.sh"
    "${PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh"
    "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/merge.sh"
    "${PLUGIN_ROOT}/skills/gaia-sprint-close/scripts/close.sh"
  )
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    local raw_hits
    raw_hits=$({ /usr/bin/grep -n 'flock -' "$f" \
      | /usr/bin/grep -v '#.*flock' \
      | /usr/bin/grep -v '_FLOCK_BIN' \
      | /usr/bin/grep -v 'require_flock' \
      | /usr/bin/grep -v 'command -v' \
      | /usr/bin/grep -v "printf\|echo\|die\|'" \
      || true; } | wc -l | tr -d ' ')
    [ "$raw_hits" -eq 0 ] || {
      echo "Direct flock calls in $(basename "$f"): $raw_hits" >&2
      false
    }
  done
}

# ──────────────────────────────────────────────────────────────
# AC2: Timeout returns exit 3 with stderr diagnostic
# ──────────────────────────────────────────────────────────────

@test "ac2 — exit code constant is 3" {
  [ "${ACQUIRE_LOCK_EXIT_TIMEOUT:-}" = "3" ]
}

@test "ac2 — flock path returns exit 3 with diagnostic on timeout" {
  [ -z "${_ACQUIRE_LOCK_FLOCK_BIN:-}" ] && skip "flock not available"
  local lockpath="$TEST_TMP/.gaia/state/.test-timeout.lock"
  local ready="$TEST_TMP/timeout-flock-ready"

  cat > "$TEST_TMP/timeout-holder.sh" <<'SCRIPT'
#!/usr/bin/env bash
export GAIA_LOCK_FORCE_FALLBACK=0
source "$1"; set +u
acquire_lock "$2" 30 200
touch "$3"
exec sleep 30
SCRIPT
  chmod +x "$TEST_TMP/timeout-holder.sh"

  bash "$TEST_TMP/timeout-holder.sh" "$LOCK_LIB" "$lockpath" "$ready" &
  _HOLDER_PID=$!

  local waited=0
  while [ ! -f "$ready" ] && [ "$waited" -lt 10 ]; do
    sleep 0.2; waited=$((waited + 1))
  done
  [ -f "$ready" ]

  local stderr_out="$TEST_TMP/stderr"
  local rc=0
  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=0
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 2 201
  " 2>"$stderr_out" || rc=$?

  [ "$rc" -eq 3 ]
  /usr/bin/grep -q 'lock_timeout:' "$stderr_out"
  /usr/bin/grep -q 'after 2s' "$stderr_out"

  kill "$_HOLDER_PID" 2>/dev/null || true
  wait "$_HOLDER_PID" 2>/dev/null || true
  _HOLDER_PID=""
}

@test "ac2 — fallback path returns exit 3 with diagnostic on timeout" {
  local lockpath="$TEST_TMP/.gaia/state/.test-timeout-fb.lock"

  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 30 200
    exec sleep 30
  " &
  _HOLDER_PID=$!
  sleep 1

  local stderr_out="$TEST_TMP/stderr-fb"
  local rc=0
  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 2 201
  " 2>"$stderr_out" || rc=$?

  [ "$rc" -eq 3 ]
  /usr/bin/grep -q 'lock_timeout:' "$stderr_out"
  /usr/bin/grep -q 'after 2s' "$stderr_out"

  kill "$_HOLDER_PID" 2>/dev/null || true
  wait "$_HOLDER_PID" 2>/dev/null || true
  _HOLDER_PID=""
}

@test "ac2 — reconcile timeout aligned to 5s" {
  local sprint_state="${PLUGIN_ROOT}/scripts/sprint-state.sh"
  [ -f "$sprint_state" ] || skip "sprint-state.sh not found"

  local timeout_val
  timeout_val=$(sed -n '/cmd_reconcile()/,/^[a-z_]*cmd_/{
    /acquire_lock.*SPRINT_STATUS_LOCK/{ s/.*SPRINT_STATUS_LOCK"[[:space:]]*//; s/[[:space:]].*//; p; q; }
  }' "$sprint_state")
  [ "$timeout_val" = "5" ]
}

# ──────────────────────────────────────────────────────────────
# AC3: Strict mode
# ──────────────────────────────────────────────────────────────

@test "ac3 — strict mode refuses symlink with exit 4" {
  local lockpath="$TEST_TMP/.gaia/state/.concurrent-resource-ledger.lock"
  ln -sf /dev/null "$lockpath"

  local stderr_out="$TEST_TMP/stderr-strict-sym"
  local rc=0
  acquire_lock "$lockpath" 5 200 --strict 2>"$stderr_out" || rc=$?

  [ "$rc" -eq 4 ]
  /usr/bin/grep -q 'lock_symlink_detected:' "$stderr_out"
  [ -L "$lockpath" ]
}

@test "ac3 — strict mode refuses directory with exit 4" {
  local lockpath="$TEST_TMP/.gaia/state/.promotion-merge.lock"
  mkdir -p "$lockpath"

  local stderr_out="$TEST_TMP/stderr-strict-dir"
  local rc=0
  acquire_lock "$lockpath" 5 200 --strict 2>"$stderr_out" || rc=$?

  [ "$rc" -eq 4 ]
  /usr/bin/grep -q 'lock_symlink_detected:' "$stderr_out"
}

@test "ac3 — strict mode refuses fifo with exit 4 (bounded)" {
  local lockpath="$TEST_TMP/.gaia/state/.sprint-lifecycle-fifo.lock"
  mkfifo "$lockpath"

  local stderr_out="$TEST_TMP/stderr-strict-fifo"
  local marker="$TEST_TMP/fifo-done"
  # Run in background with a kill timer so a regression (fifo read hang)
  # fails the test instead of hanging CI.
  cat > "$TEST_TMP/fifo-test.sh" <<'SCRIPT'
#!/usr/bin/env bash
source "$1"; set +u
rc=0
acquire_lock "$2" 5 200 --strict 2>"$3" || rc=$?
echo "$rc" > "$4"
SCRIPT
  chmod +x "$TEST_TMP/fifo-test.sh"

  bash "$TEST_TMP/fifo-test.sh" "$LOCK_LIB" "$lockpath" "$stderr_out" "$marker" &
  local bg=$!
  local waited=0
  while kill -0 "$bg" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1; waited=$((waited + 1))
  done
  if kill -0 "$bg" 2>/dev/null; then
    kill "$bg" 2>/dev/null || true
    wait "$bg" 2>/dev/null || true
    echo "fifo test hung for ${waited}s — strict check did not fire" >&2
    false
  fi
  wait "$bg" 2>/dev/null || true

  [ -f "$marker" ]
  local rc; rc=$(cat "$marker")
  [ "$rc" = "4" ]
  /usr/bin/grep -q 'lock_symlink_detected:' "$stderr_out"
}

@test "ac3 — non-strict mode still unlinks symlinks (unchanged behavior)" {
  local lockpath="$TEST_TMP/.gaia/state/.test-compat.lock"
  ln -sf /dev/null "$lockpath"

  local rc=0
  acquire_lock "$lockpath" 5 200 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  [ ! -L "$lockpath" ]
  release_lock 200
}

@test "ac3 — exit constants correct" {
  [ "${ACQUIRE_LOCK_EXIT_SYMLINK:-}" = "4" ]
  [ "${ACQUIRE_LOCK_EXIT_IDENTITY:-}" = "5" ]
}

@test "ac3 — strict mode acquires successfully on a clean path (flock)" {
  [ -z "${_ACQUIRE_LOCK_FLOCK_BIN:-}" ] && skip "flock not available"
  local lockpath="$TEST_TMP/.gaia/state/.strict-success-flock.lock"

  local rc=0
  GAIA_LOCK_FORCE_FALLBACK=0 acquire_lock "$lockpath" 5 200 --strict 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  [ -n "$(_al_get_path 200)" ]
  release_lock 200
}

@test "ac3 — strict mode acquires successfully on a clean path (fallback)" {
  local lockpath="$TEST_TMP/.gaia/state/.strict-success-fb.lock"

  local rc=0
  GAIA_LOCK_FORCE_FALLBACK=1 acquire_lock "$lockpath" 5 200 --strict 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  [ -n "$(_al_get_path 200)" ]
  release_lock 200
}

# ──────────────────────────────────────────────────────────────
# AC4: Lock constants and close-lock predicate
# ──────────────────────────────────────────────────────────────

@test "ac4 — all constants match expected values" {
  [ "$GAIA_LOCK_L1_TEMPLATE" = "sprint-status-{sprint_id}.yaml.lock" ]
  [ "$GAIA_LOCK_L2_PATH" = ".concurrent-resource-ledger.lock" ]
  [ "$GAIA_LOCK_L3_PATH" = ".promotion-merge.lock" ]
  [ "$GAIA_LOCK_L4_PATH" = ".sprint-lifecycle.lock" ]
  [ "$GAIA_LOCK_L5_PATH" = ".sprint-proxy.lock" ]
  [ "$GAIA_LOCK_L1_TIMEOUT" = "5" ]
  [ "$GAIA_LOCK_L2_TIMEOUT" = "5" ]
  [ "$GAIA_LOCK_L3_TIMEOUT" = "120" ]
  [ "$GAIA_LOCK_L4_TIMEOUT" = "10" ]
  [ "$GAIA_LOCK_L5_TIMEOUT" = "2" ]
}

@test "ac4 — L3 timeout overridable via env" {
  GAIA_MERGE_LOCK_TIMEOUT=30 source "$LOCK_LIB"
  set +u
  [ "$GAIA_LOCK_L3_TIMEOUT" = "30" ]
  unset GAIA_MERGE_LOCK_TIMEOUT
  source "$LOCK_LIB"; set +u
}

@test "ac4 — predicate returns L4 when limit > 1" {
  local state_dir="$TEST_TMP/.gaia/state"
  local result
  result=$(acquire_lock_close_predicate 2 "$state_dir")
  /usr/bin/grep -q '.sprint-lifecycle.lock' <<< "$result"
  /usr/bin/grep -q '10' <<< "$result"
}

@test "ac4 — predicate returns L4 in transitional state" {
  local state_dir="$TEST_TMP/.gaia/state"
  touch "$state_dir/sprint-status-sprint-99.yaml"

  local result
  result=$(acquire_lock_close_predicate 1 "$state_dir")
  /usr/bin/grep -q '.sprint-lifecycle.lock' <<< "$result"

  result=$(acquire_lock_close_predicate "" "$state_dir")
  /usr/bin/grep -q '.sprint-lifecycle.lock' <<< "$result"
  rm -f "$state_dir/sprint-status-sprint-99.yaml"
}

@test "ac4 — predicate returns L1 in single-sprint mode" {
  local state_dir="$TEST_TMP/.gaia/state"
  rm -f "$state_dir"/sprint-status-*.yaml 2>/dev/null || true

  local result
  result=$(acquire_lock_close_predicate 1 "$state_dir")
  /usr/bin/grep -q 'sprint-status-{sprint_id}.yaml.lock' <<< "$result"
  /usr/bin/grep -q ' 5' <<< "$result"

  result=$(acquire_lock_close_predicate "" "$state_dir")
  /usr/bin/grep -q 'sprint-status-{sprint_id}.yaml.lock' <<< "$result"
}

# ──────────────────────────────────────────────────────────────
# AC5: Hardened mkdir -p
# ──────────────────────────────────────────────────────────────

@test "ac5 — mkdir failure produces diagnostic and non-zero exit" {
  local blocked_dir="$TEST_TMP/blocked"
  mkdir -p "$blocked_dir"
  chmod 000 "$blocked_dir"

  local lockpath="$blocked_dir/sub/.test.lock"
  local stderr_out="$TEST_TMP/stderr-mkdir"
  local rc=0
  acquire_lock "$lockpath" 5 200 2>"$stderr_out" || rc=$?
  chmod 755 "$blocked_dir"

  [ "$rc" -ne 0 ]
  /usr/bin/grep -qi 'cannot create lock directory' "$stderr_out"
}

@test "ac5 — mkdir succeeds when state dir is absent but creatable" {
  local state_dir="$TEST_TMP/fresh/.gaia/state"
  mkdir -p "$(dirname "$state_dir")"
  [ ! -d "$state_dir" ]

  local lockpath="$state_dir/.promotion-merge.lock"
  local rc=0
  acquire_lock "$lockpath" 5 200 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  [ -d "$state_dir" ]
  release_lock 200
}

# ──────────────────────────────────────────────────────────────
# AC6: flock and fallback parity under contention
# ──────────────────────────────────────────────────────────────

@test "ac6 — flock path serializes two concurrent processes" {
  [ -z "${_ACQUIRE_LOCK_FLOCK_BIN:-}" ] && skip "flock not available"
  local lockpath="$TEST_TMP/.gaia/state/.parity-flock.lock"
  local outfile="$TEST_TMP/parity-out-flock"
  local ready="$TEST_TMP/parity-flock-ready"
  : > "$outfile"

  # Holder acquires, signals readiness, holds, writes, releases.
  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=0
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 10 200
    touch '$ready'
    sleep 0.3
    printf 'A\n' >> '$outfile'
    release_lock 200
  " &
  local pid_a=$!

  # Contender waits for readiness then contends.
  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=0
    source '$LOCK_LIB'; set +u
    while [ ! -f '$ready' ]; do sleep 0.02; done
    acquire_lock '$lockpath' 10 201
    printf 'B\n' >> '$outfile'
    release_lock 201
  " &
  local pid_b=$!

  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  local count
  count=$(wc -l < "$outfile" | tr -d ' ')
  [ "$count" -eq 2 ]
  /usr/bin/grep -q '^A$' "$outfile"
  /usr/bin/grep -q '^B$' "$outfile"
}

@test "ac6 — fallback path serializes two concurrent processes" {
  local lockpath="$TEST_TMP/.gaia/state/.parity-fb.lock"
  local outfile="$TEST_TMP/parity-out-fb"
  local ready="$TEST_TMP/parity-fb-ready"
  : > "$outfile"

  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 10 200
    touch '$ready'
    sleep 0.3
    printf 'A\n' >> '$outfile'
    release_lock 200
  " &
  local pid_a=$!

  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$LOCK_LIB'; set +u
    while [ ! -f '$ready' ]; do sleep 0.02; done
    acquire_lock '$lockpath' 10 201
    printf 'B\n' >> '$outfile'
    release_lock 201
  " &
  local pid_b=$!

  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  local count
  count=$(wc -l < "$outfile" | tr -d ' ')
  [ "$count" -eq 2 ]
  /usr/bin/grep -q '^A$' "$outfile"
  /usr/bin/grep -q '^B$' "$outfile"
}

# ──────────────────────────────────────────────────────────────
# AC7: Trap-based cleanup chains with existing traps (behavioural)
# ──────────────────────────────────────────────────────────────

@test "ac7 — chained traps in sprint-state.sh include release_lock and _cleanup_tmps" {
  local sprint_state="${PLUGIN_ROOT}/scripts/sprint-state.sh"
  [ -f "$sprint_state" ] || skip "sprint-state.sh not found"

  local lock_traps
  lock_traps=$(/usr/bin/grep "trap 'release_lock" "$sprint_state" | /usr/bin/grep -c '_cleanup_tmps')
  [ "$lock_traps" -ge 21 ]
}

@test "ac7 — outer _cleanup_tmps trap not overwritten" {
  local sprint_state="${PLUGIN_ROOT}/scripts/sprint-state.sh"
  [ -f "$sprint_state" ] || skip "sprint-state.sh not found"
  /usr/bin/grep -q "^trap '_cleanup_tmps' EXIT INT TERM" "$sprint_state"
}

@test "ac7 — INT/TERM handlers have explicit exit" {
  local sprint_state="${PLUGIN_ROOT}/scripts/sprint-state.sh"
  [ -f "$sprint_state" ] || skip "sprint-state.sh not found"

  local int_no_exit
  int_no_exit=$(/usr/bin/grep "trap 'release_lock.*INT$" "$sprint_state" | /usr/bin/grep -cv 'exit' || true)
  [ "$int_no_exit" -eq 0 ]

  local term_no_exit
  term_no_exit=$(/usr/bin/grep "trap 'release_lock.*TERM$" "$sprint_state" | /usr/bin/grep -cv 'exit' || true)
  [ "$term_no_exit" -eq 0 ]
}

@test "ac7 — SIGTERM releases the lock on a real holder process" {
  [ -z "${_ACQUIRE_LOCK_FLOCK_BIN:-}" ] && skip "flock not available"
  local lockpath="$TEST_TMP/.gaia/state/.trap-term.lock"
  local released_marker="$TEST_TMP/trap-term-released"
  local cleanup_marker="$TEST_TMP/trap-term-cleanup"

  # The holder acquires a lock, installs a chained trap (like sprint-state),
  # then waits. We send it SIGTERM and verify the lock is released and
  # cleanup ran.
  cat > "$TEST_TMP/trap-holder.sh" <<'SCRIPT'
#!/usr/bin/env bash
source "$1"; set +u
lockpath="$2"
released="$3"
cleanup="$4"
my_cleanup() { touch "$cleanup"; }
acquire_lock "$lockpath" 10 200
trap 'release_lock 200; my_cleanup; exit 143' TERM
trap 'release_lock 200; my_cleanup' EXIT
# Signal readiness, then wait.
touch "$lockpath.ready"
while true; do sleep 1; done
SCRIPT
  chmod +x "$TEST_TMP/trap-holder.sh"

  bash "$TEST_TMP/trap-holder.sh" "$LOCK_LIB" "$lockpath" "$released_marker" "$cleanup_marker" &
  _HOLDER_PID=$!

  # Wait for readiness.
  local waited=0
  while [ ! -f "$lockpath.ready" ] && [ "$waited" -lt 5 ]; do
    sleep 0.2; waited=$((waited + 1))
  done
  [ -f "$lockpath.ready" ]

  # Send SIGTERM.
  kill -TERM "$_HOLDER_PID" 2>/dev/null || true
  wait "$_HOLDER_PID" 2>/dev/null || true
  _HOLDER_PID=""

  # Verify cleanup ran.
  [ -f "$cleanup_marker" ]

  # Verify the lock is released: a new acquirer succeeds immediately.
  local rc=0
  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=0
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 2 201
    release_lock 201
  " 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
}

@test "ac7 — SIGINT releases the lock on a real holder process" {
  [ -z "${_ACQUIRE_LOCK_FLOCK_BIN:-}" ] && skip "flock not available"
  local lockpath="$TEST_TMP/.gaia/state/.trap-int.lock"
  local cleanup_marker="$TEST_TMP/trap-int-cleanup"

  # Use a script that traps INT, signals readiness, then sleeps via read
  # (which is interruptible by INT, unlike `sleep` in some configurations).
  cat > "$TEST_TMP/trap-int-holder.sh" <<'SCRIPT'
#!/usr/bin/env bash
source "$1"; set +u
lockpath="$2"
cleanup="$3"
my_cleanup() { touch "$cleanup"; }
acquire_lock "$lockpath" 10 200
trap 'release_lock 200; my_cleanup; exit 130' INT
trap 'release_lock 200; my_cleanup' EXIT
touch "$lockpath.ready"
# read on a pipe that never closes — interruptible by signals.
read -r < /dev/stdin 2>/dev/null || true
SCRIPT
  chmod +x "$TEST_TMP/trap-int-holder.sh"

  # Feed stdin from a pipe that stays open until we close it.
  bash "$TEST_TMP/trap-int-holder.sh" "$LOCK_LIB" "$lockpath" "$cleanup_marker" < /dev/null &
  _HOLDER_PID=$!

  local waited=0
  while [ ! -f "$lockpath.ready" ] && [ "$waited" -lt 10 ]; do
    sleep 0.2; waited=$((waited + 1))
  done
  [ -f "$lockpath.ready" ]

  kill -INT "$_HOLDER_PID" 2>/dev/null || true
  # Give a moment for trap to fire.
  sleep 0.5
  wait "$_HOLDER_PID" 2>/dev/null || true
  _HOLDER_PID=""

  [ -f "$cleanup_marker" ]

  local rc=0
  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=0
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 2 201
    release_lock 201
  " 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────
# AC8: No internal traceability identifiers in published files
# ──────────────────────────────────────────────────────────────

@test "ac8 — no leaked IDs in published files" {
  local files=(
    "${PLUGIN_ROOT}/scripts/lib/acquire-lock.sh"
    "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/lib/acquire-lock.sh"
    "${PLUGIN_ROOT}/scripts/sprint-state.sh"
    "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/sprint-state.sh"
    "${PLUGIN_ROOT}/tests/concurrent-sprint-lock.bats"
  )

  local leak_re='FR-[0-9]+|NFR-[0-9]+|SR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-CONC-|AF-[0-9]{4}-[0-9]{2}-[0-9]{2}'

  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    local matches
    matches=$(/usr/bin/grep -cE "$leak_re" "$f" || true)
    local self_refs
    self_refs=$(/usr/bin/grep -cE "leak_re=|leak_pattern=" "$f" || true)
    local real=$(( matches - self_refs ))
    [ "$real" -le 0 ] || {
      echo "Leaked identifiers in $(basename "$f"):" >&2
      /usr/bin/grep -nE "$leak_re" "$f" | /usr/bin/grep -vE "leak_re=|leak_pattern=" >&2
      false
    }
  done
}

# ──────────────────────────────────────────────────────────────
# AC8 addendum: byte-identical mirrors
# ──────────────────────────────────────────────────────────────

@test "ac8 — acquire-lock.sh mirrors are byte-identical" {
  cmp "${PLUGIN_ROOT}/scripts/lib/acquire-lock.sh" \
      "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/lib/acquire-lock.sh"
}

@test "ac8 — sprint-state.sh mirrors are byte-identical" {
  cmp "${PLUGIN_ROOT}/scripts/sprint-state.sh" \
      "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/sprint-state.sh"
}

# ──────────────────────────────────────────────────────────────
# AC9: Single-sprint mode backward compatible
# ──────────────────────────────────────────────────────────────

@test "ac9 — basic lock acquire/release works without strict mode" {
  local lockpath="$TEST_TMP/.gaia/state/.test-compat-basic.lock"
  local rc=0
  acquire_lock "$lockpath" 5 200 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  release_lock 200
}

@test "ac9 — timeout exit 3 does not break callers that assert non-zero" {
  # Verify by actually triggering a timeout: the exit code is 3, which
  # satisfies every existing caller's `if ! acquire_lock` pattern.
  local lockpath="$TEST_TMP/.gaia/state/.compat-timeout.lock"

  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 30 200
    exec sleep 30
  " &
  _HOLDER_PID=$!
  sleep 1

  local rc=0
  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 1 201
  " 2>/dev/null || rc=$?

  # The pattern `if ! acquire_lock` treats any non-zero as failure.
  # Exit 3 is non-zero so the pattern still works.
  [ "$rc" -ne 0 ]
  [ "$rc" -eq 3 ]

  kill "$_HOLDER_PID" 2>/dev/null || true
  wait "$_HOLDER_PID" 2>/dev/null || true
  _HOLDER_PID=""
}

@test "ac9 — existing lock-helper bats exist and source the same lib" {
  local existing="${PLUGIN_ROOT}/tests/lock-helper.bats"
  [ -f "$existing" ]
  /usr/bin/grep -q 'acquire-lock.sh' "$existing"
}

# ──────────────────────────────────────────────────────────────
# AC-EC1: Lock directory auto-created when absent
# ──────────────────────────────────────────────────────────────

@test "acec1 — lock directory auto-created when .gaia/state/ absent" {
  local state_dir="$TEST_TMP/auto-create/.gaia/state"
  mkdir -p "$(dirname "$state_dir")"
  [ ! -d "$state_dir" ]

  local lockpath="$state_dir/.promotion-merge.lock"
  local rc=0
  acquire_lock "$lockpath" 5 200 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  [ -d "$state_dir" ]
  release_lock 200
}

# ──────────────────────────────────────────────────────────────
# AC-EC2: Strict-mode identity re-check detects swap (integration)
# ──────────────────────────────────────────────────────────────

@test "acec2 — _al_dev_ino detects different files" {
  local f1="$TEST_TMP/file1"
  local f2="$TEST_TMP/file2"
  echo "a" > "$f1"
  echo "b" > "$f2"

  local id1 id2
  id1=$(_al_dev_ino "$f1")
  id2=$(_al_dev_ino "$f2")
  [ "$id1" != "$id2" ]

  local id1b
  id1b=$(_al_dev_ino "$f1")
  [ "$id1" = "$id1b" ]
}

@test "acec2 — identity hook causes exit 5 with identity_unstable diagnostic" {
  [ -z "${_ACQUIRE_LOCK_FLOCK_BIN:-}" ] && skip "flock not available"
  local lockpath="$TEST_TMP/.gaia/state/.strict-hook.lock"
  local stderr_out="$TEST_TMP/stderr-hook"

  # Use the test-only hook to deterministically swap the lock file after
  # acquisition, simulating a concurrent replacement.
  cat > "$TEST_TMP/hook-acquirer.sh" <<'SCRIPT'
#!/usr/bin/env bash
source "$1"; set +u
lockpath="$2"
stderr_out="$3"
# Define the identity hook: on each call, replace the lock file so the
# identity re-check sees a different inode.
_al_identity_hook() {
  local lf="$1"
  rm -f "$lf" 2>/dev/null || true
  touch "$lf"
}
acquire_lock "$lockpath" 2 200 --strict 2>"$stderr_out"
SCRIPT
  chmod +x "$TEST_TMP/hook-acquirer.sh"

  local rc=0
  bash "$TEST_TMP/hook-acquirer.sh" "$LOCK_LIB" "$lockpath" "$stderr_out" || rc=$?

  [ "$rc" -eq 5 ]
  /usr/bin/grep -q 'lock_identity_unstable:' "$stderr_out"
  /usr/bin/grep -q 'identity re-check mismatch:' "$stderr_out"
}

# ──────────────────────────────────────────────────────────────
# AC-EC3: Permission-denied on fd open emits diagnostic
# ──────────────────────────────────────────────────────────────

@test "acec3 — mode 000 lock file produces diagnostic" {
  local lockpath="$TEST_TMP/.gaia/state/.test-perm.lock"
  touch "$lockpath"
  chmod 000 "$lockpath"

  local stderr_out="$TEST_TMP/stderr-perm"
  local rc=0
  acquire_lock "$lockpath" 5 200 2>"$stderr_out" || rc=$?
  chmod 644 "$lockpath" 2>/dev/null || true

  [ "$rc" -ne 0 ]
  local diag_size
  diag_size=$(wc -c < "$stderr_out" | tr -d ' ')
  [ "$diag_size" -gt 0 ]
}

@test "acec3 — unreadable parent triggers diagnostic" {
  local blocked_parent="$TEST_TMP/blocked-parent-ec3"
  mkdir -p "$blocked_parent/sub"
  chmod 000 "$blocked_parent"

  local lockpath="$blocked_parent/sub/.test.lock"
  local stderr_out="$TEST_TMP/stderr-perm-parent"
  local rc=0
  acquire_lock "$lockpath" 5 200 2>"$stderr_out" || rc=$?
  chmod 755 "$blocked_parent" 2>/dev/null || true

  [ "$rc" -ne 0 ]
  local diag_size
  diag_size=$(wc -c < "$stderr_out" | tr -d ' ')
  [ "$diag_size" -gt 0 ]
}

# ──────────────────────────────────────────────────────────────
# AC-EC4: Independent locks held simultaneously
# ──────────────────────────────────────────────────────────────

@test "acec4 — L1 and L4 held simultaneously without conflict" {
  local l1_path="$TEST_TMP/.gaia/state/sprint-status-sprint-42.yaml.lock"
  local l4_path="$TEST_TMP/.gaia/state/.sprint-lifecycle.lock"

  acquire_lock "$l1_path" 5 200
  acquire_lock "$l4_path" 5 201

  [ -n "$(_al_get_path 200)" ]
  [ -n "$(_al_get_path 201)" ]

  release_lock 200
  release_lock 201
}

# ──────────────────────────────────────────────────────────────
# AC-EC5: L3 timeout returns exit 3 with diagnostic
# ──────────────────────────────────────────────────────────────

@test "acec5 — L3 timeout returns exit 3" {
  [ -z "${_ACQUIRE_LOCK_FLOCK_BIN:-}" ] && skip "flock not available"
  local lockpath="$TEST_TMP/.gaia/state/.promotion-merge.lock"

  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=0
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 60 200
    exec sleep 30
  " &
  _HOLDER_PID=$!
  sleep 1

  local stderr_out="$TEST_TMP/stderr-l3"
  local rc=0
  bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=0
    source '$LOCK_LIB'; set +u
    acquire_lock '$lockpath' 2 201
  " 2>"$stderr_out" || rc=$?

  [ "$rc" -eq 3 ]
  /usr/bin/grep -q 'lock_timeout:' "$stderr_out"
  /usr/bin/grep -q '.promotion-merge.lock' "$stderr_out"

  kill "$_HOLDER_PID" 2>/dev/null || true
  wait "$_HOLDER_PID" 2>/dev/null || true
  _HOLDER_PID=""
}

# ──────────────────────────────────────────────────────────────
# AC-EC6: Mixed fallback mode — verify all contention tests use same value
# ──────────────────────────────────────────────────────────────

@test "acec6 — all contention tests use consistent fallback mode per sub-case" {
  # Scan this file for contention test functions that set GAIA_LOCK_FORCE_FALLBACK.
  # In each test, every assignment must use the same value (0 or 1).
  local this_file="${BATS_TEST_FILENAME}"
  [ -f "$this_file" ] || skip "cannot read test file"

  # Extract test blocks that contain GAIA_LOCK_FORCE_FALLBACK assignments.
  # Check that within each @test block, all assignments use the same value.
  local violations=""
  local current_test="" vals=""
  while IFS= read -r line; do
    case "$line" in
      *'@test '*) current_test="$line"; vals="" ;;
      *GAIA_LOCK_FORCE_FALLBACK=*)
        local v="${line##*GAIA_LOCK_FORCE_FALLBACK=}"
        v="${v%%[^01]*}"
        if [ -n "$vals" ] && [ "$vals" != "$v" ]; then
          violations="${violations}MIXED: $current_test (saw $vals and $v)
"
        fi
        vals="$v"
        ;;
    esac
  done < "$this_file"

  [ -z "$violations" ] || {
    echo "$violations" >&2
    false
  }
}

# ──────────────────────────────────────────────────────────────
# AC-EC7: Recycled inode on different device detected by dev:ino
# ──────────────────────────────────────────────────────────────

@test "acec7 — _al_dev_ino returns dev:ino format" {
  local testfile="$TEST_TMP/devino-test"
  echo "test" > "$testfile"
  local result
  result=$(_al_dev_ino "$testfile")
  /usr/bin/grep -qE '^[0-9]+:[0-9]+$' <<< "$result"
}

@test "acec7 — dev:ino works on this platform" {
  local testfile="$TEST_TMP/devino-platform"
  echo "test" > "$testfile"
  local result
  result=$(_al_dev_ino "$testfile")
  [ -n "$result" ]
  /usr/bin/grep -q ':' <<< "$result"
}

# ──────────────────────────────────────────────────────────────
# AC-EC8: SIGTERM before trap — flock auto-releases on fd close
# ──────────────────────────────────────────────────────────────

@test "acec8 — flock auto-releases on process death, new acquirer succeeds" {
  [ -z "${_ACQUIRE_LOCK_FLOCK_BIN:-}" ] && skip "flock not available"
  local lockpath="$TEST_TMP/.gaia/state/.test-sigterm.lock"
  local marker="$TEST_TMP/acec8-marker"

  cat > "$TEST_TMP/holder.sh" <<'SCRIPT'
#!/usr/bin/env bash
export GAIA_LOCK_FORCE_FALLBACK=0
source "$1"; set +u
acquire_lock "$2" 10 200
exec sleep 30
SCRIPT
  chmod +x "$TEST_TMP/holder.sh"

  cat > "$TEST_TMP/acquirer.sh" <<'SCRIPT'
#!/usr/bin/env bash
export GAIA_LOCK_FORCE_FALLBACK=0
source "$1"; set +u
if acquire_lock "$2" 3 201; then
  touch "$3"
  release_lock 201
fi
SCRIPT
  chmod +x "$TEST_TMP/acquirer.sh"

  bash "$TEST_TMP/holder.sh" "$LOCK_LIB" "$lockpath" &
  local holder_pid=$!
  sleep 1

  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  bash "$TEST_TMP/acquirer.sh" "$LOCK_LIB" "$lockpath" "$marker" 2>/dev/null
  [ -f "$marker" ]
}
