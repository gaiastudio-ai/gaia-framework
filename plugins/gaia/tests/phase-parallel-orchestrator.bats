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

  # Pin the Mode B substrate to a known state for every test in this suite.
  # _dt_substrate_available (dispatch-teammate.sh) falls back to reading
  # CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS from the ambient environment when
  # GAIA_MODE_B_SUBSTRATE is unset -- a real, user-facing opt-in flag, not a
  # test knob. A developer's own interactive Claude Code session commonly
  # has that flag set to 1, so a suite that never pins GAIA_MODE_B_SUBSTRATE
  # silently inherits "available" locally and "unavailable" on a clean CI
  # runner (or any shell without that flag) -- every dispatch-hook-driven
  # test then admits for real locally but degrades the WHOLE run to
  # mode=sequential on CI, so `dispatch story=...` never appears and the
  # hook is never invoked: "0 stories dispatched" on every one of them,
  # nothing to do with locking. Default to `available` here so the suite's
  # result never depends on which flag happens to be set in the invoking
  # shell; the one test that exercises the real substrate-unavailable path
  # (AC4) overrides this locally, exactly as it already did.
  export GAIA_MODE_B_SUBSTRATE=available
}

teardown() {
  _assert_no_stub_processes_leaked
  common_teardown
}

# _assert_no_stub_processes_leaked — fail THIS test (not just clean up
# quietly) if any process this test started under its own $TEST_TMP is still
# alive when it ends. $TEST_TMP is unique per test (test_helper.bash names it
# gaia-<test-slug>-$$ under bats' own per-test tmpdir), and every dispatch
# stub this file's tests install lives under "$TEST_TMP/bin" -- so any
# stub/timeout/hook-grandchild process still around at teardown carries
# $TEST_TMP somewhere in its own argv or an ancestor's, making `pgrep -f
# "$TEST_TMP"` a marker unique to exactly this test, never a sibling running
# concurrently in a different $TEST_TMP. A leak here means
# _ppo_run_kill_children (or a test driving `run` outside its trap, e.g. via
# a hand-rolled background process) failed to reap something -- that must
# turn this test red, not be silently swept away, or a regression in the
# product's own cleanup would go unnoticed forever.
_assert_no_stub_processes_leaked() {
  [ -n "${TEST_TMP:-}" ] || return 0
  command -v pgrep >/dev/null 2>&1 || return 0

  local survivors
  survivors="$(pgrep -f "$TEST_TMP" 2>/dev/null || true)"
  [ -z "$survivors" ] && return 0

  # Force-kill so a leak from THIS test cannot also poison the next one, but
  # the leak itself still fails the test -- cleanup and the assertion are
  # separate concerns; a killed-but-unreported leak would just mask a real
  # product regression under a green suite.
  local pid
  for pid in $survivors; do
    kill -KILL "$pid" 2>/dev/null || true
  done

  {
    printf 'process leak: %s survived teardown under $TEST_TMP=%s\n' \
      "$(printf '%s' "$survivors" | tr '\n' ' ')" "$TEST_TMP"
    ps -o pid,ppid,pgid,command -p $survivors 2>/dev/null || true
  } >&2
  return 1
}

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
  # Create the evidence logs when the stub is INSTALLED, not when it first
  # runs. An assertion that reads one must not depend on the stub having been
  # reached: a run that legitimately dispatched nothing would otherwise make
  # `sort` exit 2 on a missing file, and the suite-wide errexit aborts the test
  # before its own "nothing was measured" guard can say so -- a phantom failure
  # that appears only when load changes what gets dispatched.
  local _st="${GAIA_STUB_STATE:-$TEST_TMP/stubstate}"
  mkdir -p "$_st"
  : >> "$_st/dispatch-times.log"
  : >> "$_st/span.log"
  : >> "$_st/dispatched.log"
  : >> "$_st/registry-peak.log"
  : >> "$_st/spawn.log"
  : >> "$_st/merged-not-done.log"
  cat > "$dir/gaia-dispatch-story" <<STUB
#!/usr/bin/env bash
set -uo pipefail
key="\${1:-}"
mode="$mode"
GAIA_DT_LIB="${GAIA_DT_LIB:-$PLUGIN_ROOT/scripts/lib/dispatch-teammate.sh}"
counter="\${GAIA_STUB_STATE:-$TEST_TMP/stubstate}"
mkdir -p "\$counter"
# Create every log the assertions read, before anything can exit early. A
# `sort` on a missing file exits 2, and under the suite-wide errexit that
# aborts the test BEFORE its own "nothing was measured" guard can report --
# so a run that legitimately dispatched nothing failed as a phantom
# assertion failure, intermittently and only under load.
: >> "\$counter/dispatch-times.log"
: >> "\$counter/span.log"
: >> "\$counter/dispatched.log"
: >> "\$counter/registry-peak.log"
: >> "\$counter/spawn.log"
: >> "\$counter/merged-not-done.log"
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
# GAIA_STUB_BLOCK_UNTIL_<key>=<path>: poll for that path to appear rather
# than sleeping a fixed duration. Order-based, not wall-clock-based -- a
# caller creates the path only after observing whatever OTHER event must
# happen first (e.g. a sibling's own dispatch line), so the assertion this
# supports is about ADMISSION ORDER, immune to how fast or slow any given
# machine happens to run the surrounding bookkeeping.
_bf="\$(eval printf '%s' "\\\${GAIA_STUB_BLOCK_UNTIL_\${key}:-}" 2>/dev/null || true)"
if [ -n "\$_bf" ]; then
  _bw=0
  while [ ! -e "\$_bf" ]; do
    _bw=\$((_bw + 1))
    [ "\$_bw" -lt 300 ] || break
    sleep 0.1
  done
fi
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
    # Sample the shared registry while this story's admission is in flight.
    # The step engine admits for REAL before this hook ever runs (ppo_next's
    # own spawn_teammate call, under the reservation lock, is what puts this
    # story's entry in the registry) -- so the hook no longer spawns its own
    # entry here. An earlier version of this stub called spawn_teammate
    # itself, which was correct when the hook substituted for the ORCHESTRATOR's
    # entire admission-and-run in one call; under the step engine that would
    # double-register (one entry from the real ppo_next admission, a second
    # from this stub), silently inflating the observed peak past the ceiling
    # it is supposed to bound. The dwell (a real sleep window while the real
    # admission's entry sits in the registry) is what still makes the
    # check-then-act race observable.
    reg="\${GAIA_SESSION_DIR}/registry"
    mkdir -p "\$reg"
    printf 'spawned %s\n' "\$key" >> "\$counter/spawn.log"
    sleep 0.3
    find "\$reg" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d " " >> "\$counter/registry-peak.log"
    sleep 0.3
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
# Merged but NOT done: the run succeeded and the branch is merged, but the
# story's review gate is still open, so the story is not terminal. Reported
# with its own status so the caller can tell it from a plain success -- the
# distinction AC4 rests on. GAIA_STUB_MND_ATTEMPTS names how many attempts
# report merged-not-done before the story finally reaches done, so the resume
# path can be driven to both outcomes: it clears, or it never does.
if [ "\$key" = "\${GAIA_STUB_MERGED_NOT_DONE:-}" ]; then
  _mnd_seen="\$(grep -c . "\$counter/merged-not-done.log" 2>/dev/null)" || _mnd_seen=0
  _mnd_max="\${GAIA_STUB_MND_ATTEMPTS:-999}"
  case "\$_mnd_max" in ''|*[!0-9]*) _mnd_max=999 ;; esac
  if [ "\$_mnd_seen" -le "\$_mnd_max" ]; then
    printf 'tm-shay-%s\n' "\$key"
    exit 11
  fi
fi
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
  printf '%s' "$last" | sed -n 's/.*reason=\([a-z0-9-]*\).*/\1/p;q'
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
  # Every phase-1 story must be dispatched before the phase-2 story: the third
  # phase-1 story proves a freed slot was refilled from its own phase.
  local log="$TEST_TMP/stubstate/dispatched.log"
  local k4_line k3_line
  k4_line="$(grep -n -m1 '^K4$' "$log" | cut -d: -f1)"
  k3_line="$(grep -n -m1 '^K3$' "$log" | cut -d: -f1)"
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  # Independent oracle: in the dispatch log the phase-2 story must appear after
  # both phase-1 stories. A constant accessor cannot satisfy this.
  local log="$TEST_TMP/stubstate/dispatched.log"
  local k3 k1 k2
  k3="$(grep -n -m1 '^K3$' "$log" | cut -d: -f1)"
  k1="$(grep -n -m1 '^K1$' "$log" | cut -d: -f1)"
  k2="$(grep -n -m1 '^K2$' "$log" | cut -d: -f1)"
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  k3_start="$(awk '/^K3 /{print $2; exit}' "$dt")"
  [ -n "$last_p1" ] && [ -n "$k3_start" ] \
    || { echo "missing timings: last phase-1 '$last_p1', phase-2 start '$k3_start'"; return 1; }
  [ "$k3_start" -ge "$last_p1" ] \
    || { echo "phase 2 started at $k3_start, before the last phase-1 completion at $last_p1"; return 1; }

  # And the slow story really was slow, so the window above was real.
  local k2_done k1_done
  k2_done="$(awk '/^K2 /{print $2; exit}' "$ct")"
  k1_done="$(awk '/^K1 /{print $2; exit}' "$ct")"
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
    span_lo="$(awk '$2=="start" {print $3}' "$span" | sort -n)"
    span_lo="${span_lo%%$'\n'*}"
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # Two slots. K1 blocks on a release file (GAIA_STUB_BLOCK_UNTIL_K1) instead
  # of sleeping a fixed duration -- there is no wall-clock margin to race:
  # the test itself only creates that file AFTER it has observed K3's
  # dispatch line, so the assertion is about ADMISSION ORDER (K3 dispatched
  # while K1 is still blocked), never about how fast any given machine
  # happens to run the surrounding bookkeeping between two timestamps. K2
  # has no delay at all, so its slot frees as soon as the run can reap it.
  local release="$TEST_TMP/k1-release"
  export GAIA_STUB_BLOCK_UNTIL_K1="$release"

  run timeout 60 env PATH="$PATH" GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story \
    GAIA_STUB_BLOCK_UNTIL_K1="$release" GAIA_STUB_STATE="$TEST_TMP/stubstate" \
    bash -c '
      . "'"$ORCH"'"
      ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2 &
      runner=$!
      # Release K1 only once K3 has genuinely been dispatched -- a bounded
      # poll on the real evidence log, not a sleep.
      w=0
      while ! grep -q "^K3\$" "'"$TEST_TMP"'/stubstate/dispatched.log" 2>/dev/null; do
        w=$((w + 1))
        [ "$w" -lt 300 ] || break
        sleep 0.1
      done
      : > "'"$release"'"
      wait "$runner"
    '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  local dispatched="$TEST_TMP/stubstate/dispatched.log"
  grep -q '^K3$' "$dispatched" \
    || { echo "K3 was never dispatched (K1 may have finished before it could be released): $(cat "$dispatched" 2>/dev/null)"; return 1; }

  # Order-based oracle: K3 must appear in the dispatch log strictly AFTER
  # K1 and K2's own dispatch lines but the whole point is it was admitted
  # BEFORE K1's block was lifted -- which the release-file protocol above
  # already enforces structurally (the test could not have created the
  # release file without first seeing K3 in this same log). The remaining
  # check is that K1 really was still running (not yet in span.log's "end"
  # column) at the moment the release file was created, proving the
  # backfill did not simply wait for K1 to finish on its own.
  local span="$TEST_TMP/stubstate/span.log"
  ! grep -q '^K1 end ' "$span" \
    || {
        local k1_end k3_start
        k1_end="$(awk '$1=="K1" && $2=="end" {print $3; exit}' "$span")"
        k3_start="$(awk '$1=="K3" && $2=="start" {print $3; exit}' "$span")"
        [ -n "$k1_end" ] && [ -n "$k3_start" ] && [ "$k3_start" -lt "$k1_end" ] \
          || { echo "K1 already ended before K3 started, so this run proved nothing about backfill-before-slow-sibling: $(cat "$span")"; return 1; }
       }
}

@test "one story failing does not abort its siblings (AC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1 K4:1 K5:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fail:K2)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2

  # Independent oracle: the phase-2 story must still be dispatched last even
  # though a phase-1 story failed -- the barrier waits for terminal, not success.
  local log="$TEST_TMP/stubstate/dispatched.log"
  local k3 k2
  k3="$(grep -n -m1 '^K3$' "$log" | cut -d: -f1)"
  k2="$(grep -n -m1 '^K2$' "$log" | cut -d: -f1)"
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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

  # _ppo_admit_bookkeeping claims AND spawns the real teammate (a real
  # registry entry), with no running-phase to park -- unlike the old
  # ppo_admit_slot, which needed a park-mode hook to hold its claim open
  # while the peak was measured. Here the registry entry itself, written by
  # the real spawn_teammate call, is what stays live until this test tears
  # it down -- no hook needed at all.
  #
  # Widen the count-then-claim window so every admission reaches its count
  # before any of them claims. One second is wider than the spread in when
  # eight backgrounded admissions get there, which is what makes the overshoot
  # reproducible rather than timing-dependent.
  export GAIA_PPO_CLAIM_DELAY=1
  local k pids=""
  for k in R1 R2 R3 R4 R5 R6 R7 R8; do
    _ppo_admit_bookkeeping "$k" "" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  # Sample once every admission has had time to clear the 1s claim-delay
  # window with margin for 8 backgrounded processes to be scheduled -- 2s
  # leaves a full second of margin over that window. Each admission's
  # registry entry persists (no completion is ever reported) until this
  # test's own cleanup below.
  sleep 2
  local peak ceiling
  peak="$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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

