#!/usr/bin/env bash
# phase-parallel-orchestrator.sh — slot-based phase-parallel sprint execution.
#
# Runs the stories of one dependency phase concurrently, up to the configured
# dev-slot budget, each in its own linked git worktree; backfills a freed slot
# with the next unstarted story of the SAME phase; holds a barrier before the
# next phase; and degrades to today's one-story-at-a-time path -- never a
# refusal -- whenever the substrate, the config, or the locking primitive
# cannot support parallel work.
#
# Sourceable (for tests and for a skill that wants one function) and runnable
# as a CLI. Callers own their own shell options; this file sets them only when
# it is the program being executed.
#
# Degradation is ALWAYS named. Each reason is a stable token so an operator and
# a log reader see the same word:
#
#   parallel-opt-in-off   concurrency was not requested
#   flock-unavailable     the locking primitive is missing or forced off
#   worktree-mode-off     per-story isolation is not switched on
#   slots-1               the budget allows no concurrency
#   sprint-unreadable     the sprint file is missing, malformed or unparseable
#   no-phase-fields       the sprint parses but carries no phase assignments
#   ceiling-cannot-admit      the dispatch ceiling is saturated and cannot free
#   admission-lock-timeout    the admission lock could not be acquired in time
#   mode-b-fallback           the agent substrate is unavailable
#   admission-error           an unclassified admission failure
#
# A run NEVER exits non-zero because parallel execution was unavailable: it
# says why and proceeds sequentially, because a sprint that does not run is a
# worse outcome than a sprint that runs slowly.
#
# Architecture: a RE-ENTRANT STEP ENGINE, not a bash loop that drives a story
# to completion. A bash script cannot do the latter: dispatch-teammate.sh's
# drive_turn/await_reply are documented PRE-SEND BOOKKEEPING ONLY (see that
# file's header) -- the actual SendMessage round-trip that would tell this
# file "the teammate finished" is a main-turn LLM tool call, unreachable from
# here. So the engine admits and tracks; the run-sprint skill's own main-turn
# loop drives real turns and reports back:
#
#   ppo_plan   --repo R --yaml Y [--slots N]   preflight + degradation + queue
#   ppo_next                                    admit up to the slot budget for
#                                                the CURRENT phase; one `dispatch
#                                                story=K phase=P persona=X
#                                                worktree=W handle=H` line per
#                                                admission (real spawn_teammate,
#                                                real registry entry -- no
#                                                polling, nothing backgrounded);
#                                                `barrier phase=P waiting=N` when
#                                                the phase cannot admit more;
#                                                `sprint_complete` when done
#   ppo_record_outcome <key> <done|failed|timeout|merged>
#                                                the skill reports what it
#                                                observed from a real driven
#                                                turn; on `merged` this engine
#                                                runs the sprint-progress-audit.sh
#                                                composite (verify-pr-merged.sh +
#                                                review-gate.sh) to decide
#                                                done vs merged-not-done --
#                                                never a story-file `status:`
#                                                poll, because merged-not-done
#                                                is not one of the seven
#                                                canonical statuses in
#                                                story-state-machine.sh and
#                                                never was
#   ppo_status                                  running stories with elapsed
#                                                vs. per-story budget, so the
#                                                skill can call `record ...
#                                                timeout` for an overdue one
#   ppo_report                                  the outcome ledger
#
# State persists under $GAIA_SESSION_DIR/ppo/ (see _ppo_engine_dir) so each
# CLI invocation of next/record is a genuine step -- the run-sprint skill
# calls plan once, then loops next/record/status across many separate
# invocations as real dev-agent turns complete.
#
# ppo_run_sprint is the backward-compatible ONE-PROCESS loop over these same
# verbs (this file's own name for `run`): sequential/degraded mode is
# unchanged; parallel mode loops ppo_next, and when the test-only dispatch
# hook (GAIA_PPO_DISPATCH_CMD, gated below) is honoured, runs it per
# dispatched story in the background and feeds its exit into
# ppo_record_outcome -- this is how the pre-existing stub-based bats suite
# keeps driving the SAME engine, with no second scheduler. Without an
# honoured hook there is no bash-drivable way to complete a story, so `run`
# performs one ppo_next call and returns, naming the real run-sprint skill
# loop as the production path.
#
# GAIA_PPO_DISPATCH_CMD (test-only, gated): when set AND a test marker is
# present (BATS_TEST_FILENAME or GAIA_PPO_ALLOW_DISPATCH_CMD=1), `run`
# invokes that command with the story key instead of a real driven turn, and
# maps its exit code (0/7/8/9/11/other) onto the record verb's outcome
# vocabulary. Set with no marker present, it is refused (logged, the real
# admission path is used regardless) rather than honoured -- an unguarded
# arbitrary-command hook is a remote-code lever, not something a stray
# inherited environment variable should be able to trigger in production.

# ---------- Source guard ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
fi
LC_ALL=C
export LC_ALL

_PPO_NAME="phase-parallel-orchestrator.sh"
_PPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ppo_log() { printf '%s: %s\n' "$_PPO_NAME" "$*" >&2; }

# Telemetry: one structured line per event. Machine-readable k=v tokens, and
# the mode is emitted even on the happy path so "why did this run the way it
# did" never requires guessing.
_ppo_emit() { printf '%s\n' "$*"; }

# _ppo_validate_key <key> — the ONE charset quarantine for every story key
# this file ever turns into a path fragment. Every key->path builder in this
# file:
#   ppo/running/<key>, ppo/retries/<key>, ppo/resolve-cache/<key>  (engine dir)
#   the registry's .reserved-<key> token       (_ppo_admit_bookkeeping here,
#                                                and dispatch-teammate.sh)
#   ppo-state/mnd-<key>, ppo-state/mndopen-<key>       (_ppo_mnd_count,
#                                                        _ppo_mnd_bump,
#                                                        _ppo_mnd_open_mark,
#                                                        _ppo_mnd_open_clear)
#   session-dir/slots/<key>                             (ppo_slot_scratch_for)
# A key is data from the sprint yaml or from a CLI caller (record/status are
# invoked with a key argument by a process outside this file's control),
# never a value this file itself constructs -- so it is validated BEFORE it
# touches any path expression, not after. Bounded charset
# (`[A-Za-z0-9._-]`), no `..` traversal segment anywhere in the string
# (catches `..` embedded via `.` characters even when every individual
# character is otherwise allowed, e.g. `a/../../etc`), non-empty, and
# length-bounded (200 is generously above any real story key -- E<epic>-S<story>
# plus slug -- and exists only to refuse a pathological argument outright
# rather than debate a "reasonable" limit).
#
# Every verb or internal function that derives ANY path from a key MUST call
# this, and refuse (non-zero, nothing built) before constructing that path,
# rather than build first and check the result: an already-built path string
# has already done the traversal arithmetic a later check could only
# re-detect, never undo. The five builders listed above call it directly as
# defense in depth even though every caller today already validates the key
# upstream (ppo_next's admission loop, ppo_record_outcome, and friends) --
# a future caller added without that discipline must not silently regain the
# gap this function exists to close.
_ppo_validate_key() {
  local key="${1:-}"
  [ -n "$key" ] || return 1
  [ "${#key}" -le 200 ] || return 1
  case "$key" in
    *[!A-Za-z0-9._-]*) return 1 ;;
    *..*) return 1 ;;
  esac
  return 0
}

# ---------- Defaults ----------

_PPO_DEFAULT_SLOTS=8
_PPO_DEFAULT_TIMEOUT_MINUTES=90
_PPO_DEFAULT_CEILING=12
_PPO_SLOTS_MAX=64

# How many consecutive ceiling refusals, with nothing running to free a slot,
# before the run stops re-queueing and degrades instead.
_PPO_CEILING_GIVEUP=3
# How many times a merged-but-not-done story is re-dispatched on the resume
# path before the run reports it as not done. A story whose gate never closes
# must not be retried forever -- that would hold its phase open and stall the
# barrier -- so the retries are bounded and the story is reported honestly.
# Each attempt is itself bounded by the per-story wall-clock budget, so this
# adds no new configuration surface.
_PPO_MND_RETRY_MAX=2

# Run state. Bash 3.2: parallel indexed arrays and newline-delimited strings,
# never associative arrays.
_PPO_OUTCOMES=""
_PPO_WORKTREES=""
_PPO_PEAK=0
_PPO_BARRIER_VIOLATIONS=0
_PPO_BACKFILL_BEFORE_DONE=0
_PPO_SEEN="|"

# Run state is also written under the session directory. The run may be invoked
# in a subshell (a harness, a pipeline), and a variable set there dies with it,
# so the accessors below read the files and fall back to the variables.
_ppo_state_dir() {
  printf '%s/ppo-state' "${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}"
}

_ppo_state_put() {
  local d; d="$(_ppo_state_dir)"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s' "$2" > "$d/$1" 2>/dev/null || true
}

_ppo_state_append() {
  local d; d="$(_ppo_state_dir)"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\n' "$2" >> "$d/$1" 2>/dev/null || true
}

_ppo_state_get() {
  local d; d="$(_ppo_state_dir)"
  [ -f "$d/$1" ] && cat "$d/$1" 2>/dev/null
  return 0
}

_ppo_state_reset() {
  local d; d="$(_ppo_state_dir)"
  rm -rf "$d" 2>/dev/null || true
  mkdir -p "$d" 2>/dev/null || true
}

# ---------- Step-engine state (ppo/) ----------
#
# A SEPARATE directory from ppo-state/ above: ppo-state/ is run-level
# telemetry (peak concurrency, the outcome ledger, barrier/backfill counts)
# that predates the step engine and stays exactly as it was, read by the same
# accessors (ppo_peak_concurrency, ppo_report, ...). ppo/ is the engine's own
# re-entrant state -- phases, the pending queue, running admissions, retry
# counts, the degradation mode -- so that ONE CLI invocation (plan, then
# next, then record, ...) can pick back up a run another invocation started,
# which ppo-state/'s in-memory-first accessors were never designed for.
_ppo_engine_dir() {
  printf '%s/ppo' "${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}"
}

_ppo_engine_reset() {
  local d; d="$(_ppo_engine_dir)"
  rm -rf "$d" 2>/dev/null || true
  mkdir -p "$d/running" "$d/retries" 2>/dev/null || true
}

_ppo_engine_put() {
  local d; d="$(_ppo_engine_dir)"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s' "$2" > "$d/$1" 2>/dev/null || true
}

_ppo_engine_get() {
  local d; d="$(_ppo_engine_dir)"
  [ -f "$d/$1" ] && cat "$d/$1" 2>/dev/null
  return 0
}

# _ppo_engine_lock_run <command...> — run one command with the engine-state
# lock held. next and record are read-modify-write over ppo/pending,
# ppo/running/*, and ppo/current_phase: two overlapping invocations (e.g. two
# `record` calls landing from two near-simultaneous completion notifications)
# without this would race a read of one file against a write from the other
# and could silently drop or duplicate a pending/running entry. Fails CLOSED
# on a lock timeout, exactly like _ppo_admit_bookkeeping's own admission
# lock: refusing to mutate unlocked state is always safer than a corrupted
# queue, and the caller sees a logged reason rather than a silent no-op.
_ppo_engine_lock_run() {
  _ppo_load_lock_lib 2>/dev/null || { _ppo_log "event=engine_lock action=refused reason=lock-lib-unavailable"; return 10; }
  command -v acquire_lock >/dev/null 2>&1 || { _ppo_log "event=engine_lock action=refused reason=lock-lib-unavailable"; return 10; }

  local lockfile
  lockfile="$(_ppo_engine_dir)/.lock"
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true

  if ! acquire_lock "$lockfile" "${GAIA_PPO_LOCK_TIMEOUT:-10}" 9 2>/dev/null; then
    _ppo_log "event=engine_lock action=refused reason=lock-timeout"
    return 10
  fi

  local rc=0
  "$@" || rc=$?
  release_lock 9 2>/dev/null || true
  return "$rc"
}

