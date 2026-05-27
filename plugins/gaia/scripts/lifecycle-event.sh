#!/usr/bin/env bash
# lifecycle-event.sh — GAIA foundation script (E28-S12)
#
# Append a JSONL lifecycle event to ${MEMORY_PATH}/lifecycle-events.jsonl under
# an advisory lock, for consumption by a tailing sync agent. Produces events
# only — the consumer side is out of scope and lands in a follow-up cascade.
#
# Refs: FR-325, FR-328, NFR-048, ADR-042, ADR-048
# Brief: P2-S4 (.gaia/artifacts/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
#
# Invocation contract (stable for E28-S17 bats-core authors):
#
#   lifecycle-event.sh --type <event_type> --workflow <name>
#                      [--story <story_key>] [--step <n>] [--data '<json>']
#                      [--event-types-file <path>] [--help]
#
# Exit codes:
#   0 — success (single JSONL line appended, or --help)
#   1 — usage error, unknown event type (strict mode), malformed --data,
#       missing required flag, or lock acquisition failure
#
# Performance budget (NFR-048): < 50ms wall-clock on a developer workstation.
# Measure with: time ./plugins/gaia/scripts/lifecycle-event.sh \
#                   --type test --workflow noop
# The script forks at most two subshells per invocation (jq + the lock wrapper)
# to stay within the budget.
#
# Output schema (one JSON object per line):
#   { "timestamp":  "<ISO 8601 UTC with ms precision>",
#     "event_type": "<string>",
#     "workflow":   "<string>",
#     "pid":        <int>,
#     // optional, present only when the corresponding flag was supplied:
#     "story_key":  "<string>",
#     "step":       <int>,
#     "data":       <any valid JSON> }
#
# Atomicity:
#   `flock -x` serializes concurrent writers. On macOS /bin/bash 3.2 where
#   util-linux `flock(1)` is not installed, the script degrades to a
#   mv-based advisory lockfile with a bounded spin-loop (same pattern used by
#   checkpoint.sh §E28-S10). `printf '%s\n'` inside the lock is a single
#   write(2) for lines under PIPE_BUF (4KB Linux, 512B macOS) — callers SHOULD
#   keep --data payloads under ~2KB on macOS to preserve write atomicity.
#
# POSIX discipline: the only non-POSIX constructs are [[ ]] and bash indexed
# arrays. macOS /bin/bash 3.2 compatible. Uses `jq` (required) and `flock`
# (optional — graceful fallback).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="lifecycle-event.sh"

# ---------- Helpers ----------

die() {
  # message…  (always exit 1)
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  lifecycle-event.sh --type <event_type> --workflow <name>
                     [--story <story_key>] [--step <n>] [--data '<json>']
                     [--event-types-file <path>] [--help]

Required flags:
  --type      Event type name (e.g., step_complete, gate_failed). When
              --event-types-file is supplied, must appear in that file.
  --workflow  Workflow name emitting the event (e.g., dev-story, create-story).

Optional flags:
  --story             Story key (e.g., E1-S1) — emitted as story_key.
  --step              Integer step number — emitted as step.
  --data              Valid JSON scalar/object/array — emitted as data.
  --event-types-file  Path to a file listing allowed event types, one per
                      line; lines starting with '#' are comments. When
                      supplied, unknown --type values are rejected.
  --help              Print this usage and exit 0.

Output:
  Appends one JSON object per invocation to ${MEMORY_PATH}/lifecycle-events.jsonl
  under an advisory lock. Creates the file (mode 0644) and parent directory
  if missing.

Exit codes:
  0  success
  1  usage error, unknown event type, malformed --data, lock failure
USAGE
}

# ISO 8601 UTC with millisecond precision. Resolution order (by fork cost):
#   1. GNU `date -u +%3N` — near-zero (shell builtin date on Linux)
#   2. `gdate -u +%3N` — GNU coreutils on macOS via Homebrew
#   3. `perl -MTime::HiRes` — universally installed on macOS (~37ms cold),
#      chosen as the single documented fallback (story spec §Technical Notes).
# Pure-shell `date +%s` cannot provide sub-second precision portably, so a
# helper fork is unavoidable on BSD/macOS. perl is ~3x faster than python3
# cold-start, keeping total invocation wall-clock under the NFR-048 50ms
# budget for the happy path.
iso_utc_now_ms() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || true)
  case "$ts" in
    ''|*3N*) ;;  # fall through — BSD date prints literal "3N"
    *) printf '%s' "$ts"; return ;;
  esac
  if command -v gdate >/dev/null 2>&1; then
    ts=$(gdate -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || true)
    if [ -n "$ts" ]; then printf '%s' "$ts"; return; fi
  fi
  # perl fallback (macOS/BSD). Time::HiRes and POSIX are core modules.
  perl -MTime::HiRes=time -MPOSIX -e '
    my $t  = time;
    my $ms = int(($t - int($t)) * 1000);
    printf "%s.%03dZ", POSIX::strftime("%Y-%m-%dT%H:%M:%S", gmtime(int($t))), $ms;
  '
}