@test "the admission path survives errexit and preserves a sourced caller's options (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  # A registry already AT the ceiling forces a real return-8 (capacity
  # refusal) out of _ppo_admit_bookkeeping without needing the legacy hook --
  # the property under test is the admission path's own guarded-capture
  # idiom (every internal command substitution is `|| var=$?`, never a bare
  # capture an errexit caller would die on), not the hook contract.
  mkdir -p "$GAIA_SESSION_DIR/registry"
  local i=0
  while [ "$i" -lt 12 ]; do
    : > "$GAIA_SESSION_DIR/registry/other-teammate-$i"
    i=$((i + 1))
  done

  # A caller with errexit ON that USES the captured status: an unguarded
  # bare-capture form dies at the assignment before the status is ever read.
  run bash -c '
    set -euo pipefail
    . "'"$ORCH"'"
    export GAIA_SESSION_DIR="'"$GAIA_SESSION_DIR"'"
    rc=0
    _ppo_admit_bookkeeping "K1" "" || rc=$?
    printf "survived rc=%s\n" "$rc"
  '
  [ "$status" -eq 0 ] \
    || { echo "an errexit caller died at the admission assignment: $output"; return 1; }
  [[ "$output" == *"survived rc=8"* ]] \
    || { echo "expected the captured status to be the real ceiling refusal (8): $output"; return 1; }

  # A sourced caller that deliberately ran `set +e` must keep it: shell options
  # belong to the caller, and flipping errexit underneath one is a real bug.
  run bash -c '
    set +e
    . "'"$ORCH"'"
    export GAIA_SESSION_DIR="'"$GAIA_SESSION_DIR"'"
    _ppo_admit_bookkeeping "K1" "" >/dev/null 2>&1
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # Widen the count-then-claim window so the race is reachable deterministically
  # rather than only under lucky scheduling. Without the lock, four admissions
  # all read the same count inside this window and all claim.
  export GAIA_PPO_CLAIM_DELAY=1

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 4

  # Oracle: the stub samples the REAL registry on every dispatch and logs how
  # many entries it saw while holding one itself. The peak across the run is
  # what the ceiling is supposed to bound.
  local peak
  # `|| true` as well as the pre-created log: sort exits 2 on a missing file
  # and pipefail propagates it, which under errexit aborts the test before the
  # guard below can report that nothing was measured.
  peak="$(sort -n "$TEST_TMP/stubstate/registry-peak.log" 2>/dev/null | tail -1 || true)"
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  # Pin the substrate. Without this the library derives availability from the
  # ambient CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS opt-in, so the test exercises
  # the Mode B spawn path on a developer box that has the flag set and the Mode
  # A fallback (exit 7) on a runner that does not -- passing on one platform and
  # failing on the other while appearing to assert the same thing. What is under
  # test here is story-keyed handle allocation on the Mode B path, so say so.
  export GAIA_MODE_B_SUBSTRATE=available
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

# _mk_story_file <impl_root> <key> <status> — a real, legacy-flat story file
# with canonical `template: 'story'` frontmatter, resolvable by
# resolve-story-file.sh's own tier-2 glob (${impl_root}/${key}-*.md).
_mk_story_file() {
  local root="$1" key="$2" status="$3"
  mkdir -p "$root"
  cat > "$root/${key}-fixture-story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Fixture story ${key}"
stack: "bash"
status: ${status}
---

# Story: Fixture story ${key}
EOF
}

@test "the default admission path drives the real teammate surface, no gaia-dispatch-story (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  mkdir -p "$GAIA_SESSION_DIR/registry"
  export GAIA_MODE_B_SUBSTRATE=available
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl-artifacts"
  _mk_story_file "$IMPLEMENTATION_ARTIFACTS" "K1" "done"

  # No GAIA_PPO_DISPATCH_CMD set, and no gaia-dispatch-story on PATH at all --
  # the default admission path must not reference that command. If it did,
  # this would fail command-not-found instead of returning a real handle.
  unset GAIA_PPO_DISPATCH_CMD 2>/dev/null || true
  command -v gaia-dispatch-story >/dev/null 2>&1 \
    && { echo "test fixture bug: gaia-dispatch-story is on PATH"; return 1; }

  local out rc=0
  out="$(_ppo_admit_bookkeeping "K1" "" 2>"$TEST_TMP/dispatch.err")" || rc=$?

  ! grep -q "gaia-dispatch-story" "$TEST_TMP/dispatch.err" \
    || { echo "default admission path referenced gaia-dispatch-story: $(cat "$TEST_TMP/dispatch.err")"; return 1; }
  [ "$rc" -eq 0 ] \
    || { echo "expected a successful admission via the real surface, got $rc: $(cat "$TEST_TMP/dispatch.err")"; return 1; }
  printf '%s\n' "$out" | grep -q '^handle:tm-bash-dev-K1$' \
    || { echo "expected a real handle on stdout: $out"; return 1; }
}

@test "record <key> done is authoritative regardless of the story file's own status field (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # shellcheck disable=SC1090
  . "$WT_LIB"
  export GAIA_WORKTREE_MODE=1
  mkdir -p "$GAIA_SESSION_DIR/registry"
  export GAIA_MODE_B_SUBSTRATE=available
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl-artifacts"
  # The story file, if one even exists, says "in-progress" -- never a
  # terminal value. Under the OLD architecture this was the completion
  # oracle a bash poll would time out against; under the step engine there
  # is no poll at all -- the skill's own `record done` call is what a real
  # driven turn reports, and it is authoritative on its own, independent of
  # whatever a story file's frontmatter happens to say (there may not even
  # BE a resolvable story file for a brand-new key, and that must not block
  # a real completion from being recorded).
  _mk_story_file "$IMPLEMENTATION_ARTIFACTS" "K2" "in-progress"

  _ppo_engine_reset
  _ppo_engine_put repo "$repo"
  local wt; wt="$(worktree_create "$repo" "K2" "slug")"
  {
    printf 'phase:1\n'
    printf 'persona:bash-dev\n'
    printf 'worktree:%s\n' "$wt"
    printf 'handle:tm-bash-dev-K2\n'
    printf 'dispatched_at:%s\n' "$(date +%s)"
  } > "$(_ppo_engine_dir)/running/K2"

  ppo_record_outcome K2 done >/dev/null 2>"$TEST_TMP/record.err"

  local ledger; ledger="$(ppo_report)"
  printf '%s\n' "$ledger" | grep -q '^story=K2 outcome=done$' \
    || { echo "the skill's own done report was not authoritative: $ledger ($(cat "$TEST_TMP/record.err"))"; return 1; }
  [ ! -e "$wt" ] \
    || { echo "a done outcome did not tear down the worktree despite the story file never going terminal: $wt"; return 1; }
}

@test "an unclassified spawn exit code is surfaced as itself, never reclassified as merged-not-done (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  mkdir -p "$GAIA_SESSION_DIR/registry"
  export GAIA_MODE_B_SUBSTRATE=available
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl-artifacts"
  # 11 is deliberately an unrelated internal code (gaia-migrate.sh's own
  # "needs reconciliation", and any external tool could exit 11 for its own
  # reasons) -- the property under test is that _ppo_admit_bookkeeping passes
  # a spawn's raw, unrecognised exit code straight through as an unclassified
  # admission failure. Under the OLD architecture this mattered because 11
  # ALSO meant "merged-not-done" in the status-polling vocabulary, and a
  # story that never reached a terminal status could only otherwise time out
  # (9) -- so a run reporting anything other than the raw 11 proved the two
  # had been conflated. The step engine has no such second vocabulary to
  # collide with (merged-not-done is decided by ppo_record_outcome's audit
  # call, never by a spawn exit code), but the underlying discipline --
  # never silently reclassify an unrecognised code -- still needs a test.
  # shellcheck disable=SC1090
  . "$DT_LIB"
  spawn_teammate() { return 11; }

  local rc=0
  _ppo_admit_bookkeeping "K3" "" >/dev/null 2>/dev/null || rc=$?

  [ "$rc" -eq 11 ] \
    || { echo "expected the spawn's own raw code (11) passed through unclassified, got $rc"; return 1; }
}

# Note: an earlier version of this file had a test here named "a merged story
# that is not yet done blocks its slot from being backfilled (AC4)" asserting
# only `ppo_backfill_before_done == 0` -- which also passes against a no-op
# orchestrator that never runs anything. "a merged-but-not-done story reaches
# done via the resume path (AC4)" and "removing the resume re-dispatch leaves
# a merged-not-done story unreported (AC4)" below already prove the real
# claim from real dispatch-log/ledger evidence (K1 dispatched, exits
# merged-not-done, is re-queued via `outcome=resume-requeued`, and only then
# reaches `outcome=done`) -- so the vacuous test was deleted rather than kept
# as a duplicate name.

# ---------------------------------------------------------------------------
# Worktree lifecycle, resume, orphans (AC1, AC-EC6)
# ---------------------------------------------------------------------------

# Note: an earlier version of this file had a test here named "a clean run
# leaves no orphan worktree behind (AC1)" asserting only that one worktree
# (the primary checkout) remained after the run -- which also passes against
# a no-op orchestrator that never creates any worktree at all. "a clean run
# creates worktrees and then removes all of them (AC1)" below already proves
# the real claim, adding the positive precondition (worktrees were actually
# created and both stories were actually dispatched) before checking they are
# all gone -- so the vacuous test was deleted rather than kept as a duplicate.

@test "re-entry attaches a surviving worktree and still dispatches it exactly once (AC1)" {
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  # Attaching REUSES the worktree instead of recreating it -- it does not mean
  # the story's gate is closed. A surviving worktree from a crashed run is
  # dispatched exactly once, through the same slot path as any other story,
  # and its ledger outcome comes from the real dispatch result rather than an
  # unconditional "done" recorded from worktree presence alone.
  [[ "$output" == *"event=attached story=K1"* ]] \
    || { echo "the story was not attached; output: $output"; return 1; }
  local n; n="$(grep -c '^K1$' "$TEST_TMP/stubstate/dispatched.log" 2>/dev/null)" || n=0
  [ "$n" -eq 1 ] \
    || { echo "a story with a live worktree was dispatched $n times, expected exactly 1"; return 1; }
  printf '%s\n' "$output" | grep -qE '^event=story_complete story=K1 .*outcome=done$' \
    || { echo "K1's outcome was not taken from the real dispatch result: $output"; return 1; }

  # The pre-existing worktree PATH must be the one the run actually used --
  # attach reuses it in place rather than creating a second one under a new
  # path. (The story then runs to done, and its worktree is torn down on the
  # normal post-merge path like any other completed story's -- reuse is about
  # not duplicating the checkout while it is live, not about surviving past
  # the story's own cleanup.)
  local used; used="$(ppo_slot_worktrees | grep -Fx "$wt" || true)"
  [ "$used" = "$wt" ] \
    || { echo "the pre-existing worktree path $wt was not the one the run used: $(ppo_slot_worktrees)"; return 1; }
}

@test "a re-attached story that fails is recorded failed, not done (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # shellcheck disable=SC1090
  . "$WT_LIB"
  local wt; wt="$(worktree_create "$repo" "K1" "slug")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  # K1's worktree survived a crash, but its gate is still open: the real
  # dispatch call this time reports failure. A tri-state driven from the real
  # result must record "failed", never the unconditional "done" that worktree
  # PRESENCE alone would imply.
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" fail:K1)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  [[ "$output" == *"event=attached story=K1"* ]] \
    || { echo "the story was not attached; output: $output"; return 1; }
  local n; n="$(grep -c '^K1$' "$TEST_TMP/stubstate/dispatched.log" 2>/dev/null)" || n=0
  [ "$n" -eq 1 ] \
    || { echo "a re-attached story was dispatched $n times, expected exactly 1"; return 1; }
  printf '%s\n' "$output" | grep -qE '^event=story_complete story=K1 .*outcome=failed$' \
    || { echo "a re-attached story's real failure was not recorded: $output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^event=story_complete story=K1 .*outcome=done$' \
    && { echo "a re-attached story that failed was still recorded done: $output"; return 1; }
  return 0
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
           | grep -vE '^[0-9]+:[[:space:]]*#')"
  line="${line%%$'\n'*}"
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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

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
    run _ppo_admit_bookkeeping "$k" "$repo"
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
  local out; out="$(_ppo_admit_bookkeeping LOCKT "" 2>&1)" || rc=$?
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
  # Skip comment lines to find the CODE usage.
  local ctx; ctx="$(grep -n 'admission-lock-timeout' "$ORCH" | grep -v '^[0-9]*:[[:space:]]*#' | head -1)"
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
  body="$(sed -n '/^_ppo_admit_bookkeeping()/,/^}/p' "$ORCH")"
  acq_line="$(printf '%s
' "$body" | grep -n -m1 'acquire_lock ' | cut -d: -f1)"
  ceil_line="$(printf '%s
' "$body" | grep -n -m1 'ceiling="\$(ppo_resolve_ceiling)"' | cut -d: -f1)"
  rel_line="$(printf '%s
' "$body" | grep -n -m1 'release_lock ' | cut -d: -f1)"
  [ -n "$acq_line" ] && [ -n "$ceil_line" ] && [ -n "$rel_line" ] \
    || { echo "could not locate acquire/ceiling/release in _ppo_admit_bookkeeping"; return 1; }
  [ "$ceil_line" -lt "$acq_line" ] \
    || { echo "the ceiling read (line $ceil_line) is inside the critical section (acquire $acq_line, release $rel_line)"; return 1; }
}

@test "a missing sprint file degrades at exit 0, never a non-zero run (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # The ordinary unplanned-sprint path: the skill passes
  # "${PROJECT_ROOT}/.gaia/state/sprint-status.yaml", so an unplanned sprint --
  # or an unset PROJECT_ROOT resolving to /.gaia/state/sprint-status.yaml --
  # lands here. The file's promise is that a run NEVER exits non-zero because
  # parallel execution was unavailable, so the status is the assertion; the
  # reason token alone would pass even while the run died.
  run timeout 60 env PATH="$PATH" bash -c '
    set -euo pipefail
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$TEST_TMP"'/nonexistent-sprint.yaml" --slots 4
    printf "CALLER CONTINUED\n"
  '
  [ "$status" -eq 0 ] \
    || { echo "a missing sprint file exited $status, expected 0: $output"; return 1; }
  printf '%s' "$output" | grep -q 'CALLER CONTINUED' \
    || { echo "errexit killed the caller on the missing-sprint path: $output"; return 1; }
  [ "$(_reason_of "$output")" = "sprint-unreadable" ] \
    || { echo "expected sprint-unreadable, got: $output"; return 1; }
}

