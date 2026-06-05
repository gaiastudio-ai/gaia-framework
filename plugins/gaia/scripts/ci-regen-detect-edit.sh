#!/usr/bin/env bash
# ci-regen-detect-edit.sh — manual-edit detection for /gaia-config-ci --regenerate.
#
# Reads a generated CI workflow file and decides whether it has been hand-edited
# since generation. The decision compares the body hash (everything after the
# four-line header) against the Source-hash recorded in the header.
#
# Exit codes:
#   0  — clean (body hash matches header hash)
#   1  — manually edited (body hash does NOT match header hash)
#   2  — no header / no Source-hash line (treated as "stale" by callers)
#

set -euo pipefail
LC_ALL=C
export LC_ALL

target="${1:-}"
if [ -z "$target" ] || [ ! -f "$target" ]; then
  echo "ci-regen-detect-edit.sh: file not found: $target" >&2
  exit 2
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HEADER_LIB="$SELF_DIR/lib/ci-regen-header.sh"

# Extract the recorded header hash. parse exits 2 when no header is present.
expected="$(bash "$HEADER_LIB" parse "$target" 2>/dev/null || true)"
if [ -z "$expected" ]; then
  exit 2
fi

# Compute body hash: strip every leading line that starts with `# ` so the
# header is excluded but in-body comments authored by users / generators are
# preserved as part of the body. The header is contiguous at the top.
body_hash="$(awk 'NR==1 && /^# / {in_hdr=1} in_hdr && /^# / {next} {in_hdr=0; print}' "$target" \
  | bash "$HEADER_LIB" hash)"

if [ "$expected" = "$body_hash" ]; then
  exit 0
fi
exit 1
