#!/usr/bin/env bash
# compose-verdict.sh — composite verdict reducer for /gaia-sprint-review (E93-S3)
#
# Pure deterministic reducer that combines Track A + Track B verdicts
# into the canonical composite verdict per NFR-070 and ADR-108 D2.
#
# Reduction rules:
#   - PASSED iff BOTH tracks PASSED (Track B SKIPPED counts as PASSED-
#     equivalent on the E93-S3 stub path — only on the stub; once E93-S4
#     ships the real runner, SKIPPED on Track B can ONLY arise from D6
#     UNVERIFIED-bypass-eligible sprints).
#   - FAILED if EITHER track FAILED.
#   - UNVERIFIED if EITHER track UNVERIFIED and neither FAILED.
#   - PASSED also when Track A is PARTIAL and Track B is PASSED (PARTIAL
#     does not block — per FR-489 AC6 / TC-SGR-26).
#
# Input verdicts: PASSED | FAILED | UNVERIFIED | PARTIAL | SKIPPED
# Output (stdout): exactly one of: PASSED | FAILED | UNVERIFIED
#
# Non-canonical inputs are rejected with canonical stderr per ADR-074 C3.
#
# Usage:
#   compose-verdict.sh --track-a <verdict> --track-b <verdict>
#
# Exit codes:
#   0 — composite verdict emitted on stdout.
#   1 — usage error or non-canonical input.
#
# POSIX discipline: bash with [[ ]] only. LC_ALL=C. macOS /bin/bash 3.2.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-review/compose-verdict.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  compose-verdict.sh --track-a <verdict> --track-b <verdict>

Each <verdict> must be one of: PASSED | FAILED | UNVERIFIED | PARTIAL | SKIPPED.
Stdout: exactly one of PASSED | FAILED | UNVERIFIED.
Non-canonical inputs are rejected with a non-canonical-input error.

Reduction (NFR-070, ADR-108 D2):
  - FAILED if EITHER track is FAILED.
  - UNVERIFIED if EITHER track is UNVERIFIED (and neither FAILED).
  - PASSED otherwise (PASSED, PARTIAL, SKIPPED on either side combine to PASSED).
USAGE
}

# ---------- Arg parse ----------

track_a=""
track_b=""
while [ $# -gt 0 ]; do
  case "$1" in
    --track-a)      [ $# -ge 2 ] || die "--track-a requires an argument"
                    track_a="$2"; shift 2 ;;
    --track-a=*)    track_a="${1#--track-a=}"; shift ;;
    --track-b)      [ $# -ge 2 ] || die "--track-b requires an argument"
                    track_b="$2"; shift 2 ;;
    --track-b=*)    track_b="${1#--track-b=}"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown flag: $1" ;;
  esac
done

[ -n "$track_a" ] || { usage; die "--track-a is required"; }
[ -n "$track_b" ] || { usage; die "--track-b is required"; }

# ---------- Input validation ----------

is_canonical() {
  case "$1" in
    PASSED|FAILED|UNVERIFIED|PARTIAL|SKIPPED) return 0 ;;
    *) return 1 ;;
  esac
}

# AF-2026-05-22-9 Bug-13: Val emits WARNING as a non-blocking verdict per
# ADR-063 ("WARNING is informational; cascade proceeds"). Accept WARNING on
# either track and normalize to PASSED before the reduction so callers do
# not have to hand-map WARNING -> PASSED at each call site.
if [ "$track_a" = "WARNING" ]; then track_a="PASSED"; fi
if [ "$track_b" = "WARNING" ]; then track_b="PASSED"; fi

if ! is_canonical "$track_a"; then
  die "non-canonical track-a verdict: '$track_a' (expected one of: PASSED, FAILED, UNVERIFIED, PARTIAL, SKIPPED, WARNING)"
fi
if ! is_canonical "$track_b"; then
  die "non-canonical track-b verdict: '$track_b' (expected one of: PASSED, FAILED, UNVERIFIED, PARTIAL, SKIPPED, WARNING)"
fi

# ---------- Reduction ----------

# FAILED dominates.
if [ "$track_a" = "FAILED" ] || [ "$track_b" = "FAILED" ]; then
  printf 'FAILED\n'
  exit 0
fi

# UNVERIFIED dominates over PASSED/PARTIAL/SKIPPED.
if [ "$track_a" = "UNVERIFIED" ] || [ "$track_b" = "UNVERIFIED" ]; then
  printf 'UNVERIFIED\n'
  exit 0
fi

# Otherwise PASSED — PARTIAL + SKIPPED both fold into PASSED equivalents.
printf 'PASSED\n'
exit 0
