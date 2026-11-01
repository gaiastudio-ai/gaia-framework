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
#   - Non-blocking: a write or validation error is logged to stderr and
#     the line is skipped (exit 0). Only usage errors (missing required
#     args, unknown subcommand) exit 1.
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

# Validate that a value is a non-negative integer (digits only).
# Returns 0 if valid, 1 if invalid. Empty/null strings return 1.
_tw_is_integer() {
  case "$1" in
    ''|null) return 1 ;;
    *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Validate that a value is a non-negative number (integer or decimal).
# Returns 0 if valid, 1 if invalid.
_tw_is_number() {
  case "$1" in
    ''|null) return 1 ;;
    *[!0-9.]*) return 1 ;;
    *.*.*) return 1 ;;  # multiple dots
    *) return 0 ;;
  esac
}

# Validate a run_id against the safe token pattern.
# Alphanumerics, hyphens, underscores, dots, colons, plus.
_tw_is_safe_token() {
  case "$1" in
    ''|null) return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._:+-]+$'
}

# Validate --gates-json: must be a JSON object whose keys are strings
# and whose values are strings (verdict names). Rejects non-object types,
# nested objects, and numeric/boolean values in the gate map.
_tw_validate_gates_json() {
  local json="$1"
  # Must parse as a JSON object.
  if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _tw_err "gates-json must be a JSON object"
    return 1
  fi
  # Every value must be a string (verdict name).
  local bad
  bad="$(printf '%s' "$json" | jq '[.[] | type] | map(select(. != "string")) | length' 2>/dev/null)" || bad="1"
  if [ "$bad" != "0" ]; then
    _tw_err "gates-json values must all be strings"
    return 1
  fi
  return 0
}

# Resolve the telemetry file path for a story key.
# When --story-file is provided, skip the lookup.
# Returns the path on stdout; empty on failure.
_tw_resolve_path() {
  local key="$1" story_file="${2:-}"
  if [ -z "$story_file" ]; then
    story_file="$("$SCRIPT_DIR/resolve-story-file.sh" "$key" 2>/dev/null)" || {
      _tw_err "cannot resolve story file for '$key'"
      return 1
    }
  fi
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
  local story="" gate="" verdict="" round="" run_id=""
  local started_at="" ended_at="" mutation_score="" token_estimate=""
  local story_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --story)        shift; story="${1:-}" ;;
      --story-file)   shift; story_file="${1:-}" ;;
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

  # --- Input validation (security: reject before any arithmetic/argjson) ---

  # Numeric fields: must be digits-only or empty/unset.
  if [ -n "$started_at" ] && ! _tw_is_integer "$started_at"; then
    _tw_err "gate-entry: --started-at must be a non-negative integer, got '$started_at' — skipping"
    return 0
  fi
  if [ -n "$ended_at" ] && ! _tw_is_integer "$ended_at"; then
    _tw_err "gate-entry: --ended-at must be a non-negative integer, got '$ended_at' — skipping"
    return 0
  fi
  if [ -n "$token_estimate" ] && ! _tw_is_integer "$token_estimate"; then
    _tw_err "gate-entry: --token-estimate must be a non-negative integer, got '$token_estimate' — skipping"
    return 0
  fi
  if [ -n "$round" ] && ! _tw_is_integer "$round"; then
    _tw_err "gate-entry: --round must be a non-negative integer, got '$round' — skipping"
    return 0
  fi
  if [ -n "$mutation_score" ] && ! _tw_is_number "$mutation_score"; then
    _tw_err "gate-entry: --mutation-score must be numeric, got '$mutation_score' — skipping"
    return 0
  fi

  # run_id: safe token pattern when present.
  if [ -n "$run_id" ] && ! _tw_is_safe_token "$run_id"; then
    _tw_err "gate-entry: --run-id contains unsafe characters — skipping"
    return 0
  fi

  # --- Build typed jq arguments ---

  local duration_ms="null" jq_start="null" jq_end="null"
  if [ -n "$started_at" ]; then
    jq_start="$started_at"
    if [ -n "$ended_at" ]; then
      jq_end="$ended_at"
      duration_ms=$(( ended_at - started_at ))
    fi
  fi

  local jq_round="null"
  [ -n "$round" ] && jq_round="$round"

  local jq_mscore="null"
  [ -n "$mutation_score" ] && jq_mscore="$mutation_score"

  local jq_tokens="null"
  [ -n "$token_estimate" ] && jq_tokens="$token_estimate"

  local run_id_args=()
  if [ -n "$run_id" ]; then
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
  path="$(_tw_resolve_path "$story" "$story_file")" || return 0
  _tw_append "$path" "$line"
}

# ---------- round-summary / story-total ----------

_tw_summary() {
  local entry_type="$1"; shift
  local story="" round="" composite_verdict=""
  local total_duration_ms="" total_tokens="" gates_json="{}"
  local story_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --story)             shift; story="${1:-}" ;;
      --story-file)        shift; story_file="${1:-}" ;;
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

  # --- Input validation ---
  if [ -n "$round" ] && ! _tw_is_integer "$round"; then
    _tw_err "$entry_type: --round must be a non-negative integer, got '$round' — skipping"
    return 0
  fi
  if [ -n "$total_duration_ms" ] && ! _tw_is_integer "$total_duration_ms"; then
    _tw_err "$entry_type: --total-duration-ms must be a non-negative integer, got '$total_duration_ms' — skipping"
    return 0
  fi
  if [ -n "$total_tokens" ] && ! _tw_is_integer "$total_tokens"; then
    _tw_err "$entry_type: --total-tokens must be a non-negative integer, got '$total_tokens' — skipping"
    return 0
  fi
  if ! _tw_validate_gates_json "$gates_json"; then
    _tw_err "$entry_type: --gates-json validation failed — skipping"
    return 0
  fi

  # --- Build typed jq arguments ---
  local jq_args=()
  jq_args+=(--argjson schema_version "$SCHEMA_VERSION")
  jq_args+=(--arg type "$entry_type")
  jq_args+=(--arg composite_verdict "$composite_verdict")

  if [ -n "$round" ]; then
    jq_args+=(--argjson round "$round")
  else
    jq_args+=(--argjson round "null")
  fi

  if [ -n "$total_duration_ms" ]; then
    jq_args+=(--argjson total_duration_ms "$total_duration_ms")
  else
    jq_args+=(--argjson total_duration_ms "null")
  fi

  if [ -n "$total_tokens" ]; then
    jq_args+=(--argjson total_tokens "$total_tokens")
  else
    jq_args+=(--argjson total_tokens "null")
  fi

  jq_args+=(--argjson gates "$gates_json")

  local line
  line="$(jq -nc "${jq_args[@]}" \
    '{schema_version: $schema_version, type: $type, round: $round,
      composite_verdict: $composite_verdict,
      total_duration_ms: $total_duration_ms, total_tokens: $total_tokens,
      gates: $gates}')" \
    || { _tw_err "jq failed building $entry_type line"; return 0; }

  local path
  path="$(_tw_resolve_path "$story" "$story_file")" || return 0
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
