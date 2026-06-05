#!/usr/bin/env bash
# secret-scrubber.sh — gaia-meeting secret-pattern scrubber
#
# Single source of truth for the regex set used by the pre-CLOSE checkpoint
# yield. Reads an input file, writes a scrubbed copy with sensitive patterns
# replaced by the literal token `REDACTED-{KIND}`.
#
# Patterns covered:
#   - AWS access key id            (AKIA[0-9A-Z]{16})
#   - GitHub personal access token (ghp_[A-Za-z0-9]{30,})
#   - GitHub app token             (ghs_[A-Za-z0-9]{30,})
#   - GitHub OAuth token           (gho_[A-Za-z0-9]{30,})
#   - PEM private-key headers      (-----BEGIN [^-]+ PRIVATE KEY-----)
#   - api_key / api-key / token / secret assignments to long opaque strings
#
# Usage:
#   secret-scrubber.sh --in <input-path> --out <output-path>
#
# Exit codes:
#   0 = success
#   2 = malformed args / missing input

set -euo pipefail

IN=""
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)    IN="${2-}"; shift 2 ;;
    --in=*)  IN="${1#--in=}"; shift ;;
    --out)   OUT="${2-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    *)
      echo "secret-scrubber.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$IN" || -z "$OUT" ]]; then
  echo "secret-scrubber.sh: --in and --out are required" >&2
  exit 2
fi
if [[ ! -f "$IN" ]]; then
  echo "secret-scrubber.sh: input file not found: $IN" >&2
  exit 2
fi

# Use sed with extended regex (-E) for portability across BSD and GNU.
sed -E \
  -e 's/AKIA[0-9A-Z]{16}/REDACTED-AWS-KEY/g' \
  -e 's/(ghp|ghs|gho|ghu)_[A-Za-z0-9]{30,}/REDACTED-GITHUB-TOKEN/g' \
  -e 's/-----BEGIN [^-]+ PRIVATE KEY-----/REDACTED-PRIVATE-KEY-HEADER/g' \
  -e 's/-----END [^-]+ PRIVATE KEY-----/REDACTED-PRIVATE-KEY-FOOTER/g' \
  -e 's/(api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9_+\/=.-]{20,}"?/\1=REDACTED-OPAQUE-SECRET/Ig' \
  "$IN" > "$OUT"

exit 0
