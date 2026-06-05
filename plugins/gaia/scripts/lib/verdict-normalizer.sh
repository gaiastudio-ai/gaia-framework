#!/usr/bin/env bash
# verdict-normalizer.sh
# ---------------------------------------------------------------------------
# Normalizes a review subagent's verdict string to the canonical Review Gate
# vocabulary defined in CLAUDE.md:
#
#   canonical = { PASSED, FAILED, UNVERIFIED }
#
# Mapping table:
#   PASSED            -> PASSED
#   FAILED            -> FAILED
#   APPROVE           -> PASSED                     (code-review legacy keyword)
#   REQUEST_CHANGES   -> FAILED                     (code-review legacy keyword)
#   UNVERIFIED        -> UNVERIFIED                 (pass-through only for "never executed")
#   <anything else>   -> FAILED (annotated: "ERROR — non-canonical verdict: <value>")
#
# Usage:
#   verdict-normalizer.sh <verdict>
#   echo "APPROVE" | verdict-normalizer.sh -
#
# Exit code is always 0 on successful invocation; the caller interprets the output.
# ---------------------------------------------------------------------------

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <verdict|->" >&2
  exit 2
fi

input="$1"
if [ "$input" = "-" ]; then
  input="$(cat)"
fi

case "$input" in
  PASSED)          echo "PASSED" ;;
  FAILED)          echo "FAILED" ;;
  APPROVE)         echo "PASSED" ;;
  REQUEST_CHANGES) echo "FAILED" ;;
  UNVERIFIED)      echo "UNVERIFIED" ;;
  *)               echo "FAILED — ERROR — non-canonical verdict: ${input}" ;;
esac
