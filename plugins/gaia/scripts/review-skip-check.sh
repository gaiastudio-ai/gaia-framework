#!/usr/bin/env bash
# review-skip-check.sh — Skip-already-PASSED filter for /gaia-run-all-reviews
#
# Reads the current Review Gate table for a story (via review-gate.sh status)
# and emits a deterministic JSON partition `{"skip":[...],"run":[...]}` listing
# which canonical reviewers are already PASSED (skip) and which still need to
# run (run). Extracts the inline LLM gate-counting step into a script — the
# LLM never counts gate rows again.
#
# Invocation contract:
#
#   review-skip-check.sh --story <key>                     # partition by current gate state
#   review-skip-check.sh --story <key> --force             # skip=[], run=<all 6>
#   review-skip-check.sh --story <key> --bind-head <sha>   # re-partition: PASSED rows not
#                                                          # bound to <sha> move to run
#   review-skip-check.sh --help
#
# Output (stdout, exit 0): single-line JSON, e.g.
#   {"skip":["code-review","qa-tests"],"run":["security-review","test-automate","test-review","review-perf"]}
#
# Canonical short-name vocabulary (story spec, exact case, exact spelling):
#   code-review | qa-tests | security-review | test-automate | test-review | review-perf
#
# Canonical gate-name vocabulary (review-gate.sh, exact case, exact spelling):
#   "Code Review" | "QA Tests" | "Security Review"
#   "Test Automation" | "Test Review" | "Performance Review"
#
# Canonical verdict vocabulary (review-gate.sh, exact case):
#   PASSED | FAILED | UNVERIFIED
#
# Exit codes:
#   0 — success; well-formed JSON emitted to stdout
#   1 — story not found (review-gate.sh status failed because the story file
#       does not exist or zero canonical files match the glob)
#   2 — malformed gate state: unknown verdict token, zero-row gate table,
#       unknown CLI flag, or any review-gate.sh error other than "story not
#       found"
#
# Non-atomicity caveat:
#   This script is intentionally NOT atomic with respect to the subsequent
#   reviewer runs. It is invoked once at SKILL.md Step 2 and is NOT refreshed
#   between reviewer invocations. A concurrent gate write between this
#   skip-check and the actual reviewer dispatch is rare and is safe — re-running
#   an already-PASSED reviewer simply rewrites the same verdict (verdict
#   overwrite is safe, best-effort skip filter contract). Do NOT introduce a
#   flock here — the upstream review-gate.sh `update` operation is atomic on
#   its own and that is the relevant invariant.
#
# Read-only guarantee:
#   This script never writes to the story file, never creates tempfiles or
#   sidecar scratch files, and never mutates sprint-status.yaml. It only
#   shells out to review-gate.sh status (a read-only sub-operation).
#
# POSIX discipline: macOS /bin/bash 3.2 compatible. Uses jq (required) and
# grep / awk / printf. No Python, no Node, no curl.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="review-skip-check.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- Canonical vocabulary ----------

# Canonical gate-name vocabulary (review-gate.sh table column 1, exact case).
# Order is the canonical Review Gate table order — this is the order the
# story spec mandates for the JSON output. It matches the row order in the
# Review Gate table emitted by review-gate.sh `status` and the per-story
# Markdown table.
CANONICAL_GATES=(
  "Code Review"
  "QA Tests"
  "Security Review"
  "Test Automation"
  "Test Review"
  "Performance Review"
)

# Canonical short-name vocabulary (JSON output). 1:1 indexed mapping with
# CANONICAL_GATES above. The order matches review-runner.sh and the SKILL.md
# wiring. DO NOT reorder either array independently.
CANONICAL_SHORT_NAMES=(
  "code-review"
  "qa-tests"
  "security-review"
  "test-automate"
  "test-review"
  "review-perf"
)

# Canonical verdict vocabulary (review-gate.sh, exact case). Anything outside
# this set is malformed and triggers exit 2.
CANONICAL_VERDICTS_REGEX='^(PASSED|FAILED|UNVERIFIED)$'

# ---------- Helpers ----------

_die_usage() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  printf 'Usage: %s --story <key> [--force]\n' "$SCRIPT_NAME" >&2
  exit 2
}

_die_not_found() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

_die_malformed() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 2
}

