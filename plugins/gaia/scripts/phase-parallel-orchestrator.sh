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
#   ceiling-cannot-admit  the dispatch ceiling is saturated and cannot free
#   mode-b-fallback       the agent substrate is unavailable
#   admission-error       an unclassified admission failure
#
# A run NEVER exits non-zero because parallel execution was unavailable: it
# says why and proceeds sequentially, because a sprint that does not run is a
# worse outcome than a sprint that runs slowly.

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

# ---------- Defaults ----------

_PPO_DEFAULT_SLOTS=8
_PPO_DEFAULT_TIMEOUT_MINUTES=90
_PPO_DEFAULT_CEILING=12
_PPO_SLOTS_MAX=64

# How many consecutive ceiling refusals, with nothing running to free a slot,
# before the run stops re-queueing and degrades instead.
_PPO_CEILING_GIVEUP=3

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

# ---------- Dependencies ----------

_ppo_lib() {
  local name="$1"
  [ -f "$_PPO_DIR/lib/$name" ] || return 1
  # shellcheck disable=SC1090
  . "$_PPO_DIR/lib/$name"
}

_ppo_load_worktree_lib() { _ppo_lib story-worktree.sh; }
_ppo_load_lock_lib()     { _ppo_lib acquire-lock.sh; }

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
# is worse than leaving one small directory per story.
ppo_slot_scratch_for() {
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
    awk '/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k=$0; sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/,"",k)
      gsub(/^["'"'"']|["'"'"']$/,"",k); print k }' "$yaml" 2>/dev/null
    return 0
  fi
  printf '%s\n' "$phases" | while IFS='|' read -r k _; do
    [ -n "$k" ] && printf '%s\n' "$k"
  done
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

  _ppo_emit "mode=parallel reason=none"
  return 0
}

# ---------- Dispatch ----------

# ppo_dispatch_slot <story_key> — one admission attempt.
#
# Returns the dispatcher's own status: 0 handle, 7 substrate fallback, 8
# ceiling saturated, anything else unclassified. Exit 8 is a NORMAL outcome,
# so the capture is guarded: an unguarded assignment under errexit dies before
# the caller ever reads the status. The bridge's idiom is used rather than a
# bare `|| rc=$?` because this file is sourceable, and in a sourced file the
# shell options belong to the CALLER -- flipping errexit underneath one that
# deliberately ran `set +e` to branch on the fallback code is a real bug.
ppo_dispatch_slot() {
  local key="${1:-}" rc=0 out="" errexit_was_set=0
  [ -n "$key" ] || return 1

  # The budget is applied HERE, around the dispatch itself: a story that never
  # returns must not hold its slot indefinitely. Exit 124 (the conventional
  # timeout status) is mapped to a distinct internal code so the caller can tell
  # "ran out of wall clock" from "failed".
  local budget
  budget="${GAIA_STORY_TIMEOUT_SECONDS:-}"
  if [ -z "$budget" ]; then
    budget="$(ppo_resolve_timeout)"
    budget=$((budget * 60))
  fi

  case "$-" in *e*) errexit_was_set=1 ;; esac
  set +e
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout "$budget" gaia-dispatch-story "$key" 2>/dev/null)"
    rc=$?
  else
    # No timeout(1): run it in the background and reap it ourselves, so the
    # budget holds on a host without GNU coreutils too.
    local tmp_out pid waited
    tmp_out="$(mktemp "${TMPDIR:-/tmp}/ppo-dispatch.XXXXXX")"
    gaia-dispatch-story "$key" >"$tmp_out" 2>/dev/null &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge "$budget" ]; then
        kill -TERM "$pid" 2>/dev/null
        sleep 1
        kill -KILL "$pid" 2>/dev/null
        rc=124
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
    if [ "${rc:-0}" -ne 124 ]; then
      wait "$pid" 2>/dev/null
      rc=$?
    fi
    out="$(cat "$tmp_out" 2>/dev/null)"
    rm -f "$tmp_out" 2>/dev/null || true
  fi
  [ "$errexit_was_set" -eq 1 ] && set -e

  # 124 is timeout(1)'s own status; normalise it to the internal timeout code.
  [ "$rc" -eq 124 ] && rc=9

  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

