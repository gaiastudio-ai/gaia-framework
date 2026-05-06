#!/usr/bin/env bash
# dispatch-dynamic-test.sh — E74-S9 / AC3, AC7
#
# Resolves a mobile dynamic adapter manifest, executes the underlying test
# runner, then emits a structured JSON report on stdout containing:
#   adapter, exit_code, test_count, pass_count, fail_count, duration_ms
#
# Usage:
#   dispatch-dynamic-test.sh --adapter <name> --suite <path> [--manifest-dir <dir>]
#
# Exit codes:
#   0 — dispatched and reported (regardless of test result; see exit_code in JSON)
#   1 — bad arguments
#   2 — adapter manifest not found

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="dispatch-dynamic-test.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

ADAPTER=""
SUITE=""
MANIFEST_DIR="$SCRIPT_DIR/../config/adapters/dynamic"

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter)      ADAPTER="$2"; shift 2 ;;
    --suite)        SUITE="$2"; shift 2 ;;
    --manifest-dir) MANIFEST_DIR="$2"; shift 2 ;;
    -h|--help)      sed -n '1,18p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" 1 ;;
  esac
done

[ -n "$ADAPTER" ] || die "--adapter required" 1
[ -n "$SUITE" ]   || die "--suite required" 1

MANIFEST="$MANIFEST_DIR/$ADAPTER.yaml"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST" 2

# Minimal POSIX-shell YAML reader: extract `key: value` pairs at top level.
# Adequate for the flat manifest schema defined in E74-S9.
yaml_get() {
  local file="$1" key="$2"
  awk -v k="$key" '
    $0 ~ "^"k":[[:space:]]" {
      sub("^"k":[[:space:]]+", "");
      gsub(/^"|"$/, "");
      print; exit
    }' "$file"
}

BINARY="$(yaml_get "$MANIFEST" "binary")"
[ -n "$BINARY" ] || die "manifest missing 'binary': $MANIFEST" 2

# Construct invocation command. Honor a shell-style 'binary' value (e.g.,
# "npx detox", "./gradlew connectedAndroidTest"). The suite path is appended
# as an opaque argument the test runner can interpret.
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"

set +e
# shellcheck disable=SC2086  # intentional word-splitting on $BINARY
$BINARY "$SUITE" >/dev/null 2>&1
EXIT_CODE=$?
set -e

END_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
DURATION_MS=$(( END_MS - START_MS ))

# In a real run, the test runner emits its native output (junit-xml/json/xcresult)
# and normalize-adapter-output.sh is invoked to summarise. For dispatch-level
# reporting we synthesize counts from the runner's exit code: 0 = all pass,
# non-zero = at least one failure. Real consumers should also call normalize-
# adapter-output.sh against the runner's emitted artifact for per-test detail.
if [ "$EXIT_CODE" -eq 0 ]; then
  TEST_COUNT=1; PASS_COUNT=1; FAIL_COUNT=0
else
  TEST_COUNT=1; PASS_COUNT=0; FAIL_COUNT=1
fi

# Emit canonical dispatch JSON.
jq -nc \
  --arg adapter "$ADAPTER" \
  --argjson exit_code "$EXIT_CODE" \
  --argjson test_count "$TEST_COUNT" \
  --argjson pass_count "$PASS_COUNT" \
  --argjson fail_count "$FAIL_COUNT" \
  --argjson duration_ms "$DURATION_MS" \
  '{adapter:$adapter, exit_code:$exit_code, test_count:$test_count, pass_count:$pass_count, fail_count:$fail_count, duration_ms:$duration_ms}'