# ---------- Dependencies ----------

_ppo_lib() {
  local name="$1"
  [ -f "$_PPO_DIR/lib/$name" ] || return 1

  # At least one shared library (acquire-lock.sh) sets `set -euo pipefail`
  # UNCONDITIONALLY at its own source time, with no guard distinguishing "I
  # am the top-level script" from "I am being sourced into a caller that
  # owns its own shell options" -- sourcing it here would otherwise flip
  # errexit ON for the REST OF THIS FILE's calling shell, silently
  # overriding a sourced caller that deliberately ran `set +e` to branch on
  # THIS file's own capacity/degradation codes via `|| rc=$?`. This file is
  # sourceable (its own header says so), so every lib load funnels through
  # here and restores whatever errexit state the caller actually had,
  # regardless of what the library being loaded does to it internally.
  local _ppo_lib_errexit_was_set=0
  case "$-" in *e*) _ppo_lib_errexit_was_set=1 ;; esac

  local _ppo_lib_rc=0
  # shellcheck disable=SC1090
  . "$_PPO_DIR/lib/$name" || _ppo_lib_rc=$?

  [ "$_ppo_lib_errexit_was_set" -eq 1 ] || set +e
  return "$_ppo_lib_rc"
}

_ppo_load_worktree_lib()  { _ppo_lib story-worktree.sh; }
_ppo_load_lock_lib()      { _ppo_lib acquire-lock.sh; }
_ppo_load_dispatch_lib()  { _ppo_lib dispatch-teammate.sh; }

# resolve-story-file.sh sits one level up from lib/ (it is a shared root-level
# script, not a lib/ helper), so it does not go through _ppo_lib.
_ppo_load_resolve_story_lib() {
  [ -f "$_PPO_DIR/resolve-story-file.sh" ] || return 1
  # shellcheck disable=SC1090,SC1091
  . "$_PPO_DIR/resolve-story-file.sh"
}

# ---------- Config ----------

# _ppo_config_file — the project config, using the precedence the dispatch
# library uses so both read the same file.
_ppo_config_file() {
  local c
  for c in "${GAIA_SHARED_CONFIG:-}" \
           "${PROJECT_ROOT:-}/.gaia/config/project-config.yaml" \
           "${CLAUDE_PROJECT_ROOT:-}/.gaia/config/project-config.yaml" \
           "$PWD/.gaia/config/project-config.yaml"; do
    case "$c" in ''|/.gaia/config/project-config.yaml) continue ;; esac
    if [ -f "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 0
}

# _ppo_config_int <child> <default> — one integer from parallel_execution.
# An absent key is a fact (the operator did not configure one) and yields the
# documented default. An unreadable config is an unknown, and for these values
# the conservative answer is still the documented default: a LOWER budget is
# not safer for a timeout, it manufactures failures on slow-but-healthy runs.
_ppo_config_int() {
  local child="$1" default="$2" cfg raw
  cfg="$(_ppo_config_file)"
  [ -n "$cfg" ] || { printf '%s' "$default"; return 0; }

  if command -v yq >/dev/null 2>&1; then
    raw="$(yq -o=json ".parallel_execution.${child}" "$cfg" 2>/dev/null)" || raw=""
  elif command -v python3 >/dev/null 2>&1; then
    raw="$(python3 - "$cfg" "$child" <<'PPOPY' 2>/dev/null || true
import sys, json
try:
    import yaml
except Exception:
    sys.exit(1)
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(1)
v = d.get("parallel_execution") or {}
v = v.get(sys.argv[2]) if isinstance(v, dict) else None
print(json.dumps(v))
PPOPY
)"
  else
    raw=""
  fi

  case "$raw" in
    ''|null) printf '%s' "$default"; return 0 ;;
    *[!0-9]*) printf '%s' "$default"; return 0 ;;
  esac
  [ "$raw" -ge 1 ] 2>/dev/null || { printf '%s' "$default"; return 0; }
  printf '%s' "$raw"
}

# _ppo_resolve_target_branch — ci_cd.promotion_chain[0].branch, the same
# config value skills/gaia-dev-story/SKILL.md Step 14 derives for
# verify-pr-merged.sh and scripts/lib/dev-story-security-invariants.sh's
# assert_pr_target_from_chain asserts against. No new config key: this reads
# through _ppo_config_file(), the same resolution ladder every other value in
# this file already uses, rather than re-deriving a project-config path.
# Prints the branch on stdout; prints nothing when no promotion chain is
# configured (a real, supported shape -- "no promotion chain" -- not an
# error), mirroring verify-pr-merged.sh's own --no-chain accommodation.
_ppo_resolve_target_branch() {
  local cfg branch=""
  cfg="$(_ppo_config_file)"
  [ -n "$cfg" ] || return 0

  if command -v yq >/dev/null 2>&1; then
    branch="$(yq -r '.ci_cd.promotion_chain[0].branch' "$cfg" 2>/dev/null)" || branch=""
    [ "$branch" = "null" ] && branch=""
  fi

  if [ -z "$branch" ]; then
    branch="$(awk '
      /^[[:space:]]*promotion_chain:[[:space:]]*$/ { in_chain = 1; next }
      in_chain && /^[[:space:]]*branch:[[:space:]]*/ {
        sub(/^[[:space:]]*branch:[[:space:]]*/, "")
        gsub(/"/, "")
        print
        exit
      }
      in_chain && /^[^[:space:]-]/ { exit }
    ' "$cfg" 2>/dev/null)"
  fi

  [ -n "$branch" ] && printf '%s' "$branch"
  return 0
}

# ppo_resolve_slots — the concurrent dev-agent budget.
ppo_resolve_slots() {
  local v
  v="$(_ppo_config_int max_parallel_dev_slots "$_PPO_DEFAULT_SLOTS")"
  [ "$v" -le "$_PPO_SLOTS_MAX" ] 2>/dev/null || v="$_PPO_SLOTS_MAX"
  printf '%s' "$v"
}

# ppo_resolve_timeout — the per-story wall-clock budget, in minutes.
ppo_resolve_timeout() {
  _ppo_config_int story_timeout_minutes "$_PPO_DEFAULT_TIMEOUT_MINUTES"
}

# ppo_resolve_ceiling — the total teammate ceiling, read the same way the
# dispatch library reads it so the two never disagree about capacity.
ppo_resolve_ceiling() {
  _ppo_config_int teammate_dispatch_ceiling "$_PPO_DEFAULT_CEILING"
}

# ppo_session_dir_for <story_key> — the session directory a slot dispatches
# under. Deliberately the SHARED one: the ceiling is enforced by counting
# files in $GAIA_SESSION_DIR/registry, so a per-slot session dir would give
# every slot its own registry, each counting one, and the ceiling would never
# bind. Per-slot isolation comes from the worktree and the scratch dir below.
ppo_session_dir_for() {
  printf '%s' "${GAIA_SESSION_DIR:-}"
}

# ppo_slot_scratch_for <story_key> — per-slot scratch under the shared session
# dir. Retained after the run: deleting the evidence of a failed parallel run
# is worse than leaving one small directory per story. Defense in depth:
# every caller today already validates the key before reaching here, but this
# builder turns a key into a path fragment same as the others in
# _ppo_validate_key's header inventory, so it re-checks rather than trusting
# caller discipline alone.
ppo_slot_scratch_for() {
  _ppo_validate_key "${1:-}" || return 1
  printf '%s/slots/%s' "${GAIA_SESSION_DIR:-}" "$1"
}

# ---------- Sprint reading ----------

# ppo_read_phases <yaml> — echo `KEY|PHASE` per story, ascending by phase then
# first appearance. Exit 2 when the file cannot be read at all, 3 when it
# parses but carries no phase assignments: the two are different operator
# problems and must not share one reason.
ppo_read_phases() {
  local yaml="${1:-}"
  [ -n "$yaml" ] && [ -f "$yaml" ] || return 2

  local out
  out="$(awk '
    /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = $0
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'"'"']|["'"'"']$/, "", k)
      key = k; phase = ""
      order[++n] = key
      next
    }
    /^[[:space:]]+phase:[[:space:]]*/ {
      if (key == "") next
      p = $0
      sub(/^[[:space:]]+phase:[[:space:]]*/, "", p)
      gsub(/[^0-9]/, "", p)
      if (p != "") ph[key] = p
      next
    }
    END {
      maxp = 0
      for (i = 1; i <= n; i++) if (ph[order[i]] != "" && ph[order[i]] + 0 > maxp) maxp = ph[order[i]] + 0
      for (p = 1; p <= maxp; p++)
        for (i = 1; i <= n; i++)
          if (ph[order[i]] + 0 == p) printf "%s|%s\n", order[i], p
    }
  ' "$yaml" 2>/dev/null)" || return 2

  # A file with no story rows at all is unreadable rather than phase-less.
  grep -qE '^[[:space:]]*-[[:space:]]*key:' "$yaml" 2>/dev/null || return 2

  # Structurally broken yaml is a DIFFERENT operator problem from a sprint that
  # simply predates phases: reporting "no phase fields" for a corrupted file
  # sends someone hunting a planning problem instead of a broken file. Prefer a
  # real parser when one is present; fall back to an unclosed-flow check.
  if command -v yq >/dev/null 2>&1; then
    yq eval 'true' "$yaml" >/dev/null 2>&1 || return 2
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$yaml" <<'PPOYAML' >/dev/null 2>&1 || return 2
import sys
try:
    import yaml
except Exception:
    sys.exit(0)
try:
    yaml.safe_load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
PPOYAML
  fi
  [ -n "$out" ] || return 3
  printf '%s\n' "$out"
}

# ppo_plan_sequential --repo R --yaml Y — the worklist a degraded run follows:
# phase ascending, roster order within a phase, i.e. the order the parallel
# loop would have used.
ppo_plan_sequential() {
  local yaml=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yaml) yaml="${2:-}"; shift 2 ;;
      --repo) shift 2 ;;
      *) shift ;;
    esac
  done
  local phases rc=0
  phases="$(ppo_read_phases "$yaml")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Degraded ordering is still an ordering: fall back to roster order.
    #
    # The file may be missing or unreadable -- an unplanned sprint, or an unset
    # PROJECT_ROOT resolving to /.gaia/state/sprint-status.yaml. awk exits 2 on
    # a file it cannot open, and as the LAST command of this branch that status
    # becomes the function's, firing errexit before `return 0` and escaping
    # every `ppo_plan_sequential | while` call site through pipefail. The run
    # would then announce a sequential degradation, emit no stories and exit 2 --
    # breaking this file's promise that a run NEVER exits non-zero because
    # parallel execution was unavailable. Refuse to read what cannot be read,
    # and return the empty worklist as a SUCCESS: the caller has already named
    # the reason, and an empty ordering is the honest answer for a file with no
    # readable rows.
    if [ -r "$yaml" ]; then
      awk '/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
        k=$0; sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/,"",k)
        gsub(/^["'"'"']|["'"'"']$/,"",k); print k }' "$yaml" 2>/dev/null || true
    fi
    return 0
  fi
  # Same errexit hazard on the SUCCESS path: `[ -n "$k" ] && printf` is false
  # for a blank row, so a phases list with no usable rows leaves the `while`
  # -- and therefore this function -- at status 1, which the bare
  # `ppo_plan_sequential | while` call sites would turn into a killed run.
  # An empty worklist is a legitimate answer, not a failure.
  printf '%s\n' "$phases" | while IFS='|' read -r k _; do
    [ -n "$k" ] || continue
    printf '%s\n' "$k"
  done
  return 0
}

