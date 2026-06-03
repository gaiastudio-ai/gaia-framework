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
# Downcast bookkeeping (E87-S9 / AF-2026-06-03-2 / ADR-130 / NFR-95):
#   When the INPUT track-a or track-b verdict is one of the coercible
#   synonyms {WARNING, PASS, CRITICAL}, the synonym-mapping path below
#   downcasts it (WARNING/PASS -> PASSED, CRITICAL -> FAILED) before the
#   reduction. That coercion silently collapses telemetry-relevant
#   provenance: a composite PASSED renders identically whether Val emitted
#   PASS directly or WARNING with non-blocking findings. To preserve
#   provenance WITHOUT changing the reduced verdict, the script captures the
#   pre-coercion value(s) and, when `--with-provenance` is passed, emits an
#   additive second stdout line:
#       original_status=track_a=<raw>[,track_b=<raw>]
#   The line is absent when no track was coerced. The DEFAULT invocation
#   (flag absent) is byte-identical to the pre-S9 single-line contract, so
#   the `COMPOSITE=$(...)` consumer contract and every existing
#   `[ "$output" = "..." ]` assertion are preserved (NFR-95: additive,
#   absent-when-not-coerced, never required).
#
# Usage:
#   compose-verdict.sh --track-a <verdict> --track-b <verdict> [--with-provenance]
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
  compose-verdict.sh --track-a <verdict> --track-b <verdict> [--with-provenance]

Each <verdict> must be one of: PASSED | FAILED | UNVERIFIED | PARTIAL | SKIPPED
(the synonyms WARNING, PASS, CRITICAL are also accepted and coerced).
Stdout: exactly one of PASSED | FAILED | UNVERIFIED.
Non-canonical inputs are rejected with a non-canonical-input error.

Reduction (NFR-070, ADR-108 D2):
  - FAILED if EITHER track is FAILED.
  - UNVERIFIED if EITHER track is UNVERIFIED (and neither FAILED).
  - PASSED otherwise (PASSED, PARTIAL, SKIPPED on either side combine to PASSED).

--with-provenance (E87-S9, ADR-130, NFR-95):
  When set AND either track's INPUT was a coercible synonym (WARNING, PASS,
  CRITICAL), append an additive second stdout line capturing the
  pre-coercion value(s):
      original_status=track_a=<raw>[,track_b=<raw>]
  Absent when no track was coerced. The verdict line is unaffected.
USAGE
}

# ---------- Arg parse ----------

track_a=""
track_b=""
with_provenance=0
while [ $# -gt 0 ]; do
  case "$1" in
    --track-a)         [ $# -ge 2 ] || die "--track-a requires an argument"
                       track_a="$2"; shift 2 ;;
    --track-a=*)       track_a="${1#--track-a=}"; shift ;;
    --track-b)         [ $# -ge 2 ] || die "--track-b requires an argument"
                       track_b="$2"; shift 2 ;;
    --track-b=*)       track_b="${1#--track-b=}"; shift ;;
    --with-provenance) with_provenance=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown flag: $1" ;;
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

# E87-S9 / AF-2026-06-03-2 / ADR-130 / NFR-95: capture the RAW pre-coercion
# track values BEFORE the synonym-mapping reassignments below. A track is
# "coerced" iff its raw value is one of the coercible synonyms {WARNING, PASS,
# CRITICAL}. The provenance line (emitted only under --with-provenance) records
# those raw values so downstream consumers can recover the pre-coercion outer
# status; the reduced verdict itself is UNCHANGED by this bookkeeping.
raw_track_a="$track_a"
raw_track_b="$track_b"

is_coercible() {
  case "$1" in
    WARNING|PASS|CRITICAL) return 0 ;;
    *) return 1 ;;
  esac
}

original_status=""
if is_coercible "$raw_track_a"; then
  original_status="track_a=${raw_track_a}"
fi
if is_coercible "$raw_track_b"; then
  if [ -n "$original_status" ]; then
    original_status="${original_status},track_b=${raw_track_b}"
  else
    original_status="track_b=${raw_track_b}"
  fi
fi

# emit_verdict <composite> — print the composite verdict, then (only under
# --with-provenance, and only when a track was coerced) the additive
# original_status provenance line. Keeps the default single-line contract.
emit_verdict() {
  printf '%s\n' "$1"
  if [ "$with_provenance" -eq 1 ] && [ -n "$original_status" ]; then
    printf 'original_status=%s\n' "$original_status"
  fi
}

# AF-2026-05-22-9 Bug-13: Val emits WARNING as a non-blocking verdict per
# ADR-063 ("WARNING is informational; cascade proceeds"). Accept WARNING on
# either track and normalize to PASSED before the reduction so callers do
# not have to hand-map WARNING -> PASSED at each call site.
if [ "$track_a" = "WARNING" ]; then track_a="PASSED"; fi
if [ "$track_b" = "WARNING" ]; then track_b="PASSED"; fi

# Test17 F-M05 / AF-2026-06-02-6: accept ADR-037 envelope verdicts as
# synonyms for the gate vocabulary. The Val ADR-037 status enum is
# {PASS|WARNING|CRITICAL}; `write-val-sentinel.sh` already accepts both
# {PASS,PASSED} forms, but compose-verdict.sh previously rejected `PASS`
# as non-canonical, forcing operators to hand-translate PASS→PASSED
# between two steps of the same /gaia-sprint-review. Map PASS→PASSED and
# CRITICAL→FAILED at this boundary so the two scripts in the same skill
# share one vocabulary.
if [ "$track_a" = "PASS" ]; then track_a="PASSED"; fi
if [ "$track_b" = "PASS" ]; then track_b="PASSED"; fi
if [ "$track_a" = "CRITICAL" ]; then track_a="FAILED"; fi
if [ "$track_b" = "CRITICAL" ]; then track_b="FAILED"; fi

if ! is_canonical "$track_a"; then
  die "non-canonical track-a verdict: '$track_a' (expected one of: PASS, PASSED, FAILED, UNVERIFIED, PARTIAL, SKIPPED, WARNING, CRITICAL)"
fi
if ! is_canonical "$track_b"; then
  die "non-canonical track-b verdict: '$track_b' (expected one of: PASS, PASSED, FAILED, UNVERIFIED, PARTIAL, SKIPPED, WARNING, CRITICAL)"
fi

# ---------- Reduction ----------

# FAILED dominates.
if [ "$track_a" = "FAILED" ] || [ "$track_b" = "FAILED" ]; then
  emit_verdict 'FAILED'
  exit 0
fi

# UNVERIFIED dominates over PASSED/PARTIAL/SKIPPED.
if [ "$track_a" = "UNVERIFIED" ] || [ "$track_b" = "UNVERIFIED" ]; then
  emit_verdict 'UNVERIFIED'
  exit 0
fi

# Otherwise PASSED — PARTIAL + SKIPPED both fold into PASSED equivalents.
emit_verdict 'PASSED'
exit 0
