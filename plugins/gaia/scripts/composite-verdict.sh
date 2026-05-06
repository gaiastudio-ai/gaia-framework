#!/usr/bin/env bash
# composite-verdict.sh — E74-S10 / AC4.
#
# Reads a JSON array of per-device results (each with a `verdict` field of
# PASSED | FAILED | ERROR | TIMEOUT) and emits a single JSON object with the
# composite verdict plus per-bucket counts.
#
# Priority (highest wins): FAILED > ERROR > TIMEOUT > PASSED
#
# This helper is shared by /gaia-test-mobile-e2e and /gaia-test-device-matrix.
#
# Usage: composite-verdict.sh --results <path-to-json-array>
#
# Exit codes:
#   0 — composite verdict emitted on stdout
#   1 — bad arguments / unreadable input

set -euo pipefail
LC_ALL=C; export LC_ALL

RESULTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --results) RESULTS="$2"; shift 2 ;;
    -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
    *) printf 'composite-verdict.sh: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$RESULTS" ] || { printf 'composite-verdict.sh: --results required\n' >&2; exit 1; }
[ -f "$RESULTS" ] || { printf 'composite-verdict.sh: results file not found: %s\n' "$RESULTS" >&2; exit 1; }

python3 - "$RESULTS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
counts = {"PASSED": 0, "FAILED": 0, "ERROR": 0, "TIMEOUT": 0}
for entry in data:
    v = entry.get("verdict", "").upper()
    if v in counts:
        counts[v] += 1
# Priority: FAILED > ERROR > TIMEOUT > PASSED
if counts["FAILED"] > 0:
    composite = "FAILED"
elif counts["ERROR"] > 0:
    composite = "ERROR"
elif counts["TIMEOUT"] > 0:
    composite = "TIMEOUT"
else:
    composite = "PASSED"
out = {
    "verdict": composite,
    "passed_count":  counts["PASSED"],
    "failed_count":  counts["FAILED"],
    "error_count":   counts["ERROR"],
    "timeout_count": counts["TIMEOUT"],
}
print(json.dumps(out))
PY