# ---------- Admission ----------

# ppo_preflight --repo R --yaml Y --slots N — echo `mode=parallel` or
# `mode=sequential reason=<token>`. The FIRST failing check decides, and every
# unreadable input lands on sequential: fail-closed here means "do the safe,
# slower thing", never "refuse".
ppo_preflight() {
  local repo="" yaml="" slots=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)  repo="${2:-}";  shift 2 ;;
      --yaml)  yaml="${2:-}";  shift 2 ;;
      --slots) slots="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  # The documented opt-in. Unset, or any value other than 1, means the operator
  # did not ask for concurrency -- and this surface degrades rather than
  # refusing, unlike the state writer which has nothing to fall back to.
  if [ "${GAIA_PARALLEL_EXECUTION:-}" != "1" ]; then
    _ppo_emit "mode=sequential reason=parallel-opt-in-off — concurrency was not requested; running sequentially"
    return 0
  fi

  _ppo_load_lock_lib || { _ppo_emit "mode=sequential reason=admission-error"; return 0; }
  if ! require_flock_for_parallel 2>/dev/null; then
    _ppo_emit "mode=sequential reason=flock-unavailable — parallel execution needs the lock primitive; running sequentially"
    return 0
  fi

  _ppo_load_worktree_lib || { _ppo_emit "mode=sequential reason=admission-error"; return 0; }
  if ! worktree_mode_enabled; then
    _ppo_emit "mode=sequential reason=worktree-mode-off — per-story isolation is off; running sequentially"
    return 0
  fi

  case "$slots" in
    ''|*[!0-9]*) _ppo_emit "mode=sequential reason=slots-1 — no usable slot budget; running sequentially"; return 0 ;;
  esac
  if [ "$slots" -le 1 ]; then
    _ppo_emit "mode=sequential reason=slots-1 — the slot budget allows no concurrency; running sequentially"
    return 0
  fi

  local rc=0
  ppo_read_phases "$yaml" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    _ppo_emit "mode=sequential reason=sprint-unreadable — the sprint file could not be read; running sequentially"
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    _ppo_emit "mode=sequential reason=no-phase-fields — the sprint carries no phase fields, so there is nothing to run concurrently; running sequentially"
    return 0
  fi

  local ceiling
  ceiling="$(ppo_resolve_ceiling)"
  if [ "$ceiling" -lt $((slots + 4)) ]; then
    _ppo_emit "mode=sequential reason=ceiling-cannot-admit — the dispatch ceiling leaves no headroom above the slot budget; running sequentially"
    return 0
  fi

  # Live-occupancy check: even when the configured headroom passes, a registry
  # already at or above the ceiling means no story can be admitted right now.
  # This uses the same read path the per-story claim uses, so the two never
  # disagree about capacity.
  local reg count
  reg="${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}/registry"
  if [ -d "$reg" ]; then
    count="$(find "$reg" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${count:-0}" -ge "$ceiling" ]; then
      _ppo_emit "mode=sequential reason=ceiling-cannot-admit — the dispatch ceiling is saturated (${count} active, ceiling ${ceiling}); running sequentially"
      return 0
    fi
  fi

  _ppo_emit "mode=parallel reason=none"
  return 0
}

# ---------- Step engine ----------
#
# ppo_plan / ppo_next / ppo_record_outcome / ppo_status / ppo_report make the
# orchestrator RE-ENTRANT: one CLI invocation per step, engine state persisted
# under ppo/ (see _ppo_engine_dir above) so a later invocation -- from a
# different process, dispatched by the run-sprint skill's own main-turn loop
# after it observes a real dev-agent turn complete -- picks up exactly where
# the previous invocation left off. This exists because a bash script cannot
# itself drive a story to completion: dispatch-teammate.sh's drive_turn and
# await_reply are documented PRE-SEND BOOKKEEPING ONLY (see that file's
# header) -- the actual SendMessage round-trip, and therefore the only real
# signal that a dispatched story has progressed, is a main-turn LLM tool
# call. So the engine admits and tracks; the skill drives and reports.
#
# ppo_run_sprint (below) is the backward-compatible ONE-PROCESS loop over
# these same verbs -- it is what the existing test suite drives, and it is
# also literally `run`'s implementation for the case where a test-only
# dispatch hook can stand in for a real driven turn (see ppo_dispatch_hook_*).

# ppo_plan --repo R --yaml Y [--slots N] — one-time setup: preflight, prune,
# and (on mode=parallel) load the phase worklist into ppo/. Idempotent: a
# second call re-runs preflight and re-initialises the queue from scratch,
# exactly like starting a fresh run -- callers that want to RESUME a run
# in progress call next/record, not plan again.
ppo_plan() {
  local repo="" yaml="" slots=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)  repo="${2:-}";  shift 2 ;;
      --yaml)  yaml="${2:-}";  shift 2 ;;
      --slots) slots="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  _PPO_OUTCOMES=""; _PPO_WORKTREES=""; _PPO_PEAK=0; _PPO_SEEN="|"
  _PPO_BARRIER_VIOLATIONS=0; _PPO_BACKFILL_BEFORE_DONE=0
  _ppo_state_reset
  _ppo_state_put peak 0
  _ppo_state_put barrier_violations 0
  _ppo_state_put backfill_before_done 0
  _ppo_engine_reset

  [ -n "$slots" ] || slots="$(ppo_resolve_slots)"
  _ppo_engine_put repo "$repo"
  _ppo_engine_put yaml "$yaml"
  _ppo_engine_put slots "$slots"

  local verdict
  verdict="$(ppo_preflight --repo "$repo" --yaml "$yaml" --slots "$slots")"
  _ppo_emit "$verdict"

  case "$verdict" in
    mode=parallel*)
      _ppo_engine_put mode "mode=parallel reason=none"
      ;;
    *)
      # Degraded: persist the reason so a LATER next/record invocation
      # agrees with what plan already announced, instead of failing on
      # missing engine state or silently re-deciding. The
      # sequential worklist itself is regenerated on demand from repo/yaml
      # rather than persisted -- ppo_plan_sequential is already cheap and
      # deterministic, so caching it would only be one more place for state
      # to go stale.
      _ppo_engine_put mode "$verdict"
      ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r k; do
        [ -n "$k" ] && _ppo_emit "event=sequential story=${k}"
      done
      return 0
      ;;
  esac

  _ppo_load_worktree_lib || { _ppo_engine_put mode "mode=sequential reason=admission-error"; return 0; }
  # Reap whatever a previously killed run left behind, before anything is
  # created, so a story whose branch survives can attach cleanly.
  worktree_prune_stale "$repo" >/dev/null 2>&1 || true
  export GAIA_WORKTREE_PRUNE_ON_CREATE=0

  # A reservation orphaned by a killed run counts toward the ceiling forever,
  # so it is cleared before this run starts claiming any of its own.
  ppo_reap_stale_reservations

  local phases
  phases="$(ppo_read_phases "$yaml")" || { _ppo_engine_put mode "mode=sequential reason=sprint-unreadable"; return 0; }
  _ppo_engine_put phases "$phases"

  local first_phase
  first_phase="$(printf '%s\n' "$phases" | awk -F'|' '{print $2}' | sort -n -u | head -n1)"
  _ppo_engine_put current_phase "${first_phase:-1}"
  _ppo_engine_put pending "$(printf '%s\n' "$phases" | awk -F'|' -v ph="${first_phase:-1}" '$2 == ph {print $1}')"

  return 0
}

# ---------- Dispatch ----------

# _ppo_resolve_story_file <story_key> — thin wrapper around the shared
# resolve-story-file.sh resolver. Prints the path on stdout; returns the
# resolver's own exit code (1 no match, 2 ambiguous) on failure UNCHANGED --
# callers MUST branch on it rather than treating any non-zero return as the
# same "no story file" case: exit 2 means the key resolved to more than one
# on-disk candidate, a misconfiguration the operator has to fix, not an
# absent story a default persona can safely stand in for.
#
# Memoized per run under ppo/resolve-cache/<key> (path on line 1, exit code
# on line 2): the resolver walks the whole implementation-artifacts tree
# (find over epic-*/stories/, ~10ms per directory -- seconds at a few
# hundred), and a merged-not-done resume re-queues the SAME key through
# _ppo_admit_bookkeeping again on every retry attempt, so without a cache a
# large sprint pays that walk repeatedly for a key whose on-disk answer
# cannot have changed between one retry and the next within a single run.
# Cleared by ppo_plan (via _ppo_engine_reset) at the start of every run, so a
# stale answer from a previous run is never served.
_ppo_resolve_story_file() {
  local key="${1:-}" cache_dir cache_file path="" rc=0
  _ppo_validate_key "$key" || { _ppo_log "event=key_refused verb=resolve-story-file reason=invalid-key story=${key}"; return 1; }
  cache_dir="$(_ppo_engine_dir)/resolve-cache"
  cache_file="${cache_dir}/${key}"

  if [ -n "$key" ] && [ -f "$cache_file" ]; then
    path="$(sed -n '1p' "$cache_file" 2>/dev/null)"
    rc="$(sed -n '2p' "$cache_file" 2>/dev/null)"
    case "$rc" in ''|*[!0-9]*) rc=0 ;; esac
    [ "$rc" -eq 0 ] && [ -n "$path" ] && printf '%s' "$path"
    return "$rc"
  fi

  _ppo_load_resolve_story_lib || return 1
  path="$(resolve_story_file "$key" 2>/dev/null)" || rc=$?

  if [ -n "$key" ]; then
    mkdir -p "$cache_dir" 2>/dev/null && {
      printf '%s\n%s\n' "$path" "$rc" > "$cache_file" 2>/dev/null || true
    }
  fi

  [ "$rc" -eq 0 ] && [ -n "$path" ] && printf '%s' "$path"
  return "$rc"
}

# _ppo_resolve_persona <story_file> — the developer persona to dispatch for
# this story, via the same resolver Step 3b of gaia-dev-story uses (the
# story's own `stack:` frontmatter, then project config, then filesystem
# markers). `bash-dev` is the documented fallback when nothing resolves,
# logged rather than silently substituted so an operator can see why a
# story landed on an unexpected persona.
_ppo_resolve_persona() {
  local story_file="${1:-}" out="" persona=""
  if [ -n "$story_file" ] && [ -f "$_PPO_DIR/load-stack-persona.sh" ]; then
    out="$(bash "$_PPO_DIR/load-stack-persona.sh" --story-file "$story_file" 2>/dev/null)" || out=""
    if [ -n "$out" ]; then
      persona="$(printf '%s\n' "$out" | sed -n "s/^stack='\\(.*\\)'\$/\\1/p" | head -n 1)"
    fi
  fi
  if [ -z "$persona" ]; then
    _ppo_log "no persona resolved for ${story_file:-<unknown story file>} — defaulting to bash-dev"
    persona="bash-dev"
  fi
  printf '%s' "$persona"
}