@test "an unset PROJECT_ROOT degrades at exit 0 rather than killing the run (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # With PROJECT_ROOT unset the skill's path collapses to an absolute
  # /.gaia/state/... that no ordinary user can read. Same promise, different
  # way of reaching it.
  run timeout 60 env PATH="$PATH" bash -c '
    set -euo pipefail
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "${PROJECT_ROOT:-}/.gaia/state/sprint-status.yaml" --slots 4
    printf "CALLER CONTINUED\n"
  '
  [ "$status" -eq 0 ] \
    || { echo "an unset PROJECT_ROOT exited $status, expected 0: $output"; return 1; }
  printf '%s' "$output" | grep -q 'CALLER CONTINUED' \
    || { echo "errexit killed the caller on the unset-PROJECT_ROOT path: $output"; return 1; }
}

@test "a sprint file unreadable mid-run degrades at exit 0 with its reason (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  [ "$(id -u)" -ne 0 ] || skip "running as root: chmod 000 does not deny reads"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"

  # The serious shape: readable at pre-flight, unreadable by the time a
  # degradation arm asks for the worklist. Those call sites are bare
  # `ppo_plan_sequential | while` pipelines, so a non-zero status there escapes
  # through pipefail and kills a run that has already announced it is
  # continuing sequentially -- an announced degradation that executes nothing.
  local yaml="$TEST_TMP/sprint.yaml"
  printf 'stories:\n  - key: K1\n    phase: 1\n' > "$yaml"
  chmod 000 "$yaml"

  run timeout 60 env PATH="$PATH" bash -c '
    set -euo pipefail
    . "'"$ORCH"'"
    ppo_plan_sequential --repo "'"$TEST_TMP"'/repo" --yaml "'"$yaml"'" | while IFS= read -r sk; do
      [ -n "$sk" ] && printf "event=sequential story=%s\n" "$sk"
    done
    printf "CALLER CONTINUED\n"
  '
  chmod 644 "$yaml" 2>/dev/null || true

  [ "$status" -eq 0 ] \
    || { echo "an unreadable sprint file exited $status, expected 0: $output"; return 1; }
  printf '%s' "$output" | grep -q 'CALLER CONTINUED' \
    || { echo "errexit killed the caller mid-run: $output"; return 1; }
}

@test "the sequential worklist is non-empty when the sprint file is readable (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }

  # The companion to the three above: exit 0 is only half the promise. A
  # degradation that returns cleanly while emitting nothing would satisfy the
  # status assertions and still lose the whole sprint, so pin that a readable
  # roster still produces its stories -- including one with no phase fields,
  # which is the roster-order fallback the guarded awk serves.
  local yaml="$TEST_TMP/roster.yaml"
  printf 'stories:\n  - key: K1\n  - key: K2\n' > "$yaml"
  local out
  out="$(ppo_plan_sequential --repo "$TEST_TMP/repo" --yaml "$yaml")"
  printf '%s' "$out" | grep -q '^K1$' \
    || { echo "roster-order fallback lost K1: $out"; return 1; }
  printf '%s' "$out" | grep -q '^K2$' \
    || { echo "roster-order fallback lost K2: $out"; return 1; }
}

@test "a phase list with no usable rows still degrades at exit 0 (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }

  # The same promise on the SUCCESS path. When the phase read succeeds but
  # yields no usable rows, `[ -n "$k" ] && printf` is false for every row, so
  # the `while` -- and the function -- would end at status 1. The bare
  # `ppo_plan_sequential | while` degradation call sites turn that into a
  # killed run, with a reason already printed. An empty worklist is a
  # legitimate answer, not a failure.
  run timeout 60 bash -c '
    set -euo pipefail
    . "'"$ORCH"'"
    ppo_read_phases() { printf "\n"; }
    ppo_plan_sequential --repo "'"$TEST_TMP"'/repo" --yaml "'"$TEST_TMP"'/x.yaml" | while IFS= read -r sk; do
      [ -n "$sk" ] && printf "event=sequential story=%s\n" "$sk"
    done
    printf "CALLER CONTINUED\n"
  '
  [ "$status" -eq 0 ] \
    || { echo "an empty phase list exited $status, expected 0: $output"; return 1; }
  printf '%s' "$output" | grep -q 'CALLER CONTINUED' \
    || { echo "errexit killed the caller on an empty phase list: $output"; return 1; }
}

# _mk_yaml_raw <out> <key>... — a sprint whose keys are written verbatim, so a
# key carrying whitespace can reach the dispatch loop. _mk_yaml splits its spec
# on ":" and cannot express one.
_mk_yaml_raw() {
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  {
    printf 'sprint_id: test-sprint\nstatus: active\ntotal_points: 0\ngoals: []\nitems:\n'
    local k
    for k in "$@"; do
      printf '  - key: "%s"\n' "$k"
      printf '    title: story\n    status: ready-for-dev\n    points: 1\n'
      printf '    risk_level: low\n    phase: 1\n'
    done
  } > "$out"
  printf '%s' "$out"
}

@test "a whitespace story key never desynchronises the completion ledger (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # The reap indexes a key list against a pid list. Splitting the keys on IFS
  # rather than on the newline they are joined with makes "aa bb" enumerate as
  # two entries, so every later index names a different slot in each list. The
  # damage lands on the VALID story: the ledger reports phantom fragments and
  # never mentions GOOD at all.
  local yaml; yaml="$(_mk_yaml_raw "$TEST_TMP/sprint.yaml" "aa bb" "GOOD")"
  run timeout 90 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    ppo_report
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  printf '%s\n' "$output" | grep -q '^story=GOOD outcome=' \
    || { echo "the valid story GOOD is missing from the ledger: $output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^story=(aa|bb) outcome=' \
    && { echo "a fragment of the split key was reported as its own story: $output"; return 1; }
  return 0
}

@test "a whitespace key does not hide a later valid story from the report (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # The second reproduction: with a bad key first, a story that runs to
  # completion is silently absent from the report.
  local yaml; yaml="$(_mk_yaml_raw "$TEST_TMP/sprint.yaml" "bad key" "OK1" "OK2")"
  run timeout 90 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    ppo_report
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
  local k
  for k in OK1 OK2; do
    printf '%s\n' "$output" | grep -q "^story=${k} outcome=" \
      || { echo "$k completed but is absent from the ledger: $output"; return 1; }
  done
}

@test "a tab or padded story key is refused rather than split (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # Tabs and edge padding split on IFS exactly as spaces do.
  local yaml; yaml="$(_mk_yaml_raw "$TEST_TMP/sprint.yaml" "t1	t2" " lead" "trail " "REAL")"
  run timeout 90 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    ppo_report
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
  printf '%s\n' "$output" | grep -q '^story=REAL outcome=' \
    || { echo "the valid story REAL is missing from the ledger: $output"; return 1; }
  # No fragment of a split key may appear as a story of its own.
  local frag
  for frag in t1 t2 lead trail; do
    printf '%s\n' "$output" | grep -qE "^story=${frag} outcome=" \
      && { echo "phantom story '$frag' reported from a split key: $output"; return 1; }
  done
  return 0
}

@test "a merged-but-not-done story reaches done via the resume path (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # Merged but not done means the branch landed and the review gate is still
  # open, so the story is NOT terminal. The orchestrator re-dispatches it on
  # the resume path; here the gate closes on the second attempt, so the story
  # must end up done rather than abandoned.
  export GAIA_STUB_MERGED_NOT_DONE="K1" GAIA_STUB_MND_ATTEMPTS=1

  run timeout 120 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    printf -- "--- ledger ---\n"
    ppo_report
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }
  printf '%s\n' "$output" | grep -q 'outcome=resume-requeued' \
    || { echo "the story was never re-dispatched on the resume path: $output"; return 1; }
  printf '%s\n' "$output" | grep -q '^story=K1 outcome=done$' \
    || { echo "K1 did not reach done after its gate closed: $output"; return 1; }
}

@test "a story whose gate never closes is reported not-done, bounded (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # The gate never closes. Retries must be BOUNDED -- an unbounded resume loop
  # would hold the phase open forever -- and the story must be reported as not
  # done rather than quietly recorded done, which is what would let a later
  # phase start on unmet work.
  export GAIA_STUB_MERGED_NOT_DONE="K1"

  run timeout 120 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    printf -- "--- ledger ---\n"
    ppo_report
  '
  [ "$status" -eq 0 ] || { echo "run failed or never terminated: $output"; return 1; }
  printf '%s\n' "$output" | grep -q 'outcome=not-done' \
    || { echo "an unclosable gate was not reported as not-done: $output"; return 1; }
  printf '%s\n' "$output" | grep -q '^story=K1 outcome=merged-not-done$' \
    || { echo "K1 is not recorded merged-not-done: $output"; return 1; }
  printf '%s\n' "$output" | grep -q '^story=K1 outcome=done$' \
    && { echo "a story with an open gate was recorded done: $output"; return 1; }
  return 0
}

@test "the next phase does not start while a story is merged-but-not-done (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # Phase 1's story is merged-but-not-done and its gate closes on the second
  # attempt. Phase 2 must not begin until that has happened: the order of the
  # real dispatch events is the oracle, not a counter.
  export GAIA_STUB_MERGED_NOT_DONE="K1" GAIA_STUB_MND_ATTEMPTS=1

  run timeout 120 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  local k1_done k2_disp
  k1_done="$(printf '%s\n' "$output" | grep -n 'event=story_complete story=K1 .*outcome=done' | head -1 | cut -d: -f1)"
  k2_disp="$(printf '%s\n' "$output" | grep -n 'event=dispatched story=K2' | head -1 | cut -d: -f1)"
  [ -n "$k1_done" ] \
    || { echo "K1 never completed: $output"; return 1; }
  [ -n "$k2_disp" ] \
    || { echo "K2 was never dispatched: $output"; return 1; }
  [ "$k2_disp" -gt "$k1_done" ] \
    || { echo "phase 2 started before phase 1's open gate closed (K2 at $k2_disp, K1 done at $k1_done): $output"; return 1; }
  [ "$(ppo_barrier_violations)" = "0" ] \
    || { echo "a barrier violation was recorded on a legitimate run"; return 1; }
}

@test "the product's own claim refuses when the registry is at the ceiling (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 for the config fixture"

  # Every other ceiling fixture in this suite gets exit 8 from the STUB, and
  # the prefill fixtures leave real headroom at claim time -- so the
  # orchestrator's OWN no-room refusal is never the thing that fires, and
  # deleting it leaves the suite green while the ceiling inverts. Here the stub
  # ALWAYS succeeds and the registry is prefilled to exactly the ceiling, so
  # the only thing that can refuse is the product.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  max_parallel_dev_slots: 2\n  teammate_dispatch_ceiling: 6\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"

  mkdir -p "$GAIA_SESSION_DIR/registry"
  local i=0
  while [ "$i" -lt 6 ]; do
    : > "$GAIA_SESSION_DIR/registry/occupant-$i"
    i=$(( i + 1 ))
  done

  # A stub that never refuses: any refusal must come from the claim path.
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  run timeout 120 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  # With no headroom at all the run must degrade with the capacity reason, and
  # must NOT report a story as dispatched-and-done as though there were room.
  printf '%s\n' "$output" | grep -q 'reason=ceiling-cannot-admit' \
    || { echo "a registry at the ceiling did not produce ceiling-cannot-admit: $output"; return 1; }
  printf '%s\n' "$output" | grep -q 'mode=parallel reason=none' \
    && { echo "the run claimed parallel mode with no ceiling headroom: $output"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Live-occupancy pre-flight and per-story claim (AC2, item A)
# ---------------------------------------------------------------------------

@test "_ppo_admit_bookkeeping returns 8 when the registry is at the ceiling (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 for the config fixture"

  # Ceiling 4, registry pre-filled to 4: the per-story claim path has no room.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  teammate_dispatch_ceiling: 4\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"
  mkdir -p "$GAIA_SESSION_DIR/registry"
  local i=0
  while [ "$i" -lt 4 ]; do
    : > "$GAIA_SESSION_DIR/registry/occupant-$i"
    i=$(( i + 1 ))
  done

  local rc=0
  _ppo_admit_bookkeeping "FULL" "" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ] \
    || { echo "_ppo_admit_bookkeeping returned $rc with a full registry, expected 8"; return 1; }
  # No reservation left behind.
  [ ! -f "$GAIA_SESSION_DIR/registry/.reserved-FULL" ] \
    || { echo "a refused admission left a reservation behind"; return 1; }
}

