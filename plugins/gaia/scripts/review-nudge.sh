#!/usr/bin/env bash
# review-nudge.sh — Deterministic V1 progressive-nudge renderer
#
# Reads the current Review Gate table for a story (via review-gate.sh status)
# and prints the V1 three-part progressive nudge block:
#
#   Part 1 — Gate Status table (Markdown, 6 canonical rows in V1 order)
#   Part 2 — Overall classification line:
#              ALL PASSED | N FAILED | M UNVERIFIED
#   Part 3 — Suggested-next branch:
#              ALL PASSED        → /gaia-check-review-gate {key}
#                                   /gaia-check-dod {key}
#              ANY FAILED        → list failed gates +
#                                   /gaia-correct-course {key}
#              UNVERIFIED-only   → per-gate commands from canonical map
#              MIXED             → FAILED branch wins +
#                                   `Also unrun:` line for UNVERIFIED rows
#
# Output is wrapped in `--- Review Gate Nudge ---` fences (start + end) so
# downstream tooling and humans scanning a transcript can delimit the block
# from surrounding orchestrator output.
#
# Anchor notes: scripts-over-LLM policy; review-gate.sh ledger +
#              canonical PASSED/FAILED/UNVERIFIED vocabulary;
#              review-gate-check composite operation.
#
# Invocation contract:
#
#   review-nudge.sh --story <key>
#   review-nudge.sh --help
#
# Advisory-only contract:
#   Exit 0 unconditionally on every gate state — including malformed /
#   unreadable / story-not-found. The block is informational; halting belongs
#   to /gaia-dev-story Step 15, not the nudge block. The single exception is
#   the story-key regex check: a non-canonical story key is rejected with a
#   non-zero exit BEFORE any read so a metachar-laden key cannot trigger any
#   side effect.
#
# Read-only guarantee:
#   This script never writes to the story file, never creates tempfiles or
#   sidecar scratch files, and never mutates sprint-status.yaml. It only
#   shells out to review-gate.sh status (a read-only sub-operation).
#
# Static gate→command map (canonical, drift-detected by bats):
#   Code Review        → /gaia-code-review
#   QA Tests           → /gaia-qa-tests
#   Security Review    → /gaia-security-review
#   Test Automation    → /gaia-test-automate
#   Test Review        → /gaia-test-review
#   Performance Review → /gaia-review-perf
#
# POSIX discipline: macOS /bin/bash 3.2 compatible. Uses jq (for review-gate.sh
# status JSON parsing) and printf / grep. No Python, no Node, no curl. Forces
# `LC_ALL=C` regardless of caller environment.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="review-nudge.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

NUDGE_FENCE="--- Review Gate Nudge ---"

# ---------- Canonical vocabulary ----------

# Six canonical gate names in V1 row order. This order is locked by
# review-summary-gen.sh and the story template's Review Gate table; drift
# here desyncs the nudge from the summary file.
CANONICAL_GATES=(
  "Code Review"
  "QA Tests"
  "Security Review"
  "Test Automation"
  "Test Review"
  "Performance Review"
)

# Canonical verdict regex (review-gate.sh, exact case). Anything outside this
# set is treated as malformed → advisory fallback.
CANONICAL_VERDICTS_REGEX='^(PASSED|FAILED|UNVERIFIED)$'

# Story-key regex (shell-safety). Canonical production form is
# `E<digits>-S<digits>`. We additionally allow simple alphanumeric / dash
# identifiers used by sibling tests — these are safe identifiers (letters,
# digits, dash) and contain no shell metacharacters.
#
# The regex rejects shell metacharacters ($, (, ), `, ;, &, |, space, *, ?,
# >, <, ", ', \, !, etc.) before any read so a metachar-laden key cannot
# trigger any side effect.
STORY_KEY_REGEX='^[A-Za-z0-9][A-Za-z0-9-]*$'

# ---------- Helpers ----------

usage() {
  cat <<'USAGE'
Usage:
  review-nudge.sh --story <key>
  review-nudge.sh --help

Reads the current Review Gate table for <key> via review-gate.sh status and
prints the V1 three-part progressive nudge block (Gate Status table, Overall
classification, Suggested-next command branched on outcome).

Output is wrapped in `--- Review Gate Nudge ---` fences. Exit 0 always —
malformed gate state falls back to a single advisory line within the fences.
The ONE exception is a malformed story key (regex `^E[0-9]+-S[0-9]+$`),
which exits non-zero before any read.

Advisory-only: this script never halts a /gaia-run-all-reviews invocation.

Exit codes:
  0 — block emitted (or advisory fallback emitted)
  2 — invalid story key (regex check failed; no side effects)
USAGE
}

_die_usage() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  printf 'Usage: %s --story <key>\n' "$SCRIPT_NAME" >&2
  exit 2
}

# Map a canonical gate name to its per-gate slash command. Used by the
# UNVERIFIED-only and MIXED branches. Keep in sync with the story-spec map.
_gate_to_command() {
  local gate="$1"
  case "$gate" in
    "Code Review")        printf '/gaia-code-review' ;;
    "QA Tests")           printf '/gaia-qa-tests' ;;
    "Security Review")    printf '/gaia-security-review' ;;
    "Test Automation")    printf '/gaia-test-automate' ;;
    "Test Review")        printf '/gaia-test-review' ;;
    "Performance Review") printf '/gaia-review-perf' ;;
    *)                    printf '' ;;
  esac
}

# Emit the advisory-fallback block (used when gate state is unreadable). Always
# exits 0 from main() after this is printed.
_emit_fallback() {
  printf '%s\n' "$NUDGE_FENCE"
  printf 'gate state unreadable, see story file directly\n'
  printf '%s\n' "$NUDGE_FENCE"
}

