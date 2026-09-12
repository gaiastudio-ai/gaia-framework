#!/usr/bin/env bats

# phase-parallel-orchestrator.bats — slot-based phase-parallel sprint execution.
#
# Covers slot fill and backfill, the phase barrier, failure isolation, the
# admission chain and every degradation reason, ceiling saturation, worktree
# isolation and resume, the stall budget, and telemetry.
#
# Fixtures are real: throwaway git repositories, the REAL worktree and locking
# libraries, and real sprint yaml written by the state writer. The only stub is
# the agent substrate -- a dispatch shim honouring the library's documented exit
# codes (0 handle, 7 fallback, 8 ceiling) -- because a background agent cannot
# run inside bats. The classification logic under test is never stubbed: for a
# gate whose point is catching failures, a mocked dispatcher asserts nothing.
#
# This suite manipulates a shared registry directory and deliberately exercises
# concurrency, so it must not be run with parallel jobs.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  ORCH="$PLUGIN_ROOT/scripts/phase-parallel-orchestrator.sh"
  WT_LIB="$PLUGIN_ROOT/scripts/lib/story-worktree.sh"
  LOCK_LIB="$PLUGIN_ROOT/scripts/lib/acquire-lock.sh"
  DT_LIB="$PLUGIN_ROOT/scripts/lib/dispatch-teammate.sh"

  # Parallel execution is opt-in on both axes; individual tests unset these to
  # drive the degradation paths.
  export GAIA_PARALLEL_EXECUTION=1
  export GAIA_WORKTREE_MODE=1
  export GAIA_SESSION_DIR="$TEST_TMP/session"
  mkdir -p "$GAIA_SESSION_DIR"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

_source_orch() {
  [ -f "$ORCH" ] || return 1
  # shellcheck disable=SC1090
  . "$ORCH"
}

# _mk_repo <dir> — a real repo with one commit, a remote, and ignored paths.
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

# _mk_yaml <path> <phase_spec...> — real sprint yaml. Each spec is KEY:PHASE,
# or KEY alone to write a row carrying no phase field at all.
_mk_yaml() {
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

# _ensure_flock — put a REAL flock(2)-backed binary first on PATH.
#
# Parallel mode is fail-closed on the locking primitive, and macOS ships no
# flock(1), so on such a host every parallel assertion would otherwise degrade
# to sequential and prove nothing about scheduling. Skipping instead would hide
# the entire parallel path on the developer platform. This shim goes straight to
# the real fcntl.flock(2) syscall, so the exclusion it provides is genuine kernel
# locking -- it substitutes for a MISSING BINARY, never for the behaviour under
# test. Echoes the directory to prepend; returns 1 if no interpreter is around.
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
"""Minimal flock(1) over the real flock(2) syscall: -x -w <sec> <fd> and -u <fd>."""
import sys, fcntl, time

args = sys.argv[1:]
unlock = False
wait = None
fd = None
i = 0
while i < len(args):
    a = args[i]
    if a == "-u":
        unlock = True
    elif a == "-x":
        pass
    elif a == "-w":
        i += 1
        wait = float(args[i])
    elif a.lstrip("-").isdigit():
        fd = int(a.lstrip("-")) if not a.startswith("-") else int(a)
    i += 1
if fd is None:
    sys.exit(2)
try:
    if unlock:
        fcntl.flock(fd, fcntl.LOCK_UN)
        sys.exit(0)
    deadline = time.time() + (wait if wait is not None else 0)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sys.exit(0)
        except OSError:
            if wait is None or time.time() >= deadline:
                sys.exit(1)
            time.sleep(0.02)
except OSError:
    sys.exit(1)
FLOCKSHIM
  chmod +x "$dir/flock"
  printf '%s' "$dir"
}

# _mk_dispatch_stub <dir> <mode> — a dispatch shim on PATH honouring the real
# exit-code contract. Modes: ok | ceiling:<n> (exit 8 for the first n attempts,
# then 0) | fallback (exit 7 with the machine-readable record) | fail:<KEY> |
# stall:<KEY> | ceiling-always (exit 8 on every attempt) | error (an
# unclassified non-contract status).
#
# GAIA_STUB_MERGED_NOT_DONE names a story whose run succeeds but whose gate is
# still open: the shim records it so the orchestrator must treat the story as
# non-terminal rather than backfilling its slot.
_mk_dispatch_stub() {
  local dir="$1" mode="$2"
  mkdir -p "$dir"
  cat > "$dir/gaia-dispatch-story" <<STUB
#!/usr/bin/env bash
set -uo pipefail
key="\${1:-}"
mode="$mode"
GAIA_DT_LIB="${GAIA_DT_LIB:-$PLUGIN_ROOT/scripts/lib/dispatch-teammate.sh}"
counter="\${GAIA_STUB_STATE:-$TEST_TMP/stubstate}"
mkdir -p "\$counter"
# Millisecond stamps: at 1-second granularity two genuinely overlapping
# stories can look adjacent, and two adjacent ones can look overlapping.
_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    printf '%s000' "\$(date +%s)"
  fi
}
printf '%s %s\n' "\$key" "\$(date +%s)" >> "\$counter/dispatch-times.log"
printf '%s start %s\n' "\$key" "\$(_ms)" >> "\$counter/span.log"
printf '%s\n' "\$key" >> "\$counter/dispatched.log"
# Per-story delay: the phase's slots then finish at different moments, so a
# barrier that waits only for the QUEUE to drain (and not for running work)
# lets the next phase start while a sibling is still going.
_d="\$(eval printf '%s' "\\\${GAIA_STUB_DELAY_\${key}:-0}" 2>/dev/null || printf 0)"
case "\$_d" in ''|*[!0-9]*) _d=0 ;; esac
[ "\$_d" -gt 0 ] && sleep "\$_d"
if [ "\$key" = "\${GAIA_STUB_MERGED_NOT_DONE:-}" ]; then
  printf '%s\n' "\$key" >> "\$counter/merged-not-done.log"
fi
case "\$mode" in
  ceiling-always)
    printf 'dispatch: ceiling reached\n' >&2
    exit 8
    ;;
  error)
    printf 'dispatch: unclassified failure\n' >&2
    exit 42
    ;;
  park)
    # Hold the slot open so the caller's reservation stays visible to a
    # concurrent measurement, then exit when told to.
    sleep 30
    ;;
  registry-dwell)
    # Behave like a real spawn: register in the shared registry, hold it while
    # sampling how many entries exist, then deregister. The dwell is what makes
    # a check-then-act race observable at all.
    reg="\${GAIA_SESSION_DIR}/registry"
    mkdir -p "\$reg"
    # Go through the REAL spawn path, ceiling gate included. Writing the
    # registry entry by hand would bypass exactly the gate under test -- the
    # reason an earlier version of this suite could not see that a story's own
    # reservation was being counted against its own spawn.
    . "\$GAIA_DT_LIB"
    _dt_ensure_registry
    export GAIA_MODE_B_SUBSTRATE=available
    _rc=0
    spawn_teammate shay --story-key "\$key" >/dev/null 2>&1 || _rc=\$?
    if [ "\$_rc" -ne 0 ]; then
      printf 'spawn-refused %s rc=%s\n' "\$key" "\$_rc" >> "\$counter/spawn.log"
      exit "\$_rc"
    fi
    printf 'spawned %s\n' "\$key" >> "\$counter/spawn.log"
    sleep 1
    find "\$reg" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d " " >> "\$counter/registry-peak.log"
    sleep 1
    shutdown_teammate "tm-shay-\$key" >/dev/null 2>&1 || rm -f "\$reg/tm-shay-\$key"
    ;;
  ceiling:*)
    n="\${mode#ceiling:}"
    # Slots run concurrently now, so the refusal counter must be claimed
    # atomically: a read-then-write would let two slots both see the same count
    # and refuse the same number of times, or neither refuse at all.
    c=0
    while [ "\$c" -lt "\$n" ]; do
      if mkdir "\$counter/ceil.\$c" 2>/dev/null; then
        printf 'dispatch: ceiling reached\n' >&2
        exit 8
      fi
      c=\$(( c + 1 ))
    done
    ;;
  fallback)
    printf 'mode_b_fallback story_key:%s persona:shay reason:substrate-unavailable\n' "\$key"
    exit 7
    ;;
  fail:*)
    if [ "\$key" = "\${mode#fail:}" ]; then
      printf 'dispatch: story failed\n' >&2
      exit 1
    fi
    ;;
  stall:*)
    if [ "\$key" = "\${mode#stall:}" ]; then sleep 3600; fi
    ;;