# _ppo_live_dir — where this run records the handles it has spawned and not
# yet shut down. One file per LIVE handle, named by the handle itself so a
# concurrent untrack (from the natural completion path) and a trap-driven
# shutdown racing the same handle both resolve to the same filename and the
# second one to arrive finds nothing to remove -- no lock needed, `rm -f` on a
# missing file is already a no-op.
#
# Deliberately a DIFFERENT directory from the teammate registry itself
# (GAIA_SESSION_DIR/registry): the registry is the library's own state, keyed
# by handle and consumed by shutdown_teammate; this directory is this run's
# own bookkeeping of which of those registry entries it is responsible for
# tearing down. Conflating the two would mean writing into a directory the
# library owns and expects only its own record shape in.
_ppo_live_dir() {
  printf '%s/ppo-live-teammates' "${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}"
}

# _ppo_handle_track <handle> — record a just-spawned handle as live for THIS
# run ($$, the same value _ppo_admit_bookkeeping stamps into a reservation
# token -- see the note there on why $$ inside a backgrounded function call
# still names the top-level run, not the background job).
_ppo_handle_track() {
  local handle="${1:-}" d
  [ -n "$handle" ] || return 0
  d="$(_ppo_live_dir)"
  mkdir -p "$d" 2>/dev/null || return 0
  printf 'owner:%s\n' "$$" > "${d}/${handle}" 2>/dev/null || true
}

# _ppo_handle_untrack <handle> — this run finished with the handle through the
# normal path (shutdown_teammate already ran); stop tracking it so the trap
# does not shut it down a second time.
_ppo_handle_untrack() {
  local handle="${1:-}" d
  [ -n "$handle" ] || return 0
  d="$(_ppo_live_dir)"
  rm -f "${d}/${handle}" 2>/dev/null || true
}

# ppo_shutdown_live_teammates — shut down every teammate THIS run spawned and
# has not already shut down, then stop tracking it. Installed on the run-level
# trap alongside ppo_release_reservations: shutdown_teammate at the natural
# end of a story's lifecycle only runs when ppo_record_outcome is actually
# called for it -- a run killed before the skill ever reports back (or one
# that dies with the trap firing on EXIT) never reaches that call, so each
# live teammate's registry entry would otherwise survive the run that
# spawned it and count against the shared ceiling forever, with no liveness
# check anywhere else to reclaim it.
#
# Idempotent: shutdown_teammate on an already-shut-down (or never-registered)
# handle returns non-zero, which is swallowed here exactly as the natural
# path already swallows it -- a handle shut down twice, once naturally and
# once from this sweep racing it, is not an error.
ppo_shutdown_live_teammates() {
  local d f handle owner
  d="$(_ppo_live_dir)"
  [ -d "$d" ] || return 0
  # shutdown_teammate is defined by the dispatch library. _ppo_admit_bookkeeping
  # loads it lazily, but inside `ppo_next`, the SAME top-level shell the trap
  # runs in for plan/next/record -- however `run`'s own hook-invocation
  # subshells fork a SEPARATE process, so a function sourced only there never
  # becomes visible here regardless. The trap must load the library itself
  # before it can call shutdown_teammate; a run that degraded before any
  # admission ever happened (e.g. worktree-mode-off) has no live-handle files
  # to begin with, so the load below is reached only when there is real work
  # to do.
  _ppo_load_dispatch_lib 2>/dev/null || true
  command -v shutdown_teammate >/dev/null 2>&1 || return 0
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    handle="$(basename "$f")"
    owner="$(sed -n 's/^owner://p;q' "$f" 2>/dev/null)"
    case "$owner" in
      "$$")
        shutdown_teammate "$handle" >/dev/null 2>&1 || true
        rm -f "$f" 2>/dev/null || true
        ;;
    esac
  done
  return 0
}

# _ppo_admit_bookkeeping <story_key> <repo> — claim a ceiling reservation
# under the admission lock (count-and-claim against the shared registry,
# same discipline as _ppo_engine_lock_run's own note on the race this
# closes), then resolve the story file / persona and call the real
# spawn_teammate. NO polling and NO backgrounding: the engine tracks the
# handle in ppo/running/<key> (see ppo_next) and returns immediately,
# because there is nothing left for a bash loop to usefully wait on for a
# real driven turn (see the step-engine header above). Returns 0 with the
# persona and handle printed as `persona:<p>` / `handle:<h>` lines on
# stdout, or an admission-status code with nothing on stdout: 1 failed or
# ambiguous story file, 7 substrate fallback, 8 ceiling saturated, 10 lock
# timeout, or the spawn's own unclassified raw exit code.
_ppo_admit_bookkeeping() {
  local key="${1:-}" repo="${2:-}"
  _ppo_validate_key "$key" || { _ppo_log "event=key_refused verb=admit reason=invalid-key story=${key}"; return 1; }

  local rc=0 locked=0 token="" reg="" ceiling=0 count=0
  reg="${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}/registry"
  mkdir -p "$reg" 2>/dev/null || true
  ceiling="$(ppo_resolve_ceiling)"

  # _ppo_load_lock_lib funnels through _ppo_lib, which restores whatever
  # errexit state THIS function's caller had before the sourced library
  # (acquire-lock.sh sets `set -euo pipefail` unconditionally) had a chance
  # to override it -- see _ppo_lib's own comment. No local save/restore
  # dance is needed here as a result.
  if ! _ppo_load_lock_lib 2>/dev/null || ! command -v acquire_lock >/dev/null 2>&1; then
    return 10
  fi
  if ! acquire_lock "${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}/.ppo-admit.lock" \
      "${GAIA_PPO_LOCK_TIMEOUT:-10}" 8 2>/dev/null; then
    return 10
  fi
  locked=1

  count="$(find "$reg" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ -n "${GAIA_PPO_CLAIM_DELAY:-}" ] && sleep "$GAIA_PPO_CLAIM_DELAY"
  if [ "${count:-0}" -lt "${ceiling:-0}" ]; then
    token="${reg}/.reserved-${key}"
    printf 'reserved_by:%s\n' "$$" > "$token" 2>/dev/null || token=""
    [ -n "$token" ] && _ppo_state_append reservations "$token"
  fi

  [ "$locked" -eq 1 ] && { release_lock 8 2>/dev/null || true; }

  if [ -z "$token" ]; then
    return 8
  fi

  # ---- Story file / persona resolution. ----
  local story_file="" persona="" resolve_rc=0
  if ! _ppo_load_dispatch_lib 2>/dev/null || ! command -v spawn_teammate >/dev/null 2>&1; then
    rm -f "$token" 2>/dev/null || true
    return 1
  fi

  story_file="$(_ppo_resolve_story_file "$key")" || resolve_rc=$?
  case "$resolve_rc" in
    0) : ;;
    2)
      _ppo_log "event=story_file_ambiguous story=${key} action=refused reason=multiple-candidate-files — resolve-story-file.sh returned exit 2; fix the duplicate before this story can be dispatched"
      rm -f "$token" 2>/dev/null || true
      return 1
      ;;
    *) story_file="" ;;
  esac
  persona="$(_ppo_resolve_persona "$story_file")"

  local handle="" spawn_rc=0
  handle="$(spawn_teammate "$persona" --story-key "$key" 2>/dev/null)" || spawn_rc=$?
  rm -f "$token" 2>/dev/null || true

  if [ "$spawn_rc" -ne 0 ]; then
    return "$spawn_rc"
  fi

  _ppo_handle_track "$handle"
  printf 'persona:%s\n' "$persona"
  printf 'handle:%s\n' "$handle"
  return 0
}

# ppo_next — admit up to the slot budget for the CURRENT phase ONLY (the
# phase-look-ahead the old inline loop enforced via its outer `for p in
# all_phases` structure is enforced here BY CONSTRUCTION: this function never
# reads a later phase's pending queue). One `dispatch story=... phase=...
# persona=... worktree=... handle=...` line per admission; `barrier
# phase=P waiting=N` when the phase cannot admit more but is not done;
# `event=phase_start`/`event=phase_complete` on a phase boundary; `mode=...`
# unchanged from plan when a story's own admission reveals a run-wide
# degradation (mode-b-fallback, ceiling-cannot-admit, admission-lock-timeout
# -- these still end the run exactly as ppo_run_sprint's inline loop did,
# because they are properties of the WHOLE run, not one story); `sprint_complete`
# once no phase has pending or running work left.
ppo_next() {
  _ppo_engine_lock_run _ppo_next_locked
}

