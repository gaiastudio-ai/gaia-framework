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
# Sourceable: review-gate.sh sources this file and calls _tw_gate_entry
# directly (in-process, no subprocess spawn) for the fast path. The main()
# dispatcher runs only when the script is executed directly.
#
# Design constraints:
#   - Non-blocking: a write or validation error is logged to stderr and
#     the line is skipped (return 0). Only usage errors (missing required
#     args, unknown subcommand) exit 1 in CLI mode.
#   - Append-only: existing lines are never rewritten or deleted.
#   - Atomic: a single printf of a complete line stays under PIPE_BUF (4096+).
#   - No secrets: only canonical gate names, canonical verdicts, and numeric
#     metric fields are written. Free-text values are rejected.
#   - Bash 3.2 compatible: no local -A, mapfile, readarray or ${x,,}.
#   - All values are passed via jq --arg/--argjson (never spliced).
#
# Exit codes (CLI mode only):
#   0 — line written or skipped (validation/write errors are non-fatal)
#   1 — usage error (missing required args, bad subcommand)

# Guard: only set shell options when NOT sourced (the sourcing script owns
# its own set -euo pipefail).
if [ -z "${_TW_SOURCED:-}" ]; then
  set -euo pipefail
  LC_ALL=C; export LC_ALL
fi

_TW_SCRIPT_NAME="review-telemetry-writer.sh"
_TW_SCHEMA_VERSION=1

# Lazy-resolved script directory (only needed for CLI resolve-story-file).
_TW_SCRIPT_DIR=""
_tw_script_dir() {
  if [ -z "$_TW_SCRIPT_DIR" ]; then
    _TW_SCRIPT_DIR="$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
  fi
  printf '%s' "$_TW_SCRIPT_DIR"
}

# ---------- Canonical vocabularies ----------

_TW_CANONICAL_GATES="Code Review|QA Tests|Security Review|Test Automation|Test Review|Performance Review"
_TW_CANONICAL_VERDICTS="PASSED|FAILED|UNVERIFIED"
_TW_CANONICAL_COMPOSITES="COMPLETE|BLOCKED|PENDING"

_tw_is_canonical_gate() {
  case "$1" in
    "Code Review"|"QA Tests"|"Security Review"|"Test Automation"|"Test Review"|"Performance Review") return 0 ;;
    *) return 1 ;;
  esac
}

_tw_is_canonical_verdict() {
  case "$1" in
    PASSED|FAILED|UNVERIFIED) return 0 ;;
    *) return 1 ;;
  esac
}

_tw_is_canonical_composite() {
  case "$1" in
    COMPLETE|BLOCKED|PENDING) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- Validators ----------

_tw_err() { printf '%s: %s\n' "$_TW_SCRIPT_NAME" "$*" >&2; }

_tw_die() {
  local rc="$1"; shift
  _tw_err "$*"
  exit "$rc"
}

# Non-negative integer: digits only, no leading zeros (except bare "0").
_tw_is_integer() {
  case "$1" in
    ''|null) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;  # leading zero (octal trap)
    *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Non-negative number: integer or decimal (one dot allowed).
_tw_is_number() {
  case "$1" in
    ''|null) return 1 ;;
    *[!0-9.]*) return 1 ;;
    *.*.*) return 1 ;;
    .) return 1 ;;
    *) return 0 ;;
  esac
}

# Safe token: alphanumerics, hyphens, underscores, dots, colons, plus.
# Pure case-pattern, no subprocess.
_tw_is_safe_token() {
  case "$1" in
    ''|null) return 1 ;;
    *[!A-Za-z0-9._:+'-']*) return 1 ;;
    *) return 0 ;;
  esac
}