usage() {
  cat <<'USAGE'
Usage:
  review-skip-check.sh --story <key> [--force] [--bind-head <sha>]
  review-skip-check.sh --help

Reads the current Review Gate table for <key> via review-gate.sh status and
emits a JSON partition {"skip":[...],"run":[...]} where:
  - skip lists canonical short-names of gates already at verdict PASSED
  - run lists canonical short-names of gates NOT at PASSED (FAILED, UNVERIFIED)

With --force, skip is always [] and run lists all 6 in canonical order.

With --bind-head <sha>, a PASSED row whose reviewed SHA is not <sha> is moved
from skip to run: the row is stale after a fix commit, or carries no binding
at all (absent or empty SHA, or the story file cannot be read). Without
--bind-head, the partition is SHA-blind (today's default behaviour).

Canonical short-name order:
  code-review, qa-tests, security-review, test-automate, test-review, review-perf

Exit codes:
  0 — success
  1 — story not found
  2 — malformed gate state (unknown verdict, zero rows, unknown flag)
USAGE
}

# ---------- Argument parsing ----------

STORY_KEY=""
FORCE=0
BIND_HEAD=""

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          _die_usage "--story requires a value"
        fi
        STORY_KEY="$2"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --bind-head)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          _die_usage "--bind-head requires a SHA value"
        fi
        BIND_HEAD="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        _die_usage "unknown flag: $1"
        ;;
    esac
  done

  if [ -z "$STORY_KEY" ]; then
    _die_usage "--story <key> is required"
  fi
}

# ---------- Main ----------

# Resolve review-gate.sh location: same directory as this script.
REVIEW_GATE="${REVIEW_GATE_SCRIPT:-$SCRIPT_DIR/review-gate.sh}"

_emit_force_run_all() {
  # skip=[], run=<all 6 canonical short names>
  local run_json
  run_json=$(printf '%s\n' "${CANONICAL_SHORT_NAMES[@]}" | jq -R . | jq -sc .)
  jq -cn --argjson run "$run_json" '{skip: [], run: $run}'
}