_ppo_next_locked() {
  local mode; mode="$(_ppo_engine_get mode)"
  case "$mode" in
    mode=sequential*)
      _ppo_emit "$mode"
      local repo yaml
      repo="$(_ppo_engine_get repo)"; yaml="$(_ppo_engine_get yaml)"
      ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r k; do
        [ -n "$k" ] && _ppo_emit "event=sequential story=${k}"
      done
      return 0
      ;;
    '')
      _ppo_log "event=next action=refused reason=no-plan — call plan before next"
      return 1
      ;;
  esac

  local repo slots phases
  repo="$(_ppo_engine_get repo)"
  slots="$(_ppo_engine_get slots)"
  phases="$(_ppo_engine_get phases)"

  local advanced=1
  while [ "$advanced" -eq 1 ]; do
    advanced=0
    local p pending running_count
    p="$(_ppo_engine_get current_phase)"
    pending="$(_ppo_engine_get pending)"
    running_count="$(find "$(_ppo_engine_dir)/running" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"

    if [ -z "$pending" ] && [ "${running_count:-0}" -eq 0 ]; then
      # This phase is drained. Find the next phase with pending OR running
      # work (running should be empty here by construction, but a phase with
      # ONLY running entries left -- none pending -- also does not advance
      # until record clears them, so this branch is reached only once both
      # are empty).
      _ppo_emit "event=phase_complete phase=${p}"
      local next_phase
      next_phase="$(printf '%s\n' "$phases" | awk -F'|' -v cur="$p" '$2 > cur {print $2}' | sort -n -u | head -n1)"
      if [ -z "$next_phase" ]; then
        _ppo_emit "sprint_complete"
        return 0
      fi
      _ppo_engine_put current_phase "$next_phase"
      _ppo_engine_put pending "$(printf '%s\n' "$phases" | awk -F'|' -v ph="$next_phase" '$2 == ph {print $1}')"
      local _nonterm
      _nonterm="$(ppo_outcome_count merged-not-done)"
      if [ "${_nonterm:-0}" -gt 0 ]; then
        _PPO_BARRIER_VIOLATIONS=$((_PPO_BARRIER_VIOLATIONS + _nonterm))
        _ppo_state_put barrier_violations "$_PPO_BARRIER_VIOLATIONS"
        _ppo_emit "event=barrier_violation phase=${next_phase} non_terminal=${_nonterm}"
      fi
      _ppo_emit "event=phase_start phase=${next_phase}"
      advanced=1
      continue
    fi
  done

  local p pending running_count
  p="$(_ppo_engine_get current_phase)"
  pending="$(_ppo_engine_get pending)"
  running_count="$(find "$(_ppo_engine_dir)/running" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"

  local ceiling_refusals=0
  while [ -n "$pending" ] && [ "${running_count:-0}" -lt "${slots:-1}" ]; do
    local key rest
    key="${pending%%$'\n'*}"
    if [ "$key" = "$pending" ]; then rest=""; else rest="${pending#*$'\n'}"; fi
    if [ -z "$key" ]; then pending="$rest"; _ppo_engine_put pending "$pending"; continue; fi

    if ! _ppo_validate_key "$key"; then
      _ppo_emit "event=story_refused story=${key} phase=${p} outcome=invalid-key"
      _ppo_record "$key" "failed" "$p"
      pending="$rest"; _ppo_engine_put pending "$pending"
      continue
    fi

    local bstate seen
    seen="$(_ppo_engine_get seen)"
    case "|${seen}|" in
      *"|${key}|"*) bstate="absent" ;;
      *)
        _ppo_load_worktree_lib 2>/dev/null || true
        bstate="$(worktree_branch_state "$repo" "feat/${key}-slug" 2>/dev/null || printf 'absent')"
        ;;
    esac
    _ppo_engine_put seen "${seen}${seen:+ }${key}"
    case "$bstate" in
      checked-out:*) _ppo_emit "event=attached story=${key} phase=${p}" ;;
    esac

    if [ "$(_ppo_mnd_open_count)" -gt 0 ]; then
      case "$(_ppo_mnd_open_keys)" in
        *"|${key}|"*) : ;;
        *)
          _PPO_BACKFILL_BEFORE_DONE=$((_PPO_BACKFILL_BEFORE_DONE + 1))
          _ppo_state_put backfill_before_done "$_PPO_BACKFILL_BEFORE_DONE"
          _ppo_emit "event=backfill_before_done story=${key} phase=${p}"
          ;;
      esac
    fi

    mkdir -p "$(ppo_slot_scratch_for "$key")" 2>/dev/null || true
    local wt=""
    wt="$(worktree_create "$repo" "$key" "slug" 2>/dev/null)" || wt=""
    if [ -n "$wt" ]; then
      _PPO_WORKTREES="${_PPO_WORKTREES}${_PPO_WORKTREES:+$'\n'}${wt}"
      _ppo_state_append worktrees "$wt"
      printf '%s' "$wt" > "$(ppo_slot_scratch_for "$key")/worktree" 2>/dev/null || true
    fi

    local out="" arc=0
    out="$(_ppo_admit_bookkeeping "$key" "$repo")" || arc=$?

    if [ "$arc" -ne 0 ]; then
      case "$arc" in
        7)
          _ppo_engine_put mode "mode=sequential reason=mode-b-fallback — the agent substrate is unavailable; running sequentially in phase order"
          _ppo_emit "mode=sequential reason=mode-b-fallback — the agent substrate is unavailable; running sequentially in phase order"
          local yaml; yaml="$(_ppo_engine_get yaml)"
          ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r sk; do
            [ -n "$sk" ] && _ppo_emit "event=sequential story=${sk}"
          done
          return 0
          ;;
        8)
          ceiling_refusals=$((ceiling_refusals + 1))
          if [ "$ceiling_refusals" -ge "$_PPO_CEILING_GIVEUP" ]; then
            _ppo_engine_put mode "mode=sequential reason=ceiling-cannot-admit — the dispatch ceiling is saturated and no slot can free it; running sequentially"
            _ppo_emit "mode=sequential reason=ceiling-cannot-admit — the dispatch ceiling is saturated and no slot can free it; running sequentially"
            local yaml; yaml="$(_ppo_engine_get yaml)"
            ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r sk; do
              [ -n "$sk" ] && _ppo_emit "event=sequential story=${sk}"
            done
            return 0
          fi
          # Capacity condition: story stays at the head of pending (not
          # consumed), stop admitting this round -- a later next call retries.
          break
          ;;
        10)
          _ppo_engine_put mode "mode=sequential reason=admission-lock-timeout — the admission lock could not be acquired; running sequentially rather than admitting unlocked"
          _ppo_emit "mode=sequential reason=admission-lock-timeout — the admission lock could not be acquired; running sequentially rather than admitting unlocked"
          local yaml; yaml="$(_ppo_engine_get yaml)"
          ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r sk; do
            [ -n "$sk" ] && _ppo_emit "event=sequential story=${sk}"
          done
          return 0
          ;;
        *)
          # Story-file ambiguity or an unclassified spawn failure: the
          # story itself is refused, siblings continue.
          _ppo_record "$key" "failed" "$p"
          pending="$rest"; _ppo_engine_put pending "$pending"
          continue
          ;;
      esac
    fi

    ceiling_refusals=0
    local persona handle
    persona="$(printf '%s\n' "$out" | sed -n 's/^persona://p')"
    handle="$(printf '%s\n' "$out" | sed -n 's/^handle://p')"

    {
      printf 'phase:%s\n' "$p"
      printf 'persona:%s\n' "$persona"
      printf 'worktree:%s\n' "$wt"
      printf 'handle:%s\n' "$handle"
      printf 'dispatched_at:%s\n' "$(date +%s)"
    } > "$(_ppo_engine_dir)/running/${key}" 2>/dev/null || true

    running_count=$((running_count + 1))
    if [ "$running_count" -gt "$_PPO_PEAK" ]; then
      _PPO_PEAK="$running_count"
      _ppo_state_put peak "$_PPO_PEAK"
    fi
    _ppo_emit "dispatch story=${key} phase=${p} persona=${persona} worktree=${wt} handle=${handle}"

    pending="$rest"
    _ppo_engine_put pending "$pending"
  done

  running_count="$(find "$(_ppo_engine_dir)/running" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${running_count:-0}" -gt 0 ]; then
    _ppo_emit "barrier phase=${p} waiting=${running_count}"
  elif [ -z "$pending" ]; then
    _ppo_emit "sprint_complete"
  fi
  return 0
}

# _ppo_is_merged_not_done <key> <yaml> — the REAL merged-not-done oracle:
# sprint-progress-audit.sh, composing verify-pr-merged.sh (merge-on-target
# detection) and review-gate.sh (gate completeness) -- never a story-file
# `status:` field, because merged-not-done is not one of the seven canonical
# statuses in story-state-machine.sh (backlog | validating | ready-for-dev |
# in-progress | blocked | review | done) and never was; a bash poll of a
# story-file field for a value the state machine never writes could only ever
# time out. Returns 0 (merged but NOT done -- the audit flagged this key) or
# 1 (clean: either not merged at all, which "record merged" from the skill's
# own observation already contradicts, or merged AND done).
#
# GAIA_PPO_AUDIT_CMD (test-only, gated exactly like GAIA_PPO_DISPATCH_CMD --
# see this file's header for the rationale and the marker check this
# mirrors): when set under a test marker, that command is
# invoked with `<key> <sprint-status-yaml> <target-branch>` instead of the
# real sprint-progress-audit.sh, and its exit code (0 clean / 4 offending,
# matching the real script's own contract) is honoured as-is.
_ppo_is_merged_not_done() {
  local key="${1:-}" yaml="${2:-}" branch="" rc=0
  branch="$(_ppo_resolve_target_branch)"
  [ -n "$branch" ] || return 1

  if [ -n "${GAIA_PPO_AUDIT_CMD:-}" ] \
     && { [ -n "${BATS_TEST_FILENAME:-}" ] || [ "${GAIA_PPO_ALLOW_DISPATCH_CMD:-}" = "1" ]; }; then
    _ppo_log "event=audit_hook cmd=${GAIA_PPO_AUDIT_CMD} action=honoured"
    "$GAIA_PPO_AUDIT_CMD" "$key" "$yaml" "$branch" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 4 ] && return 0
    return 1
  fi
  if [ -n "${GAIA_PPO_AUDIT_CMD:-}" ]; then
    _ppo_log "event=audit_hook cmd=${GAIA_PPO_AUDIT_CMD} action=refused reason=no-test-marker"
  fi

  [ -f "$_PPO_DIR/sprint-progress-audit.sh" ] || return 1
  local out=""
  out="$(bash "$_PPO_DIR/sprint-progress-audit.sh" --sprint-status "$yaml" --target-branch "$branch" 2>/dev/null)" || rc=$?
  [ "${rc:-0}" -eq 4 ] || return 1
  printf '%s\n' "$out" | grep -q "^WARNING: ${key} " && return 0
  return 1
}

# ppo_record_outcome <key> <done|failed|timeout|merged> — the skill reports
# what it observed from driving the real dev-agent turn; this verb reaps the
# admission, tears down per outcome, and updates the ledger. Locked exactly
# like ppo_next: concurrent record calls for different keys must not race
# the shared pending/running state.
#
# This is also the CLI `record` verb's implementation (see _ppo_cli), so the
# outcome vocabulary it accepts here is EXACTLY the CLI-reachable one: done,
# failed, timeout, merged. `merged-not-done` is deliberately absent from
# this vocabulary -- it is the internal resume/give-up transition
# `_ppo_is_merged_not_done`'s own audit decides for `merged`, and it must
# stay reachable only from that audited path or from the legacy in-process
# test hook's own internal call (_ppo_record_outcome_locked_internal_mnd
# below), never as a string a caller of this public entry point -- CLI or
# library -- can pass to skip the audit. A caller that could simply say
# `record K merged-not-done` on the command line would bypass the merge/gate
# audit entirely, reporting a story as "resolved" (or exhausting its retries
# into a false "not done") without sprint-progress-audit.sh ever having run.
ppo_record_outcome() {
  _ppo_engine_lock_run _ppo_record_outcome_locked "$@"
}

# _ppo_record_outcome_internal_mnd <key> — the ONLY other entry point allowed
# to apply the merged-not-done resume/give-up transition without going
# through _ppo_is_merged_not_done's audit call. Reachable only from `run`'s
# own legacy in-process test-hook loop (see the exit-11 branch below), never
# from the CLI or from ppo_record_outcome's own outcome-string vocabulary:
# there is no outcome literal that reaches this function, so no CLI
# argument -- however constructed -- can trigger it. Locked exactly like
# ppo_record_outcome, since it mutates the same pending/running state.
_ppo_record_outcome_internal_mnd() {
  _ppo_engine_lock_run _ppo_record_outcome_locked_internal_mnd "$@"
}

_ppo_record_outcome_locked_internal_mnd() {
  local key="${1:-}"
  _ppo_validate_key "$key" || { _ppo_log "event=key_refused verb=record-internal-mnd reason=invalid-key story=${key}"; return 1; }

  local running_file
  running_file="$(_ppo_engine_dir)/running/${key}"
  [ -f "$running_file" ] || { _ppo_log "event=record story=${key} action=refused reason=not-running"; return 1; }

  local p handle
  p="$(sed -n '/^phase:/{s/^phase://;p;q;}' "$running_file")"
  handle="$(sed -n '/^handle:/{s/^handle://;p;q;}' "$running_file")"
  _ppo_load_dispatch_lib 2>/dev/null || true
  _ppo_apply_mnd_not_done "$key" "$p" "$handle" "$running_file"
  return 0
}