# ppo_admit_slot <story_key> — dispatch one story under the admission lock.
#
# The library's own ceiling check is an unlocked read-then-register, so two
# concurrent admissions can both pass a nearly-full ceiling. Serialising
# admission here closes that from the caller side; the stories still RUN
# concurrently, only the moment of admission is ordered.
ppo_admit_slot() {
  local key="${1:-}"
  [ -n "$key" ] || return 1

  # A key that could escape the worktree parent or break a path is refused
  # before it reaches any filesystem operation.
  case "$key" in
    *[!A-Za-z0-9._-]*|*..*|'') return 1 ;;
  esac

  local rc=0 locked=0

  # Claim a CEILING TOKEN under the lock, then run the story outside it.
  #
  # The dispatch library counts registry files and then registers, which is a
  # check-then-act: concurrent admissions can all read the same count and all
  # proceed past a nearly-full ceiling. Closing that needs a lock spanning the
  # count and the claim -- but the library's own window sits inside the spawn,
  # which this caller reaches only by running the story, and holding the lock
  # across a whole story would serialise the sprint (every slot backgrounded,
  # every one queued on the lock).
  #
  # So the count-and-claim happens HERE, under the lock, against the same
  # registry the library counts: read the count and, if there is room, plant a
  # token that makes this admission visible to every other admission before the
  # lock is released. A token is a RESERVATION, not a teammate record: the
  # library's registration consumes it, so a story never holds two ceiling
  # slots, and it is cleared on every exit path.
  #
  # Acquiring and releasing around nothing would be worse than no lock at all --
  # it would look like mutual exclusion while excluding nothing.
  local token="" reg="" ceiling=0 count=0
  if _ppo_load_lock_lib 2>/dev/null && command -v acquire_lock >/dev/null 2>&1; then
    if acquire_lock "${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}/.ppo-admit.lock" 10 8 2>/dev/null; then
      locked=1
    fi
  fi

  reg="${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}/registry"
  mkdir -p "$reg" 2>/dev/null || true
  ceiling="$(ppo_resolve_ceiling)"
  count="$(find "$reg" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  # Test-only widening of the count-then-claim window. The window is a few
  # syscalls wide in production, which is real but hard to hit deterministically;
  # a test that cannot reach it cannot prove the lock is doing anything.
  [ -n "${GAIA_PPO_CLAIM_DELAY:-}" ] && sleep "$GAIA_PPO_CLAIM_DELAY"
  if [ "${count:-0}" -lt "${ceiling:-0}" ]; then
    token="${reg}/.reserved-${key}"
    # Stamp the owning pid so a reservation orphaned by a killed run can be
    # told from a live one and reaped at the next start.
    printf 'reserved_by:%s\n' "$$" > "$token" 2>/dev/null || token=""
    [ -n "$token" ] && _ppo_state_append reservations "$token"
  fi

  [ "$locked" -eq 1 ] && { release_lock 8 2>/dev/null || true; }

  # No room: a capacity condition, reported with the library's own code so the
  # caller queues the story rather than failing it.
  if [ -z "$token" ]; then
    return 8
  fi

  # The reservation is released on EVERY path out of here. On a successful
  # registration the library has already renamed it, so this removes nothing;
  # on any other outcome -- spawn refusal, a saturated ceiling, a failed or
  # stalled story -- it must not be left holding a ceiling slot.
  ppo_dispatch_slot "$key" || rc=$?
  rm -f "$token" 2>/dev/null || true
  return "$rc"
}