esac
printf '%s end %s\n' "\$key" "\$(_ms)" >> "\$counter/span.log"
printf '%s %s\n' "\$key" "\$(date +%s)" >> "\$counter/complete-times.log"
printf 'tm-shay-%s\n' "\$key"
exit 0
STUB
  chmod +x "$dir/gaia-dispatch-story"
  printf '%s' "$dir"
}

# _max_overlap <span-log> — the largest number of stories simultaneously in
# flight, computed from real start/end timestamps. 1 means no concurrency at
# all: the stories ran one after another however they were dispatched.
_max_overlap() {
  python3 - "$1" <<'OVPY'
import sys
st, en = {}, {}
try:
    for line in open(sys.argv[1]):
        p = line.split()
        if len(p) == 3:
            (st if p[1] == "start" else en)[p[0]] = int(p[2])
except Exception:
    print(0); raise SystemExit
best = 0
for k in st:
    n = sum(1 for j in st if st[j] < en.get(k, 0) and en.get(j, 0) > st[k])
    best = max(best, n)
print(best)
OVPY
}

# _reason_of <output> — the reason token from a degradation line.
_reason_of() {
  # A run can START parallel and degrade later, so the LAST mode line is the
  # verdict; an earlier `reason=none` would otherwise mask every degradation.
  local last
  last="$(printf '%s\n' "$1" | grep -E '^mode=' | tail -1)"
  [ -n "$last" ] || last="$1"
  printf '%s' "$last" | sed -n 's/.*reason=\([a-z0-9-]*\).*/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# Slot fill, backfill, barrier (AC1)
# ---------------------------------------------------------------------------

@test "concurrency never exceeds the configured slot budget (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1 K4:1 K5:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  # Independent oracle first: the stub logs every dispatch, so all five stories
  # must actually have been dispatched. Without this a no-op scheduler with a
  # constant accessor satisfies the budget assertion by never running anything.
  local dispatched
  dispatched="$(sort -u "$TEST_TMP/stubstate/dispatched.log" | grep -c . || true)"
  [ "$dispatched" -eq 5 ] \
    || { echo "expected 5 stories dispatched, log shows $dispatched"; return 1; }

  local peak; peak="$(ppo_peak_concurrency)"
  [ -n "$peak" ] && [ "$peak" -ge 1 ] \
    || { echo "peak concurrency was not measured: '$peak'"; return 1; }
  [ "$peak" -le 2 ] \
    || { echo "peak concurrency was $peak against a budget of 2"; return 1; }
}

@test "a freed slot is backfilled from the same phase (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1 K4:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
  # Every phase-1 story must be dispatched before the phase-2 story: the third
  # phase-1 story proves a freed slot was refilled from its own phase.
  local log="$TEST_TMP/stubstate/dispatched.log"
  local k4_line k3_line
  k4_line="$(grep -n '^K4$' "$log" | head -1 | cut -d: -f1)"
  k3_line="$(grep -n '^K3$' "$log" | head -1 | cut -d: -f1)"
  [ -n "$k3_line" ] && [ -n "$k4_line" ] \
    || { echo "expected both stories dispatched; log: $(cat "$log")"; return 1; }
  [ "$k3_line" -lt "$k4_line" ] \
    || { echo "the next phase started before the current phase was drained"; return 1; }
}

@test "each concurrent story runs in its own worktree (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
  # Two stories, two distinct worktree paths and two distinct branches: one
  # shared checkout is the cross-contamination this design exists to prevent.
  # Independent oracle: git's own record of what was created, so a constant
  # accessor cannot fake isolation that never happened.
  local branches
  branches="$(git -C "$repo" branch --list 'feat/K*' | grep -c . || true)"
  [ "$branches" -eq 2 ] \
    || { echo "expected 2 story branches in git, found $branches"; return 1; }

  local paths; paths="$(ppo_slot_worktrees | sort -u | grep -c . || true)"
  [ "$paths" -eq 2 ] \
    || { echo "expected 2 distinct worktrees, got $paths"; return 1; }
}

@test "the next phase starts only after every story of the current phase is terminal (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  # Independent oracle: in the dispatch log the phase-2 story must appear after
  # both phase-1 stories. A constant accessor cannot satisfy this.
  local log="$TEST_TMP/stubstate/dispatched.log"
  local k3 k1 k2
  k3="$(grep -n '^K3$' "$log" | head -1 | cut -d: -f1)"
  k1="$(grep -n '^K1$' "$log" | head -1 | cut -d: -f1)"
  k2="$(grep -n '^K2$' "$log" | head -1 | cut -d: -f1)"
  [ -n "$k1" ] && [ -n "$k2" ] && [ -n "$k3" ] \
    || { echo "not every story was dispatched; log: $(cat "$log")"; return 1; }
  [ "$k3" -gt "$k1" ] && [ "$k3" -gt "$k2" ] \
    || { echo "the phase-2 story was dispatched before phase 1 drained"; return 1; }

  run ppo_barrier_violations
  [ "$output" = "0" ] \
    || { echo "a phase-2 dispatch preceded the last phase-1 completion"; return 1; }
}

# ---------------------------------------------------------------------------
# Failure isolation (AC5, AC-EC1)
# ---------------------------------------------------------------------------