main() {
  parse_args "$@"

  # ---- --force fast path ----
  if [ "$FORCE" -eq 1 ]; then
    _emit_force_run_all
    exit 0
  fi

  # ---- Read current gate state via review-gate.sh status ----
  local status_json
  local status_rc=0
  STATUS_STDERR_FILE="$(mktemp -t review-skip-check.XXXXXX)"
  # Trap uses a script-global so EXIT cleanup survives main()'s scope.
  trap 'rm -f "${STATUS_STDERR_FILE:-}"' EXIT

  set +e
  status_json="$("$REVIEW_GATE" status --story "$STORY_KEY" 2>"$STATUS_STDERR_FILE")"
  status_rc=$?
  set -e

  if [ "$status_rc" -ne 0 ]; then
    # Distinguish "story not found" (exit 1) from other malformed-gate errors
    # (exit 2). review-gate.sh emits "no story file found for key" on the
    # locate_story_file path. Anything else (missing Review Gate section,
    # fewer than six rows, etc.) is malformed gate state.
    local err
    err="$(cat "$STATUS_STDERR_FILE")"
    if [[ "$err" =~ (no\ story\ file\ found|story\ not\ found) ]]; then
      _die_not_found "story not found: $STORY_KEY"
    fi
    # Surface the upstream stderr for debuggability and exit 2.
    if [ -n "$err" ]; then
      printf '%s: %s\n' "$SCRIPT_NAME" "$err" >&2
    fi
    _die_malformed "malformed gate state for story $STORY_KEY (review-gate.sh status exit=$status_rc)"
  fi

  # ---- Validate JSON shape ----
  if ! printf '%s' "$status_json" | jq -e '.gates' >/dev/null 2>&1; then
    _die_malformed "review-gate.sh status returned no .gates object for story $STORY_KEY"
  fi

  # ---- When --bind-head is set, load SHA bindings from the story file ----
  # The status JSON is SHA-blind; we parse the story file's Review Gate table
  # directly via the shared review-gate-table library for SHA comparison.
  # gate_sha_map is a newline-delimited list of gate=sha pairs.
  local gate_sha_map=""
  if [ -n "$BIND_HEAD" ]; then
    # Resolve the story file via resolve-story-file.sh (same resolver
    # used by dev-story Step 1).
    local story_file=""
    local _resolver="${SCRIPT_DIR}/resolve-story-file.sh"
    if [ -x "$_resolver" ]; then
      story_file="$("$_resolver" "$STORY_KEY" 2>/dev/null)" || story_file=""
    fi
    if [ -n "$story_file" ] && [ -f "$story_file" ]; then
      # Source the shared parser if not already loaded.
      local _lib_dir="${SCRIPT_DIR}/lib"
      if [ -f "$_lib_dir/review-gate-table.sh" ]; then
        # shellcheck source=lib/review-gate-table.sh
        . "$_lib_dir/review-gate-table.sh"
      fi
      # Read Review Gate table rows from the story file.
      local _in_gate=0 _line
      while IFS= read -r _line; do
        case "$_line" in
          "## Review Gate"*) _in_gate=1; continue ;;
          "## "*) [ "$_in_gate" -eq 1 ] && break ;;
        esac
        [ "$_in_gate" -eq 0 ] && continue
        case "$_line" in
          "| Review"*|"| -"*|"|-"*) continue ;;
          "| "*) ;;
          *) continue ;;
        esac
        local _parsed
        _parsed="$(parse_review_gate_row "$_line" 2>/dev/null)" || continue
        local _rg _rs
        _rg="$(printf '%s\n' "$_parsed" | grep '^gate=' | head -1)"
        _rg="${_rg#gate=}"
        _rs="$(printf '%s\n' "$_parsed" | grep '^reviewed_sha=' | head -1)"
        _rs="${_rs#reviewed_sha=}"
        if [ -n "$_rg" ]; then
          gate_sha_map="${gate_sha_map}${_rg}=${_rs}"$'\n'
        fi
      done < "$story_file"
    else
      printf '%s: cannot resolve the story file for %s; no row can be shown bound to %s, so every PASSED row will re-run\n' \
        "$SCRIPT_NAME" "$STORY_KEY" "$BIND_HEAD" >&2
    fi
  fi

  # ---- Iterate canonical gate order; partition into skip / run ----
  local skip_list=()
  local run_list=()
  local i
  for i in "${!CANONICAL_GATES[@]}"; do
    local gate="${CANONICAL_GATES[$i]}"
    local short="${CANONICAL_SHORT_NAMES[$i]}"
    local verdict
    verdict="$(printf '%s' "$status_json" | jq -r --arg g "$gate" '.gates[$g] // empty')"

    if [ -z "$verdict" ]; then
      _die_malformed "gate table empty for story $STORY_KEY (missing row: $gate)"
    fi

    if [[ ! "$verdict" =~ $CANONICAL_VERDICTS_REGEX ]]; then
      _die_malformed "malformed gate row: $gate has non-canonical verdict '$verdict'"
    fi

    if [ "$verdict" = "PASSED" ]; then
      # With --bind-head: move PASSED rows bound to a different SHA to run.
      if [ -n "$BIND_HEAD" ]; then
        # Only a row shown to be bound to <sha> may stay in skip: an absent,
        # empty or unreadable binding is re-reviewed like a stale one.
        local row_sha
        row_sha="$(printf '%s\n' "$gate_sha_map" | awk -F= -v g="$gate" '$1 == g && !seen { print $2; seen = 1 }')"
        row_sha="${row_sha#"${row_sha%%[![:space:]]*}"}"
        row_sha="${row_sha%"${row_sha##*[![:space:]]}"}"
        if [ "$row_sha" != "$BIND_HEAD" ]; then
          run_list+=("$short")
          continue
        fi
      fi
      skip_list+=("$short")
    else
      run_list+=("$short")
    fi
  done

  # ---- Emit JSON ----
  local skip_json run_json
  if [ "${#skip_list[@]}" -eq 0 ]; then
    skip_json='[]'
  else
    skip_json=$(printf '%s\n' "${skip_list[@]}" | jq -R . | jq -sc .)
  fi
  if [ "${#run_list[@]}" -eq 0 ]; then
    run_json='[]'
  else
    run_json=$(printf '%s\n' "${run_list[@]}" | jq -R . | jq -sc .)
  fi

  jq -cn --argjson skip "$skip_json" --argjson run "$run_json" '{skip: $skip, run: $run}'
}

main "$@"