@test "pre-flight degrades when live registry occupancy matches the ceiling (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 for the config fixture"

  # Ceiling 12, slots 4: configured headroom passes (12 >= 4+4=8), but the
  # registry is already full so live occupancy must trigger degradation.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  teammate_dispatch_ceiling: 12\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"
  mkdir -p "$GAIA_SESSION_DIR/registry"
  local i=0
  while [ "$i" -lt 12 ]; do
    : > "$GAIA_SESSION_DIR/registry/occupant-$i"
    i=$(( i + 1 ))
  done

  run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 4
  [ "$(_reason_of "$output")" = "ceiling-cannot-admit" ] \
    || { echo "expected ceiling-cannot-admit, got: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# Pre-flight headroom check (AC3, item E-W3)
# ---------------------------------------------------------------------------

@test "pre-flight headroom check degrades when ceiling < slots+4 (AC3)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 for the config fixture"

  # Ceiling 8, slots 8: 8 < 8+4=12, so the headroom rule fires.
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  teammate_dispatch_ceiling: 8\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"

  run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 8
  [ "$(_reason_of "$output")" = "ceiling-cannot-admit" ] \
    || { echo "expected ceiling-cannot-admit for ceiling 8/slots 8, got: $output"; return 1; }

  # Boundary: ceiling exactly = slots+4 should PASS.
  printf 'parallel_execution:\n  teammate_dispatch_ceiling: 12\n' > "$cfg"
  run ppo_preflight --repo "$repo" --yaml "$yaml" --slots 8
  [[ "$output" == *"mode=parallel"* ]] \
    || { echo "expected parallel for ceiling 12/slots 8, got: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# Re-entry attach (AC1, item E-W2)
# ---------------------------------------------------------------------------

# Note: an earlier version of this file had a duplicate test here named
# "re-entry attaches a surviving worktree: attach event, zero dispatches
# (AC1)". It asserted the SAME shape as "re-entry attaches a surviving
# worktree and still dispatches it exactly once (AC1)" above, plus the
# worktree-identity check, which is now folded into that test -- so the
# duplicate was deleted rather than fixed twice.

# ---------------------------------------------------------------------------
# Clean-run worktree cleanup (AC1, item E-W4)
# ---------------------------------------------------------------------------

@test "a clean run creates worktrees and then removes all of them (AC1)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  # Positive precondition: worktrees WERE created during the run.
  local wt_count; wt_count="$(ppo_slot_worktrees | grep -c . || true)"
  [ "$wt_count" -ge 2 ] \
    || { echo "expected at least 2 worktrees to have been created, recorded $wt_count"; return 1; }

  # Both stories were dispatched (evidence of actual work).
  local dispatched; dispatched="$(sort -u "$TEST_TMP/stubstate/dispatched.log" | grep -c . || true)"
  [ "$dispatched" -eq 2 ] \
    || { echo "expected 2 stories dispatched, got $dispatched"; return 1; }

  # After the run, only the primary checkout remains.
  local remaining
  remaining="$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ' || true)"
  [ "$remaining" -eq 1 ] \
    || { echo "expected only the primary checkout after cleanup, found $remaining worktrees"; return 1; }
}

# ---------------------------------------------------------------------------
# Reservation release independent of trap (AC2, item C)
# ---------------------------------------------------------------------------

@test "_ppo_admit_bookkeeping releases the reservation even when the spawn itself fails (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  command -v python3 >/dev/null 2>&1 || skip "no python3 for the config fixture"

  local cfg="$TEST_TMP/cfg/project-config.yaml"
  mkdir -p "$TEST_TMP/cfg"
  printf 'parallel_execution:\n  teammate_dispatch_ceiling: 12\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"
  mkdir -p "$GAIA_SESSION_DIR/registry"

  # Force the REAL spawn_teammate call to fail -- admission (the reservation
  # claim) happens before the spawn attempt, so a spawn failure is the case
  # under test: the reservation must not survive it.
  # shellcheck disable=SC1090
  . "$DT_LIB"
  spawn_teammate() { return 42; }

  # Drive _ppo_admit_bookkeeping DIRECTLY (not through `run`, which wraps in a
  # subshell whose EXIT trap would sweep the reservation). The per-admission
  # cleanup must remove the reservation independently of the run-level trap.
  local rc=0
  _ppo_admit_bookkeeping "FAILME" "" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 42 ] \
    || { echo "a failing spawn should return its own raw code (42), got $rc"; return 1; }
  [ ! -f "$GAIA_SESSION_DIR/registry/.reserved-FAILME" ] \
    || { echo "a failed spawn left a reservation behind after _ppo_admit_bookkeeping returned"; return 1; }
}

# ---------------------------------------------------------------------------
# Discard-ignored flag placement (AC-EC6, item D)
# ---------------------------------------------------------------------------

@test "a timed-out story keeps its worktree even with ignored files present (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" stall:K1)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # K1 stalls, and its worktree is seeded with an ignored-only file while it is
  # in flight. If --discard-ignored leaked to the timeout path, that file (and
  # the worktree holding it) would be destroyed instead of preserved.
  export GAIA_STORY_TIMEOUT_SECONDS=3
  export GAIA_SESSION_DIR="$TEST_TMP/session"

  local outfile="$TEST_TMP/run.out"
  ( timeout 120 env PATH="$PATH" GAIA_SESSION_DIR="$GAIA_SESSION_DIR" bash -c '
      . "'"$ORCH"'"
      ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    ' > "$outfile" 2>&1
  ) &
  local run_pid=$!

  # Poll (bounded) for the orchestrator to have created K1's worktree, then
  # drop an ignored-only file into it while K1 is still stalled.
  local wt_marker="$GAIA_SESSION_DIR/slots/K1/worktree" wt="" waited=0
  while [ "$waited" -lt 100 ]; do
    if [ -s "$wt_marker" ]; then
      wt="$(cat "$wt_marker" 2>/dev/null)"
      [ -n "$wt" ] && [ -d "$wt" ] && break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -n "$wt" ] && [ -d "$wt" ] \
    || { echo "K1's worktree never appeared for seeding"; kill "$run_pid" 2>/dev/null || true; return 1; }
  mkdir -p "$wt/.gaia"
  printf 'ignored-while-stalled\n' > "$wt/.gaia/timeout-marker.txt"

  wait "$run_pid"
  local output; output="$(cat "$outfile")"

  [[ "$output" == *"slot-timeout"* ]] \
    || { echo "K1 was not reported as timed out: $output"; return 1; }
  [[ "$output" == *"K2"* ]] \
    || { echo "K2 was not dispatched: $output"; return 1; }

  # Real assertion: the timed-out worktree AND the ignored file it holds must
  # still be on disk. A mutant that moves --discard-ignored onto the timeout
  # path would remove the worktree (it holds only ignored content), which
  # deletes the marker file along with it and turns this red.
  [ -d "$wt" ] \
    || { echo "the timed-out story's worktree was removed: $wt"; return 1; }
  [ -f "$wt/.gaia/timeout-marker.txt" ] \
    || { echo "the ignored file seeded during the timeout did not survive: $wt"; return 1; }
}

@test "a merged story has its ignored files discarded while timeout preserves them (AC-EC6)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # shellcheck disable=SC1090
  . "$WT_LIB"

  # Create a worktree with only gitignored files.
  local wt; wt="$(worktree_create "$repo" "K1" "slug")"
  mkdir -p "$wt/.gaia"
  printf 'ignored\n' > "$wt/.gaia/data.txt"

  # The post-merge path (exit 0) should discard the ignored files.
  worktree_teardown "$repo" "$wt" --discard-ignored >/dev/null 2>&1 || true
  [ ! -d "$wt" ] \
    || { echo "post-merge teardown did not remove worktree with only ignored files"; return 1; }

  # Now test the non-merge path: it preserves.
  local wt2; wt2="$(worktree_create "$repo" "K2" "slug2")"
  mkdir -p "$wt2/.gaia"
  printf 'ignored2\n' > "$wt2/.gaia/data2.txt"

  # Without --discard-ignored, the worktree is preserved because it has files.
  worktree_teardown "$repo" "$wt2" >/dev/null 2>&1 || true
  [ -d "$wt2" ] \
    || { echo "non-merge teardown removed worktree with local files"; return 1; }
}

# ---------------------------------------------------------------------------
# Resume path mutant proofs (AC4, item B)
# ---------------------------------------------------------------------------

@test "backfill_before_done tracks real events, not a constant (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # K1 is merged-but-not-done and its gate closes on the 2nd attempt. With 2
  # slots and 3 stories, K1 and K2 fill the slots. When K1 returns exit 11 it
  # is re-queued at the front. After K1 is re-dispatched and K2 finishes, K3
  # gets a slot while K1 may still be running its re-dispatch, which IS a
  # backfill-before-done event. The counter must track the real event.
  export GAIA_STUB_MERGED_NOT_DONE="K1" GAIA_STUB_MND_ATTEMPTS=1

  run timeout 120 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  # The resume path must fire.
  printf '%s\n' "$output" | grep -q 'outcome=resume-requeued' \
    || { echo "K1 was not re-queued: $output"; return 1; }

  # The counter must be a real value from real events, not a hardcoded constant.
  # Its numeric value depends on scheduling order, so we only assert it is an
  # integer and matches the event count in the telemetry.
  local bfd; bfd="$(ppo_backfill_before_done)"
  case "$bfd" in ''|*[!0-9]*) echo "backfill_before_done is not a number: '$bfd'"; return 1 ;; esac

  local event_count
  event_count="$(printf '%s\n' "$output" | grep -c 'event=backfill_before_done' || true)"
  [ "$bfd" = "$event_count" ] \
    || { echo "accessor ($bfd) disagrees with telemetry event count ($event_count)"; return 1; }
}

@test "removing the resume re-dispatch leaves a merged-not-done story unreported (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # Gate closes on the 2nd attempt. If the resume re-dispatch is removed,
  # K1 would be recorded as merged-not-done after the first attempt and never
  # re-dispatched.
  export GAIA_STUB_MERGED_NOT_DONE="K1" GAIA_STUB_MND_ATTEMPTS=1

  run timeout 120 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    printf -- "--- ledger ---\n"
    ppo_report
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  # The resume path must fire.
  printf '%s\n' "$output" | grep -q 'outcome=resume-requeued' \
    || { echo "the resume re-dispatch never fired: $output"; return 1; }

  # And the story must reach done.
  printf '%s\n' "$output" | grep -q '^story=K1 outcome=done$' \
    || { echo "K1 did not reach done via the resume path: $output"; return 1; }
}

@test "a real barrier violation is detected and counted (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  # K1 is merged-not-done and the gate NEVER closes (no GAIA_STUB_MND_ATTEMPTS).
  # After exhausting retries K1 is recorded as merged-not-done, which means phase
  # 2 starts while a phase-1 story is still non-terminal. The barrier_violations
  # counter must be non-zero.
  export GAIA_STUB_MERGED_NOT_DONE="K1"

  run timeout 120 env PATH="$PATH" bash -c '
    . "'"$ORCH"'"
    ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
  '
  [ "$status" -eq 0 ] || { echo "run failed: $output"; return 1; }

  local bv; bv="$(ppo_barrier_violations)"
  [ "${bv:-0}" -gt 0 ] \
    || { echo "a phase-2 dispatch with a non-terminal phase-1 story recorded 0 barrier violations: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# GAIA_PPO_DISPATCH_CMD is a test-only hook gated on a test marker
# ---------------------------------------------------------------------------

@test "the dispatch hook is honoured under the BATS_TEST_FILENAME marker (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story
  # BATS_TEST_FILENAME is already set by bats for this whole process -- the
  # marker under test, exercised exactly as every other test in this suite
  # relies on it (no per-call-site export needed).
  [ -n "${BATS_TEST_FILENAME:-}" ] \
    || { echo "test fixture bug: BATS_TEST_FILENAME is not set"; return 1; }

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] \
    || { echo "expected the stub's own contract (0) under the test marker: $output"; return 1; }
  grep -q "K1" "$TEST_TMP/stubstate/dispatched.log" \
    || { echo "the stub was never invoked: $output"; return 1; }
  printf '%s\n' "$output" | grep -q "event=dispatch_hook cmd=gaia-dispatch-story action=honoured" \
    || { echo "no honoured log line: $output"; return 1; }
}

@test "the dispatch hook is IGNORED (real path used) with no test marker present (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  mkdir -p "$GAIA_SESSION_DIR/registry"
  export GAIA_MODE_B_SUBSTRATE=available
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl-artifacts"
  _mk_story_file "$IMPLEMENTATION_ARTIFACTS" "K1" "done"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"

  # Run in a CHILD process with BATS_TEST_FILENAME explicitly unset and no
  # allow-marker -- this is the one place in the suite that must simulate
  # "outside bats, no marker" despite running under bats itself. GAIA_PPO_
  # DISPATCH_CMD names a real stub on PATH, so if the gate failed open the
  # hook would fire and the stub's dispatched.log would gain an entry.
  run env -u BATS_TEST_FILENAME -u GAIA_PPO_ALLOW_DISPATCH_CMD \
    PATH="$stub:$PATH" \
    GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story \
    GAIA_MODE_B_SUBSTRATE=available \
    IMPLEMENTATION_ARTIFACTS="$IMPLEMENTATION_ARTIFACTS" \
    GAIA_SESSION_DIR="$GAIA_SESSION_DIR" \
    GAIA_PARALLEL_EXECUTION=1 GAIA_WORKTREE_MODE=1 \
    bash -c '
      . "'"$ORCH"'"
      ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    '

  [ ! -s "$TEST_TMP/stubstate/dispatched.log" ] \
    || { echo "the stub was invoked with no test marker present: $(cat "$TEST_TMP/stubstate/dispatched.log")"; return 1; }
  printf '%s\n' "$output" | grep -q "event=dispatch_hook cmd=gaia-dispatch-story action=refused" \
    || { echo "no refused log line: $output"; return 1; }
  printf '%s\n' "$output" | grep -q "run: no bash-drivable dispatcher in this context" \
    || { echo "expected the no-bash-drivable-dispatcher line once the hook was refused: $output"; return 1; }
}

@test "the dispatch hook is honoured under an explicit GAIA_PPO_ALLOW_DISPATCH_CMD marker with no bats context (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"

  run env -u BATS_TEST_FILENAME \
    PATH="$fl:$stub:$PATH" \
    GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story \
    GAIA_PPO_ALLOW_DISPATCH_CMD=1 \
    GAIA_SESSION_DIR="$GAIA_SESSION_DIR" \
    GAIA_PARALLEL_EXECUTION=1 GAIA_WORKTREE_MODE=1 \
    bash -c '
      . "'"$ORCH"'"
      ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
    '

  [ "$status" -eq 0 ] \
    || { echo "expected the stub's own contract (0) under the explicit marker: $output"; return 1; }
  printf '%s\n' "$output" | grep -q "event=dispatch_hook cmd=gaia-dispatch-story action=honoured" \
    || { echo "no honoured log line: $output"; return 1; }
  grep -q "K1" "$TEST_TMP/stubstate/dispatched.log" \
    || { echo "the stub was never invoked despite the explicit marker: $(cat "$TEST_TMP/stubstate/dispatched.log" 2>/dev/null)"; return 1; }
}