@test "the next phase waits for the LAST phase-N completion, not the first (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  # The two phase-1 stories finish at DIFFERENT times. A barrier that waits only
  # for the queue to drain would release phase 2 once K1 is dispatched, while K2
  # is still running -- indistinguishable from a correct barrier when every
  # story completes instantly, which is why this test sets a delay.
  export GAIA_STUB_DELAY_K2=3
  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  local ct="$TEST_TMP/stubstate/complete-times.log"
  local dt="$TEST_TMP/stubstate/dispatch-times.log"
  [ -f "$ct" ] && [ -f "$dt" ] \
    || { echo "the stub recorded no timings"; return 1; }

  # Oracle: phase 2's dispatch timestamp must be >= the LAST phase-1 completion.
  local last_p1 k3_start
  last_p1="$(grep -E '^(K1|K2) ' "$ct" | awk '{print $2}' | sort -n | tail -1)"
  k3_start="$(grep '^K3 ' "$dt" | awk '{print $2}' | head -1)"
  [ -n "$last_p1" ] && [ -n "$k3_start" ] \
    || { echo "missing timings: last phase-1 '$last_p1', phase-2 start '$k3_start'"; return 1; }
  [ "$k3_start" -ge "$last_p1" ] \
    || { echo "phase 2 started at $k3_start, before the last phase-1 completion at $last_p1"; return 1; }

  # And the slow story really was slow, so the window above was real.
  local k2_done k1_done
  k2_done="$(grep '^K2 ' "$ct" | awk '{print $2}' | head -1)"
  k1_done="$(grep '^K1 ' "$ct" | awk '{print $2}' | head -1)"
  [ "$k2_done" -gt "$k1_done" ] \
    || { echo "the stories completed together, so the barrier was never exercised"; return 1; }
}

@test "stories of one phase genuinely run at the same time (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 to compute overlap"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  # Each story takes measurable time, and the budget is wide enough for all of
  # them. Slot accounting alone cannot show concurrency -- a scheduler that
  # awaits each dispatch inline satisfies every budget assertion while running
  # strictly one at a time -- so this reads the REAL start/end timestamps.
  export GAIA_STUB_DELAY_K1=2 GAIA_STUB_DELAY_K2=2 GAIA_STUB_DELAY_K3=2

  local t0 t1 wall
  t0="$(date +%s)"
  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 3
  t1="$(date +%s)"
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
  wall=$((t1 - t0))

  local span="$TEST_TMP/stubstate/span.log"
  [ -f "$span" ] || { echo "the stub recorded no spans"; return 1; }
  local overlap; overlap="$(_max_overlap "$span")"
  [ "${overlap:-0}" -ge 2 ] \
    || { echo "no two stories overlapped (max in flight: ${overlap:-0})"; return 1; }

  # And the wall clock must beat running them back to back. The bound is the
  # serial sum plus per-story setup (a real worktree per slot), not a latency
  # assertion: three 2s stories serialised cannot finish under 6s of sleep
  # alone, while concurrent ones spend ~2s sleeping regardless of setup.
  local sleep_total=6
  [ "$wall" -lt "$sleep_total" ] || {
    # Setup cost can push a genuinely concurrent run past the raw sum on a
    # loaded host, so fall back to the property that cannot be faked: the
    # sleeping itself overlapped.
    local span_lo span_hi
    span_lo="$(awk '$2=="start" {print $3}' "$span" | sort -n | head -1)"
    span_hi="$(awk '$2=="end" {print $3}' "$span" | sort -n | tail -1)"
    [ $(( (span_hi - span_lo) / 1000 )) -lt "$sleep_total" ] \
      || { echo "stories spanned $(( (span_hi - span_lo) / 1000 ))s, no better than the ${sleep_total}s serial sum"; return 1; }
  }
}

@test "a single-slot budget runs stories strictly one at a time (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 to compute overlap"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_STUB_DELAY_K1=2 GAIA_STUB_DELAY_K2=2

  # The control for the test above: with no budget for concurrency there must
  # be none, so a passing overlap assertion cannot be an artefact of the clock.
  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 1
  local span="$TEST_TMP/stubstate/span.log"
  if [ -f "$span" ]; then
    local overlap; overlap="$(_max_overlap "$span")"
    [ "${overlap:-1}" -le 1 ] \
      || { echo "a one-slot budget still ran ${overlap} stories at once"; return 1; }
  fi
}

@test "a fast story frees its slot before a slower sibling finishes (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  # Two slots. K1 is slow, K2 is fast. Reaping the OLDEST slot would make K3
  # wait for K1 even though K2's slot has been free for seconds -- head-of-line
  # blocking that honours the budget while wasting the throughput it exists for.
  export GAIA_STUB_DELAY_K1=6 GAIA_STUB_DELAY_K2=1
  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  local span="$TEST_TMP/stubstate/span.log"
  local k1_end k3_start
  k1_end="$(awk '$1=="K1" && $2=="end" {print $3}' "$span" | head -1)"
  k3_start="$(awk '$1=="K3" && $2=="start" {print $3}' "$span" | head -1)"
  [ -n "$k1_end" ] && [ -n "$k3_start" ] \
    || { echo "missing timings; span: $(cat "$span")"; return 1; }
  [ "$k3_start" -lt "$k1_end" ] \
    || { echo "the backfilled story waited for the slow sibling (started ${k3_start}, slow one ended ${k1_end})"; return 1; }
}

@test "one story failing does not abort its siblings (AC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1 K4:1 K5:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fail:K2)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2

  # Independent oracle: every one of the five stories reached the dispatcher,
  # so the failing story did not stop its siblings from being scheduled.
  local dispatched
  dispatched="$(sort -u "$TEST_TMP/stubstate/dispatched.log" | grep -c . || true)"
  [ "$dispatched" -eq 5 ] \
    || { echo "the phase aborted early; only $dispatched stories dispatched"; return 1; }

  local done_count; done_count="$(ppo_outcome_count done)"
  [ "$done_count" -eq 4 ] \
    || { echo "expected 4 siblings to complete, got $done_count"; return 1; }
}

@test "the barrier waits for a FAILED story, not only successful ones (AC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fail:K1)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2

  # Independent oracle: the phase-2 story must still be dispatched last even
  # though a phase-1 story failed -- the barrier waits for terminal, not success.
  local log="$TEST_TMP/stubstate/dispatched.log"
  local k3 k2
  k3="$(grep -n '^K3$' "$log" | head -1 | cut -d: -f1)"
  k2="$(grep -n '^K2$' "$log" | head -1 | cut -d: -f1)"
  [ -n "$k2" ] && [ -n "$k3" ] \
    || { echo "a failure suppressed a later dispatch; log: $(cat "$log")"; return 1; }
  [ "$k3" -gt "$k2" ] \
    || { echo "phase 2 started before the failing phase drained"; return 1; }

  run ppo_barrier_violations
  [ "$output" = "0" ] \
    || { echo "the barrier advanced past an unfinished failing story"; return 1; }
}

@test "a failed story is recorded for the sprint review (AC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fail:K2)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  run ppo_report
  [[ "$output" == *"K2"* ]] \
    || { echo "the failing story is absent from the report"; return 1; }
  [[ "$output" == *"failed"* ]] \
    || { echo "the report does not record the failure outcome"; return 1; }
}

@test "five stories with one failure keep four running and record the failure (AC-EC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1 K4:1 K5:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fail:K3)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 3

  # Independent oracle before the accessors: all five reached the dispatcher.
  local dispatched
  dispatched="$(sort -u "$TEST_TMP/stubstate/dispatched.log" | grep -c . || true)"
  [ "$dispatched" -eq 5 ] \
    || { echo "the phase aborted; only $dispatched stories dispatched"; return 1; }

  [ "$(ppo_outcome_count done)" -eq 4 ] \
    || { echo "siblings did not all complete"; return 1; }
  [ "$(ppo_outcome_count failed)" -eq 1 ] \
    || { echo "the failure was not recorded exactly once"; return 1; }
}

# ---------------------------------------------------------------------------
# Ceiling saturation (AC2, AC-EC4)
# ---------------------------------------------------------------------------