# ---------- Argument parsing ----------

STORY_KEY=""

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

  # AC-EC2: reject shell-metachar / malformed keys BEFORE any read. This is
  # the single non-zero-exit path; everything past this point exits 0.
  if ! printf '%s' "$STORY_KEY" | grep -Eq "$STORY_KEY_REGEX"; then
    printf '%s: invalid story key: %s (must match %s)\n' \
      "$SCRIPT_NAME" "$STORY_KEY" "$STORY_KEY_REGEX" >&2
    exit 2
  fi
}

# ---------- Main ----------

REVIEW_GATE="${REVIEW_GATE_SCRIPT:-$SCRIPT_DIR/review-gate.sh}"

main() {
  parse_args "$@"

  # ---- Read current gate state via review-gate.sh status ----
  local status_json status_rc=0

  set +e
  status_json="$("$REVIEW_GATE" status --story "$STORY_KEY" 2>/dev/null)"
  status_rc=$?
  set -e

  if [ "$status_rc" -ne 0 ]; then
    _emit_fallback
    exit 0
  fi

  # Validate JSON shape: must contain a .gates object.
  if ! printf '%s' "$status_json" | jq -e '.gates' >/dev/null 2>&1; then
    _emit_fallback
    exit 0
  fi

  # ---- Iterate canonical gate order; collect verdicts ----
  local -a verdicts=()
  local gate verdict
  for gate in "${CANONICAL_GATES[@]}"; do
    verdict="$(printf '%s' "$status_json" | jq -r --arg g "$gate" '.gates[$g] // empty')"
    if [ -z "$verdict" ] || [[ ! "$verdict" =~ $CANONICAL_VERDICTS_REGEX ]]; then
      _emit_fallback
      exit 0
    fi
    verdicts+=("$verdict")
  done

  # ---- Classify ----
  local n_failed=0 n_unverified=0
  local i
  for i in "${!verdicts[@]}"; do
    case "${verdicts[$i]}" in
      FAILED)     n_failed=$((n_failed + 1)) ;;
      UNVERIFIED) n_unverified=$((n_unverified + 1)) ;;
    esac
  done

  # ---- Render fences + Part 1 (Gate Status table) ----
  printf '%s\n' "$NUDGE_FENCE"
  printf '\n'
  printf '| Gate | Verdict | Report |\n'
  printf '|------|---------|--------|\n'
  for i in "${!CANONICAL_GATES[@]}"; do
    printf '| %s | %s | — |\n' "${CANONICAL_GATES[$i]}" "${verdicts[$i]}"
  done
  printf '\n'

  # ---- Part 2: Overall classification line ----
  if [ "$n_failed" -eq 0 ] && [ "$n_unverified" -eq 0 ]; then
    printf 'Overall: ALL PASSED\n'
  elif [ "$n_failed" -gt 0 ]; then
    printf 'Overall: %d FAILED\n' "$n_failed"
  else
    printf 'Overall: %d UNVERIFIED\n' "$n_unverified"
  fi
  printf '\n'

  # ---- Part 3: Suggested-next branch ----
  if [ "$n_failed" -eq 0 ] && [ "$n_unverified" -eq 0 ]; then
    # ALL PASSED branch
    printf 'Suggested next: /gaia-check-review-gate %s\n' "$STORY_KEY"
    printf '/gaia-check-dod %s\n' "$STORY_KEY"
  elif [ "$n_failed" -gt 0 ]; then
    # ANY FAILED branch (FAILED dominates over UNVERIFIED).
    # Each failed-row line starts with "- FAILED: " so downstream parsers
    # can grep for `^[[:space:]]*-?[[:space:]]*FAILED` to count failed rows.
    printf 'Failed gates:\n'
    for i in "${!verdicts[@]}"; do
      if [ "${verdicts[$i]}" = "FAILED" ]; then
        printf '  - FAILED: %s\n' "${CANONICAL_GATES[$i]}"
      fi
    done
    printf 'Suggested next: /gaia-correct-course %s\n' "$STORY_KEY"

    # MIXED state: also enumerate UNVERIFIED rows and append a single-line
    # `Also unrun:` summary listing the per-gate commands.
    if [ "$n_unverified" -gt 0 ]; then
      printf 'Unrun gates:\n'
      local -a unrun_cmds=()
      for i in "${!verdicts[@]}"; do
        if [ "${verdicts[$i]}" = "UNVERIFIED" ]; then
          printf '  - UNVERIFIED: %s → %s\n' \
            "${CANONICAL_GATES[$i]}" \
            "$(_gate_to_command "${CANONICAL_GATES[$i]}")"
          unrun_cmds+=("$(_gate_to_command "${CANONICAL_GATES[$i]}")")
        fi
      done
      # Render as comma-separated command list on a single line.
      local IFS_save="$IFS"
      IFS=", "
      printf 'Also unrun: %s\n' "${unrun_cmds[*]}"
      IFS="$IFS_save"
    fi
  else
    # UNVERIFIED-only branch — per-gate commands from canonical map.
    # Each unrun-row line starts with "- UNVERIFIED: " so downstream parsers
    # can count UNVERIFIED rows symmetrically with the FAILED branch above.
    printf 'Unrun gates:\n'
    for i in "${!verdicts[@]}"; do
      if [ "${verdicts[$i]}" = "UNVERIFIED" ]; then
        printf '  - UNVERIFIED: %s → %s\n' \
          "${CANONICAL_GATES[$i]}" \
          "$(_gate_to_command "${CANONICAL_GATES[$i]}")"
      fi
    done
  fi

  # ---- Closing fence ----
  printf '\n'
  printf '%s\n' "$NUDGE_FENCE"
}

main "$@"