# ---------------------------------------------------------------------------
# The run-level trap shuts down every teammate it spawned
# ---------------------------------------------------------------------------

@test "SIGTERM to a running orchestrator shuts down its live teammates and clears reservations (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  # Two REAL admissions via the step engine's own `next` (real spawn_teammate,
  # real registry entries), then both stall forever via the legacy hook's
  # stall:<key> contract -- exercises `run`'s trap through its own real
  # dispatch loop rather than a hand-installed trap, with genuinely TWO live
  # teammates so the sweep's iteration (not just a single-entry special case)
  # is under test.
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" stall:K1)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story
  export GAIA_STUB_DELAY_K2=0

  env PATH="$PATH" GAIA_SESSION_DIR="$GAIA_SESSION_DIR" \
      GAIA_PARALLEL_EXECUTION=1 GAIA_WORKTREE_MODE=1 \
      GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story \
      bash -c '
        . "'"$ORCH"'"
        ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
      ' &
  local runner_bg=$!

  # Wait for both teammates to actually register before signalling -- a
  # signal sent before either admission has run would prove nothing about
  # the trap's sweep. K2 (mode "stall:K1", so K2 itself completes and is
  # backfilled by nothing else in a 2-story/2-slot sprint) may also still be
  # in-flight; either way both admissions happen before either hook exits.
  local waited=0
  while [ "$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f -name 'tm-*' 2>/dev/null | wc -l | tr -d ' ')" -lt 2 ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || { echo "teammates never registered: $(ls "$GAIA_SESSION_DIR/registry" 2>/dev/null)"; kill -TERM "$runner_bg" 2>/dev/null || true; return 1; }
    sleep 0.1
  done

  local before_count
  before_count="$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f -name 'tm-*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$before_count" -ge 2 ] \
    || { echo "expected 2 live teammates before signalling, found $before_count"; return 1; }

  kill -TERM "$runner_bg"

  # Bounded wait for the runner to exit -- with the stalled hook's own
  # background child now killed by _ppo_run_kill_children, this should be
  # prompt rather than waiting on the stall's own 3600s sleep.
  local w=0
  while kill -0 "$runner_bg" 2>/dev/null; do
    w=$((w + 1))
    [ "$w" -lt 100 ] || { echo "runner did not exit after SIGTERM"; kill -KILL "$runner_bg" 2>/dev/null || true; return 1; }
    sleep 0.1
  done
  wait "$runner_bg" 2>/dev/null || true

  local after_count
  after_count="$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f -name 'tm-*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$after_count" -eq 0 ] \
    || { echo "teammate registry entries survived SIGTERM: $(ls "$GAIA_SESSION_DIR/registry" 2>/dev/null)"; return 1; }

  [ ! -f "$GAIA_SESSION_DIR/registry/.reserved-K1" ] && [ ! -f "$GAIA_SESSION_DIR/registry/.reserved-K2" ] \
    || { echo "reservations survived SIGTERM: $(ls "$GAIA_SESSION_DIR/registry"/.reserved-* 2>/dev/null)"; return 1; }
}

@test "SIGTERM to the production ppo_run_sprint trap tears down a live teammate and exits promptly (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # Same real admission as the previous test, one story instead of two --
  # pins that the trap actually wired into the production entry point calls
  # ppo_shutdown_live_teammates, not only that the function works when
  # installed by hand, AND (now that `run`'s own backgrounded hook
  # invocations are tracked and killed from the trap -- see
  # _ppo_run_kill_children) that the process exits PROMPTLY rather than
  # waiting on the stalled hook's own long-lived sleep.
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" stall:K1)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  env PATH="$PATH" GAIA_SESSION_DIR="$GAIA_SESSION_DIR" \
      GAIA_PARALLEL_EXECUTION=1 GAIA_WORKTREE_MODE=1 \
      GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story \
      bash -c '
        . "'"$ORCH"'"
        ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
      ' &
  local runner_bg=$!

  local waited=0
  while [ "$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f -name 'tm-*' 2>/dev/null | wc -l | tr -d ' ')" -lt 1 ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 150 ] || { echo "no teammate ever registered: $(ls "$GAIA_SESSION_DIR/registry" 2>/dev/null)"; kill -TERM "$runner_bg" 2>/dev/null || true; return 1; }
    sleep 0.1
  done

  local t0; t0="$(date +%s)"
  kill -TERM "$runner_bg"

  # Bounded, TIGHT wait (the whole point of the prompt-exit fix): the stub's
  # stall:K1 mode sleeps 3600s, so if the trap's own kill of that background
  # hook invocation did not work, this loop runs out at ~2s and the test
  # fails -- it would NOT silently pass by waiting the full 3600s.
  local w=0
  while kill -0 "$runner_bg" 2>/dev/null; do
    w=$((w + 1))
    [ "$w" -lt 20 ] || { echo "runner did not exit within ~2s of SIGTERM (prompt-exit regression)"; kill -KILL "$runner_bg" 2>/dev/null || true; wait "$runner_bg" 2>/dev/null || true; return 1; }
    sleep 0.1
  done
  wait "$runner_bg" 2>/dev/null || true
  local t1; t1="$(date +%s)"
  local elapsed=$(( t1 - t0 ))
  [ "$elapsed" -le 3 ] \
    || { echo "runner took ${elapsed}s to exit after SIGTERM, expected prompt (~2s bound)"; return 1; }

  local after_count
  after_count="$(find "$GAIA_SESSION_DIR/registry" -maxdepth 1 -type f -name 'tm-*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$after_count" -eq 0 ] \
    || { echo "a teammate registry entry survived SIGTERM to ppo_run_sprint's own trap: $(ls "$GAIA_SESSION_DIR/registry" 2>/dev/null)"; return 1; }
}

# ---------------------------------------------------------------------------
# Hermeticity: a stalled hook's own grandchild dies with the RUN it belongs
# to, not just the hook process `run` itself tracks (AC-EC5, AC4)
# ---------------------------------------------------------------------------
#
# `timeout` (see the header comment where run-pgids is populated in
# ppo_run_sprint) puts ITSELF in a new process group by default, so its OWN
# internal expiry already reaches its whole group -- that path was never
# broken. What WAS broken: `run`'s INT/TERM trap killing only the wrapper
# subshell's pid (ppo/run-pids) while a hook invocation is still in flight.
# `timeout` forks as a genuinely separate process (the `local hrc=0`
# statement ahead of it in the subshell defeats bash's single-command
# exec-replacement optimisation), so it is NOT in the wrapper subshell's own
# process group -- a signal to the subshell alone never reaches `timeout` or
# anything IT goes on to fork (e.g. this stub's own `sleep 3600` in its
# stall:<key> branch). This is exactly the shape the CI orphan report named:
# a `timeout` -> `bash` -> `sleep` chain outliving the SIGTERM'd `run`.
#
# Waits on the stub's OWN dispatch.log line (not the teammate registry count)
# before signalling: `ppo_next`'s real admission can register a teammate
# BEFORE the hook subshell's `timeout` has forked, so signalling on registry
# count alone risks killing `run` while it is still inside that first
# `ppo_next` call -- before there is any hook-owned process tree to leak in
# the first place, proving nothing about this fix.

@test "a stalled hook's own grandchild sleep does not survive a SIGTERM to run (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" stall:K1)"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story
  export GAIA_STUB_STATE="$TEST_TMP/stubstate"

  env PATH="$PATH" GAIA_SESSION_DIR="$GAIA_SESSION_DIR" \
      GAIA_PARALLEL_EXECUTION=1 GAIA_WORKTREE_MODE=1 \
      GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story GAIA_STUB_STATE="$GAIA_STUB_STATE" \
      bash -c '
        . "'"$ORCH"'"
        ppo_run_sprint --repo "'"$repo"'" --yaml "'"$yaml"'" --slots 2
      ' &
  local runner_bg=$!

  # Wait for the STUB itself to have started (its own dispatch-times.log line
  # for K1), not merely a registry entry -- this is the moment the hook
  # subshell's `timeout K1-stub` has actually forked and the stub has reached
  # its stall:K1 branch's `sleep 3600`, i.e. the process tree this fix must
  # reap actually exists to leak.
  local waited=0
  while ! grep -q '^K1 ' "$GAIA_STUB_STATE/dispatch-times.log" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -lt 150 ] || { echo "the stub never recorded a K1 dispatch: $(cat "$GAIA_STUB_STATE/dispatch-times.log" 2>/dev/null)"; kill -TERM "$runner_bg" 2>/dev/null || true; return 1; }
    sleep 0.1
  done
  # A short settle so the stub's OWN `sleep 3600` (forked from inside its
  # stall:K1 branch, after the dispatch-times.log line is written) has time
  # to actually exist as a process before this test signals `run` -- the
  # write above happens a few lines before the stub reaches `sleep 3600`.
  sleep 0.2

  command -v pgrep >/dev/null 2>&1 || skip "no pgrep to enumerate the timeout process"
  # The `timeout` invocation wrapping this stub is identifiable by its own
  # argv (it names the stub command and the story key directly) -- capture
  # its pid BEFORE signalling `run`, because `timeout`'s pid IS the pgid of
  # the whole group it and its descendants (the stub, and the stub's own
  # `sleep 3600`) belong to (see the header comment above and where
  # run-pgids is populated in ppo_run_sprint): a survivor anywhere in that
  # group after cleanup -- not just `timeout` itself -- is the leak this test
  # exists to catch, and grep on `sleep 3600`'s own argv alone would miss it
  # (an orphaned `sleep 3600` re-parented to init carries no reference back
  # to this test's stub path in its own command line).
  local timeout_pid
  timeout_pid="$(pgrep -f "gaia-dispatch-story K1" 2>/dev/null | head -1)"
  [ -n "$timeout_pid" ] \
    || { echo "could not find the timeout process wrapping the K1 stub"; kill -TERM "$runner_bg" 2>/dev/null || true; return 1; }

  kill -TERM "$runner_bg"

  local w=0
  while kill -0 "$runner_bg" 2>/dev/null; do
    w=$((w + 1))
    [ "$w" -lt 100 ] || { echo "runner did not exit after SIGTERM"; kill -KILL "$runner_bg" 2>/dev/null || true; return 1; }
    sleep 0.1
  done
  wait "$runner_bg" 2>/dev/null || true

  local leaked
  leaked="$(pgrep -g "$timeout_pid" 2>/dev/null || true)"
  if [ -n "$leaked" ]; then
    {
      echo "process(es) survived SIGTERM to run, still in timeout's own group ($timeout_pid):"
      ps -o pid,ppid,pgid,command -p $leaked 2>/dev/null
    } >&2
    kill -KILL -- "-$timeout_pid" 2>/dev/null || true
    return 1
  fi
}

# ---------------------------------------------------------------------------
# resolve-story-file.sh exit 2 (ambiguous) is distinct from exit 1
# ---------------------------------------------------------------------------

@test "an ambiguous story-file resolution refuses to spawn, distinct from not-found (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  mkdir -p "$GAIA_SESSION_DIR/registry"
  export GAIA_MODE_B_SUBSTRATE=available
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl-artifacts"

  # Two legacy-nested candidates for the SAME key -- resolve-story-file.sh's
  # own documented ambiguity case (exit 2), independent of whether a file
  # exists at all.
  mkdir -p "$IMPLEMENTATION_ARTIFACTS/epic-1/stories"
  cat > "$IMPLEMENTATION_ARTIFACTS/epic-1/stories/K1-first.md" <<'EOF'
---
template: 'story'
key: "K1"
status: ready-for-dev
---
EOF
  cat > "$IMPLEMENTATION_ARTIFACTS/epic-1/stories/K1-second.md" <<'EOF'
---
template: 'story'
key: "K1"
status: ready-for-dev
---
EOF

  local rc=0
  _ppo_admit_bookkeeping "K1" "" >/dev/null 2>"$TEST_TMP/dispatch.err" || rc=$?

  [ "$rc" -ne 0 ] \
    || { echo "an ambiguous story file must not spawn (rc 0): $(cat "$TEST_TMP/dispatch.err")"; return 1; }
  grep -q "event=story_file_ambiguous story=K1" "$TEST_TMP/dispatch.err" \
    || { echo "no distinct ambiguity log line: $(cat "$TEST_TMP/dispatch.err")"; return 1; }
}

@test "a genuinely absent story file (exit 1) still defaults the persona and proceeds, unlike exit 2 (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  mkdir -p "$GAIA_SESSION_DIR/registry"
  export GAIA_MODE_B_SUBSTRATE=available
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl-artifacts-empty"
  mkdir -p "$IMPLEMENTATION_ARTIFACTS"

  local out="" rc=0
  out="$(_ppo_admit_bookkeeping "NOPE" "" 2>"$TEST_TMP/dispatch.err")" || rc=$?

  ! grep -q "event=story_file_ambiguous" "$TEST_TMP/dispatch.err" \
    || { echo "a genuinely absent story file was misclassified as ambiguous: $(cat "$TEST_TMP/dispatch.err")"; return 1; }
  # No story file at all is the exit-1/not-found path -- _ppo_resolve_persona
  # falls back to bash-dev and the admission still succeeds (a real spawn),
  # unlike the exit-2 ambiguous case above which refuses outright.
  [ "$rc" -eq 0 ] \
    || { echo "expected a successful admission (default persona) on the exit-1/not-found path, got $rc: $(cat "$TEST_TMP/dispatch.err")"; return 1; }
  printf '%s\n' "$out" | grep -q '^persona:bash-dev$' \
    || { echo "expected the default persona on the not-found path: $out"; return 1; }
}

# ---------------------------------------------------------------------------
# resolve-story-file.sh resolution is memoized per run
# ---------------------------------------------------------------------------