@test "a saturated ceiling re-queues the story and never records a failure (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ceiling:2)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2

  # Independent oracle: the stub refused twice, so the log must show MORE
  # dispatch attempts than stories -- proof the orchestrator actually re-queued
  # rather than an accessor merely reporting success.
  local attempts stories
  attempts="$(grep -c . "$TEST_TMP/stubstate/dispatched.log" || true)"
  stories="$(sort -u "$TEST_TMP/stubstate/dispatched.log" | grep -c . || true)"
  [ "$stories" -eq 2 ] \
    || { echo "expected 2 distinct stories, log shows $stories"; return 1; }
  [ "$attempts" -gt "$stories" ] \
    || { echo "no retry occurred: $attempts attempts for $stories stories"; return 1; }

  # A full registry is a capacity condition, not a story outcome.
  [ "$(ppo_outcome_count failed)" -eq 0 ] \
    || { echo "a saturated ceiling was recorded as a story failure"; return 1; }
  [ "$(ppo_outcome_count done)" -eq 2 ] \
    || { echo "re-queued stories did not eventually complete"; return 1; }
}

@test "the admission lock keeps concurrent claims inside the ceiling (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 for the config fixture"

  # Eight concurrent admissions against a ceiling of 12, from an EMPTY registry,
  # with the count-then-claim window widened. All eight read the same count, so
  # without the lock they all pass a bound that only four of them had room for
  # once every claim lands. A fixture that pre-fills close to the ceiling cannot
  # show this: only a couple of reservations can ever coexist, so nothing races.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  max_parallel_dev_slots: 8\n  teammate_dispatch_ceiling: 12\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"
  mkdir -p "$GAIA_SESSION_DIR/registry"

  # Occupy most of the ceiling with other agents, leaving room for four more.
  # Eight unguarded claims then overshoot it structurally -- every one of them
  # reads the same count and passes a bound only four had room for -- while a
  # guarded run admits exactly the four that fit.
  local i=0
  while [ "$i" -lt 8 ]; do
    : > "$GAIA_SESSION_DIR/registry/gate-agent-$i"
    i=$(( i + 1 ))
  done

  # ppo_admit_slot claims AND dispatches, releasing its reservation on the way
  # out. A stub that parks keeps every claim held while the peak is measured;
  # without one the reservations are gone before anything can count them.
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" park)"
  PATH="$stub:$PATH"

  # Widen the count-then-claim window so every admission reaches its count
  # before any of them claims. One second is wider than the spread in when
  # eight backgrounded admissions get there, which is what makes the overshoot
  # reproducible rather than timing-dependent.
  export GAIA_PPO_CLAIM_DELAY=1
  local k pids=""
  for k in R1 R2 R3 R4 R5 R6 R7 R8; do
    ppo_admit_slot "$k" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  # Sample while every admission is still parked holding its claim.
  sleep 4
  local peak ceiling
  peak="$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  for i in $pids; do kill "$i" 2>/dev/null || true; done
  for i in $pids; do wait "$i" 2>/dev/null || true; done
  ceiling="$(ppo_resolve_ceiling)"
  [ "$peak" -le "$ceiling" ] \
    || { echo "concurrent claims reached $peak against the configured ceiling ${ceiling}"; return 1; }
}

@test "a story's own reservation never counts against its own spawn (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # shellcheck disable=SC1090
  . "$DT_LIB"
  command -v python3 >/dev/null 2>&1 || skip "no python3 for the config fixture"

  # The SHIPPED defaults, swept across pre-existing gate agents. A reservation
  # is a registry file, so the ceiling gate counts it -- including the one the
  # caller just planted for the story now being spawned. Counting that against
  # itself produces a cliff exactly at the designed headroom: every admission
  # reserves, every spawn is then refused, and the sprint degrades as if the
  # ceiling were saturated while it had room.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  max_parallel_dev_slots: 8\n  teammate_dispatch_ceiling: 12\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg" GAIA_MODE_B_SUBSTRATE=available
  export _DT_CEILING_RETRY_BASE_DELAY=0

  local prefill expect spawned i k rc
  for prefill in 0 2 4; do
    rm -rf "$GAIA_SESSION_DIR/registry"
    mkdir -p "$GAIA_SESSION_DIR/registry"
    _DT_MAX_TEAMMATES=""
    i=0
    while [ "$i" -lt "$prefill" ]; do
      : > "$GAIA_SESSION_DIR/registry/gate-agent-$i"
      i=$(( i + 1 ))
    done

    spawned=0
    for k in S1 S2 S3 S4 S5 S6 S7 S8; do
      printf 'reserved_by:%s\n' "$$" > "$GAIA_SESSION_DIR/registry/.reserved-$k"
      rc=0
      spawn_teammate shay --story-key "$k" >/dev/null 2>&1 || rc=$?
      if [ "$rc" -eq 0 ]; then
        spawned=$(( spawned + 1 ))
      else
        rm -f "$GAIA_SESSION_DIR/registry/.reserved-$k"
      fi
    done

    # min(slots, ceiling - prefill): 8 admissions, 12-prefill room.
    expect=$(( 12 - prefill ))
    [ "$expect" -gt 8 ] && expect=8
    [ "$spawned" -eq "$expect" ] \
      || { echo "prefill $prefill: spawned $spawned, expected $expect"; return 1; }
    # And never a standstill while the designed headroom is intact.
    [ "$spawned" -gt 0 ] \
      || { echo "prefill $prefill admitted nothing at all"; return 1; }
  done
}

@test "a reservation is released on every non-registration exit path (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"

  # A reservation counts toward the ceiling by design, so one left behind by a
  # story that never registered would silently shrink the budget from then on.
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fail:K1)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  local leaked
  leaked="$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -name '.reserved-*' 2>/dev/null | grep -c . || true)"
  [ "$leaked" -eq 0 ] \
    || { echo "a failed story left $leaked reservation(s) holding ceiling slots"; return 1; }
}

@test "a reservation orphaned by a killed run is reaped at the next start (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  # A dead owner's reservation: nothing will ever release it, so a later sprint
  # would run under a permanently reduced ceiling.
  mkdir -p "$GAIA_SESSION_DIR/registry"
  local dead; dead="$(bash -c 'echo $$')"
  printf 'reserved_by:%s\n' "$dead" > "$GAIA_SESSION_DIR/registry/.reserved-GHOST"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ ! -f "$GAIA_SESSION_DIR/registry/.reserved-GHOST" ] \
    || { echo "a dead run's reservation survived the next start"; return 1; }

  # And the reaper is safe to call directly: a LIVE owner's reservation is not
  # collateral damage, or a concurrent sprint would lose its ceiling slots.
  printf 'reserved_by:%s\n' "$$" > "$GAIA_SESSION_DIR/registry/.reserved-LIVE"
  run ppo_reap_stale_reservations
  [ -f "$GAIA_SESSION_DIR/registry/.reserved-LIVE" ] \
    || { echo "the reaper removed a live owner's reservation"; return 1; }
  rm -f "$GAIA_SESSION_DIR/registry/.reserved-LIVE"
}