# Validate gates-json: must be a JSON object, keys are canonical gate
# names, values are canonical verdict strings.
_tw_validate_gates_json() {
  local json="$1"
  if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _tw_err "gates-json must be a JSON object"; return 1
  fi
  # Every value must be a string.
  local bad
  bad="$(printf '%s' "$json" | jq '[.[] | type] | map(select(. != "string")) | length' 2>/dev/null)" || bad="1"
  if [ "$bad" != "0" ]; then
    _tw_err "gates-json values must all be strings"; return 1
  fi
  # Keys must be canonical gate names; values must be canonical verdicts.
  local k v
  while IFS=$'\t' read -r k v; do
    if ! _tw_is_canonical_gate "$k"; then
      _tw_err "gates-json key '$k' is not a canonical gate name"; return 1
    fi
    if ! _tw_is_canonical_verdict "$v"; then
      _tw_err "gates-json value '$v' for gate '$k' is not a canonical verdict"; return 1
    fi
  done < <(printf '%s' "$json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null)
  return 0
}

# ---------- Path resolution ----------

# Resolve the telemetry file path. When story_file is provided, skip lookup.
# Uses parameter expansion instead of dirname (no subprocess).
_tw_resolve_path() {
  local key="$1" story_file="${2:-}"
  if [ -z "$story_file" ]; then
    story_file="$("$(_tw_script_dir)/resolve-story-file.sh" "$key" 2>/dev/null)" || {
      _tw_err "cannot resolve story file for '$key'"; return 1
    }
  fi
  printf '%s/review-telemetry.jsonl' "${story_file%/*}"
}

# Atomic append. On failure, log and return 0 (non-blocking).
_tw_append() {
  local path="$1" line="$2"
  local dir="${path%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || {
    _tw_err "cannot create directory '$dir' — skipping telemetry write"; return 0
  }
  printf '%s\n' "$line" >> "$path" 2>/dev/null || {
    _tw_err "write failed for '$path' — skipping telemetry write"; return 0
  }
}

