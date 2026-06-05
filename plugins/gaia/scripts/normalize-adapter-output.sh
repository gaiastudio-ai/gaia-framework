#!/usr/bin/env bash
# normalize-adapter-output.sh — adapter output normalizer
#
# Reads framework-native test output (JUnit XML, JSON, xcresult) and emits the
# canonical schemas/adapter-output.schema.json shape on stdout.
#
# Usage:
#   normalize-adapter-output.sh --adapter <name> --format <fmt> --input <path>
#
# Supported --format values: junit-xml, json, xcresult
#
# Exit codes:
#   0 — normalization succeeded
#   1 — bad arguments or unsupported format
#   2 — input file missing or unreadable
#   3 — parse error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="normalize-adapter-output.sh"

# Internal helpers — leading underscore prefix excludes them from the
# public-function coverage gate. They are exercised end-to-end
# via the public entry point in tests/E74-S9-mobile-dynamic-adapters.bats:
#   _normalize_junit_xml — covered by junit-xml test
#   _normalize_json      — covered by maestro json test
#   _normalize_xcresult  — covered by xcresult-format input branch (delegates to jq)

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

ADAPTER=""
FORMAT=""
INPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter) ADAPTER="$2"; shift 2 ;;
    --format)  FORMAT="$2";  shift 2 ;;
    --input)   INPUT="$2";   shift 2 ;;
    -h|--help) sed -n '1,18p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" 1 ;;
  esac
done

[ -n "$ADAPTER" ] || die "--adapter required" 1
[ -n "$FORMAT" ]  || die "--format required" 1
[ -n "$INPUT" ]   || die "--input required" 1
[ -f "$INPUT" ]   || die "input not found: $INPUT" 2

# Map adapter name -> canonical platform string. Mirrors the dynamic manifests.
case "$ADAPTER" in
  detox|maestro|appium) PLATFORM="cross-platform" ;;
  xcuitest)             PLATFORM="ios" ;;
  espresso)             PLATFORM="android" ;;
  *)                    PLATFORM="cross-platform" ;;
esac

_normalize_junit_xml() {
  local file="$1"
  command -v python3 >/dev/null 2>&1 || die "python3 required for junit-xml" 3

  python3 - "$file" "$ADAPTER" "$PLATFORM" <<'PY'
import sys, json, xml.etree.ElementTree as ET

path, adapter, platform = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    tree = ET.parse(path)
except ET.ParseError as e:
    print(f"junit parse error: {e}", file=sys.stderr); sys.exit(3)

root = tree.getroot()
suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")

total = passed = failed = skipped = 0
duration_ms = 0
test_results = []
exit_code = 0

for suite in suites:
    s_time = float(suite.attrib.get("time", "0") or 0)
    duration_ms += int(s_time * 1000)
    for case in suite.findall("testcase"):
        total += 1
        c_time = float(case.attrib.get("time", "0") or 0)
        c_dur_ms = int(c_time * 1000)
        name = case.attrib.get("name", "")
        failure = case.find("failure")
        error = case.find("error")
        skipped_el = case.find("skipped")
        if failure is not None:
            status, err = "fail", (failure.attrib.get("message") or (failure.text or "").strip() or "failure")
            failed += 1
            exit_code = 1
        elif error is not None:
            status, err = "error", (error.attrib.get("message") or (error.text or "").strip() or "error")
            failed += 1
            exit_code = 1
        elif skipped_el is not None:
            status, err = "skip", None
            skipped += 1
        else:
            status, err = "pass", None
            passed += 1
        test_results.append({
            "name": name,
            "status": status,
            "duration_ms": c_dur_ms,
            "error_message": err,
        })

out = {
    "adapter": adapter,
    "framework": adapter,
    "platform": platform,
    "exit_code": exit_code,
    "summary": {"total": total, "passed": passed, "failed": failed, "skipped": skipped},
    "duration_ms": duration_ms,
    "test_results": test_results,
}
print(json.dumps(out))
PY
}