@test "an interrupted run does not leave its reservations behind (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # The per-slot cleanup never runs on an interrupt, so the trap is the only
  # thing standing between a killed sprint and a permanently shrunken ceiling.
  mkdir -p "$GAIA_SESSION_DIR/registry"
  run bash -c '
    . "'"$ORCH"'"
    export GAIA_SESSION_DIR="'"$GAIA_SESSION_DIR"'"
    printf "reserved_by:%s\n" "$$" > "$GAIA_SESSION_DIR/registry/.reserved-MINE"
    trap "ppo_release_reservations" INT TERM EXIT
    exit 0
  '
  [ ! -f "$GAIA_SESSION_DIR/registry/.reserved-MINE" ] \
    || { echo "the exit trap did not release this run's reservation"; return 1; }
}

@test "the guard idiom survives errexit and preserves a sourced caller's options (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ceiling:1)"
  PATH="$stub:$PATH"

  # A caller with errexit ON that USES the captured status: the bare-capture
  # form dies at the assignment before the status is ever read.
  run bash -c '
    set -euo pipefail
    . "'"$ORCH"'"
    rc=0
    ppo_dispatch_slot "K1" || rc=$?
    printf "survived rc=%s\n" "$rc"
  '
  [ "$status" -eq 0 ] \
    || { echo "an errexit caller died at the spawn assignment: $output"; return 1; }
  [[ "$output" == *"survived"* ]] \
    || { echo "the captured status was never reached"; return 1; }

  # A sourced caller that deliberately ran `set +e` must keep it: shell options
  # belong to the caller, and flipping errexit underneath one is a real bug.
  run bash -c '
    set +e
    . "'"$ORCH"'"
    ppo_dispatch_slot "K1" >/dev/null 2>&1
    case "$-" in *e*) echo "errexit was switched on underneath the caller"; exit 1 ;; esac
    echo "options preserved"
  '
  [ "$status" -eq 0 ] \
    || { echo "$output"; return 1; }
}

@test "reviewer personas are refused as teammates and consume no dev slot (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # Driven against the REAL clean-room gate and the REAL persona list: this is
  # the mechanism that makes budget exclusion structural rather than arithmetic.
  # shellcheck disable=SC1090
  . "$DT_LIB"
  local p
  for p in validator security qa tdd-reviewer; do
    run _dt_clean_room_gate "$p"
    [ "$status" -ne 0 ] \
      || { echo "reviewer persona '$p' was accepted as a teammate"; return 1; }
  done
  # Nothing entered the registry, so nothing can have consumed a slot.
  run ppo_dev_slot_consumers
  [ "$output" = "0" ] \
    || { echo "reviewer dispatches consumed $output dev slots"; return 1; }
}

@test "a reviewer pile-up near the ceiling retries rather than failing a story (AC-EC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ceiling:3)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 3
  [ "$(ppo_outcome_count failed)" -eq 0 ] \
    || { echo "ceiling pressure from reviewers failed a story"; return 1; }
}

@test "the ceiling binds across slots through one shared registry (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # shellcheck disable=SC1090
  . "$DT_LIB"
  # Per-slot session directories would give each slot its own registry, each
  # counting one, so the ceiling would never bind -- an unbounded swarm.
  local before; before="$(_dt_active_count)"
  : > "$GAIA_SESSION_DIR/registry/tm-shay-K1" 2>/dev/null || {
    mkdir -p "$GAIA_SESSION_DIR/registry"
    : > "$GAIA_SESSION_DIR/registry/tm-shay-K1"
  }
  : > "$GAIA_SESSION_DIR/registry/tm-shay-K2"
  local after; after="$(_dt_active_count)"
  [ "$after" -eq $(( before + 2 )) ] \
    || { echo "the shared registry did not observe both slots"; return 1; }

  run ppo_session_dir_for K1
  local d1="$output"
  run ppo_session_dir_for K2
  [ "$d1" = "$output" ] \
    || { echo "slots resolved different session dirs, splitting the registry"; return 1; }
}

@test "concurrent slot admission never exceeds the ceiling (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1 K4:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"

  # Slots 4, ceiling 8: the slot budget permits four admissions at once, so the
  # ceiling is the only thing that can hold the line once the registry already
  # carries other teammates. Pre-fill it to 6 so just two of the four stories
  # can be admitted at a time. The ceiling must clear the headroom rule
  # (ceiling >= slots + 4) or pre-flight degrades before any dispatch happens.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  teammate_dispatch_ceiling: 8\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"
  mkdir -p "$GAIA_SESSION_DIR/registry"
  local i=0
  while [ "$i" -lt 6 ]; do
    : > "$GAIA_SESSION_DIR/registry/other-teammate-$i"
    i=$(( i + 1 ))
  done

  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" registry-dwell)"
  PATH="$stub:$PATH"

  # Widen the count-then-claim window so the race is reachable deterministically
  # rather than only under lucky scheduling. Without the lock, four admissions
  # all read the same count inside this window and all claim.
  export GAIA_PPO_CLAIM_DELAY=1

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 4

  # Oracle: the stub samples the REAL registry on every dispatch and logs how
  # many entries it saw while holding one itself. The peak across the run is
  # what the ceiling is supposed to bound.
  local peak
  peak="$(sort -n "$TEST_TMP/stubstate/registry-peak.log" 2>/dev/null | tail -1)"
  [ -n "$peak" ] && [ "$peak" -gt 0 ] \
    || { echo "the stub never sampled the registry, so nothing was measured"; return 1; }
  # Pre-existing entries plus the admissions this run is allowed must never
  # exceed the configured ceiling. More means the check-then-act window let
  # extra admissions through. The bound is read from the config rather than
  # written as a literal, so this asserts nothing about any particular value.
  local configured; configured="$(ppo_resolve_ceiling)"
  [ "$peak" -le "$configured" ] \
    || { echo "peak registry entries was $peak against the configured ceiling ${configured}"; return 1; }

  # And a bounded ceiling must not lose work: every story still completes,
  # queued via the capacity code rather than failed.
  local n
  n="$(sort -u "$TEST_TMP/stubstate/dispatched.log" | grep -c . || true)"
  [ "$n" -eq 4 ] \
    || { echo "expected all 4 stories dispatched, saw $n"; return 1; }
  [ "$(ppo_outcome_count failed)" -eq 0 ] \
    || { echo "a capacity condition was recorded as a story failure"; return 1; }
}

# ---------------------------------------------------------------------------
# Degradation paths (AC3)
# ---------------------------------------------------------------------------

@test "the pre-flight admission chain emits a reason for each refusal it owns (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  local r

  # A degradation nobody can see is indistinguishable from a broken feature.
  # flock must be reachable for the later checks to be reachable at all; this
  # arm forces its absence deliberately.
  GAIA_LOCK_FORCE_FALLBACK=1 run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 4
  r="$(_reason_of "$output")"
  [ "$r" = "flock-unavailable" ] || { echo "flock: got reason '$r'"; return 1; }

  GAIA_WORKTREE_MODE=0 run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 4
  r="$(_reason_of "$output")"
  [ "$r" = "worktree-mode-off" ] || { echo "worktree: got reason '$r'"; return 1; }

  run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 1
  r="$(_reason_of "$output")"
  [ "$r" = "slots-1" ] || { echo "slots: got reason '$r'"; return 1; }

  local noph; noph="$(_mk_yaml "$TEST_TMP/nophase.yaml" K1 K2)"
  run ppo_preflight --repo "$repo" --yaml "$noph" --slots 4
  r="$(_reason_of "$output")"
  [ "$r" = "no-phase-fields" ] || { echo "phaseless: got reason '$r'"; return 1; }

  printf 'items: [oops\n' > "$TEST_TMP/bad.yaml"
  run ppo_preflight --repo "$repo" --yaml "$TEST_TMP/bad.yaml" --slots 4
  r="$(_reason_of "$output")"
  [ "$r" = "sprint-unreadable" ] || { echo "malformed: got reason '$r'"; return 1; }
}