# Reject event types not listed in an allow-list file. Comments (#...) and
# blank lines are ignored. Matches whole lines only.
event_type_allowed() {
  local type="$1" file="$2" line stripped
  while IFS= read -r line || [ -n "$line" ]; do
    # strip leading whitespace
    stripped="${line#"${line%%[![:space:]]*}"}"
    # skip blank and comments
    case "$stripped" in
      ''|'#'*) continue ;;
    esac
    # strip trailing whitespace
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
    if [ "$stripped" = "$type" ]; then
      return 0
    fi
  done < "$file"
  return 1
}

# ---------- Argument parsing ----------

event_type=""
workflow=""
story_key=""
step=""
data=""
types_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --type)
      [ $# -ge 2 ] || die "--type requires an argument"
      event_type="$2"; shift 2 ;;
    --type=*)
      event_type="${1#--type=}"; shift ;;
    --workflow)
      [ $# -ge 2 ] || die "--workflow requires an argument"
      workflow="$2"; shift 2 ;;
    --workflow=*)
      workflow="${1#--workflow=}"; shift ;;
    --story)
      [ $# -ge 2 ] || die "--story requires an argument"
      story_key="$2"; shift 2 ;;
    --story=*)
      story_key="${1#--story=}"; shift ;;
    --step)
      [ $# -ge 2 ] || die "--step requires an argument"
      step="$2"; shift 2 ;;
    --step=*)
      step="${1#--step=}"; shift ;;
    --data)
      [ $# -ge 2 ] || die "--data requires an argument"
      data="$2"; shift 2 ;;
    --data=*)
      data="${1#--data=}"; shift ;;
    --event-types-file)
      [ $# -ge 2 ] || die "--event-types-file requires a path"
      types_file="$2"; shift 2 ;;
    --event-types-file=*)
      types_file="${1#--event-types-file=}"; shift ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2
      usage >&2
      exit 1 ;;
  esac
done

# Required flags (AC1, S8)
[ -n "$event_type" ] || { printf '%s: --type is required\n' "$SCRIPT_NAME" >&2; usage >&2; exit 1; }
[ -n "$workflow" ]   || { printf '%s: --workflow is required\n' "$SCRIPT_NAME" >&2; usage >&2; exit 1; }

# Step must be an integer if supplied
if [ -n "$step" ]; then
  case "$step" in
    ''|*[!0-9]*) die "--step must be a non-negative integer (got: $step)" ;;
  esac
fi

# Event-type validation (AC4) — only when a types file is supplied.
if [ -n "$types_file" ]; then
  [ -f "$types_file" ] || die "--event-types-file not found: $types_file"
  if ! event_type_allowed "$event_type" "$types_file"; then
    printf '%s: event type %q not in allow-list %s\n' \
      "$SCRIPT_NAME" "$event_type" "$types_file" >&2
    exit 1
  fi
fi

# --data must be parseable JSON if supplied (AC7)
if [ -n "$data" ]; then
  if ! printf '%s' "$data" | jq empty >/dev/null 2>&1; then
    printf '%s: --data is not valid JSON: %s\n' "$SCRIPT_NAME" "$data" >&2
    exit 1
  fi
fi

# ---------- MEMORY_PATH resolution (ADR-111: .gaia/ canonical) ----------

# AF-2026-05-27-3: .gaia/memory is the only memory tree — the legacy _memory
# fallback was removed with the consolidation migration. Env override wins.
if [ -z "${MEMORY_PATH:-}" ]; then
  MEMORY_PATH=".gaia/memory"
fi
JSONL="${MEMORY_PATH}/lifecycle-events.jsonl"

mkdir -p "$MEMORY_PATH"
if [ ! -f "$JSONL" ]; then
  touch "$JSONL"
  chmod 0644 "$JSONL"
fi

# ---------- Build the JSON line (AC2) ----------

ts=$(iso_utc_now_ms)
data_argjson="${data:-null}"

line=$(jq -nc \
  --arg ts       "$ts" \
  --arg type     "$event_type" \
  --arg workflow "$workflow" \
  --arg story    "${story_key:-}" \
  --arg stepv    "${step:-}" \
  --argjson data "$data_argjson" \
  --argjson pid  "$$" \
  '{timestamp: $ts, event_type: $type, workflow: $workflow, pid: $pid}
   + (if $story != ""  then {story_key: $story}    else {} end)
   + (if $stepv != ""  then {step: ($stepv|tonumber)} else {} end)
   + (if $data  != null then {data: $data}         else {} end)')

# ---------- Atomic append under lock (AC3, AC6) ----------

lockfile="${JSONL}.lock"
flock_bin=$(command -v flock || true)

append_line() {
  # Single printf write(2) inside the lock — atomic for lines under PIPE_BUF.
  printf '%s\n' "$line" >> "$JSONL"
}

if [ -n "$flock_bin" ]; then
  (
    exec 9>"$lockfile"
    if ! "$flock_bin" -x -w 1 9; then
      die "flock timeout acquiring $lockfile"
    fi
    append_line
  )
else
  # mv-based spin-loop fallback (same pattern as checkpoint.sh §E28-S10).
  # `set -C` + `: > file` is an atomic exclusive-create on POSIX filesystems.
  tries=0
  while ! ( set -C; : > "$lockfile" ) 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -ge 50 ] && die "lock timeout acquiring $lockfile"
    sleep 0.1 2>/dev/null || sleep 1
  done
  # shellcheck disable=SC2064
  trap "rm -f '$lockfile'" EXIT
  append_line
  rm -f "$lockfile"
  trap - EXIT
fi

exit 0