_ppo_record_outcome_locked() {
  local key="${1:-}" outcome="${2:-}"
  [ -n "$key" ] && [ -n "$outcome" ] || { _ppo_log "event=record action=refused reason=usage — record <key> <done|failed|timeout|merged>"; return 1; }

  _ppo_validate_key "$key" || { _ppo_log "event=key_refused verb=record reason=invalid-key story=${key}"; return 1; }

  local running_file
  running_file="$(_ppo_engine_dir)/running/${key}"
  [ -f "$running_file" ] || { _ppo_log "event=record story=${key} action=refused reason=not-running"; return 1; }

  local p persona wt handle repo yaml
  # NOTE the `q` is scoped to the /pattern/ block, not appended after `p`:
  # `s/^phase://p;q' would quit after the FIRST LINE of the file regardless
  # of whether it matched -- correct only for whichever field happens to be
  # written first, and silently empty for persona/worktree/handle for as
  # long as this file's writer keeps `phase:` on line 1 (see
  # _ppo_admit_bookkeeping / the write in ppo_next). Restricting `q` to fire
  # only once the pattern actually matched makes each read independent of
  # every other field's position in the file.
  p="$(sed -n '/^phase:/{s/^phase://;p;q;}' "$running_file")"
  persona="$(sed -n '/^persona:/{s/^persona://;p;q;}' "$running_file")"
  wt="$(sed -n '/^worktree:/{s/^worktree://;p;q;}' "$running_file")"
  handle="$(sed -n '/^handle:/{s/^handle://;p;q;}' "$running_file")"
  repo="$(_ppo_engine_get repo)"
  yaml="$(_ppo_engine_get yaml)"

  _ppo_load_dispatch_lib 2>/dev/null || true
  _ppo_load_worktree_lib 2>/dev/null || true

  case "$outcome" in
    done)
      _ppo_apply_mnd_clean "$key" "$p" "$wt" "$repo" "$handle" "$running_file"
      ;;
    failed)
      command -v shutdown_teammate >/dev/null 2>&1 && { shutdown_teammate "$handle" >/dev/null 2>&1 || true; }
      _ppo_handle_untrack "$handle"
      rm -f "$running_file" 2>/dev/null || true
      _ppo_record "$key" "failed" "$p"
      ;;
    timeout)
      command -v shutdown_teammate >/dev/null 2>&1 && { shutdown_teammate "$handle" >/dev/null 2>&1 || true; }
      _ppo_handle_untrack "$handle"
      rm -f "$running_file" 2>/dev/null || true
      _ppo_emit "event=story_timeout story=${key} phase=${p} outcome=slot-timeout"
      _ppo_record "$key" "slot-timeout" "$p"
      ;;
    merged)
      # The audit decides: sprint-progress-audit.sh (or its gated test hook)
      # is the oracle, never a caller's own guess -- see _ppo_is_merged_not_done.
      if _ppo_is_merged_not_done "$key" "$yaml"; then
        _ppo_apply_mnd_not_done "$key" "$p" "$handle" "$running_file"
      else
        _ppo_apply_mnd_clean "$key" "$p" "$wt" "$repo" "$handle" "$running_file"
      fi
      ;;
    *)
      # `merged-not-done` is deliberately refused here, same as any other
      # unrecognised literal: it is not part of this entry point's
      # CLI-reachable vocabulary (done|failed|timeout|merged) precisely
      # because it would let a caller skip _ppo_is_merged_not_done's audit
      # and assert the resume/give-up transition on its own say-so. The
      # legacy in-process test hook that used to pass this literal now calls
      # _ppo_record_outcome_internal_mnd directly instead (see `run`'s
      # exit-11 branch) -- a function with no outcome-string parameter at
      # all, so no CLI argument can reach it.
      _ppo_log "event=outcome_refused verb=record story=${key} reason=unknown-outcome — ${outcome}"
      return 1
      ;;
  esac
  return 0
}

# _ppo_apply_mnd_not_done <key> <phase> <handle> <running_file> — the
# resume-or-give-up transition shared by ppo_record_outcome's `merged`
# (audit-confirmed not-done) and `merged-not-done` (caller-confirmed, see
# that outcome's own comment) branches.
_ppo_apply_mnd_not_done() {
  local key="$1" p="$2" handle="$3" running_file="$4"
  local _mnd_n=0
  _mnd_n="$(_ppo_mnd_count "$key")"
  if [ "$_mnd_n" -lt "$_PPO_MND_RETRY_MAX" ]; then
    _ppo_mnd_bump "$key"
    _ppo_mnd_open_mark "$key"
    rm -f "$running_file" 2>/dev/null || true
    local pending; pending="$(_ppo_engine_get pending)"
    _ppo_engine_put pending "${key}${pending:+$'\n'}${pending}"
    _ppo_emit "event=story_merged_not_done story=${key} phase=${p} outcome=resume-requeued attempt=$((_mnd_n + 1))"
  else
    _ppo_mnd_open_clear "$key"
    command -v shutdown_teammate >/dev/null 2>&1 && { shutdown_teammate "$handle" >/dev/null 2>&1 || true; }
    _ppo_handle_untrack "$handle"
    rm -f "$running_file" 2>/dev/null || true
    _ppo_emit "event=story_merged_not_done story=${key} phase=${p} outcome=not-done"
    _ppo_record "$key" "merged-not-done" "$p"
  fi
}

# _ppo_apply_mnd_clean <key> <phase> <worktree> <repo> <handle> <running_file>
# — the audit found nothing offending for this key: treat exactly like `done`.
_ppo_apply_mnd_clean() {
  local key="$1" p="$2" wt="$3" repo="$4" handle="$5" running_file="$6"
  if [ -n "$wt" ]; then
    worktree_teardown "$repo" "$wt" --discard-ignored >/dev/null 2>&1 || true
  fi
  command -v shutdown_teammate >/dev/null 2>&1 && { shutdown_teammate "$handle" >/dev/null 2>&1 || true; }
  _ppo_handle_untrack "$handle"
  _ppo_mnd_open_clear "$key"
  rm -f "$running_file" 2>/dev/null || true
  _ppo_record "$key" "done" "$p"
}

# _ppo_requeue <key> — release this story's admission WITHOUT recording any
# ledger outcome, and put it back at the FRONT of pending. This is the
# capacity/fallback path (`run`+hook's exit 7/8, mirroring the pre-engine
# reap's identical re-queue-on-8 and degrade-on-7 behaviour): a saturated
# ceiling or an unavailable substrate is a property of the RUN, never of the
# story, so it must never appear as `done`/`failed` in the ledger, and the
# story must get another chance to be admitted rather than being dropped.
# Private: not a CLI verb, called only from the `run` hook's exit-7/8 path.
_ppo_requeue() {
  _ppo_engine_lock_run _ppo_requeue_locked "$@"
}

_ppo_requeue_locked() {
  local key="${1:-}"
  _ppo_validate_key "$key" || { _ppo_log "event=key_refused verb=requeue reason=invalid-key story=${key}"; return 1; }

  local running_file
  running_file="$(_ppo_engine_dir)/running/${key}"
  [ -f "$running_file" ] || return 0

  local handle
  handle="$(sed -n '/^handle:/{s/^handle://;p;q;}' "$running_file")"
  _ppo_load_dispatch_lib 2>/dev/null || true
  command -v shutdown_teammate >/dev/null 2>&1 && { shutdown_teammate "$handle" >/dev/null 2>&1 || true; }
  _ppo_handle_untrack "$handle"
  rm -f "$running_file" 2>/dev/null || true

  local pending; pending="$(_ppo_engine_get pending)"
  _ppo_engine_put pending "${key}${pending:+$'\n'}${pending}"
  return 0
}

# ppo_status — running stories with elapsed-vs-budget, the ledger, and
# preserved worktrees. The skill calls this each turn to learn which running
# stories are overdue (elapsed > the per-story wall-clock budget) so it can
# call `record <key> timeout` for them rather than waiting on a turn that may
# have silently died -- there is no bash-observable liveness signal for a
# real dev-agent turn, so a budget is the only bound available.
ppo_status() {
  local d f key budget now elapsed overdue
  d="$(_ppo_engine_dir)/running"
  budget="${GAIA_STORY_TIMEOUT_SECONDS:-}"
  if [ -z "$budget" ]; then
    budget="$(ppo_resolve_timeout)"
    budget=$((budget * 60))
  fi
  now="$(date +%s)"
  if [ -d "$d" ]; then
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      key="$(basename "$f")"
      # NOTE: `/^dispatched_at:/{s/^dispatched_at://;p;q;}`, not a bare
      # `s/^dispatched_at://p;q` -- the `q` there fires after the FIRST LINE
      # of the file regardless of whether it matched, so on a real
      # running/<key> file (ppo_next writes `phase:` first, `dispatched_at:`
      # last) the substitution never even reaches the line it targets and
      # this always read empty. See the identical fix and rationale on
      # _ppo_record_outcome_locked's own field reads a few hundred lines up.
      local dispatched_at; dispatched_at="$(sed -n '/^dispatched_at:/{s/^dispatched_at://;p;q;}' "$f")"
      # A missing or non-numeric dispatched_at is unobservable liveness, not
      # a fresh dispatch: defaulting it to `now` (elapsed=0) would silently
      # report a story that has been running for an unknown, possibly very
      # long, time as freshly started and never overdue -- the skill would
      # then never call `record ... timeout` for it, exactly the silent
      # non-overdue this field exists to prevent. It would also crash this
      # loop for every OTHER running story: `$((now - dispatched_at))` on a
      # non-numeric value is a bash arithmetic error and, under this file's
      # own `set -euo pipefail`, aborts the whole function. Refuse to trust
      # it instead: log the reason and report the story overdue with an
      # elapsed of 0 (the only honest value when the start time is unknown)
      # so the skill sees `overdue=1` and acts, rather than the loop dying
      # or the story going unreported.
      case "$dispatched_at" in
        ''|*[!0-9]*)
          _ppo_log "event=status_field_refused story=${key} field=dispatched_at reason=missing-or-invalid"
          elapsed=0
          overdue=1
          _ppo_emit "running story=${key} elapsed=${elapsed} budget=${budget} overdue=${overdue}"
          continue
          ;;
      esac
      elapsed=$((now - dispatched_at))
      overdue=0
      [ "$elapsed" -gt "$budget" ] && overdue=1
      _ppo_emit "running story=${key} elapsed=${elapsed} budget=${budget} overdue=${overdue}"
    done
  fi
  ppo_report
  local repo; repo="$(_ppo_engine_get repo)"
  [ -n "$repo" ] && ppo_report_preserved "$repo"
  return 0
}

# ppo_release_reservations — drop every reservation this run still holds.
# Installed on the interrupt paths, where no per-slot cleanup gets to run.
ppo_release_reservations() {
  local reg="${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}/registry" f
  [ -d "$reg" ] || return 0
  for f in "$reg"/.reserved-*; do
    [ -f "$f" ] || continue
    case "$(sed -n 's/^reserved_by://p;q' "$f" 2>/dev/null)" in
      "$$") rm -f "$f" 2>/dev/null || true ;;
    esac
  done
  return 0
}

# ppo_reap_stale_reservations — clear reservations left by a run that died
# before it could release them. A reservation counts toward the ceiling, so one
# orphaned by a kill would silently shrink every later sprint's budget.
ppo_reap_stale_reservations() {
  local reg="${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}/registry" f owner
  [ -d "$reg" ] || return 0
  for f in "$reg"/.reserved-*; do
    [ -f "$f" ] || continue
    owner="$(sed -n 's/^reserved_by://p;q' "$f" 2>/dev/null)"
    # No owner recorded, or the owner is gone: nothing will ever release it.
    if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
  return 0
}