@test "a ceiling that can never admit a story degrades with its own reason (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  # A registry already at the ceiling with nothing to free it: the bounded
  # retry cannot succeed, so the run must degrade rather than spin or fail the
  # story. Without its own token this is indistinguishable from a real failure.
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ceiling-always)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] \
    || { echo "a saturated ceiling refused the run instead of degrading"; return 1; }
  [ "$(_reason_of "$output")" = "ceiling-cannot-admit" ] \
    || { echo "expected ceiling-cannot-admit, got: $output"; return 1; }
  [ "$(ppo_outcome_count failed)" -eq 0 ] \
    || { echo "a capacity condition was recorded as a story failure"; return 1; }
}

@test "a substrate fallback names mode-b-fallback as the reason (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fallback)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$(_reason_of "$output")" = "mode-b-fallback" ] \
    || { echo "expected mode-b-fallback, got: $output"; return 1; }
}

@test "an unclassified dispatch status degrades with admission-error (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  # A status outside the documented contract (not 0, 7 or 8) must not be
  # silently read as one of them: it gets the catch-all reason and still runs.
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" error)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] \
    || { echo "an unclassified status refused the whole run"; return 1; }
  [[ "$output" == *"reason="* ]] \
    || { echo "an unclassified status produced no reason token"; return 1; }
}

@test "a substrate fallback degrades to sequential and never refuses (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fallback)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 4
  [ "$status" -eq 0 ] \
    || { echo "a substrate fallback refused the run instead of degrading"; return 1; }
  [[ "$output" == *"mode=sequential"* ]] \
    || { echo "the run did not degrade to sequential"; return 1; }
}

@test "sequential fallback emits phase order then roster order within phase (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" A1:1 A2:1 B1:2 B2:2)"

  run ppo_plan_sequential --repo "$repo" --yaml "$yaml"
  [ "$status" -eq 0 ] || { echo "sequential planning failed: $output"; return 1; }
  local expected; expected="$(printf 'A1\nA2\nB1\nB2')"
  [ "$output" = "$expected" ] \
    || { echo "expected phase-then-roster order, got: $output"; return 1; }
}

@test "worktree mode off degrades to sequential and is never switched on (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  GAIA_WORKTREE_MODE=0 run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 4
  [ "$status" -eq 0 ] \
    || { echo "worktree mode off refused the run"; return 1; }
  [[ "$output" == *"mode=sequential"* ]] \
    || { echo "worktree mode off did not degrade to sequential"; return 1; }
  # The orchestrator must not enable the mode for an operator who did not ask.
  # shellcheck disable=SC1090
  . "$WT_LIB"
  GAIA_WORKTREE_MODE=0
  run worktree_mode_enabled
  [ "$status" -ne 0 ] \
    || { echo "worktree mode was switched on by the orchestrator"; return 1; }
}

@test "an unavailable lock primitive refuses the parallel start but still runs (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  # The PARALLEL START is refused; the RUN is not. Exiting non-zero here would
  # strand every operator whose platform lacks the primitive.
  GAIA_LOCK_FORCE_FALLBACK=1 run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 4
  [ "$status" -eq 0 ] \
    || { echo "a missing lock primitive refused the whole run"; return 1; }
  [[ "$output" == *"mode=sequential"* ]] \
    || { echo "the run did not fall back to sequential"; return 1; }
}

@test "a phase-less sprint names no-phase-fields as the reason (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  # A sprint planned before phases existed has rows but no phase field. It must
  # degrade with a reason the operator can act on, not silently or generically.
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1 K2 K3)"

  run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 4
  [ "$(_reason_of "$output")" = "no-phase-fields" ] \
    || { echo "expected no-phase-fields, got: $output"; return 1; }
  [[ "$output" == *"no phase fields"* ]] \
    || { echo "the operator-facing text does not name the cause"; return 1; }
}

@test "a malformed sprint file reports sprint-unreadable, not no-phase-fields (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  # Sharing one reason code would send an operator hunting a planning problem
  # when the real fault is a corrupted file.
  printf 'items: [unclosed\n  - key: K1\n' > "$TEST_TMP/bad.yaml"

  run ppo_preflight --repo "$repo" --yaml "$TEST_TMP/bad.yaml" --slots 4
  [ "$(_reason_of "$output")" = "sprint-unreadable" ] \
    || { echo "expected sprint-unreadable, got: $output"; return 1; }
}

@test "the documented opt-in actually gates parallel execution (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local v
  # An opt-in nothing reads is not an opt-in: unset and 0 must both degrade.
  for v in "" "0" "false"; do
    GAIA_PARALLEL_EXECUTION="$v" run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 4
    [ "$(_reason_of "$output")" = "parallel-opt-in-off" ] \
      || { echo "opt-in '$v' did not degrade; got: $output"; return 1; }
  done
  GAIA_PARALLEL_EXECUTION=1 run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 4
  [[ "$output" == *"mode=parallel"* ]] \
    || { echo "the opt-in set to 1 did not enable parallel mode: $output"; return 1; }
}

@test "the surface states the blessed divergence from the state writer (AC3)" {
  local skill="$PLUGIN_ROOT/skills/gaia-run-sprint/SKILL.md"
  [ -f "$skill" ] || { echo "skill not implemented: $skill"; return 1; }
  # Two consumers read one opt-in flag with deliberately different policy: the
  # state writer refuses, this surface degrades. Unstated, a later reader would
  # "correct" the divergence into a hard refusal.
  grep -qi 'sequential' "$skill" \
    || { echo "the skill does not document the degradation policy"; return 1; }
  grep -q 'GAIA_PARALLEL_EXECUTION' "$skill" \
    || { echo "the skill does not name the opt-in flag"; return 1; }
}

# ---------------------------------------------------------------------------
# Ordering, empty phases, integration (AC-EC2, AC-EC3, AC4)
# ---------------------------------------------------------------------------

@test "simultaneous completions backfill in deterministic roster order (AC-EC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1 K4:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2

  # ADMISSION order is the deterministic property, and it is what the
  # orchestrator controls. Completion order is not: the stories run
  # concurrently, so which of two in-flight slots writes its line first is a
  # race the scheduler neither owns nor should pretend to.
  local order; order="$(grep -oE '^event=dispatched story=[A-Za-z0-9._-]+' <<<"$output" \
                        | sed 's/.*story=//')"
  local expected; expected="$(printf 'K1\nK2\nK3\nK4')"
  [ "$order" = "$expected" ] \
    || { echo "admission was not in roster order; got: $order"; return 1; }

  # And every story really was admitted, so the ordering is over a full set.
  local n; n="$(printf '%s\n' "$order" | grep -c . || true)"
  [ "$n" -eq 4 ] || { echo "expected 4 admissions, saw $n"; return 1; }
}

@test "an empty phase is skipped without hanging (AC-EC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # Phase 2 is empty -- the loop must not wait for zero completions.
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:3)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run timeout 60 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
  '
  [ "$status" -ne 124 ] \
    || { echo "the orchestrator hung on an empty phase"; return 1; }
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
}

