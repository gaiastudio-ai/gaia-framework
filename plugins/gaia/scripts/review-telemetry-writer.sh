#!/usr/bin/env bash
# review-telemetry-writer.sh — append-only telemetry for review gate verdicts.
#
# Writes structured JSON lines to a per-story review-telemetry.jsonl file.
# Each invocation appends exactly one line. Three entry types are supported:
#
#   gate-entry      One gate's verdict (PASSED/FAILED) with timing and metrics.
#   round-summary   Aggregate line after all gates in a round complete.
#   story-total     Terminal line when a round reaches the COMPLETE composite.
#
# The file lives in the story's artifact folder, resolved via
# resolve-story-file.sh. Access scope matches other story artifacts.
#
# Design constraints:
#   - Non-blocking: a write error is logged to stderr; exit 0 always.
#   - Append-only: existing lines are never rewritten or deleted.
#   - Atomic: a single printf of a complete line stays under PIPE_BUF (4096+).
#   - No secrets: only allowlisted fields are written; findings text, diff
#     content and credentials are never accepted or forwarded.
#   - Bash 3.2 compatible: no local -A, mapfile, readarray or ${x,,}.
#   - All values are passed via jq --arg/--argjson (never spliced).
#
# Invocation:
#   review-telemetry-writer.sh gate-entry   --story <key> --gate <name> \
#       --verdict <PASSED|FAILED> [--round <n>] [--run-id <id>] \
#       [--started-at <epoch-ms>] [--ended-at <epoch-ms>] \
#       [--mutation-score <float>] [--token-estimate <int>]
#
#   review-telemetry-writer.sh round-summary --story <key> --round <n> \
#       --composite-verdict <COMPLETE|BLOCKED|PENDING> \
#       [--total-duration-ms <int>] [--total-tokens <int>] \
#       --gates-json <json-object>
#
#   review-telemetry-writer.sh story-total   --story <key> --round <n> \
#       --composite-verdict <COMPLETE> \
#       [--total-duration-ms <int>] [--total-tokens <int>] \
#       --gates-json <json-object>
#
# Exit codes:
#   0 — always (write errors are logged, never fatal)
#   1 — usage error only (missing required args, bad subcommand)

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="review-telemetry-writer.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

SCHEMA_VERSION=1

# ---------- helpers ----------

_tw_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

_tw_die() {
  local rc="$1"; shift
  _tw_err "$*"
  exit "$rc"
}

# Resolve the telemetry file path for a story key.
# Returns the path on stdout; empty on failure.
_tw_resolve_path() {
  local key="$1"
  local story_file
  story_file="$("$SCRIPT_DIR/resolve-story-file.sh" "$key" 2>/dev/null)" || {
    _tw_err "cannot resolve story file for '$key'"
    return 1
  }
  local story_dir
  story_dir="$(dirname "$story_file")"
  printf '%s/review-telemetry.jsonl' "$story_dir"
}

# Atomic append: write the complete line via printf.
# A single printf of a line under PIPE_BUF (at least 4096 on all POSIX
# systems) is atomic. Our lines are well under that limit.
# On failure, log and return 0 (non-blocking).
_tw_append() {
  local path="$1" line="$2"
  local dir
  dir="$(dirname "$path")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    _tw_err "cannot create directory '$dir' — skipping telemetry write"
    return 0
  fi
  if ! printf '%s\n' "$line" >> "$path" 2>/dev/null; then
    _tw_err "write failed for '$path' — skipping telemetry write"
    return 0
  fi
}

# ---------- gate-entry ----------