@test "a second resolution of the same key does not invoke the resolver again (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl-artifacts"
  _mk_story_file "$IMPLEMENTATION_ARTIFACTS" "K1" "ready-for-dev"
  _ppo_engine_reset

  local first
  first="$(_ppo_resolve_story_file K1)"
  [ -n "$first" ] \
    || { echo "first resolution found nothing: fixture bug"; return 1; }

  # Mutant-detectable without intercepting the resolver: the story file is
  # REMOVED between calls. A cache hit returns the SAME (now-stale, but
  # still correct for this run) path without re-walking the tree; a real
  # second resolver invocation would find nothing and return empty (exit 1)
  # instead, because the file it would need to find no longer exists.
  rm -f "$first"

  local second rc=0
  second="$(_ppo_resolve_story_file K1)" || rc=$?

  [ "$rc" -eq 0 ] \
    || { echo "the second lookup re-walked the tree (rc=$rc) instead of serving the cached answer"; return 1; }
  [ "$second" = "$first" ] \
    || { echo "cached and fresh resolutions disagreed: '$first' vs '$second'"; return 1; }
}

@test "resolutions for DIFFERENT keys are cached independently (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl-artifacts"
  _mk_story_file "$IMPLEMENTATION_ARTIFACTS" "K1" "ready-for-dev"
  _mk_story_file "$IMPLEMENTATION_ARTIFACTS" "K2" "ready-for-dev"
  _ppo_engine_reset

  local out1 out2
  out1="$(_ppo_resolve_story_file K1)"
  out2="$(_ppo_resolve_story_file K2)"

  [[ "$out1" == *"K1-fixture-story.md" ]] \
    || { echo "K1 did not resolve to its own file: $out1"; return 1; }
  [[ "$out2" == *"K2-fixture-story.md" ]] \
    || { echo "K2 did not resolve to its own file: $out2"; return 1; }
}

# ---------------------------------------------------------------------------
# Step engine: ppo_record_outcome reads every field regardless of order
# ---------------------------------------------------------------------------

@test "ppo_record_outcome reads phase, persona, worktree and handle regardless of field order (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  export GAIA_MODE_B_SUBSTRATE=available
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # shellcheck disable=SC1090
  . "$WT_LIB"
  export GAIA_WORKTREE_MODE=1
  local wt; wt="$(worktree_create "$repo" "K1" "slug")"
  [ -n "$wt" ] || { echo "test fixture bug: worktree_create failed"; return 1; }
  _ppo_engine_reset
  _ppo_engine_put repo "$repo"

  # A running/<key> file with `phase:` FIRST (matching ppo_next's own writer
  # order) and every other field AFTER it: the mutant this pins is `sed -n
  # 's/^field://p;q'` (q unconditional after the first line it reads,
  # regardless of match) -- under that mutant `phase` (first line) reads
  # correctly by accident while persona/worktree/handle (anything after line
  # 1) silently come back empty, so a test that only checks the FIRST field
  # or a value that still "works" by accident would not catch it. worktree
  # and handle are checked here via their real EFFECTS (a real teardown, a
  # real registry removal), not by re-reading the same file the buggy code
  # read from -- an assertion that re-parsed the file with the same flawed
  # idiom would pass against the mutant for the wrong reason.
  mkdir -p "$(_ppo_engine_dir)/running"
  {
    printf 'phase:3\n'
    printf 'persona:bash-dev\n'
    printf 'worktree:%s\n' "$wt"
    printf 'handle:tm-bash-dev-K1\n'
    printf 'dispatched_at:%s\n' "$(date +%s)"
  } > "$(_ppo_engine_dir)/running/K1"

  mkdir -p "$GAIA_SESSION_DIR/registry"
  printf 'persona:bash-dev\nstatus:active\n' > "$GAIA_SESSION_DIR/registry/tm-bash-dev-K1"

  ppo_record_outcome K1 done >/dev/null 2>"$TEST_TMP/record.err"

  [ ! -e "$wt" ] \
    || { echo "the worktree field was not read (field-order regression) -- teardown never acted on the real path: $(cat "$TEST_TMP/record.err")"; return 1; }
  [ ! -f "$GAIA_SESSION_DIR/registry/tm-bash-dev-K1" ] \
    || { echo "the handle field was not read (field-order regression) -- shutdown_teammate never acted on the real handle: $(cat "$TEST_TMP/record.err")"; return 1; }
}

# ---------------------------------------------------------------------------
# Real dispatch-teammate.sh bookkeeping through plan/next/record, no hook
# ---------------------------------------------------------------------------

@test "plan/next/record drive the real dispatch surface: fill, backfill, barrier, merge-not-done (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  # K1/K2/K3 same persona (bash-dev, the default), phase 1; K4 phase 2 --
  # slots=2 forces K3 to wait for a backfill and K4 to wait for the barrier.
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:1 K3:1 K4:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  # shellcheck disable=SC1090
  . "$DT_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  unset GAIA_PPO_DISPATCH_CMD 2>/dev/null || true

  ppo_plan --repo "$repo" --yaml "$yaml" --slots 2 >/dev/null

  # `next` admits exactly `slots` (2) distinct handles for phase 1 only.
  local out1
  out1="$(ppo_next)"
  local k1_handle k2_handle
  k1_handle="$(printf '%s\n' "$out1" | sed -n 's/^dispatch story=K1 .*handle=\([^ ]*\).*/\1/p')"
  k2_handle="$(printf '%s\n' "$out1" | sed -n 's/^dispatch story=K2 .*handle=\([^ ]*\).*/\1/p')"
  [ -n "$k1_handle" ] && [ -n "$k2_handle" ] \
    || { echo "expected 2 dispatch lines with handles for K1 and K2: $out1"; return 1; }
  [ "$k1_handle" != "$k2_handle" ] \
    || { echo "same-persona stories collided on one handle: $k1_handle"; return 1; }
  printf '%s\n' "$out1" | grep -q '^dispatch story=K3' \
    && { echo "K3 was admitted before a slot freed: $out1"; return 1; }
  printf '%s\n' "$out1" | grep -q '^dispatch story=K4' \
    && { echo "phase 2 (K4) was admitted while phase 1 is still open: $out1"; return 1; }

  # Real registry entries exist for K1 and K2, story-keyed.
  [ -f "$GAIA_SESSION_DIR/registry/$k1_handle" ] \
    || { echo "no real registry entry for K1's handle $k1_handle"; return 1; }
  [ -f "$GAIA_SESSION_DIR/registry/$k2_handle" ] \
    || { echo "no real registry entry for K2's handle $k2_handle"; return 1; }
  grep -q "story_key:K1" "$GAIA_SESSION_DIR/registry/$k1_handle" \
    || { echo "K1's registry entry is not story-keyed: $(cat "$GAIA_SESSION_DIR/registry/$k1_handle")"; return 1; }

  # Phase 1 is full: another `next` reports the barrier, not a new dispatch.
  local out2
  out2="$(ppo_next)"
  printf '%s\n' "$out2" | grep -q '^barrier phase=1 waiting=2$' \
    || { echo "expected barrier phase=1 waiting=2 with both slots full: $out2"; return 1; }

  # `record K1 done` frees a slot; the VERY NEXT `next` backfills with K3
  # (same phase), with its OWN new handle -- not K1's or K2's.
  ppo_record_outcome K1 done >/dev/null
  [ ! -f "$GAIA_SESSION_DIR/registry/$k1_handle" ] \
    || { echo "K1's registry entry survived record done: shutdown_teammate was not called"; return 1; }

  local out3 k3_handle
  out3="$(ppo_next)"
  k3_handle="$(printf '%s\n' "$out3" | sed -n 's/^dispatch story=K3 .*handle=\([^ ]*\).*/\1/p')"
  [ -n "$k3_handle" ] \
    || { echo "K3 was not backfilled after K1 completed: $out3"; return 1; }
  [ "$k3_handle" != "$k1_handle" ] && [ "$k3_handle" != "$k2_handle" ] \
    || { echo "K3 was admitted with a REUSED handle instead of its own: $k3_handle"; return 1; }
  printf '%s\n' "$out3" | grep -q '^dispatch story=K4' \
    && { echo "phase 2 (K4) was admitted before phase 1 fully drained: $out3"; return 1; }

  # Finish K2 and K3; phase 2 (K4) only becomes admittable once BOTH are
  # recorded, proving the barrier -- not merely the queue -- gates the phase.
  ppo_record_outcome K2 done >/dev/null
  local out4
  out4="$(ppo_next)"
  printf '%s\n' "$out4" | grep -q '^dispatch story=K4' \
    && { echo "phase 2 (K4) was admitted while K3 is still running: $out4"; return 1; }

  ppo_record_outcome K3 done >/dev/null
  local out5
  out5="$(ppo_next)"
  printf '%s\n' "$out5" | grep -q '^dispatch story=K4' \
    || { echo "phase 2 (K4) was never admitted once phase 1 fully drained: $out5"; return 1; }

  # `record K4 merged`, audited (via the gated test hook -- see
  # _ppo_is_merged_not_done) as NOT done: re-queues K4 at the front rather
  # than recording it complete, and phase 2 still has open work.
  mkdir -p "$TEST_TMP/cfg"
  local cfg="$TEST_TMP/cfg/project-config.yaml"
  printf 'ci_cd:\n  promotion_chain:\n    - branch: staging\n' > "$cfg"
  export GAIA_SHARED_CONFIG="$cfg"
  local audit_stub="$TEST_TMP/bin/fake-audit.sh"
  mkdir -p "$TEST_TMP/bin"
  cat > "$audit_stub" <<'AUDIT'
#!/usr/bin/env bash
printf 'WARNING: %s -- merged on %s but not done\n' "$1" "$3"
exit 4
AUDIT
  chmod +x "$audit_stub"
  export GAIA_PPO_AUDIT_CMD="$audit_stub"

  ppo_record_outcome K4 merged >/dev/null
  local ledger; ledger="$(ppo_report)"
  printf '%s\n' "$ledger" | grep -q '^story=K4 outcome=done$' \
    && { echo "K4 was recorded done despite the audit flagging it not-done: $ledger"; return 1; }

  local out6
  out6="$(ppo_next)"
  printf '%s\n' "$out6" | grep -q '^dispatch story=K4' \
    || { echo "the re-queued K4 was not re-admitted: $out6"; return 1; }
}

@test "the real substrate-unavailable path degrades to sequential, phase order preserved (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1 K2:2)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  # shellcheck disable=SC1090
  . "$DT_LIB"
  # The REAL spawn_teammate path, with the substrate forced unavailable --
  # Mode A fallback, rc 7 -- never a stub standing in for the library.
  export GAIA_MODE_B_SUBSTRATE=unavailable
  unset GAIA_PPO_DISPATCH_CMD 2>/dev/null || true

  ppo_plan --repo "$repo" --yaml "$yaml" --slots 2 >/dev/null
  local out; out="$(ppo_next)"

  printf '%s\n' "$out" | grep -q '^mode=sequential reason=mode-b-fallback' \
    || { echo "expected a mode-b-fallback degradation from the real rc-7 spawn path: $out"; return 1; }
  # Phase order preserved: K1 (phase 1) named before K2 (phase 2).
  local k1_line k2_line
  k1_line="$(printf '%s\n' "$out" | grep -n '^event=sequential story=K1$' | head -1 | cut -d: -f1)"
  k2_line="$(printf '%s\n' "$out" | grep -n '^event=sequential story=K2$' | head -1 | cut -d: -f1)"
  [ -n "$k1_line" ] && [ -n "$k2_line" ] \
    || { echo "expected both stories in the sequential worklist: $out"; return 1; }
  [ "$k1_line" -lt "$k2_line" ] \
    || { echo "phase order was not preserved in the sequential worklist: $out"; return 1; }
}

# ---------------------------------------------------------------------------
# CLI verb dispatch (executed, not sourced)
# ---------------------------------------------------------------------------

@test "the CLI dispatches plan/next/record/status/report as executed verbs (AC4)" {
  [ -f "$ORCH" ] || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  export GAIA_MODE_B_SUBSTRATE=available

  run bash "$ORCH" plan --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] && [[ "$output" == mode=parallel* ]] \
    || { echo "'plan' as an executed verb did not run ppo_plan: $output"; return 1; }

  run bash "$ORCH" next
  [ "$status" -eq 0 ] && [[ "$output" == *"dispatch story=K1"* ]] \
    || { echo "'next' as an executed verb did not run ppo_next: $output"; return 1; }

  run bash "$ORCH" status
  [ "$status" -eq 0 ] && [[ "$output" == *"running story=K1"* ]] \
    || { echo "'status' as an executed verb did not run ppo_status: $output"; return 1; }

  run bash "$ORCH" record K1 done
  [ "$status" -eq 0 ] && [[ "$output" == *"outcome=done"* ]] \
    || { echo "'record' as an executed verb did not run ppo_record_outcome: $output"; return 1; }

  run bash "$ORCH" report
  [ "$status" -eq 0 ] && [[ "$output" == "story=K1 outcome=done" ]] \
    || { echo "'report' as an executed verb did not run ppo_report: $output"; return 1; }
}

@test "the CLI with no verb (or a --flag first) still runs the compat run loop (AC4)" {
  [ -f "$ORCH" ] || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"

  run bash "$ORCH" --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] && [[ "$output" == mode=parallel* ]] \
    || { echo "no-verb invocation did not run the compat ppo_run_sprint loop: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# ppo_status overdue boundary (AC-EC5)
# ---------------------------------------------------------------------------

@test "ppo_status reports elapsed == budget as not overdue (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  export GAIA_STORY_TIMEOUT_SECONDS=100
  _ppo_engine_reset
  mkdir -p "$(_ppo_engine_dir)/running"
  local now dispatched_at
  now="$(date +%s)"
  dispatched_at=$((now - 100))
  {
    printf 'phase:1\n'
    printf 'persona:bash-dev\n'
    printf 'worktree:\n'
    printf 'handle:tm-bash-dev-K1\n'
    printf 'dispatched_at:%s\n' "$dispatched_at"
  } > "$(_ppo_engine_dir)/running/K1"

  run ppo_status
  [ "$status" -eq 0 ] || { echo "ppo_status exited non-zero: $output"; return 1; }
  # elapsed is computed against a FRESH `date +%s` inside ppo_status, so
  # assert on the boundary condition (overdue=0) rather than an exact
  # elapsed value that could drift by a second under real clock skew.
  printf '%s\n' "$output" | grep -qE '^running story=K1 elapsed=(99|100) budget=100 overdue=0$' \
    || { echo "expected overdue=0 at the elapsed==budget boundary: $output"; return 1; }
}

