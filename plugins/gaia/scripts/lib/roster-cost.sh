#!/usr/bin/env bash
# roster-cost.sh — roster-cost (spawn-latency) measurement for persistent-
# teammate dispatch.
#
# Measures the wall-clock cost of a single spawn_teammate call across N
# iterations and reports the P95 in milliseconds, alongside a documented
# threshold and a pass/fail verdict.
#
# SUBSTRATE-HONEST: live persistent-teammate spawns are not exercisable in
# this environment. With the substrate unavailable, spawn_teammate degrades
# to the foreground fallback path, so what is measured here is the FALLBACK
# bookkeeping cost — registry write, handle generation, provenance append,
# and the fallback-token emission. This is the floor cost the dispatcher
# always pays; live teammate startup would add substrate latency on top. The
# report and this script label the number as the fallback-path measurement.
#
# Threshold rationale: the fallback bookkeeping is a handful of file writes
# and process forks. A generous P95 ceiling of 250 ms absorbs CI runner jitter
# while still catching a real regression (e.g. an accidental per-spawn sleep
# or an unbounded loop).
#
# Usage:
#   roster-cost.sh [--iterations N] [--threshold-ms MS]
#
# Output (one key=value pair per line):
#   iterations=<N>
#   p95_ms=<int>
#   mean_ms=<int>
#   threshold_ms=<int>
#   verdict=pass|fail
#   measurement=fallback-path
#
# Exit codes:
#   0 — measurement completed (verdict may be pass or fail; read verdict=)
#   2 — usage error
#
# bash 3.2-safe: no mapfile, no ${var,,}.

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DT_LIB="$SCRIPT_DIR/dispatch-teammate.sh"

ITERATIONS=30
THRESHOLD_MS=250

while [ $# -gt 0 ]; do
  case "$1" in
    --iterations)    ITERATIONS="${2:-}"; shift 2 ;;
    --iterations=*)  ITERATIONS="${1#--iterations=}"; shift ;;
    --threshold-ms)  THRESHOLD_MS="${2:-}"; shift 2 ;;
    --threshold-ms=*) THRESHOLD_MS="${1#--threshold-ms=}"; shift ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      printf 'roster-cost.sh: unknown flag: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$ITERATIONS" in
  ''|*[!0-9]*) printf 'roster-cost.sh: --iterations must be a positive integer\n' >&2; exit 2 ;;
esac
[ "$ITERATIONS" -ge 1 ] || { printf 'roster-cost.sh: --iterations must be >= 1\n' >&2; exit 2; }

# Force the fallback path — this script never claims to measure live spawns.
export GAIA_MODE_B_SUBSTRATE=unavailable

# Isolated session dir so the measurement leaves no residue and never collides
# with a real session.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gaia-roster-cost.XXXXXX")"
trap 'rm -rf "$WORK_DIR" 2>/dev/null || true' EXIT INT TERM

export GAIA_SESSION_DIR="$WORK_DIR/session"
export GAIA_PROVENANCE_LOG="$WORK_DIR/session/provenance.log"
export GAIA_SESSION_TRANSCRIPT="$WORK_DIR/session/transcript.md"
mkdir -p "$GAIA_SESSION_DIR"

# shellcheck source=lib/dispatch-teammate.sh disable=SC1091
. "$DT_LIB"

# _now_ms — current time in integer milliseconds.
# Prefer EPOCHREALTIME (bash 5+); fall back to a portable date-based reading
# that works on bash 3.2 / BSD date (second resolution).
_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    # EPOCHREALTIME is like 1700000000.123456 — strip the dot, keep ms.
    local raw="${EPOCHREALTIME}"
    local secs="${raw%.*}"
    local frac="${raw#*.}"
    # Pad/trim fractional part to 3 digits (ms).
    frac="${frac}000"
    frac="${frac%"${frac#???}"}"
    printf '%s%s' "$secs" "$frac"
  else
    # Second resolution fallback.
    printf '%s000' "$(date -u '+%s')"
  fi
}

# Collect per-iteration durations (ms) into a newline-separated string.
durations=""
i=0
while [ "$i" -lt "$ITERATIONS" ]; do
  start="$(_now_ms)"
  # The unit of work: one spawn (fallback path) followed by a shutdown so the
  # ceiling never trips and each iteration measures a clean single spawn.
  handle="$(spawn_teammate "perf-probe" --context "roster-cost" 2>/dev/null)"
  end="$(_now_ms)"
  shutdown_teammate "$handle" >/dev/null 2>&1 || true

  dur=$((end - start))
  [ "$dur" -lt 0 ] && dur=0
  durations="${durations}${dur}
"
  i=$((i + 1))
done

# Compute P95 and mean via awk (sort + nearest-rank percentile).
stats="$(printf '%s' "$durations" | grep -E '^[0-9]+$' | sort -n | awk '
  { a[NR] = $1; sum += $1 }
  END {
    n = NR
    if (n == 0) { print "0 0"; exit }
    # Nearest-rank P95: ceil(0.95 * n), clamped to [1, n].
    rank = int(0.95 * n)
    if (0.95 * n > rank) rank = rank + 1
    if (rank < 1) rank = 1
    if (rank > n) rank = n
    p95 = a[rank]
    mean = int((sum / n) + 0.5)
    printf "%d %d", p95, mean
  }
')"

p95_ms="${stats%% *}"
mean_ms="${stats##* }"

verdict="pass"
if [ "$p95_ms" -gt "$THRESHOLD_MS" ]; then
  verdict="fail"
fi

printf 'iterations=%d\n' "$ITERATIONS"
printf 'p95_ms=%d\n' "$p95_ms"
printf 'mean_ms=%d\n' "$mean_ms"
printf 'threshold_ms=%d\n' "$THRESHOLD_MS"
printf 'verdict=%s\n' "$verdict"
printf 'measurement=fallback-path\n'

exit 0