@test "the integration path drives the real dispatch surface with same-persona stories (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # shellcheck disable=SC1090
  . "$DT_LIB"
  mkdir -p "$GAIA_SESSION_DIR/registry"
  # Two stories, one persona: the collision that story-keyed handles exist to
  # resolve. Driven against the REAL library, not a shim.
  local h1 h2 rc1=0 rc2=0
  h1="$(spawn_teammate shay --story-key "K1")" || rc1=$?
  h2="$(spawn_teammate shay --story-key "K2")" || rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] \
    || { echo "same-persona spawns failed: $rc1 $rc2"; return 1; }
  [ "$h1" != "$h2" ] \
    || { echo "two stories collided on one handle: $h1"; return 1; }
}

@test "a merged story that is not yet done blocks its slot from being backfilled (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  # Merged-but-not-done means rework is pending: the story is NOT terminal, so
  # the barrier holds and the slot is not recycled onto another story.
  export GAIA_STUB_MERGED_NOT_DONE="K1"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 1
  run ppo_backfill_before_done
  [ "$output" = "0" ] \
    || { echo "a slot was backfilled while its story's gate was still open"; return 1; }
}

# ---------------------------------------------------------------------------
# Worktree lifecycle, resume, orphans (AC1, AC-EC6)
# ---------------------------------------------------------------------------

@test "a clean run leaves no orphan worktree behind (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
  local remaining
  remaining="$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ' || true)"
  [ "$remaining" -eq 1 ] \
    || { echo "expected only the primary checkout, found $remaining worktrees"; return 1; }
}

@test "re-entry attaches a surviving worktree instead of dispatching twice (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # shellcheck disable=SC1090
  . "$WT_LIB"
  local wt; wt="$(worktree_create "$repo" "K1" "slug")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  local n; n="$(grep -c '^K1$' "$TEST_TMP/stubstate/dispatched.log" 2>/dev/null || echo 0)"
  [ "$n" -le 1 ] \
    || { echo "a story with a live worktree was dispatched $n times"; return 1; }
}

@test "orphans from a killed run are pruned before dispatch (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # shellcheck disable=SC1090
  . "$WT_LIB"
  local wt; wt="$(worktree_create "$repo" "OLD" "slug")"
  # Simulate a killed run: the directory is gone but the record survives.
  rm -rf "$wt"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  run bash -c "git -C '$repo' worktree list --porcelain | grep -c 'OLD' || true"
  [ "$output" = "0" ] \
    || { echo "a killed run's orphan record survived the prune"; return 1; }
}

@test "a preserved worktree is reported with a recovery command that works (AC-EC6)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # shellcheck disable=SC1090
  . "$WT_LIB"
  local wt; wt="$(worktree_create "$repo" "K1" "slug")"
  printf 'work in progress\n' > "$wt/untracked.txt"

  run ppo_report_preserved "$repo"
  [[ "$output" == *"$wt"* ]] \
    || { echo "the preserved worktree was not named in the report"; return 1; }
  # A kept worktree stays locked, so a bare `remove --force` fails against it.
  [[ "$output" == *"worktree unlock"* ]] \
    || { echo "the printed recovery command omits the unlock step"; return 1; }
}

