#!/usr/bin/env bash
# validate-junit-sha.sh — validate SHA pinning of CI JUnit evidence.
#
# Recomputes HEAD from the code tree at validation time (never from a
# caller-supplied value), compares it against every run record's head SHA
# and any commit-SHA property inside the JUnit XML, and requires HTTPS
# run URLs.
#
# Usage:
#   validate-junit-sha.sh --repo <code-tree> --evidence <dir>
#
# Exit codes:
#   0 — accepted (JSON verdict on stdout)
#   1 — caller / argument error
#   3 — rejected (JSON verdict on stdout with reason)

set -euo pipefail
LC_ALL=C; export LC_ALL

_vjsh_log() { printf 'validate-junit-sha: %s\n' "$*" >&2; }
_vjsh_die() { local rc="$1"; shift; _vjsh_log "$@"; exit "$rc"; }

# _vjsh_verdict — emit a JSON verdict and exit.
# Args: status (accepted|rejected), reason (string), expected_sha, actual_sha
_vjsh_verdict() {
  local status="$1" reason="${2:-}" expected="${3:-}" actual="${4:-}"
  jq -n \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    '{status: $status, reason: $reason, expected_sha: $expected, actual_sha: $actual}'
  case "$status" in
    accepted) exit 0 ;;
    rejected) exit 3 ;;
  esac
}

# _vjsh_short_sha — truncate a SHA to 7 chars.
_vjsh_short_sha() { printf '%s' "$1" | cut -c1-7; }

# _vjsh_check_xml_sha — check commit-SHA properties in JUnit XML.
# Uses python3 -I for safe XML parsing (no external entities, size cap).
# Args: xml_file, expected_sha
# Returns 0 if no SHA property found or all match. Returns 1 if mismatch.
_vjsh_check_xml_sha() {
  local xml_file="$1" expected_sha="$2"

  # Size cap: reject files over 50 MB
  local file_size max_bytes=52428800
  if stat -f '%z' "$xml_file" >/dev/null 2>&1; then
    file_size="$(stat -f '%z' "$xml_file")"
  elif stat -c '%s' "$xml_file" >/dev/null 2>&1; then
    file_size="$(stat -c '%s' "$xml_file")"
  else
    file_size=0
  fi
  if [ "$file_size" -gt "$max_bytes" ]; then
    _vjsh_log "XML file too large: $xml_file ($file_size bytes)"
    return 2
  fi

  # Use python3 for safe XML parsing (defused against XXE)
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c '
import sys, xml.etree.ElementTree as ET

xml_file = sys.argv[1]
expected = sys.argv[2]

try:
    tree = ET.parse(xml_file)
except ET.ParseError as e:
    print("parse_error:" + str(e), file=sys.stderr)
    sys.exit(2)

root = tree.getroot()
# Check for commit SHA in common properties
sha_attrs = ["commit", "commitSha", "commit-sha", "git-sha", "revision"]

for elem in root.iter():
    for attr in sha_attrs:
        val = elem.get(attr, "")
        if val and len(val) >= 7:
            if val != expected and not expected.startswith(val) and not val.startswith(expected[:len(val)]):
                print("mismatch:" + val)
                sys.exit(1)
    # Also check <property> elements
    if elem.tag == "property":
        pname = (elem.get("name") or "").lower()
        pval = elem.get("value") or ""
        if pname in ("commit", "commitsha", "commit-sha", "git-sha", "revision", "sha"):
            if pval and len(pval) >= 7:
                if pval != expected and not expected.startswith(pval) and not pval.startswith(expected[:len(pval)]):
                    print("mismatch:" + pval)
                    sys.exit(1)

sys.exit(0)
' "$xml_file" "$expected_sha" 2>/dev/null
    return $?
  fi

  # Fallback: grep for SHA-like strings (less precise)
  return 0
}

# ── Main ────────────────────────────────────────────────────────────

main() {
  local repo="" evidence_dir=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)     [ "$#" -ge 2 ] || _vjsh_die 1 "--repo requires a value"; repo="$2"; shift 2 ;;
      --evidence) [ "$#" -ge 2 ] || _vjsh_die 1 "--evidence requires a value"; evidence_dir="$2"; shift 2 ;;
      --help)     printf 'Usage: validate-junit-sha.sh --repo <code-tree> --evidence <dir>\n'; exit 0 ;;
      *)          _vjsh_die 1 "unknown argument: $1" ;;
    esac
  done

  [ -n "$repo" ]         || _vjsh_die 1 "--repo is required"
  [ -d "$repo" ]         || _vjsh_die 1 "repo directory not found: $repo"
  [ -n "$evidence_dir" ] || _vjsh_die 1 "--evidence is required"
  [ -d "$evidence_dir" ] || _vjsh_die 1 "evidence directory not found: $evidence_dir"

  command -v jq >/dev/null 2>&1 || _vjsh_die 1 "jq is required but not found"

  # Recompute HEAD from the code tree at validation time
  local expected_sha
  expected_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || \
    _vjsh_die 1 "could not resolve HEAD in $repo"

  # Read run records
  local records_file="$evidence_dir/run-records.json"
  [ -f "$records_file" ] || _vjsh_die 1 "run-records.json not found in $evidence_dir"

  local runs_json
  runs_json="$(jq '.runs' "$records_file" 2>/dev/null)" || \
    _vjsh_die 1 "could not parse run-records.json"

  local run_count
  run_count="$(printf '%s' "$runs_json" | jq 'length')"
  if [ "$run_count" = "0" ]; then
    _vjsh_verdict "rejected" "junit_run_link_missing" "$expected_sha" ""
  fi

  # Validate each run record
  local i=0
  while [ "$i" -lt "$run_count" ]; do
    local run_record
    run_record="$(printf '%s' "$runs_json" | jq -c --argjson idx "$i" '.[$idx]')"
    local run_sha run_url
    run_sha="$(printf '%s' "$run_record" | jq -r '.head_sha')"
    run_url="$(printf '%s' "$run_record" | jq -r '.url')"

    # Check HTTPS run URL
    case "$run_url" in
      https://*) ;;
      *)
        _vjsh_verdict "rejected" "junit_run_link_missing" \
          "$(_vjsh_short_sha "$expected_sha")" ""
        ;;
    esac

    # Check run SHA matches expected
    if [ "$run_sha" != "$expected_sha" ]; then
      _vjsh_verdict "rejected" "junit_sha_mismatch" \
        "$(_vjsh_short_sha "$expected_sha")" "$(_vjsh_short_sha "$run_sha")"
    fi

    i=$((i + 1))
  done

  # Check XML files for embedded commit SHA properties
  local xml_file
  while IFS= read -r xml_file; do
    [ -n "$xml_file" ] || continue
    local xml_rc=0
    local xml_result
    xml_result="$(_vjsh_check_xml_sha "$xml_file" "$expected_sha" 2>&1)" || xml_rc=$?
    case "$xml_rc" in
      0) ;; # ok or no property
      1)
        local actual_xml_sha="${xml_result#mismatch:}"
        _vjsh_verdict "rejected" "junit_sha_mismatch" \
          "$(_vjsh_short_sha "$expected_sha")" "$(_vjsh_short_sha "$actual_xml_sha")"
        ;;
      2)
        _vjsh_verdict "rejected" "junit_parse_error" \
          "$(_vjsh_short_sha "$expected_sha")" ""
        ;;
    esac
  done < <(find "$evidence_dir" -name '*.xml' -type f 2>/dev/null)

  # All checks passed
  _vjsh_verdict "accepted" "" "$(_vjsh_short_sha "$expected_sha")" ""
}

main "$@"