# Epoch-millisecond timestamp. Uses EPOCHREALTIME (bash 5.0+) when
# available — no subprocess. On bash 3.2 this function is not called;
# jq's `now*1000|floor` stamps the end time inside the JSON build
# (zero extra processes per write).
_tw_epoch_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local sec="${EPOCHREALTIME%%.*}"
    local frac="${EPOCHREALTIME#*.}"
    frac="${frac:0:3}"
    while [ "${#frac}" -lt 3 ]; do frac="${frac}0"; done
    printf '%s%s' "$sec" "$frac"
  fi
  # No fallback — callers that need a timestamp on bash 3.2 use the
  # jq now*1000 path instead.
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
      *) _tw_err "gate-entry: unknown flag '$1'"; return 1 ;;
    esac
    shift
  done

  [ -n "$story" ]   || { _tw_err "gate-entry: --story is required"; return 1; }
  [ -n "$gate" ]    || { _tw_err "gate-entry: --gate is required"; return 1; }
  [ -n "$verdict" ] || { _tw_err "gate-entry: --verdict is required"; return 1; }

  # --- Canonical value validation ---
  if ! _tw_is_canonical_gate "$gate"; then
    _tw_err "gate-entry: --gate '$gate' is not a canonical gate name — skipping"; return 0
  fi
  if ! _tw_is_canonical_verdict "$verdict"; then
    _tw_err "gate-entry: --verdict '$verdict' is not a canonical verdict — skipping"; return 0
  fi

  # --- Numeric field validation (before any arithmetic/argjson) ---
  # Treat literal "null" the same as empty (JSON null in output).
  [ "$started_at" = "null" ] && started_at=""
  [ "$ended_at" = "null" ] && ended_at=""
  [ "$token_estimate" = "null" ] && token_estimate=""
  [ "$round" = "null" ] && round=""
  [ "$mutation_score" = "null" ] && mutation_score=""

  if [ -n "$started_at" ] && ! _tw_is_integer "$started_at"; then
    _tw_err "gate-entry: --started-at must be a non-negative integer, got '$started_at' — skipping"; return 0
  fi
  if [ -n "$ended_at" ] && ! _tw_is_integer "$ended_at"; then
    _tw_err "gate-entry: --ended-at must be a non-negative integer, got '$ended_at' — skipping"; return 0
  fi
  if [ -n "$token_estimate" ] && ! _tw_is_integer "$token_estimate"; then
    _tw_err "gate-entry: --token-estimate must be a non-negative integer — skipping"; return 0
  fi
  if [ -n "$round" ] && ! _tw_is_integer "$round"; then
    _tw_err "gate-entry: --round must be a non-negative integer — skipping"; return 0
  fi
  if [ -n "$mutation_score" ] && ! _tw_is_number "$mutation_score"; then
    _tw_err "gate-entry: --mutation-score must be numeric — skipping"; return 0
  fi
  if [ -n "$run_id" ] && ! _tw_is_safe_token "$run_id"; then
    _tw_err "gate-entry: --run-id contains unsafe characters — skipping"; return 0
  fi

  # --- Build typed values ---
  local jq_start="null"
  [ -n "$started_at" ] && jq_start="$started_at"

  # end is always stamped when not explicitly provided (jq now*1000).
  # When --ended-at is given, validate and use it; when --started-at is
  # given without --ended-at, jq computes end from wall-clock; standalone
  # calls (no --started-at) also stamp end from wall-clock.
  if [ -n "$ended_at" ] && [ -n "$started_at" ]; then
    local diff=$(( ended_at - started_at ))
    if [ "$diff" -lt 0 ]; then
      _tw_err "gate-entry: negative duration (end < start) — skipping"; return 0
    fi
  fi

  local jq_round="null"; [ -n "$round" ] && jq_round="$round"
  local jq_mscore="null"; [ -n "$mutation_score" ] && jq_mscore="$mutation_score"
  local jq_tokens="null"; [ -n "$token_estimate" ] && jq_tokens="$token_estimate"

  local run_id_args=()
  if [ -n "$run_id" ]; then
    run_id_args=(--arg run_id "$run_id")
  else
    run_id_args=(--argjson run_id "null")
  fi

  # Build the jq expression. duration_ms is computed inside jq when
  # start is present and end is wall-clock stamped, keeping everything
  # in one process.
  local jq_filter
  if [ -n "$started_at" ] && [ -z "$ended_at" ]; then
    # start given, end from jq wall-clock: compute duration inside jq.
    jq_filter='{schema_version:$schema_version,type:$type,gate:$gate,
      round:$round,run_id:$run_id,start:$start,
      end:(now*1000|floor),
      duration_ms:((now*1000|floor)-$start),
      verdict:$verdict,
      mutation_score:$mutation_score,token_estimate:$token_estimate}'
  elif [ -n "$ended_at" ]; then
    # Both start and end explicit: duration is end-start.
    jq_filter='{schema_version:$schema_version,type:$type,gate:$gate,
      round:$round,run_id:$run_id,start:$start,end:$end,
      duration_ms:($end-$start),
      verdict:$verdict,
      mutation_score:$mutation_score,token_estimate:$token_estimate}'
  else
    # No start, no end: stamp end from wall-clock, duration null.
    jq_filter='{schema_version:$schema_version,type:$type,gate:$gate,
      round:$round,run_id:$run_id,start:null,
      end:(now*1000|floor),
      duration_ms:null,
      verdict:$verdict,
      mutation_score:$mutation_score,token_estimate:$token_estimate}'
  fi

  local line
  local jq_end_val="null"
  [ -n "$ended_at" ] && jq_end_val="$ended_at"
  line="$(jq -nc \
    --argjson schema_version "$_TW_SCHEMA_VERSION" \
    --arg type "gate" \
    --arg gate "$gate" \
    --arg verdict "$verdict" \
    --argjson round "$jq_round" \
    "${run_id_args[@]}" \
    --argjson start "$jq_start" \
    --argjson end "$jq_end_val" \
    --argjson mutation_score "$jq_mscore" \
    --argjson token_estimate "$jq_tokens" \
    "$jq_filter")" \
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
      *) _tw_err "$entry_type: unknown flag '$1'"; return 1 ;;
    esac
    shift
  done

  [ -n "$story" ]             || { _tw_err "$entry_type: --story is required"; return 1; }
  [ -n "$composite_verdict" ] || { _tw_err "$entry_type: --composite-verdict is required"; return 1; }

  # --- Canonical validation ---
  if ! _tw_is_canonical_composite "$composite_verdict"; then
    _tw_err "$entry_type: --composite-verdict '$composite_verdict' is not canonical — skipping"; return 0
  fi

  # Treat literal "null" the same as empty (JSON null in output).
  [ "$round" = "null" ] && round=""
  [ "$total_duration_ms" = "null" ] && total_duration_ms=""
  [ "$total_tokens" = "null" ] && total_tokens=""

  # --- Numeric validation ---
  if [ -n "$round" ] && ! _tw_is_integer "$round"; then
    _tw_err "$entry_type: --round must be a non-negative integer — skipping"; return 0
  fi
  if [ -n "$total_duration_ms" ] && ! _tw_is_integer "$total_duration_ms"; then
    _tw_err "$entry_type: --total-duration-ms must be a non-negative integer — skipping"; return 0
  fi
  if [ -n "$total_tokens" ] && ! _tw_is_integer "$total_tokens"; then
    _tw_err "$entry_type: --total-tokens must be a non-negative integer — skipping"; return 0
  fi
  if ! _tw_validate_gates_json "$gates_json"; then
    _tw_err "$entry_type: --gates-json validation failed — skipping"; return 0
  fi

  # --- Build jq arguments ---
  local jq_args=()
  jq_args+=(--argjson schema_version "$_TW_SCHEMA_VERSION")
  jq_args+=(--arg type "$entry_type")
  jq_args+=(--arg composite_verdict "$composite_verdict")

  if [ -n "$round" ]; then jq_args+=(--argjson round "$round")
  else jq_args+=(--argjson round "null"); fi

  if [ -n "$total_duration_ms" ]; then jq_args+=(--argjson total_duration_ms "$total_duration_ms")
  else jq_args+=(--argjson total_duration_ms "null"); fi

  if [ -n "$total_tokens" ]; then jq_args+=(--argjson total_tokens "$total_tokens")
  else jq_args+=(--argjson total_tokens "null"); fi

  jq_args+=(--argjson gates "$gates_json")

  local line
  line="$(jq -nc "${jq_args[@]}" \
    '{schema_version:$schema_version,type:$type,round:$round,
      composite_verdict:$composite_verdict,
      total_duration_ms:$total_duration_ms,total_tokens:$total_tokens,
      gates:$gates}')" \
    || { _tw_err "jq failed building $entry_type line"; return 0; }

  local path
  path="$(_tw_resolve_path "$story" "$story_file")" || return 0
  _tw_append "$path" "$line"
}

# ---------- CLI entry point ----------
# Only runs when the script is executed directly, not sourced.

_tw_main() {
  if [ $# -eq 0 ]; then
    _tw_die 1 "usage: $_TW_SCRIPT_NAME <gate-entry|round-summary|story-total> [flags]"
  fi
  local subcmd="$1"; shift
  case "$subcmd" in
    gate-entry)     _tw_gate_entry "$@" ;;
    round-summary)  _tw_summary "round-summary" "$@" ;;
    story-total)    _tw_summary "story-total" "$@" ;;
    --help|-h)
      printf 'Usage: %s <gate-entry|round-summary|story-total> [flags]\n' "$_TW_SCRIPT_NAME"
      printf 'Append review telemetry lines to a per-story review-telemetry.jsonl file.\n'
      ;;
    *) _tw_die 1 "unknown subcommand '$subcmd' — expected gate-entry, round-summary or story-total" ;;
  esac
}

# Run main only when executed directly (not sourced).
if [ -z "${_TW_SOURCED:-}" ]; then
  _tw_main "$@"
fi