@test "slot scratch directories are per-story and retained (AC-EC6)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 3
  local n
  n="$(find "$GAIA_SESSION_DIR/slots" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -eq 3 ] \
    || { echo "expected 3 retained per-story scratch dirs, found $n"; return 1; }

  # Scratch is per story but lives UNDER the shared session dir: a per-slot
  # session dir would split the registry and stop the ceiling binding.
  local d1 d2
  d1="$(ppo_slot_scratch_for K1)"
  d2="$(ppo_slot_scratch_for K2)"
  [ "$d1" != "$d2" ] \
    || { echo "two stories resolved the same scratch directory"; return 1; }
  case "$d1" in
    "$GAIA_SESSION_DIR"/*) : ;;
    *) echo "scratch escaped the shared session dir: $d1"; return 1 ;;
  esac
  [ -d "$d1" ] \
    || { echo "the scratch directory was not retained: $d1"; return 1; }
}

@test "the discard flag is passed from exactly one post-merge call site (AC-EC6)" {
  [ -f "$ORCH" ] || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # Forcing removal is only safe where the work is provably merged. On the
  # teardown trap (failure and interrupt paths) or the stall path it would
  # destroy exactly the state the preserve rules exist to protect, so the
  # occurrence count is pinned at the source level.
  # Count CODE occurrences only: a comment mentioning the flag is documentation,
  # and counting it would let a real second call site hide behind a prose edit.
  local n
  n="$(grep -n -- '--discard-ignored' "$ORCH" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -c . || true)"
  [ "$n" -eq 1 ] \
    || { echo "expected exactly 1 discard code call site in the orchestrator, found $n"; return 1; }

  # And it must sit on the post-merge path, established by a code line naming
  # the teardown call it guards rather than by a nearby comment word.
  local line
  line="$(grep -n -- '--discard-ignored' "$ORCH" \
           | grep -vE '^[0-9]+:[[:space:]]*#' | head -1)"
  printf '%s' "$line" | grep -q 'worktree_teardown' \
    || { echo "the discard flag is not on a worktree_teardown call: $line"; return 1; }

  # Nothing else may PASS the flag. Three files may legitimately name it: the
  # orchestrator (the call site), the library that DEFINES the option, and the
  # skill prose that documents it.
  local other
  other="$(grep -rln -- '--discard-ignored' "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/skills" 2>/dev/null \
            | grep -v 'phase-parallel-orchestrator.sh' \
            | grep -v 'lib/story-worktree.sh' \
            | grep -v 'gaia-run-sprint/SKILL.md' || true)"
  [ -z "$other" ] \
    || { echo "the discard flag escaped its single call site: $other"; return 1; }
}

# ---------------------------------------------------------------------------
# Stall budget (AC-EC5)
# ---------------------------------------------------------------------------

@test "a stalled slot times out, frees its slot, and preserves its worktree (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" stall:K1)"
  PATH="$stub:$PATH"

  # A tiny budget keeps the test fast; the budget's existence is not optional,
  # because a slot that can block forever deadlocks the sprint.
  run timeout 120 env PATH="$PATH" GAIA_STORY_TIMEOUT_SECONDS=2 bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
  '
  [ "$status" -ne 124 ] \
    || { echo "a stalled story blocked the whole sprint"; return 1; }
  [[ "$output" == *"slot-timeout"* ]] \
    || { echo "the stall was not reported as a timeout: $output"; return 1; }
  [[ "$output" == *"K2"* ]] \
    || { echo "the sibling did not keep working through the stall"; return 1; }
}

@test "the story timeout resolves to 90 minutes when absent and when unreadable (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # For a timeout the conservative value is the documented one: a lower value
  # is not safer, it manufactures false failures on slow-but-healthy runs.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'project_name: t\n' > "$cfg"
  GAIA_SHARED_CONFIG="$cfg" run ppo_resolve_timeout
  [ "$output" = "90" ] \
    || { echo "absent config resolved to '$output', expected 90"; return 1; }

  printf 'parallel_execution: [broken\n' > "$cfg"
  GAIA_SHARED_CONFIG="$cfg" run ppo_resolve_timeout
  [ "$output" = "90" ] \
    || { echo "unreadable config resolved to '$output', expected 90"; return 1; }
}

@test "a configured story timeout is honoured (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  story_timeout_minutes: 45\n' > "$cfg"
  GAIA_SHARED_CONFIG="$cfg" run ppo_resolve_timeout
  [ "$output" = "45" ] \
    || { echo "configured timeout resolved to '$output', expected 45"; return 1; }
}

# ---------------------------------------------------------------------------
# Config resolution and telemetry (AC1, AC2)
# ---------------------------------------------------------------------------

@test "the slot budget resolves from config with a documented default (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'project_name: t\n' > "$cfg"
  GAIA_SHARED_CONFIG="$cfg" run ppo_resolve_slots
  [ "$output" = "8" ] \
    || { echo "absent config resolved slots to '$output', expected 8"; return 1; }

  printf 'parallel_execution:\n  max_parallel_dev_slots: 3\n' > "$cfg"
  GAIA_SHARED_CONFIG="$cfg" run ppo_resolve_slots
  [ "$output" = "3" ] \
    || { echo "configured slots resolved to '$output', expected 3"; return 1; }
}

@test "phases are read from the sprint file in ascending order (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" B1:2 A1:1 B2:2 A2:1)"
  run ppo_read_phases "$yaml"
  [ "$status" -eq 0 ] || { echo "phase read failed: $output"; return 1; }
  local expected; expected="$(printf 'A1|1\nA2|1\nB1|2\nB2|2')"
  [ "$output" = "$expected" ] \
    || { echo "expected ascending phase order, got: $output"; return 1; }
}

@test "the run logs its mode and reason even on the parallel path (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  # "Why did this run the way it did" must never require guessing.
  [[ "$output" == *"mode=parallel"* ]] \
    || { echo "the parallel path did not log its mode"; return 1; }
}

@test "per-story telemetry carries story, phase and outcome (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [[ "$output" == *"story=K1"* ]] || { echo "no story token in telemetry"; return 1; }
  [[ "$output" == *"phase=1"* ]] || { echo "no phase token in telemetry"; return 1; }
  [[ "$output" == *"outcome="* ]] || { echo "no outcome token in telemetry"; return 1; }
}

@test "hostile slot budgets are rejected or clamped, never run as parallel (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local v
  for v in 0 -1 abc ""; do
    run ppo_preflight --repo "$repo" --yaml "$yaml" --slots "$v"
    [[ "$output" != *"mode=parallel"* ]] \
      || { echo "slot budget '$v' was accepted as parallel"; return 1; }
  done
}

@test "a story key carrying separators or whitespace never reaches a worktree path (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local k
  for k in "../escape" "a b" "K1/../../etc"; do
    run ppo_admit_slot "$k"
    [ "$status" -ne 0 ] \
      || { echo "hostile story key '$k' was admitted"; return 1; }
  done
  [ ! -e "$TEST_TMP/escape" ] \
    || { echo "a traversing story key escaped the worktree parent"; return 1; }
}

@test "a lock timeout degrades to sequential and never admits unlocked (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 for the config fixture"

  # A lock that cannot be acquired is the one case where continuing is worse
  # than not running concurrently at all: the count-and-claim would proceed
  # with no mutual exclusion and no warning, which is exactly the overshoot the
  # lock exists to prevent. Admission must fail CLOSED -- degrade, never admit.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  max_parallel_dev_slots: 8\n  teammate_dispatch_ceiling: 12\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"
  mkdir -p "$GAIA_SESSION_DIR/registry"

  # Hold the admission lock from ANOTHER process for longer than the acquire
  # timeout, so the acquire genuinely times out rather than being simulated.
  local lockfile="$GAIA_SESSION_DIR/.ppo-admit.lock"
  : > "$lockfile"
  python3 -c '
import fcntl, sys, time
fh = open(sys.argv[1], "a")
fcntl.flock(fh, fcntl.LOCK_EX)
time.sleep(float(sys.argv[2]))
' "$lockfile" 30 &
  local holder=$!
  # Wait until the holder actually owns the lock, so the race is not with our
  # own startup.
  local waited=0
  while [ "$waited" -lt 50 ]; do
    if ! python3 -c '
import fcntl, sys
fh = open(sys.argv[1], "a")
try:
    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sys.exit(0)
except OSError:
    sys.exit(1)
' "$lockfile" 2>/dev/null; then
      break
    fi
    sleep 0.1
    waited=$(( waited + 1 ))
  done

  local before after rc=0
  before="$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  export GAIA_PPO_LOCK_TIMEOUT=1
  local out; out="$(ppo_admit_slot LOCKT 2>&1)" || rc=$?
  after="$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  # Fail CLOSED: the capacity/degradation code, never a successful admission.
  [ "$rc" -eq 10 ] \
    || { echo "lock timeout returned $rc, expected the lock-timeout code 10"; return 1; }
  # And nothing was claimed while the lock was held by somebody else.
  [ "$after" -eq "$before" ] \
    || { echo "a reservation was planted without the lock ($before -> $after)"; return 1; }
  [ ! -f "$GAIA_SESSION_DIR/registry/.reserved-LOCKT" ] \
    || { echo "an unlocked admission left a reservation behind"; return 1; }
}

@test "the lock-timeout degradation names its own reason (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }

  # The reason vocabulary is how an operator tells a deliberate degradation
  # from a crash. A lock timeout gets its own token rather than being folded
  # into the unclassified bucket, which would read as a bug instead of a
  # safety decision.
  grep -q 'admission-lock-timeout' "$ORCH" \
    || { echo "no admission-lock-timeout reason in the orchestrator"; return 1; }
  # It degrades -- exit 0 with a sequential plan -- and never hard-refuses.
  local ctx; ctx="$(grep -n 'admission-lock-timeout' "$ORCH" | head -1)"
  printf '%s' "$ctx" | grep -q 'mode=sequential' \
    || { echo "admission-lock-timeout is not emitted as a sequential degradation: $ctx"; return 1; }
}

@test "the ceiling read is outside the admission critical section (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }

  # The config read goes through yq/python3 and costs ~200ms. Inside the
  # critical section that cost is paid while every other admission queues on
  # the lock, so at large-but-legal slot budgets acquisitions start timing out
  # -- and a timeout is a degradation. The ceiling value is not the shared
  # resource (the registry is), so the read belongs OUTSIDE the lock.
  local body acq_line ceil_line rel_line
  body="$(sed -n '/^ppo_admit_slot()/,/^}/p' "$ORCH")"
  acq_line="$(printf '%s\n' "$body" | grep -n 'acquire_lock ' | head -1 | cut -d: -f1)"
  ceil_line="$(printf '%s\n' "$body" | grep -n 'ceiling="\$(ppo_resolve_ceiling)"' | head -1 | cut -d: -f1)"
  rel_line="$(printf '%s\n' "$body" | grep -n 'release_lock ' | head -1 | cut -d: -f1)"
  [ -n "$acq_line" ] && [ -n "$ceil_line" ] && [ -n "$rel_line" ] \
    || { echo "could not locate acquire/ceiling/release in ppo_admit_slot"; return 1; }
  [ "$ceil_line" -lt "$acq_line" ] \
    || { echo "the ceiling read (line $ceil_line) is inside the critical section (acquire $acq_line, release $rel_line)"; return 1; }
}