_tw_gate_entry() {
  local story="" gate="" verdict="" round="null" run_id="null"
  local started_at="null" ended_at="null" mutation_score="null" token_estimate="null"

  while [ $# -gt 0 ]; do
    case "$1" in
      --story)        shift; story="${1:-}" ;;
      --gate)         shift; gate="${1:-}" ;;
      --verdict)      shift; verdict="${1:-}" ;;
      --round)        shift; round="${1:-}" ;;
      --run-id)       shift; run_id="${1:-}" ;;
      --started-at)   shift; started_at="${1:-}" ;;
      --ended-at)     shift; ended_at="${1:-}" ;;
      --mutation-score) shift; mutation_score="${1:-}" ;;
      --token-estimate) shift; token_estimate="${1:-}" ;;
      *) _tw_die 1 "gate-entry: unknown flag '$1'" ;;
    esac
    shift
  done

  [ -n "$story" ]   || _tw_die 1 "gate-entry: --story is required"
  [ -n "$gate" ]    || _tw_die 1 "gate-entry: --gate is required"
  [ -n "$verdict" ] || _tw_die 1 "gate-entry: --verdict is required"

  # Compute duration_ms from start/end when both are present.
  local duration_ms="null"
  local jq_start="null" jq_end="null"
  if [ "$started_at" != "null" ] && [ -n "$started_at" ]; then
    jq_start="$started_at"
    if [ "$ended_at" != "null" ] && [ -n "$ended_at" ]; then
      jq_end="$ended_at"
      duration_ms=$(( ended_at - started_at )) 2>/dev/null || duration_ms="null"
    fi
  fi

  # Build the round argjson: numeric when present, null otherwise.
  local jq_round="null"
  if [ "$round" != "null" ] && [ -n "$round" ]; then
    jq_round="$round"
  fi

  # mutation_score: numeric (float) when present, null otherwise.
  local jq_mscore="null"
  if [ "$mutation_score" != "null" ] && [ -n "$mutation_score" ]; then
    jq_mscore="$mutation_score"
  fi

  # token_estimate: numeric when present, null otherwise.
  local jq_tokens="null"
  if [ "$token_estimate" != "null" ] && [ -n "$token_estimate" ]; then
    jq_tokens="$token_estimate"
  fi

  # run_id: string when present, null otherwise.
  local run_id_args=()
  if [ "$run_id" != "null" ] && [ -n "$run_id" ]; then
    run_id_args=(--arg run_id "$run_id")
  else
    run_id_args=(--argjson run_id "null")
  fi

  local line
  line="$(jq -nc \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg type "gate" \
    --arg gate "$gate" \
    --arg verdict "$verdict" \
    --argjson round "$jq_round" \
    "${run_id_args[@]}" \
    --argjson start "$jq_start" \
    --argjson end "$jq_end" \
    --argjson duration_ms "$duration_ms" \
    --argjson mutation_score "$jq_mscore" \
    --argjson token_estimate "$jq_tokens" \
    '{schema_version: $schema_version, type: $type, gate: $gate,
      round: $round, run_id: $run_id, start: $start, end: $end,
      duration_ms: $duration_ms, verdict: $verdict,
      mutation_score: $mutation_score, token_estimate: $token_estimate}')" \
    || { _tw_err "jq failed building gate-entry line"; return 0; }

  local path
  path="$(_tw_resolve_path "$story")" || return 0
  _tw_append "$path" "$line"
}

# ---------- round-summary / story-total ----------

_tw_summary() {
  local entry_type="$1"; shift
  local story="" round="null" composite_verdict=""
  local total_duration_ms="null" total_tokens="null" gates_json="{}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --story)             shift; story="${1:-}" ;;
      --round)             shift; round="${1:-}" ;;
      --composite-verdict) shift; composite_verdict="${1:-}" ;;
      --total-duration-ms) shift; total_duration_ms="${1:-}" ;;
      --total-tokens)      shift; total_tokens="${1:-}" ;;
      --gates-json)        shift; gates_json="${1:-}" ;;
      *) _tw_die 1 "$entry_type: unknown flag '$1'" ;;
    esac
    shift
  done

  [ -n "$story" ]             || _tw_die 1 "$entry_type: --story is required"
  [ -n "$composite_verdict" ] || _tw_die 1 "$entry_type: --composite-verdict is required"

  local jq_args=()
  jq_args+=(--argjson schema_version "$SCHEMA_VERSION")
  jq_args+=(--arg type "$entry_type")
  jq_args+=(--arg composite_verdict "$composite_verdict")

  # round
  if [ "$round" = "null" ] || [ -z "$round" ]; then
    jq_args+=(--argjson round "null")
  else
    jq_args+=(--argjson round "$round")
  fi

  # total_duration_ms
  if [ "$total_duration_ms" = "null" ] || [ -z "$total_duration_ms" ]; then
    jq_args+=(--argjson total_duration_ms "null")
  else
    jq_args+=(--argjson total_duration_ms "$total_duration_ms")
  fi

  # total_tokens
  if [ "$total_tokens" = "null" ] || [ -z "$total_tokens" ]; then
    jq_args+=(--argjson total_tokens "null")
  else
    jq_args+=(--argjson total_tokens "$total_tokens")
  fi

  # gates (JSON object)
  jq_args+=(--argjson gates "$gates_json")

  local line
  line="$(jq -nc "${jq_args[@]}" \
    '{schema_version: $schema_version, type: $type, round: $round,
      composite_verdict: $composite_verdict,
      total_duration_ms: $total_duration_ms, total_tokens: $total_tokens,
      gates: $gates}')" \
    || { _tw_err "jq failed building $entry_type line"; return 0; }

  local path
  path="$(_tw_resolve_path "$story")" || return 0
  _tw_append "$path" "$line"
}

# ---------- main ----------

main() {
  if [ $# -eq 0 ]; then
    _tw_die 1 "usage: $SCRIPT_NAME <gate-entry|round-summary|story-total> [flags]"
  fi

  local subcmd="$1"; shift

  case "$subcmd" in
    gate-entry)     _tw_gate_entry "$@" ;;
    round-summary)  _tw_summary "round-summary" "$@" ;;
    story-total)    _tw_summary "story-total" "$@" ;;
    --help|-h)
      printf 'Usage: %s <gate-entry|round-summary|story-total> [flags]\n' "$SCRIPT_NAME"
      printf 'Append review telemetry lines to a per-story review-telemetry.jsonl file.\n'
      ;;
    *)
      _tw_die 1 "unknown subcommand '$subcmd' — expected gate-entry, round-summary or story-total"
      ;;
  esac
}

main "$@"