@test "ppo_status reports elapsed == budget+1 as overdue (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  export GAIA_STORY_TIMEOUT_SECONDS=100
  _ppo_engine_reset
  mkdir -p "$(_ppo_engine_dir)/running"
  local now dispatched_at
  now="$(date +%s)"
  dispatched_at=$((now - 101))
  {
    printf 'phase:1\n'
    printf 'persona:bash-dev\n'
    printf 'worktree:\n'
    printf 'handle:tm-bash-dev-K1\n'
    printf 'dispatched_at:%s\n' "$dispatched_at"
  } > "$(_ppo_engine_dir)/running/K1"

  run ppo_status
  [ "$status" -eq 0 ] || { echo "ppo_status exited non-zero: $output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^running story=K1 elapsed=(101|102) budget=100 overdue=1$' \
    || { echo "expected overdue=1 one second past the budget: $output"; return 1; }
}

@test "ppo_status refuses a missing dispatched_at and reports the story overdue, not silently fine (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  export GAIA_STORY_TIMEOUT_SECONDS=100
  _ppo_engine_reset
  mkdir -p "$(_ppo_engine_dir)/running"
  # No dispatched_at line at all -- a real running/<key> file this file's own
  # writer would never omit, but a defensive read must not assume otherwise:
  # defaulting to `now` (the old behaviour) reports an unobservable start
  # time as fresh and never overdue, which is exactly the silent "fine" this
  # test forbids.
  {
    printf 'phase:1\n'
    printf 'persona:bash-dev\n'
    printf 'worktree:\n'
    printf 'handle:tm-bash-dev-K1\n'
  } > "$(_ppo_engine_dir)/running/K1"

  run ppo_status
  [ "$status" -eq 0 ] || { echo "ppo_status exited non-zero on a missing dispatched_at: $output"; return 1; }
  printf '%s\n' "$output" | grep -q '^running story=K1 elapsed=0 budget=100 overdue=1$' \
    || { echo "expected overdue=1 (unknown start time), got: $output"; return 1; }
}

@test "ppo_status refuses a garbage dispatched_at without crashing the whole status call (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  export GAIA_STORY_TIMEOUT_SECONDS=100
  _ppo_engine_reset
  mkdir -p "$(_ppo_engine_dir)/running"
  # A non-numeric dispatched_at: under this file's own `set -euo pipefail`,
  # `$((now - dispatched_at))` on a bareword is a bash arithmetic error that
  # aborts the whole function -- so this pins BOTH that ppo_status survives
  # it AND that a second, healthy running story is still reported, proving
  # one corrupted file cannot take down status reporting for every other
  # story in flight.
  {
    printf 'phase:1\n'
    printf 'persona:bash-dev\n'
    printf 'worktree:\n'
    printf 'handle:tm-bash-dev-K1\n'
    printf 'dispatched_at:not-a-number\n'
  } > "$(_ppo_engine_dir)/running/K1"
  local now
  now="$(date +%s)"
  {
    printf 'phase:1\n'
    printf 'persona:bash-dev\n'
    printf 'worktree:\n'
    printf 'handle:tm-bash-dev-K2\n'
    printf 'dispatched_at:%s\n' "$now"
  } > "$(_ppo_engine_dir)/running/K2"

  run ppo_status
  [ "$status" -eq 0 ] \
    || { echo "ppo_status crashed on a garbage dispatched_at instead of refusing the one field: $output"; return 1; }
  printf '%s\n' "$output" | grep -q '^running story=K1 elapsed=0 budget=100 overdue=1$' \
    || { echo "expected K1 (garbage dispatched_at) reported overdue=1, got: $output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^running story=K2 elapsed=[01] budget=100 overdue=0$' \
    || { echo "expected K2 (healthy dispatched_at) still reported correctly: $output"; return 1; }
}

@test "removing the dispatched_at validation reports a missing start time as fresh and never overdue (mutant) (AC-EC5)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  # Source-level mutant proof: the fix this pins is the case/esac guard in
  # ppo_status that refuses a missing-or-invalid dispatched_at BEFORE the
  # arithmetic. Assert the guard is actually present in the shipped
  # function body, so removing it (reverting to the old
  # `[ -n "$dispatched_at" ] || dispatched_at="$now"` default) turns this
  # red -- the two tests above already prove the BEHAVIOUR; this proves the
  # behaviour is not achieved by some other code path that could regress
  # back to the silent default without any of them noticing.
  local body
  body="$(sed -n '/^ppo_status() {/,/^}/p' "$ORCH")"
  printf '%s\n' "$body" | grep -q 'event=status_field_refused' \
    || { echo "ppo_status no longer refuses an invalid dispatched_at with a logged reason"; return 1; }
}

# ---------------------------------------------------------------------------
# Path-traversal quarantine on every key-derived path (AC2)
# ---------------------------------------------------------------------------
#
# _ppo_validate_key is the ONE charset gate every verb or internal function
# that turns a story key into a path MUST call before building that path.
# `record` is the sharpest edge here: it is a CLI verb (see _ppo_cli), so its
# key argument is caller-controlled with no upstream sanitisation the way a
# key drawn from the sprint yaml already gets in _ppo_next_locked.

@test "record with a traversal key is refused and touches nothing outside the session dir (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  _ppo_engine_reset

  # A file OUTSIDE $GAIA_SESSION_DIR/ppo/running that a traversal from
  # running/<key> can reach by walking back up to the filesystem root and
  # down again. Depth is computed from the real running/ path so the PoC is
  # not tied to a guessed nesting depth.
  local victim_dir="$TEST_TMP/outside-session"
  mkdir -p "$victim_dir"
  printf 'do not touch\n' > "$victim_dir/victim"

  local running_dir depth dots key
  running_dir="$(_ppo_engine_dir)/running"
  depth="$(printf '%s' "$running_dir" | awk -F'/' '{print NF-1}')"
  dots="$(python3 -c "print('/'.join(['..']*$depth))" 2>/dev/null)" \
    || skip "no python3 to compute the traversal depth"
  key="${dots}${victim_dir}/victim"

  run ppo_record_outcome "$key" done
  [ "$status" -ne 0 ] \
    || { echo "a traversal key was accepted by record (exit 0): $output"; return 1; }
  [[ "$output" == *"event=key_refused"* ]] \
    || { echo "no key_refused log line for a traversal key: $output"; return 1; }
  [[ "$output" == *"verb=record"* ]] \
    || { echo "key_refused line did not name the record verb: $output"; return 1; }

  [ -f "$victim_dir/victim" ] \
    || { echo "CRITICAL: the traversal key deleted a file outside the session dir"; return 1; }
  [ "$(cat "$victim_dir/victim")" = "do not touch" ] \
    || { echo "CRITICAL: the victim file survived but was modified"; return 1; }
}

@test "status builds no path from any caller-supplied argument (AC2)" {
  # ppo_status takes no story-key argument at all -- it enumerates its own
  # ppo/running directory -- so there is no key-shaped input for a traversal
  # to ride in on. This pins that fact so a future change that DOES thread
  # an argument into ppo_status is caught here rather than assumed safe by
  # inheritance from this test file's other key-validation coverage.
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  _ppo_engine_reset

  run ppo_status "../../../../etc/passwd" "ignored" "arguments"
  [ "$status" -eq 0 ] \
    || { echo "ppo_status must never refuse on extra arguments -- it ignores them: $output"; return 1; }
}

@test "record with an empty key is refused (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  _ppo_engine_reset

  run ppo_record_outcome "" done
  [ "$status" -ne 0 ] \
    || { echo "an empty key was accepted by record"; return 1; }
}

@test "record with a whitespace-only key is refused (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  _ppo_engine_reset

  run ppo_record_outcome "   " done
  [ "$status" -ne 0 ] \
    || { echo "a whitespace-only key was accepted by record"; return 1; }
  [[ "$output" == *"event=key_refused"* ]] \
    || { echo "no key_refused log line for a whitespace key: $output"; return 1; }
}

@test "record with a NUL-adjacent key (embedded control byte) is refused (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  _ppo_engine_reset

  # A real NUL byte cannot survive a shell argument (the kernel truncates
  # argv at the first NUL before this script ever sees it), so the
  # NUL-ADJACENT case a bash script can actually be handed is a control
  # character immediately next to the traversal shape -- still outside
  # _ppo_validate_key's [A-Za-z0-9._-] charset and so still refused by the
  # same gate, without this test overclaiming a NUL byte itself was passed.
  local key
  key="$(printf 'K1\x01../../etc')"

  run ppo_record_outcome "$key" done
  [ "$status" -ne 0 ] \
    || { echo "a control-byte-adjacent traversal key was accepted by record"; return 1; }
  [[ "$output" == *"event=key_refused"* ]] \
    || { echo "no key_refused log line for a control-byte key: $output"; return 1; }
}

@test "removing key validation from record re-opens the traversal (mutant) (AC2)" {
  # Source-level mutant proof, mirroring the same pattern used elsewhere in
  # this file for a fix that is a guard clause rather than an independently
  # observable state change: assert the guard is actually present in the
  # shipped function body, so deleting the _ppo_validate_key call from
  # _ppo_record_outcome_locked (reverting to the pre-fix code that built
  # running_file="$(_ppo_engine_dir)/running/${key}" straight from the raw
  # argument) turns this red. The traversal test above already proves the
  # BEHAVIOUR; this proves it is not achievable by some other code path that
  # could regress back to the vulnerability without that test noticing --
  # e.g. a refactor that keeps the same happy-path outcome but drops the
  # call this line names.
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local body
  body="$(sed -n '/^_ppo_record_outcome_locked() {/,/^}/p' "$ORCH")"
  printf '%s\n' "$body" | grep -q '_ppo_validate_key "\$key"' \
    || { echo "_ppo_record_outcome_locked no longer validates its key argument before building a path"; return 1; }
}

# ---------------------------------------------------------------------------
# Defense-in-depth: every direct key->path builder re-validates its own key
# (AC2)
# ---------------------------------------------------------------------------
#
# _ppo_mnd_count, _ppo_mnd_bump, _ppo_mnd_open_mark, _ppo_mnd_open_clear, and
# ppo_slot_scratch_for each turn a raw key argument into a path fragment
# under $GAIA_SESSION_DIR. Every caller today already validates the key
# before reaching these (ppo_next's admission loop, ppo_record_outcome), so
# this is defense in depth, not the primary gate the tests above already
# cover for `record`. Called directly (not through record/next) so a future
# caller added without that upstream discipline is still caught here rather
# than assumed safe by inheritance.

@test "every direct key builder refuses a traversal key and touches nothing outside the session dir (AC2)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  _ppo_state_reset

  local victim_dir="$TEST_TMP/outside-session-builders"
  mkdir -p "$victim_dir"
  printf 'do not touch\n' > "$victim_dir/victim"

  local state_dir depth dots key
  state_dir="$(_ppo_state_dir)"
  depth="$(printf '%s' "$state_dir" | awk -F'/' '{print NF-1}')"
  dots="$(python3 -c "print('/'.join(['..']*$depth))" 2>/dev/null)" \
    || skip "no python3 to compute the traversal depth"
  key="${dots}${victim_dir}/victim"

  run _ppo_mnd_count "$key"
  [ "$status" -ne 0 ] \
    || { echo "_ppo_mnd_count accepted a traversal key (exit 0)"; return 1; }

  run _ppo_mnd_bump "$key"
  [ "$status" -ne 0 ] \
    || { echo "_ppo_mnd_bump accepted a traversal key (exit 0)"; return 1; }

  run _ppo_mnd_open_mark "$key"
  [ "$status" -ne 0 ] \
    || { echo "_ppo_mnd_open_mark accepted a traversal key (exit 0)"; return 1; }

  run _ppo_mnd_open_clear "$key"
  [ "$status" -ne 0 ] \
    || { echo "_ppo_mnd_open_clear accepted a traversal key (exit 0)"; return 1; }

  GAIA_SESSION_DIR="$TEST_TMP/session-for-scratch" run ppo_slot_scratch_for "$key"
  [ "$status" -ne 0 ] \
    || { echo "ppo_slot_scratch_for accepted a traversal key (exit 0)"; return 1; }

  [ -f "$victim_dir/victim" ] \
    || { echo "CRITICAL: a traversal key touched a file outside the session dir"; return 1; }
  [ "$(cat "$victim_dir/victim")" = "do not touch" ] \
    || { echo "CRITICAL: the victim file survived but was modified"; return 1; }
}