# ppo_release_reservations — drop every reservation this run still holds.
# Installed on the interrupt paths, where no per-slot cleanup gets to run.
ppo_release_reservations() {
  local reg="${GAIA_SESSION_DIR:-${TMPDIR:-/tmp}}/registry" f
  [ -d "$reg" ] || return 0
  for f in "$reg"/.reserved-*; do
    [ -f "$f" ] || continue
    case "$(sed -n 's/^reserved_by://p' "$f" 2>/dev/null | head -1)" in
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
    owner="$(sed -n 's/^reserved_by://p' "$f" 2>/dev/null | head -1)"
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

ppo_barrier_violations() {
  local v; v="$(_ppo_state_get barrier_violations)"
  [ -n "$v" ] || v="$_PPO_BARRIER_VIOLATIONS"
  printf '%s' "${v:-0}"
}

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

# ppo_run_sprint --repo R --yaml Y [--slots N] — the whole run.
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

  _PPO_OUTCOMES=""; _PPO_WORKTREES=""; _PPO_PEAK=0; _PPO_SEEN="|"
  _PPO_BARRIER_VIOLATIONS=0; _PPO_BACKFILL_BEFORE_DONE=0
  _ppo_state_reset
  _ppo_state_put peak 0
  _ppo_state_put barrier_violations 0
  _ppo_state_put backfill_before_done 0

  [ -n "$slots" ] || slots="$(ppo_resolve_slots)"

  local verdict
  verdict="$(ppo_preflight --repo "$repo" --yaml "$yaml" --slots "$slots")"
  _ppo_emit "$verdict"

  case "$verdict" in
    mode=parallel*) : ;;
    *)
      ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r k; do
        [ -n "$k" ] && _ppo_emit "event=sequential story=${k}"
      done
      return 0
      ;;
  esac

  _ppo_load_worktree_lib || return 0
  # Reap whatever a previously killed run left behind, before anything is
  # created, so a story whose branch survives can attach cleanly.
  worktree_prune_stale "$repo" >/dev/null 2>&1 || true

  # A reservation orphaned by a killed run counts toward the ceiling forever,
  # so it is cleared before this run starts claiming any of its own.
  ppo_reap_stale_reservations
  trap 'ppo_release_reservations' INT TERM EXIT

  local phases
  phases="$(ppo_read_phases "$yaml")" || return 0

  local all_phases p
  all_phases="$(printf '%s\n' "$phases" | awk -F'|' '{print $2}' | sort -n -u)"

  for p in $all_phases; do
    local pending running_keys running_pids n_running ceiling_refusals=0
    pending="$(printf '%s\n' "$phases" | awk -F'|' -v ph="$p" '$2 == ph {print $1}')"
    if [ -z "$pending" ]; then
      _ppo_emit "event=phase_skipped phase=${p} reason=no-stories"
      continue
    fi
    _ppo_emit "event=phase_start phase=${p}"

    running_keys=""; running_pids=""; n_running=0

    # The phase ends only when the queue is empty AND no slot is still running.
    #
    # Both terms are load-bearing. Dropping `n_running` releases the phase the
    # moment the queue drains, while backgrounded slots are still running --
    # every outcome they would have reported is lost, along with the teardown
    # and the barrier. Dropping the reap's own drain condition instead leaves a
    # phase that never finishes.
    while [ -n "$pending" ] || [ "$n_running" -gt 0 ]; do
      # Fill free slots from the head of this phase's queue, in roster order.
      while [ -n "$pending" ] && [ "$n_running" -lt "$slots" ]; do
        local key rest rc=0
        key="${pending%%$'\n'*}"
        if [ "$key" = "$pending" ]; then rest=""; else rest="${pending#*$'\n'}"; fi
        [ -n "$key" ] || { pending="$rest"; continue; }

        # Already live from a previous run? Attach, do not dispatch twice.
        # Re-entry: a worktree already checked out for this story belongs to a
        # PREVIOUS run, so the story is attached rather than started twice.
        # A story this run re-queued has its own worktree checked out too, and
        # treating that as a previous run would silently mark it done without
        # ever dispatching it -- so only stories not yet seen take this path.
        local bstate
        case "$_PPO_SEEN" in
          *"|${key}|"*) bstate="absent" ;;
          *) bstate="$(worktree_branch_state "$repo" "feat/${key}-slug" 2>/dev/null || printf 'absent')" ;;
        esac
        _PPO_SEEN="${_PPO_SEEN}${key}|"
        case "$bstate" in
          checked-out:*)
            _ppo_emit "event=attached story=${key} phase=${p}"
            _ppo_record "$key" "done" "$p"
            pending="$rest"
            continue
            ;;
        esac

        # The slot's scratch dir must exist BEFORE anything is written into it.
        mkdir -p "$(ppo_slot_scratch_for "$key")" 2>/dev/null || true

        local wt=""
        wt="$(worktree_create "$repo" "$key" "slug" 2>/dev/null)" || wt=""
        if [ -n "$wt" ]; then
          _PPO_WORKTREES="${_PPO_WORKTREES}${_PPO_WORKTREES:+$'\n'}${wt}"
          _ppo_state_append worktrees "$wt"
          # Remember which worktree belongs to which story so the reap below
          # can tear down exactly that one.
          printf '%s' "$wt" > "$(ppo_slot_scratch_for "$key")/worktree" 2>/dev/null || true
        fi

        # Admission is serialised (the ceiling count is an unlocked
        # read-then-register), but the story's RUN is backgrounded so slots
        # genuinely overlap. Running it inline would make the slot budget a
        # queue depth rather than concurrency.
        #
        # Because the work is backgrounded, its status is NOT available here --
        # it is collected by the reap below, which is the single place every
        # dispatch outcome (handle, fallback, ceiling, timeout, failure) is
        # classified. Branching on a status at this point would be branching on
        # the shell's "started successfully", which is always 0.
        ppo_admit_slot "$key" >/dev/null 2>&1 &
        local slot_pid=$!

        running_keys="${running_keys}${running_keys:+$'\n'}${key}"
        running_pids="${running_pids}${running_pids:+$'\n'}${slot_pid}"
        n_running=$((n_running + 1))
        if [ "$n_running" -gt "$_PPO_PEAK" ]; then
          _PPO_PEAK="$n_running"
          _ppo_state_put peak "$_PPO_PEAK"
        fi
        _ppo_emit "event=dispatched story=${key} phase=${p} slot=${n_running}"
        pending="$rest"
      done

      # Drain one completion. Terminal means done OR failed: the barrier waits
      # for every story of the phase to finish either way, so one failure never
      # aborts its siblings and never lets the next phase start early.
      if [ "$n_running" -gt 0 ] && { [ -z "$pending" ] || [ "$n_running" -ge "$slots" ]; }; then
        # Reap whichever slot finished FIRST. Waiting on the oldest pid is
        # head-of-line blocking: a fast story that finished seconds ago could
        # not free its slot until a slow sibling ahead of it completed, so the
        # budget would be honoured while the throughput it exists for was not.
        # `wait -n` would express this directly but needs Bash 4.3, and the
        # floor here is 3.2, so the completed slot is found by polling.
        local finished="" fpid="" wrc=0 idx=0 found=-1
        local _k _p keys_arr pids_arr
        while :; do
          idx=0; found=-1
          for _p in $running_pids; do
            kill -0 "$_p" 2>/dev/null || { found="$idx"; fpid="$_p"; break; }
            idx=$((idx + 1))
          done
          [ "$found" -ge 0 ] && break
          sleep 0.2
        done

        idx=0; keys_arr=""; pids_arr=""
        for _k in $running_keys; do
          if [ "$idx" -eq "$found" ]; then
            finished="$_k"
          else
            keys_arr="${keys_arr}${keys_arr:+$'\n'}${_k}"
          fi
          idx=$((idx + 1))
        done
        idx=0
        for _p in $running_pids; do
          [ "$idx" -ne "$found" ] && pids_arr="${pids_arr}${pids_arr:+$'\n'}${_p}"
          idx=$((idx + 1))
        done
        running_keys="$keys_arr"; running_pids="$pids_arr"

        wait "$fpid" 2>/dev/null || wrc=$?
        n_running=$((n_running - 1))

        case "$wrc" in
          0)
            ceiling_refusals=0
            # The story merged, so its worktree is finished with. This is the
            # ONE call site allowed to discard ignored-only leftovers: the work
            # is provably merged here, which is what makes forcing safe. Every
            # other path (failure, timeout, interrupt) preserves instead.
            local fwt=""
            fwt="$(cat "$(ppo_slot_scratch_for "$finished")/worktree" 2>/dev/null || true)"
            if [ -n "$fwt" ]; then
              worktree_teardown "$repo" "$fwt" --discard-ignored >/dev/null 2>&1 || true
            fi
            _ppo_record "$finished" "done" "$p"
            ;;
          9)
            _ppo_emit "event=story_timeout story=${finished} phase=${p} outcome=slot-timeout"
            _ppo_record "$finished" "slot-timeout" "$p"
            ;;
          7)
            _ppo_emit "mode=sequential reason=mode-b-fallback — the agent substrate is unavailable; running sequentially in phase order"
            ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r sk; do
              [ -n "$sk" ] && _ppo_emit "event=sequential story=${sk}"
            done
            return 0
            ;;
          8)
            # Re-queue: a capacity condition is never a story outcome. But a
            # ceiling that never frees would re-queue forever, so count the
            # consecutive refusals and degrade once no slot can possibly free
            # one (nothing else is running to release capacity).
            pending="${finished}${pending:+$'\n'}${pending}"
            ceiling_refusals=$((ceiling_refusals + 1))
            # Give up once refusals have piled up with no successful admission
            # in between. Waiting for n_running to reach zero would never fire
            # when the remaining slots are themselves being refused, and the
            # phase would re-queue forever instead of degrading -- the hang this
            # bound exists to prevent. The counter resets on any success, so a
            # ceiling that DOES free up is retried rather than abandoned.
            if [ "$ceiling_refusals" -ge "$_PPO_CEILING_GIVEUP" ]; then
              _ppo_emit "mode=sequential reason=ceiling-cannot-admit — the dispatch ceiling is saturated and no slot can free it; running sequentially"
              ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r sk; do
                [ -n "$sk" ] && _ppo_emit "event=sequential story=${sk}"
              done
              return 0
            fi
            ;;
          1) _ppo_record "$finished" "failed" "$p" ;;
          *)
            _ppo_emit "mode=sequential reason=admission-error — an unclassified dispatch status (${wrc}); running sequentially"
            ppo_plan_sequential --repo "$repo" --yaml "$yaml" | while IFS= read -r sk; do
              [ -n "$sk" ] && _ppo_emit "event=sequential story=${sk}"
            done
            return 0
            ;;
        esac
      fi
    done

    _ppo_emit "event=phase_complete phase=${p}"
  done

  ppo_report_preserved "$repo"
  return 0
}

# ---------- CLI ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ppo_run_sprint "$@"
fi