_normalize_json() {
  local file="$1"
  command -v jq >/dev/null 2>&1 || die "jq required for json" 3

  # Maestro-style JSON: { "tests": [{name, status, duration_ms, error?}, ...] }
  # Status values pass/passed/fail/failed/skipped/error are normalized.
  jq --arg adapter "$ADAPTER" --arg platform "$PLATFORM" '
    def norm_status(s):
      if s == "passed" or s == "pass" then "pass"
      elif s == "failed" or s == "fail" then "fail"
      elif s == "skipped" or s == "skip" then "skip"
      elif s == "error" then "error"
      else "fail" end;

    (.tests // []) as $t
    | ($t | map(.duration_ms // 0) | add // 0) as $duration
    | {
        adapter: $adapter,
        framework: $adapter,
        platform: $platform,
        exit_code: (if ($t | map(select(norm_status(.status) == "fail" or norm_status(.status) == "error")) | length) > 0 then 1 else 0 end),
        summary: {
          total:   ($t | length),
          passed:  ($t | map(select(norm_status(.status) == "pass")) | length),
          failed:  ($t | map(select(norm_status(.status) == "fail" or norm_status(.status) == "error")) | length),
          skipped: ($t | map(select(norm_status(.status) == "skip")) | length)
        },
        duration_ms: $duration,
        test_results: ($t | map({
          name: (.name // ""),
          status: norm_status(.status),
          duration_ms: (.duration_ms // 0),
          error_message: (.error // null)
        }))
      }
  ' "$file" -c
}

_normalize_xcresult() {
  local file="$1"
  # xcresult is an Apple bundle; full parse requires `xcrun xcresulttool`. For
  # portability, accept either:
  #   - a JSON file already extracted via `xcrun xcresulttool get --format json`
  #   - a directory containing such a JSON
  # If the input is a JSON file, delegate to the json normalizer with an xcresult
  # status mapping.
  command -v jq >/dev/null 2>&1 || die "jq required for xcresult" 3

  local json_file="$file"
  if [ -d "$file" ]; then
    if command -v xcrun >/dev/null 2>&1; then
      json_file="$(mktemp)"
      xcrun xcresulttool get --format json --path "$file" >"$json_file" 2>/dev/null \
        || die "xcresulttool failed on $file" 3
    else
      die "xcresult directory requires xcrun (Xcode CLT)" 3
    fi
  fi

  # Reuse the JSON normalizer; the input shape is the same {tests:[...]} contract
  # the user's xcresult-extraction tool would emit. xcresult-native bundles can
  # be extracted by the caller before invoking the adapter.
  jq --arg adapter "$ADAPTER" --arg platform "$PLATFORM" '
    def norm_status(s):
      if s == "passed" or s == "pass" or s == "Success" then "pass"
      elif s == "failed" or s == "fail" or s == "Failure" then "fail"
      elif s == "skipped" or s == "skip" then "skip"
      else "fail" end;
    (.tests // []) as $t
    | ($t | map(.duration_ms // 0) | add // 0) as $duration
    | {
        adapter: $adapter,
        framework: $adapter,
        platform: $platform,
        exit_code: (if ($t | map(select(norm_status(.status) == "fail")) | length) > 0 then 1 else 0 end),
        summary: {
          total:   ($t | length),
          passed:  ($t | map(select(norm_status(.status) == "pass")) | length),
          failed:  ($t | map(select(norm_status(.status) == "fail")) | length),
          skipped: ($t | map(select(norm_status(.status) == "skip")) | length)
        },
        duration_ms: $duration,
        test_results: ($t | map({
          name: (.name // ""),
          status: norm_status(.status),
          duration_ms: (.duration_ms // 0),
          error_message: (.error // null)
        }))
      }
  ' "$json_file" -c
}

case "$FORMAT" in
  junit-xml) _normalize_junit_xml "$INPUT" ;;
  json)      _normalize_json "$INPUT" ;;
  xcresult)  _normalize_xcresult "$INPUT" ;;
  *) die "unsupported format: $FORMAT (expected junit-xml|json|xcresult)" 1 ;;
esac