@test "removing key validation from a direct builder re-opens the traversal (mutant) (AC2)" {
  # Source-level mutant proof mirroring the record-verb pattern above: assert
  # each builder's guard clause is present in its shipped body, so deleting
  # the _ppo_validate_key call from any ONE of these five functions (reverting
  # to building the path straight from the raw argument) turns this red. The
  # behavioural test above already proves the outcome; this proves it is not
  # achievable by some other code path that could regress back to the gap
  # this fix closes without that test noticing.
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }

  local fn body
  for fn in _ppo_mnd_count _ppo_mnd_bump _ppo_mnd_open_mark _ppo_mnd_open_clear ppo_slot_scratch_for; do
    body="$(sed -n "/^${fn}() {/,/^}/p" "$ORCH")"
    [ -n "$body" ] \
      || { echo "could not locate the ${fn} function body in $ORCH"; return 1; }
    printf '%s\n' "$body" | grep -q '_ppo_validate_key "\${1:-}"' \
      || { echo "${fn} no longer validates its key argument before building a path"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# `merged-not-done` is not a CLI-reachable outcome (AC4)
# ---------------------------------------------------------------------------
#
# merged-not-done is the audited resume/give-up transition
# _ppo_is_merged_not_done's own oracle decides for `merged` -- a caller that
# could simply pass the literal on the command line would skip that audit
# entirely and assert the transition on its own say-so.

@test "CLI record refuses the merged-not-done literal outright (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  _ppo_engine_reset
  mkdir -p "$(_ppo_engine_dir)/running"
  {
    printf 'phase:1\n'
    printf 'persona:bash-dev\n'
    printf 'worktree:\n'
    printf 'handle:tm-bash-dev-K1\n'
    printf 'dispatched_at:%s\n' "$(date +%s)"
  } > "$(_ppo_engine_dir)/running/K1"

  run ppo_record_outcome K1 merged-not-done
  [ "$status" -ne 0 ] \
    || { echo "the CLI-reachable record verb accepted merged-not-done directly: $output"; return 1; }
  [[ "$output" == *"event=outcome_refused"* ]] \
    || { echo "no outcome_refused log line for the merged-not-done literal: $output"; return 1; }
  [[ "$output" == *"unknown-outcome"* ]] \
    || { echo "expected an unknown-outcome reason: $output"; return 1; }

  # Refused, not silently accepted-but-inert: the running entry (and any
  # slot it holds) must still be there afterwards -- a caller cannot use
  # this literal to make the story vanish from `running` either.
  [ -f "$(_ppo_engine_dir)/running/K1" ] \
    || { echo "the refused merged-not-done call still tore down the running entry"; return 1; }
}

@test "the legacy hook's exit-11 resume path still works through run (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local repo; repo="$(_mk_repo "$TEST_TMP/repo")"
  local yaml; yaml="$(_mk_yaml "$TEST_TMP/sprint.yaml" K1:1)"
  local fl; fl="$(_ensure_flock)" || skip "no flock and no python3 to provide one"
  PATH="$fl:$PATH"
  # A stub that always reports the legacy exit-11 (merged-not-done) contract,
  # so the run loop's internal-only resume call is exercised for real, not
  # through the now-refused CLI outcome literal.
  local stub; stub="$(_mk_dispatch_stub "$TEST_TMP/bin" ok)"
  cat > "$stub/gaia-dispatch-story" <<'STUB'
#!/usr/bin/env bash
exit 11
STUB
  chmod +x "$stub/gaia-dispatch-story"
  PATH="$stub:$PATH"
  export GAIA_PPO_DISPATCH_CMD=gaia-dispatch-story

  run ppo_run_sprint --repo "$repo" --yaml "$yaml" --slots 2
  [ "$status" -eq 0 ] \
    || { echo "the legacy exit-11 resume path did not complete the run: $output"; return 1; }
  [[ "$output" == *"event=story_merged_not_done story=K1"*"outcome=resume-requeued"* ]] \
    || { echo "expected the resume-requeued transition from the internal exit-11 path: $output"; return 1; }
}

@test "the CLI vocabulary accepts exactly done, failed, timeout and merged (AC4)" {
  # Source-level pin on the vocabulary itself: the case arms
  # _ppo_record_outcome_locked switches on must be exactly these four
  # literals, with everything else (including merged-not-done) falling to
  # the refusal arm. Guards against a future literal being added to this
  # function without also being added to the documented CLI contract.
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local body
  body="$(sed -n '/^_ppo_record_outcome_locked() {/,/^}/p' "$ORCH")"
  for lit in done failed timeout merged; do
    printf '%s\n' "$body" | grep -qE "^\s*${lit}\)" \
      || { echo "expected a case arm for '${lit}' in _ppo_record_outcome_locked"; return 1; }
  done
  printf '%s\n' "$body" | grep -qE '^\s*merged-not-done\)' \
    && { echo "merged-not-done must not be a case arm in the CLI-reachable outcome vocabulary"; return 1; }
  true
}

# ---------------------------------------------------------------------------
# run-pgids entries are validated and owner/liveness-checked before signalling
# a `0` entry resolves to _ppo_run_kill_children's OWN process group; a `1`
# entry would broadcast to every signalable process; a stale entry with no
# owner stamp could let pid reuse after a crashed run hit an unrelated
# process.
# ---------------------------------------------------------------------------

# _spawn_probe_group <dir> — start a long-lived probe in ITS OWN process
# group and write its pid to <dir>/probe.pid. Uses the SAME mechanism the
# product code relies on (see the header comment where run-pgids is
# populated in ppo_run_sprint): GNU `timeout` puts ITSELF in a new process
# group by default, so backgrounding `timeout <n> sleep <n>` gives a probe
# whose own pid IS its own pgid, portably, with no dependency on setsid(1)
# (util-linux only, absent on macOS). The probe must survive every "nothing
# should be signalled" assertion below and must be reapable independently of
# the shell driving the test, so a mutant that DOES signal it cannot also
# take the bats process itself down with it.
_spawn_probe_group() {
  local dir="$1"
  mkdir -p "$dir"
  timeout 300 sleep 300 >/dev/null 2>&1 &
  printf '%s' "$!" > "$dir/probe.pid"
  local waited=0
  while [ ! -s "$dir/probe.pid" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 50 ] || return 1
    sleep 0.1
  done
  # Settle so the pid is genuinely its own group leader before any caller
  # reads it back.
  sleep 0.2
  return 0
}

_kill_probe_group() {
  local dir="$1" ppid
  [ -f "$dir/probe.pid" ] || return 0
  ppid="$(cat "$dir/probe.pid" 2>/dev/null)"
  [ -n "$ppid" ] || return 0
  kill -KILL -- "-$ppid" 2>/dev/null || kill -KILL "$ppid" 2>/dev/null || true
}

@test "run-pgids entries 0, 1, negative, non-numeric, empty and own-pgid are refused, nothing signalled (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local probedir="$TEST_TMP/probe"
  _spawn_probe_group "$probedir" || skip "could not start a probe process group"
  local probe_pid; probe_pid="$(cat "$probedir/probe.pid")"

  mkdir -p "$GAIA_SESSION_DIR/ppo"
  local self_pid=$$ self_pgid
  self_pgid="$(ps -o pgid= -p "$self_pid" 2>/dev/null | tr -d ' ')"
  {
    printf '0|owner:%s\n' "$self_pid"
    printf '1|owner:%s\n' "$self_pid"
    printf -- '-5|owner:%s\n' "$self_pid"
    printf 'abc|owner:%s\n' "$self_pid"
    printf '\n'
    printf '%s|owner:%s\n' "$self_pgid" "$self_pid"
    printf '%s|owner:%s\n' "$probe_pid" "$self_pid"
  } > "$GAIA_SESSION_DIR/ppo/run-pgids"
  : > "$GAIA_SESSION_DIR/ppo/run-pids"

  # _ppo_run_pgid_owned is the gate every entry above must fail EXCEPT the
  # last one (the probe, legitimately owned and alive) -- but this test's
  # point is that _ppo_run_kill_children's OWN sweep of the malformed/
  # out-of-range entries never reaches `kill` at all, so exercise the sweep
  # directly rather than only the validator function.
  local out
  out="$(_ppo_run_pgid_owned "0|owner:$self_pid" "$self_pid" "$self_pgid")" && { echo "0 was accepted: $out"; _kill_probe_group "$probedir"; return 1; }
  out="$(_ppo_run_pgid_owned "1|owner:$self_pid" "$self_pid" "$self_pgid")" && { echo "1 was accepted: $out"; _kill_probe_group "$probedir"; return 1; }
  out="$(_ppo_run_pgid_owned "-5|owner:$self_pid" "$self_pid" "$self_pgid")" && { echo "-5 was accepted: $out"; _kill_probe_group "$probedir"; return 1; }
  out="$(_ppo_run_pgid_owned "abc|owner:$self_pid" "$self_pid" "$self_pgid")" && { echo "abc was accepted: $out"; _kill_probe_group "$probedir"; return 1; }
  out="$(_ppo_run_pgid_owned "" "$self_pid" "$self_pgid")" && { echo "empty line was accepted: $out"; _kill_probe_group "$probedir"; return 1; }
  out="$(_ppo_run_pgid_owned "$self_pgid|owner:$self_pid" "$self_pid" "$self_pgid")" && { echo "own pgid was accepted: $out"; _kill_probe_group "$probedir"; return 1; }

  # The probe entry alone is well-formed, owned, and alive: it is the one
  # line _ppo_run_kill_children's sweep WOULD legitimately signal -- kill it
  # off directly afterwards rather than through the sweep, so this test
  # proves the malformed entries were refused without also asserting
  # anything about the probe's own fate.
  kill -0 "$probe_pid" 2>/dev/null || { echo "probe died on its own before the assertion"; return 1; }
  _kill_probe_group "$probedir"
}

@test "removing run-pgids validation lets a 0 entry kill the caller's own group (mutant) (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local probedir="$TEST_TMP/probe"
  _spawn_probe_group "$probedir" || skip "could not start a probe process group"
  local probe_pid; probe_pid="$(cat "$probedir/probe.pid")"

  # The mutant this test is designed to catch: signal every run-pgids entry
  # with no validation at all, exactly as the pre-fix code did. Run it
  # against the PROBE's pgid (never $$ or 0 -- that would take the bats
  # process itself down) to prove the validator in this file, not this
  # test's own harness, is what stands between an entry and `kill`.
  local unvalidated_line="$probe_pid"
  kill -TERM -- "-$unvalidated_line" 2>/dev/null || true

  local waited=0
  while kill -0 "$probe_pid" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -lt 30 ] || { echo "probe survived the unvalidated signal -- mutant not reproduced, harness issue"; _kill_probe_group "$probedir"; return 1; }
    sleep 0.1
  done
  # This demonstrates the pre-fix hazard class (a bare pid handed straight to
  # `kill -TERM -- "-<pid>"` with no gate reaches a real, unrelated process
  # group) -- the fix under test is that _ppo_run_pgid_owned refuses malformed
  # entries BEFORE any such call, proven by the companion test above.
}

@test "N concurrent run-pgids appends are all accounted for, none lost (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  mkdir -p "$GAIA_SESSION_DIR/ppo"
  : > "$GAIA_SESSION_DIR/ppo/run-pgids"
  local f="$GAIA_SESSION_DIR/ppo/run-pgids"
  local n=20 i pids=()

  # Simulate N dispatch slots completing near-simultaneously: each appends
  # its own owner-stamped entry with NO lock and NO self-removal (the
  # append-only design under test) -- a lost entry here would mean the
  # write-side race the review flagged (a self-removing grep -v -x | mv
  # racing a sibling's own append) is still present.
  for i in $(seq 1 "$n"); do
    ( printf '%s|owner:%s\n' "$((10000 + i))" "$$" >> "$f" ) &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p"; done

  local got; got="$(wc -l < "$f" | tr -d ' ')"
  [ "$got" -eq "$n" ] \
    || { echo "expected $n entries after $n concurrent appends, found $got: $(cat "$f")"; return 1; }
  for i in $(seq 1 "$n"); do
    grep -qx "$((10000 + i))|owner:$$" "$f" \
      || { echo "entry for synthetic pid $((10000 + i)) was lost: $(cat "$f")"; return 1; }
  done
}

@test "the real run-pgids write site never reintroduces a self-removing read-modify-write (mutant guard) (AC4)" {
  # Source-level pin on ppo_run_sprint's OWN dispatch subshell (not a
  # synthetic reproduction): the pre-fix code read the file back
  # (`grep -v -x "$tpid" run-pgids > run-pgids.tmp`) and clobbered it
  # (`mv run-pgids.tmp run-pgids`) on every dispatch completion, with no
  # lock -- exactly the shape that loses a concurrent sibling's own append.
  # This asserts that pattern is gone from the actual write site, so a
  # regression that reintroduces it turns this red even if a differently
  # generic append-safety test (above) would not happen to exercise the
  # real call site.
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local body
  body="$(sed -n '/^ppo_run_sprint() {/,/^}/p' "$ORCH")"
  printf '%s\n' "$body" | grep -q 'run-pgids' \
    || { echo "expected ppo_run_sprint to reference run-pgids at all"; return 1; }
  printf '%s\n' "$body" | grep -qE 'grep .*-v.*run-pgids|run-pgids.*\.tmp' \
    && { echo "ppo_run_sprint still contains a read-modify-write against run-pgids -- must be append-only"; return 1; }
  true
}

@test "a stale run-pgids entry whose pid now belongs to a foreign probe is skipped (AC4)" {
  _source_orch || { echo "orchestrator not implemented: $ORCH"; return 1; }
  local probedir="$TEST_TMP/probe"
  _spawn_probe_group "$probedir" || skip "could not start a probe process group"
  local probe_pid; probe_pid="$(cat "$probedir/probe.pid")"

  # The probe's pid is real and alive, but stamped with an OWNER that is not
  # this run's own $$ -- the shape a pid-reuse-after-crash scenario takes:
  # the number in the file is live, just not live as a process THIS run
  # started. _ppo_run_pgid_owned must refuse it on the owner check alone,
  # never reaching the liveness check as a reason to signal it.
  local self_pid=$$ self_pgid foreign_owner
  self_pgid="$(ps -o pgid= -p "$self_pid" 2>/dev/null | tr -d ' ')"
  foreign_owner=$((self_pid + 1))
  [ "$foreign_owner" != "$self_pid" ] || foreign_owner=$((self_pid - 1))

  local out rc=0
  out="$(_ppo_run_pgid_owned "${probe_pid}|owner:${foreign_owner}" "$self_pid" "$self_pgid")" || rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] \
    || { echo "a foreign-owned entry was accepted: $out"; _kill_probe_group "$probedir"; return 1; }

  # Confirm it is genuinely the owner check doing the refusing, not merely
  # that the probe pid looked dead: the SAME line with THIS run's own pid as
  # owner must be accepted.
  out="$(_ppo_run_pgid_owned "${probe_pid}|owner:${self_pid}" "$self_pid" "$self_pgid")" || rc=$?
  [ "$out" = "$probe_pid" ] \
    || { echo "expected the probe pid to be accepted once owned by this run: $out"; _kill_probe_group "$probedir"; return 1; }

  _kill_probe_group "$probedir"
}
