#!/usr/bin/env bash
# phase-derivation.sh — execution-phase partition over a candidate story set.
#
# DELIBERATE FORK of the dependency-depth traversal in sm-capacity-check.sh.
# Same input contract, same memoised recurrence, same "a dependency outside
# the candidate set contributes nothing" rule. Two deliberate divergences:
#
#   (1) OUTPUT: the capacity check reduces the whole graph to one scalar (the
#       longest serial chain). This helper keeps the per-story value and emits
#       the partition, so the caller can group stories that may run
#       concurrently.
#   (2) CYCLES: the capacity check breaks a cycle defensively and still
#       reports a number, because a capacity advisory must never halt
#       planning. A phase partition is undefined on a cyclic graph, so a
#       cycle here is a HARD ERROR naming every member.
#
# The capacity check is NOT refactored to share this code: its cycle
# behaviour is load-bearing for its own contract, and a shared traversal
# would force one of the two callers to carry a behaviour flag through a
# hot path. The two are kept separate on purpose.
#
# --stories-file format: one story per line, `KEY|DEP1,DEP2,...|POINTS`
#   (deps and points may be empty; deps are comma-separated story keys).
#   Points are read and ignored — the format is shared with the capacity
#   check so a caller materialises the candidate set exactly once. The dep
#   column carries HARD dependencies only, already normalised by the caller.
#
# Output (stdout): one `KEY|PHASE` line per input story, ascending by phase
#   then by first-appearance order within a phase. A cycle produces NO
#   partition output at all — a partition is undefined on a cyclic graph,
#   so emitting a partial one would be worse than emitting none.
#
# Exit codes:
#   0 — partition computed (including the empty-input case)
#   1 — bad arguments
#   2 — dependency cycle; stderr names every member in traversal order,
#       closing back to the re-entered node

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="phase-derivation.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
phase-derivation.sh — execution-phase partition over a candidate story set

Usage:
  phase-derivation.sh --stories-file <file>

Partitions the candidate set into execution phases: phase 1 is every story
with no hard dependency inside the set; a story whose hard dependencies all
sit in phases <= N lands in phase N+1. A dependency outside the candidate
set is treated as already satisfied. Stories sharing a phase carry no
ordering constraint between them.

--stories-file lines: KEY|DEP1,DEP2,...|POINTS  (hard deps only)
Output: one KEY|PHASE line per story. A dependency cycle is a hard error.
USAGE
  exit 0
fi

STORIES_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stories-file) STORIES_FILE="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$STORIES_FILE" ] || die "--stories-file is required (try --help)"
[ -r "$STORIES_FILE" ] || die "stories file not found/readable: $STORIES_FILE"

# Forked from sm-capacity-check.sh's DEPTH_AWK. The ingest block and the
# recurrence are carried over; the cycle branch and the emit are the fork.
PHASE_AWK='
  BEGIN { FS="|"; n=0; cycle=0 }
  {
    key=$1
    gsub(/^[ \t]+|[ \t]+$/, "", key)
    if (key=="") next
    if (!(key in keys)) { keys[key]=1; order[++n]=key }
    deps[key]=$2   # comma-separated dependency keys
  }
  END {
    # Traversal is driven from first-appearance order, not `for (k in keys)`:
    # awk hash order would otherwise decide which node enters a cycle, making
    # the diagnostic vary by awk flavour.
    for (i=1; i<=n && !cycle; i++) phase(order[i])

    # A cycle invalidates the WHOLE partition, including any clean component
    # that memoised legitimately before the cycle was reached. The emit loop
    # below is the SINGLE point where output is decided: it is never guarded,
    # so `emit` is the only thing that can suppress a line. Adding a second
    # guard around the loop would make this one untestable.
    emit = 1
    if (cycle) {
      emit = 0
      # A cycle member holding a phase is impossible when the traversal
      # abandons the computation correctly, so it is reported rather than
      # silently swallowed.
      poisoned = 0
      cn = split(cyc, cm, " -> ")
      for (ci=1; ci<=cn; ci++) if (cm[ci] in memo) poisoned++
      if (poisoned > 0)
        printf "internal error: %d cycle member(s) recorded a phase\n", poisoned > "/dev/stderr"
    }

    if (emit)
      for (p=1; p<=maxp; p++)
        for (i=1; i<=n; i++)
          if (memo[order[i]]==p) print order[i] "|" p

    if (cycle) { printf "cycle detected: %s\n", cyc > "/dev/stderr"; exit 2 }
  }
  function phase(k,   i,arr,best,dd,j,hit,m) {
    # A dependency outside the candidate set contributes nothing: it is
    # already satisfied (closed in an earlier sprint, or not selected).
    if (k=="" || !(k in keys)) return 0
    if (k in memo) return memo[k]
    if (k in onstack) {
      # Fork point: the capacity check returns a partial depth here. A phase
      # partition cannot absorb a cycle, so capture every member and abort.
      cycle=1; cyc=""; hit=0
      for (j=1; j<=sp; j++) {
        if (stk[j]==k) hit=1
        if (hit) cyc = cyc (cyc==""?"":" -> ") stk[j]
      }
      cyc = cyc " -> " k
      return 0
    }
    onstack[k]=1; stk[++sp]=k
    best=0
    m=split(deps[k], arr, ",")
    for (i=1;i<=m;i++) {
      gsub(/^[ \t]+|[ \t]+$/, "", arr[i])
      if (arr[i]=="") continue
      dd=phase(arr[i])
      # Abandon the computation outright: a sentinel must never flow into the
      # memo table, or a cyclic graph would ship fabricated phases.
      if (cycle) { delete onstack[k]; sp--; return 0 }
      if (dd>best) best=dd
    }
    delete onstack[k]; sp--
    memo[k]=best+1
    if (memo[k]>maxp) maxp=memo[k]
    return memo[k]
  }
'

# Capture stderr separately so the awk exit code can be shaped into a
# deliberate exit rather than an errexit accident. The temp file lives in
# TMPDIR, never beside the (possibly read-only) input.
ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/phase-derivation.XXXXXX")"
trap 'rm -f "$ERR_FILE"' EXIT INT TERM

set +e
PARTITION="$(awk "$PHASE_AWK" "$STORIES_FILE" 2>"$ERR_FILE")"
rc=$?
set -e

if [ -s "$ERR_FILE" ]; then
  cat "$ERR_FILE" >&2
fi

# Emit whatever the traversal produced, then propagate its status. The awk
# program is the SINGLE point of truth for what a cyclic graph emits: it
# clears the partition itself, so there is deliberately no second
# suppression here. A guard at this layer would mask a regression in that
# one, leaving the real invariant untested.
[ -z "$PARTITION" ] || printf '%s\n' "$PARTITION"
exit "$rc"
