#!/usr/bin/env bash
# write-evidence.sh — persist manual-test evidence artifacts
#
# Usage:
#   echo "<run-record content>" | write-evidence.sh <evidence-dir> <verdict>
#   write-evidence.sh <evidence-dir> <verdict> --verify
#
# Mode 1 (write): reads run-record content from stdin, writes run-record.md
#   and exit-code.log to the evidence directory. Fails if stdin is empty.
#
# Mode 2 (--verify): checks that both run-record.md and exit-code.log exist
#   and are non-empty in the evidence directory. If verdict is PASSED but
#   either file is missing or empty, downgrades to UNVERIFIED and exits 1.
#
# Arguments:
#   <evidence-dir>  directory for evidence artifacts (created if absent)
#   <verdict>       PASSED | FAILED | UNVERIFIED
#   --verify        run proof-of-execution gate check instead of writing
#
# Exit codes:
#   0 — success (write completed, or verify passed)
#   1 — empty stdin (write mode), or evidence missing/empty (verify mode)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="write-evidence.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

[ $# -ge 2 ] || die "usage: $SCRIPT_NAME <evidence-dir> <verdict> [--verify]"

EVIDENCE_DIR="$1"
VERDICT="$2"
VERIFY_MODE=0
if [ "${3:-}" = "--verify" ]; then
  VERIFY_MODE=1
fi

RUN_RECORD="$EVIDENCE_DIR/run-record.md"
EXIT_CODE_LOG="$EVIDENCE_DIR/exit-code.log"

# ---------- Verify mode ----------
if [ "$VERIFY_MODE" -eq 1 ]; then
  missing=""
  if [ ! -s "$RUN_RECORD" ]; then
    missing="run-record.md"
  fi
  if [ ! -s "$EXIT_CODE_LOG" ]; then
    if [ -n "$missing" ]; then
      missing="$missing + exit-code.log"
    else
      missing="exit-code.log"
    fi
  fi

  if [ -n "$missing" ]; then
    if [ "$VERDICT" = "PASSED" ]; then
      log "proof-of-execution gate: $missing missing or empty — downgrading PASSED to UNVERIFIED"
      printf 'UNVERIFIED\n'
      exit 1
    else
      log "proof-of-execution gate: $missing missing or empty (verdict already $VERDICT)"
      printf '%s\n' "$VERDICT"
      exit 1
    fi
  fi

  log "proof-of-execution gate: both evidence files present and non-empty"
  printf '%s\n' "$VERDICT"
  exit 0
fi

# ---------- Write mode ----------
# Read run-record content from stdin.
content=""
content="$(cat)"

if [ -z "$content" ]; then
  die "stdin is empty — cannot write an empty run-record"
fi

# Create the evidence directory.
mkdir -p "$EVIDENCE_DIR"

# Write run-record.md.
printf '%s\n' "$content" > "$RUN_RECORD"

# Write exit-code.log with a timestamp and the verdict.
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s 0 manual-test-run\nVERDICT: %s\n' "$timestamp" "$VERDICT" > "$EXIT_CODE_LOG"

log "evidence written to $EVIDENCE_DIR"
exit 0