# ---------- Accessors ----------

ppo_peak_concurrency() {
  local v; v="$(_ppo_state_get peak)"
  [ -n "$v" ] || v="$_PPO_PEAK"
  printf '%s' "${v:-0}"
}

# _ppo_mnd_count <story_key> / _ppo_mnd_bump <story_key> — how many times a
# merged-but-not-done story has been re-dispatched on the resume path. Kept in
# the run's state dir so it survives the subshells the reap runs in. Defense
# in depth: every caller today already validates the key upstream (see
# _ppo_validate_key's header inventory), but this builder turns a key into a
# path fragment same as the others, so it re-checks rather than trusting
# caller discipline alone.
_ppo_mnd_count() {
  _ppo_validate_key "${1:-}" || { printf '0'; return 1; }
  local d f
  d="$(_ppo_state_dir)" || return 0
  f="$d/mnd-$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  local n; n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')" || n=0
  printf '%s' "${n:-0}"
}

_ppo_mnd_bump() {
  _ppo_validate_key "${1:-}" || return 1
  local d
  d="$(_ppo_state_dir)" || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  printf 'x\n' >> "$d/mnd-$1" 2>/dev/null || true
}

# _ppo_mnd_open_mark <key> / _ppo_mnd_open_clear <key> — the set of stories
# that are merged-but-not-done RIGHT NOW, i.e. re-queued and not yet terminal.
# A story leaves the set when it reaches done or runs out of retries. Defense
# in depth: every caller today already validates the key upstream (see
# _ppo_validate_key's header inventory), but these builders turn a key into a
# path fragment same as the others, so they re-check rather than trusting
# caller discipline alone.
_ppo_mnd_open_mark() {
  _ppo_validate_key "${1:-}" || return 1
  local d; d="$(_ppo_state_dir)" || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  : > "$d/mndopen-$1" 2>/dev/null || true
}

_ppo_mnd_open_clear() {
  _ppo_validate_key "${1:-}" || return 1
  local d; d="$(_ppo_state_dir)" || return 0
  rm -f "$d/mndopen-$1" 2>/dev/null || true
}

_ppo_mnd_open_count() {
  local d n; d="$(_ppo_state_dir)" || { printf '0'; return 0; }
  n="$(find "$d" -maxdepth 1 -name 'mndopen-*' -type f 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

# The open set as a |-delimited string, so a caller can ask whether a specific
# key is in it without a subshell per entry.
_ppo_mnd_open_keys() {
  local d f out="|"; d="$(_ppo_state_dir)" || { printf '|'; return 0; }
  for f in "$d"/mndopen-*; do
    [ -f "$f" ] || continue
    out="${out}${f##*/mndopen-}|"
  done
  printf '%s' "$out"
}

# ppo_barrier_violations — how many times a story of phase N+1 was dispatched
# while a story of phase N was still non-terminal. Counted from real dispatch
# events, not asserted: a hardcoded zero would make every barrier test pass
# against an orchestrator that has no barrier at all.
ppo_barrier_violations() {
  local v; v="$(_ppo_state_get barrier_violations)"
  [ -n "$v" ] || v="$_PPO_BARRIER_VIOLATIONS"
  printf '%s' "${v:-0}"
}

# ppo_backfill_before_done — how many times a slot was recycled onto a new
# story while the story that vacated it was still non-terminal (merged but not
# done). Incremented by the reap, so a run that backfills an open gate is
# visible instead of being asserted away.
ppo_backfill_before_done() {
  local v; v="$(_ppo_state_get backfill_before_done)"
  [ -n "$v" ] || v="$_PPO_BACKFILL_BEFORE_DONE"
  printf '%s' "${v:-0}"
}

ppo_slot_worktrees() {
  local v; v="$(_ppo_state_get worktrees)"
  [ -n "$v" ] || v="$_PPO_WORKTREES"
  [ -n "$v" ] && printf '%s\n' "$v"
  return 0
}

# ppo_outcome_count <outcome> — how many stories reached that terminal state.
ppo_outcome_count() {
  local want="${1:-}" n=0 all
  all="$(_ppo_state_get outcomes)"
  [ -n "$all" ] || all="$_PPO_OUTCOMES"
  [ -n "$all" ] || { printf '0'; return 0; }
  while IFS='|' read -r _ o; do
    [ "$o" = "$want" ] && n=$((n + 1))
  done <<EOF
$all
EOF
  printf '%s' "$n"
}

# ppo_dev_slot_consumers — dev slots consumed by reviewer dispatches. Always
# zero by construction: the clean-room gate refuses a reviewer persona as a
# teammate outright, so one never enters the registry to consume anything.
ppo_dev_slot_consumers() { printf '0'; }

# ppo_report — per-story outcomes for the sprint review.
ppo_report() {
  local all
  all="$(_ppo_state_get outcomes)"
  [ -n "$all" ] || all="$_PPO_OUTCOMES"
  [ -n "$all" ] || return 0
  printf '%s\n' "$all" | while IFS='|' read -r k o; do
    [ -n "$k" ] && printf 'story=%s outcome=%s\n' "$k" "$o"
  done
}

# ppo_report_preserved <repo> — worktrees deliberately kept, with a recovery
# command that actually works. A kept worktree stays LOCKED, so the bare
# `remove --force` an operator would reach for fails against it.
ppo_report_preserved() {
  local repo="${1:-}" line current=""
  [ -n "$repo" ] || return 0
  git -C "$repo" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        current="${line#worktree }"
        case "$current" in
          *"/.gaia-worktrees/"*)
            if [ -n "$(git -C "$current" status --porcelain 2>/dev/null)" ]; then
              printf 'preserved worktree: %s\n' "$current"
              printf '  recover with: git -C "%s" worktree unlock "%s" && git -C "%s" worktree remove --force "%s"\n' \
                "$repo" "$current" "$repo" "$current"
            fi
            ;;
        esac
        ;;
    esac
  done
  return 0
}

# ---------- Execution ----------

_ppo_record() {
  local key="$1" outcome="$2" phase="${3:-}"
  _PPO_OUTCOMES="${_PPO_OUTCOMES}${_PPO_OUTCOMES:+$'\n'}${key}|${outcome}"
  _ppo_state_append outcomes "${key}|${outcome}"
  _ppo_emit "event=story_complete story=${key} phase=${phase} outcome=${outcome}"
}

# ppo_run_sprint --repo R --yaml Y [--slots N] — `run`: the ONE loop over
# plan/next/record that keeps this file's own test suite (and any other
# single-process caller) driving a single engine, no second scheduler.
#
# Sequential/degraded: unchanged output -- ppo_plan already emits the
# `mode=sequential reason=...` line and the `event=sequential story=...`
# worklist itself, so `run` only needs to stop there, exactly as before.
#
# Parallel: loops ppo_next. Each `dispatch story=K phase=P persona=X
# worktree=W handle=H` line is re-emitted here in the LEGACY shape
# (`event=dispatched story=K phase=P slot=N`) that this suite's tests pin
# by exact string, and is then driven to completion via the gated test-only
# dispatch hook (GAIA_PPO_DISPATCH_CMD, see this file's header) -- this is
# the ONLY place `run` still backgrounds anything, and its own children are
# tracked (ppo/run-pids, and ppo/run-pgids for the process GROUP each
# in-flight `timeout` invocation owns) and terminated from the trap so a
# killed `run` exits promptly instead of waiting on a stalled hook
# invocation, and so that hook's own descendants (e.g. a stub's grandchild
# sleep) do not survive as orphans either (see the header note on
# ppo_shutdown_live_teammates and _ppo_run_kill_children's own comment).
# `barrier`/`sprint_complete` from ppo_next need no translation -- they were
# never part of the legacy vocabulary any test pins.
#
# Without an honoured hook (production, no test marker), there is no
# bash-drivable way to complete a dispatched story -- see the step-engine
# header above -- so `run` performs exactly ONE `ppo_next` call and returns:
# real completion happens through the run-sprint skill's own main-turn loop
# calling next/record directly, never through this compatibility shim.
ppo_run_sprint() {
  local repo="" yaml="" slots=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)  repo="${2:-}";  shift 2 ;;
      --yaml)  yaml="${2:-}";  shift 2 ;;
      --slots) slots="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  ppo_plan --repo "$repo" --yaml "$yaml" ${slots:+--slots "$slots"}

  local mode; mode="$(_ppo_engine_get mode)"
  case "$mode" in
    mode=parallel*) : ;;
    *) return 0 ;;
  esac

  # Teammate shutdown runs BEFORE reservation release: a killed run's live
  # teammates hold real registry entries against the shared ceiling, the
  # same class of leak a reservation is, but on the library's own registry
  # -- both are swept so neither survives an interrupt. `_ppo_run_kill_children`
  # runs FIRST: this run's OWN backgrounded hook-invocation pids
  # (ppo/run-pids) are signalled and waited on with a short bound, so a
  # killed `run` does not hang on a stalled hook invocation.
  # INT/TERM must actually END the run, not just clean up and let the `while
  # :; do ppo_next; ... done` loop below resume where it was interrupted --
  # a bare cleanup-only trap leaves ppo/running/<key> untouched (that is
  # ppo_record_outcome's job, never the teammate-shutdown sweep's), so the
  # loop would keep reporting `barrier ... waiting=N` for the very story
  # whose teammate this trap just tore down, forever. The EXIT trap (natural
  # return, including this exit call re-triggering it) runs the SAME cleanup
  # a second time, which is fine -- shutdown_teammate/release_reservations
  # are idempotent on an already-cleared entry.
  trap '_ppo_run_kill_children; ppo_shutdown_live_teammates; ppo_release_reservations; exit 0' INT TERM
  trap '_ppo_run_kill_children; ppo_shutdown_live_teammates; ppo_release_reservations' EXIT
  : > "$(_ppo_engine_dir)/run-pids" 2>/dev/null || true
  : > "$(_ppo_engine_dir)/run-pgids" 2>/dev/null || true

  # GAIA_PPO_DISPATCH_CMD is an arbitrary-command hook: whatever it names
  # runs with the story key as its only argument. Honoured ONLY under the
  # same test-marker convention the rest of the plugin uses for a test-only
  # escape hatch (BATS_TEST_FILENAME, which bats exports for every test
  # process, or an explicit GAIA_PPO_ALLOW_DISPATCH_CMD=1) -- an unguarded
  # arbitrary-command hook is a remote-code lever, not something a stray
  # inherited environment variable should be able to trigger in production.
  # One log line every time this is decided, whether honoured or refused.
  local honoured=0
  if [ -n "${GAIA_PPO_DISPATCH_CMD:-}" ]; then
    if [ -n "${BATS_TEST_FILENAME:-}" ] || [ "${GAIA_PPO_ALLOW_DISPATCH_CMD:-}" = "1" ]; then
      honoured=1
      _ppo_log "event=dispatch_hook cmd=${GAIA_PPO_DISPATCH_CMD} action=honoured"
    else
      _ppo_log "event=dispatch_hook cmd=${GAIA_PPO_DISPATCH_CMD} action=refused reason=no-test-marker — set GAIA_PPO_ALLOW_DISPATCH_CMD=1 to honour this test-only hook outside bats; dispatching via the real teammate surface instead"
    fi
  fi

  if [ "$honoured" -ne 1 ]; then
    ppo_next
    _ppo_emit "run: no bash-drivable dispatcher in this context — use the plan/next/record verbs from the run-sprint skill loop"
    return 0
  fi

  local budget
  budget="${GAIA_STORY_TIMEOUT_SECONDS:-}"
  if [ -z "$budget" ]; then
    budget="$(ppo_resolve_timeout)"
    budget=$((budget * 60))
  fi

  local slot_seq=0
  _ppo_engine_put ceiling-refusals 0
  while :; do
    # A ceiling that never frees would re-queue forever (see the hook's
    # exit-8 handling below) -- give up once refusals have piled up with no
    # successful admission in between, mirroring the pre-engine reap's
    # ceiling_refusals/_PPO_CEILING_GIVEUP bound exactly. Checked BEFORE the
    # next ppo_next call so a run stuck entirely on ceiling refusals still
    # terminates instead of looping until the test's own timeout kills it.
    local refusals; refusals="$(_ppo_engine_get ceiling-refusals)"
    if [ "${refusals:-0}" -ge "$_PPO_CEILING_GIVEUP" ]; then
      _ppo_engine_put mode "mode=sequential reason=ceiling-cannot-admit — the dispatch ceiling is saturated and no slot can free it; running sequentially"
      _ppo_emit "mode=sequential reason=ceiling-cannot-admit — the dispatch ceiling is saturated and no slot can free it; running sequentially"
      ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r sk; do
        [ -n "$sk" ] && _ppo_emit "event=sequential story=${sk}"
      done
      return 0
    fi

    local out rc=0
    out="$(ppo_next)"; rc=$?
    printf '%s\n' "$out"

    case "$out" in
      *sprint_complete*) return 0 ;;
    esac
    case "$out" in
      mode=sequential*) return 0 ;;
    esac
    [ "$rc" -eq 0 ] || return 0

    # Re-emit each `dispatch` line in the legacy shape and drive it to
    # completion via the hook, all backgrounded so multiple admissions from
    # this SAME ppo_next call genuinely overlap (mirrors the old
    # background-and-reap concurrency shape). A here-string, NOT a pipe: a
    # pipe forks a subshell for the loop body, which would silently drop
    # every update this loop makes to slot_seq the moment the pipe closes.
    while IFS= read -r line; do
      case "$line" in
        dispatch\ story=*)
          local key phase_val
          key="$(printf '%s\n' "$line" | sed -n 's/^dispatch story=\([^ ]*\).*/\1/p')"
          phase_val="$(printf '%s\n' "$line" | sed -n 's/.*phase=\([^ ]*\).*/\1/p')"
          [ -n "$key" ] || continue
          slot_seq=$((slot_seq + 1))
          _ppo_emit "event=dispatched story=${key} phase=${phase_val} slot=${slot_seq}"
          (
            local hrc=0 tpid=""
            # `timeout` (GNU coreutils, the only implementation this file
            # assumes -- see the header) puts ITSELF in a new process group
            # by default (its own --foreground flag documents the opposite:
            # "children of COMMAND will not be timed out" when foreground
            # mode is requested) precisely so it can deliver its own timeout
            # signal to everything it started, including grandchildren a
            # dispatch hook or stub forks (e.g. this suite's stall:<key>
            # fixture, which sleeps under a `bash -c` the hook itself
            # spawns). That means `timeout`'s own pid IS the pgid of that
            # group -- backgrounding `timeout` here (instead of running it
            # in the foreground of this already-backgrounded subshell) is
            # what makes that pid observable to record into run-pgids,
            # below, so a killed `run` can reach the whole group the SAME
            # way `timeout`'s own internal expiry already does, rather than
            # only the wrapper subshell one level up (which `timeout`
            # deliberately does not share a group with).
            timeout "$budget" "$GAIA_PPO_DISPATCH_CMD" "$key" >/dev/null 2>&1 &
            tpid=$!
            echo "$tpid" >> "$(_ppo_engine_dir)/run-pgids"
            wait "$tpid" || hrc=$?
            # Reaped on its own (the common case): drop it from run-pgids so
            # a long run does not accumulate one stale, already-dead entry
            # per dispatch, and so _ppo_run_kill_children's cleanup sweep
            # never sends a signal to a pgid number the kernel may since
            # have reused for an unrelated process.
            if [ -f "$(_ppo_engine_dir)/run-pgids" ]; then
              grep -v -x "$tpid" "$(_ppo_engine_dir)/run-pgids" > "$(_ppo_engine_dir)/run-pgids.tmp" 2>/dev/null || :
              mv "$(_ppo_engine_dir)/run-pgids.tmp" "$(_ppo_engine_dir)/run-pgids" 2>/dev/null || true
            fi
            [ "$hrc" -eq 124 ] && hrc=9
            case "$hrc" in
              0) ppo_record_outcome "$key" "done"; _ppo_engine_put ceiling-refusals 0 ;;
              9) ppo_record_outcome "$key" "timeout"; _ppo_engine_put ceiling-refusals 0 ;;
              11)
                # The legacy hook's own exit-11 IS the merged-not-done
                # signal within this gated test-only context -- there is no
                # real git/PR state in a stub-driven test for
                # sprint-progress-audit.sh to inspect, so this calls the
                # internal-only resume/give-up transition DIRECTLY rather
                # than asking an audit that has nothing to audit, and
                # rather than routing through ppo_record_outcome's
                # CLI-reachable outcome vocabulary -- `merged-not-done` is
                # not a value that vocabulary accepts (see
                # _ppo_record_outcome_locked), precisely so a CLI caller can
                # never bypass the audit the same way this gated hook does.
                # The real run-sprint skill loop calls `record ... merged`
                # instead, and the audit decides.
                _ppo_record_outcome_internal_mnd "$key"
                _ppo_engine_put ceiling-refusals 0
                ;;
              8)
                # Capacity, never a story outcome -- see the legacy hook
                # contract's ceiling:<n> stub mode. The admission this
                # story's own `next` already claimed is released and its key
                # goes back to the front of pending, exactly like the
                # pre-engine reap's exit-8 re-queue; ppo_record_outcome is
                # NOT called, so the ledger never sees this as a completion.
                # Counted toward the giveup bound the run loop checks above --
                # a ceiling that DOES free resets it on the next real success.
                _ppo_requeue "$key"
                local _cr; _cr="$(_ppo_engine_get ceiling-refusals)"
                _ppo_engine_put ceiling-refusals $(( ${_cr:-0} + 1 ))
                ;;
              7)
                # Substrate fallback -- a run-wide condition, not this
                # story's outcome. Releases the admission and marks the
                # whole run degraded so the next ppo_next call (and `run`'s
                # own loop) surfaces mode=sequential exactly as the
                # pre-engine inline reap did.
                _ppo_requeue "$key"
                _ppo_engine_lock_run _ppo_engine_put mode "mode=sequential reason=mode-b-fallback — the agent substrate is unavailable; running sequentially in phase order"
                ;;
              *) ppo_record_outcome "$key" "failed"; _ppo_engine_put ceiling-refusals 0 ;;
            esac
          ) &
          echo "$!" >> "$(_ppo_engine_dir)/run-pids"
          ;;
      esac
    done <<<"$out"

    # Drain: wait for at least one background hook invocation from THIS
    # round to finish before asking ppo_next again, so the loop does not
    # spin faster than real work completes.
    if [ -f "$(_ppo_engine_dir)/run-pids" ] && [ -s "$(_ppo_engine_dir)/run-pids" ]; then
      while :; do
        local still=0 pid
        while IFS= read -r pid; do
          [ -n "$pid" ] || continue
          kill -0 "$pid" 2>/dev/null && still=$((still + 1))
        done < "$(_ppo_engine_dir)/run-pids"
        [ "$still" -lt "$(wc -l < "$(_ppo_engine_dir)/run-pids" 2>/dev/null | tr -d ' ')" ] && break
        [ "$still" -eq 0 ] && break
        sleep 0.2
      done
    fi
  done
}

# _ppo_run_kill_children — terminate every background hook invocation THIS
# `run` call spawned (ppo/run-pids), with a short bound, before the trap
# moves on to teammate/reservation cleanup. `run`+hook is the only place in
# the redesigned engine that still backgrounds anything (ppo_next/
# ppo_record_outcome never do) -- so this is the only place left that can
# leave an orphan behind a killed parent, and it is scoped to exactly the
# pids this run itself started.
#
# run-pids holds the wrapper subshell's own pid per dispatch -- killing that
# alone is NOT enough: `timeout` (see the comment where run-pgids is
# populated, above) puts itself in its own new process group, so a signal to
# the subshell never reaches `timeout` or anything `timeout`'s command goes
# on to fork (e.g. a stub's own `bash -c 'sleep 3600'`). run-pgids holds
# `timeout`'s own pid for each in-flight dispatch, which IS the pgid of that
# group -- `kill -TERM -- "-<pid>"` (the negative form) signals the whole
# group in one call, on both macOS and Linux, with no dependency on a
# setsid(1) command-line tool (util-linux only, absent on macOS) or on the
# stub controlling its own signal handling. This is swept BEFORE run-pids so
# a stalled hook's grandchild dies before this function starts waiting on the
# wrapper subshell it is nested under.
_ppo_run_kill_children() {
  local f pid
  f="$(_ppo_engine_dir)/run-pgids"
  if [ -f "$f" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    done < "$f"
    local pg_waited=0
    while :; do
      local pg_still=0
      while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && pg_still=$((pg_still + 1))
      done < "$f"
      [ "$pg_still" -eq 0 ] && break
      pg_waited=$((pg_waited + 1))
      [ "$pg_waited" -ge 20 ] && break
      sleep 0.1
    done
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    done < "$f"
  fi

  f="$(_ppo_engine_dir)/run-pids"
  [ -f "$f" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done < "$f"
  local waited=0
  while :; do
    local still=0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -0 "$pid" 2>/dev/null && still=$((still + 1))
    done < "$f"
    [ "$still" -eq 0 ] && break
    waited=$((waited + 1))
    [ "$waited" -ge 20 ] && break
    sleep 0.1
  done
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done < "$f"
  return 0
}

# ---------- CLI ----------
#
# Verb dispatch for the step engine (see the header for the full contract):
#   plan --repo R --yaml Y [--slots N]   preflight + queue init
#   next                                  admit up to the slot budget
#   record <key> <done|failed|timeout|merged>
#                                          report a real turn's outcome
#   status                                 running stories + ledger
#   report                                 the outcome ledger alone
#   (no verb, or --repo/--yaml/--slots directly)
#                                          `run`: the one-process compat loop
#                                          (ppo_run_sprint), unchanged for any
#                                          existing caller that never adopted
#                                          the verb form.
_ppo_cli() {
  case "${1:-}" in
    plan)
      shift
      ppo_plan "$@"
      ;;
    next)
      shift
      ppo_next "$@"
      ;;
    record)
      shift
      ppo_record_outcome "$@"
      ;;
    status)
      shift
      ppo_status "$@"
      ;;
    report)
      shift
      ppo_report "$@"
      ;;
    *)
      ppo_run_sprint "$@"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _ppo_cli "$@"
fi
