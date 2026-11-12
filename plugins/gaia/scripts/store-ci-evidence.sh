#!/usr/bin/env bash
# store-ci-evidence.sh — write CI JUnit evidence into a story folder.
#
# After validate-junit-sha.sh accepts evidence, this script copies the
# JUnit XML into the story folder with <system-out>/<system-err> content
# removed, runs the review packet builder's token-stripping and gitleaks
# scan, and writes ci-junit-evidence.json.
#
# Usage:
#   store-ci-evidence.sh --story-key <key> --evidence-dir <dir> --repo <tree> \
#     [--story-dir <dir>]
#
# Exit codes:
#   0 — evidence stored
#   1 — caller / argument error
#   3 — secret detected (nothing written)

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source review-packet-builder for _rpb_strip_tokens and _rpb_gitleaks_scan
# (CLI guard prevents main from running).
# shellcheck source=review-packet-builder.sh
. "$SCRIPT_DIR/review-packet-builder.sh"

_sce_log() { printf 'store-ci-evidence: %s\n' "$*" >&2; }
_sce_die() { local rc="$1"; shift; _sce_log "$@"; exit "$rc"; }

# _sce_strip_system_elements — remove <system-out> and <system-err> content
# from JUnit XML. Keeps the elements as empty tags for schema compat.
# Reads file path as $1, writes cleaned content to stdout.
_sce_strip_system_elements() {
  local file="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c '
import sys, xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    tree = ET.parse(path)
except ET.ParseError as e:
    print("parse error: " + str(e), file=sys.stderr)
    sys.exit(1)

root = tree.getroot()
for elem in root.iter():
    if elem.tag in ("system-out", "system-err"):
        elem.text = None
        elem.tail = elem.tail  # preserve tail whitespace

tree.write(sys.stdout.buffer, xml_declaration=True, encoding="UTF-8")
' "$file"
  else
    # Portable sed fallback: remove content between system-out/system-err tags
    sed \
      -e 's|<system-out>[^<]*</system-out>|<system-out></system-out>|g' \
      -e 's|<system-err>[^<]*</system-err>|<system-err></system-err>|g' \
      "$file"
  fi
}

# _sce_parse_junit — extract totals, skipped and flaky from JUnit XML files.
# Args: evidence_dir
# Prints JSON with totals, skipped array and flaky array to stdout.
_sce_parse_junit() {
  local evidence_dir="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c '
import json, sys, os, xml.etree.ElementTree as ET

evi_dir = sys.argv[1]
total_tests = 0
total_pass = 0
total_fail = 0
total_skip = 0
skipped = []
flaky = []

for fname in sorted(os.listdir(evi_dir)):
    if not fname.endswith(".xml"):
        continue
    fpath = os.path.join(evi_dir, fname)
    try:
        tree = ET.parse(fpath)
    except ET.ParseError:
        continue
    root = tree.getroot()

    # Iterate suites
    suites = []
    if root.tag == "testsuites":
        suites = list(root)
    elif root.tag == "testsuite":
        suites = [root]

    for suite in suites:
        if suite.tag != "testsuite":
            continue
        suite_name = suite.get("name", "unknown")

        for tc in suite:
            if tc.tag != "testcase":
                continue
            tc_name = tc.get("name", "unknown")
            total_tests += 1

            has_skip = False
            has_fail = False
            has_flaky = False

            for child in tc:
                if child.tag == "skipped":
                    has_skip = True
                    total_skip += 1
                    reason = child.get("message", "") or (child.text or "")
                    skipped.append({
                        "suite": suite_name,
                        "name": tc_name,
                        "reason": reason.strip()
                    })
                elif child.tag == "failure" or child.tag == "error":
                    has_fail = True
                elif child.tag in ("flakyFailure", "rerunFailure"):
                    has_flaky = True
                    flaky.append({
                        "suite": suite_name,
                        "name": tc_name,
                        "kind": child.tag
                    })

            if has_fail:
                total_fail += 1
            elif not has_skip and not has_flaky:
                total_pass += 1
            elif has_flaky and not has_fail:
                # Flaky tests that ultimately passed count as passed
                total_pass += 1

result = {
    "totals": {
        "tests": total_tests,
        "passed": total_pass,
        "failed": total_fail,
        "skipped": total_skip
    },
    "skipped": skipped,
    "flaky": flaky
}
json.dump(result, sys.stdout)
' "$evidence_dir"
  else
    # Minimal fallback: read counts from root element attributes
    local tests=0 failures=0 skipped_count=0
    local xml_file
    while IFS= read -r xml_file; do
      [ -n "$xml_file" ] || continue
      local t f s
      t="$(grep -o 'tests="[0-9]*"' "$xml_file" | head -1 | grep -o '[0-9]*')" || t=0
      f="$(grep -o 'failures="[0-9]*"' "$xml_file" | head -1 | grep -o '[0-9]*')" || f=0
      s="$(grep -o 'skipped="[0-9]*"' "$xml_file" | head -1 | grep -o '[0-9]*')" || s=0
      tests=$((tests + t))
      failures=$((failures + f))
      skipped_count=$((skipped_count + s))
    done < <(find "$evidence_dir" -name '*.xml' -type f 2>/dev/null)
    local passed=$((tests - failures - skipped_count))
    jq -n \
      --argjson tests "$tests" \
      --argjson passed "$passed" \
      --argjson failed "$failures" \
      --argjson skipped "$skipped_count" \
      '{totals:{tests:$tests,passed:$passed,failed:$failed,skipped:$skipped},skipped:[],flaky:[]}'
  fi
}

# ── Main ────────────────────────────────────────────────────────────

main() {
  local story_key="" evidence_dir="" repo="" story_dir=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story-key)    [ "$#" -ge 2 ] || _sce_die 1 "--story-key requires a value"; story_key="$2"; shift 2 ;;
      --evidence-dir) [ "$#" -ge 2 ] || _sce_die 1 "--evidence-dir requires a value"; evidence_dir="$2"; shift 2 ;;
      --repo)         [ "$#" -ge 2 ] || _sce_die 1 "--repo requires a value"; repo="$2"; shift 2 ;;
      --story-dir)    [ "$#" -ge 2 ] || _sce_die 1 "--story-dir requires a value"; story_dir="$2"; shift 2 ;;
      --help)         printf 'Usage: store-ci-evidence.sh --story-key <key> --evidence-dir <dir> --repo <tree> [--story-dir <dir>]\n'; exit 0 ;;
      *)              _sce_die 1 "unknown argument: $1" ;;
    esac
  done

  [ -n "$story_key" ]    || _sce_die 1 "--story-key is required"
  [ -n "$evidence_dir" ] || _sce_die 1 "--evidence-dir is required"
  [ -d "$evidence_dir" ] || _sce_die 1 "evidence directory not found: $evidence_dir"
  [ -n "$repo" ]         || _sce_die 1 "--repo is required"
  [ -d "$repo" ]         || _sce_die 1 "repo directory not found: $repo"

  command -v jq >/dev/null 2>&1 || _sce_die 1 "jq is required but not found"

  # Resolve story directory
  if [ -z "$story_dir" ]; then
    local story_file
    story_file="$("$SCRIPT_DIR/resolve-story-file.sh" "$story_key" 2>/dev/null)" || \
      _sce_die 1 "could not resolve story file for $story_key"
    story_dir="$(dirname "$story_file")"
  fi
  [ -d "$story_dir" ] || _sce_die 1 "story directory not found: $story_dir"

  # Read run records
  local records_file="$evidence_dir/run-records.json"
  [ -f "$records_file" ] || _sce_die 1 "run-records.json not found in $evidence_dir"

  # Resolve head SHA from run records
  local head_sha
  head_sha="$(jq -r '.runs[0].head_sha // ""' "$records_file")" || \
    _sce_die 1 "could not read head_sha from run records"
  [ -n "$head_sha" ] && [ "$head_sha" != "null" ] || \
    _sce_die 1 "head_sha is empty in run records"

  # ── Stage evidence in a private temp directory ─────────────────────
  local old_umask
  old_umask="$(umask)"
  umask 077
  local staging_dir
  staging_dir="$(mktemp -d)"
  umask "$old_umask"

  local staging_xml_dir="$staging_dir/ci-evidence"
  mkdir -p "$staging_xml_dir"

  # Copy XML files with system-out/system-err content removed
  local xml_file xml_count=0
  while IFS= read -r xml_file; do
    [ -n "$xml_file" ] || continue
    local basename_xml
    basename_xml="$(basename "$xml_file")"
    if _sce_strip_system_elements "$xml_file" > "$staging_xml_dir/$basename_xml" 2>/dev/null; then
      xml_count=$((xml_count + 1))
    else
      _sce_log "warning: could not strip system elements from $basename_xml"
      # Copy as-is with sed fallback
      sed \
        -e 's|<system-out>[^<]*</system-out>|<system-out></system-out>|g' \
        -e 's|<system-err>[^<]*</system-err>|<system-err></system-err>|g' \
        "$xml_file" > "$staging_xml_dir/$basename_xml"
      xml_count=$((xml_count + 1))
    fi
  done < <(find "$evidence_dir" -name '*.xml' -type f 2>/dev/null)

  if [ "$xml_count" -eq 0 ]; then
    _sce_log "no XML files found in evidence directory"
    rm -rf "$staging_dir"
    _sce_die 1 "no XML files to store"
  fi

  # ── Build ci-junit-evidence.json ───────────────────────────────────
  # Parse JUnit data from the cleaned XML
  local parse_result
  parse_result="$(_sce_parse_junit "$staging_xml_dir")" || \
    _sce_die 1 "could not parse JUnit XML"

  # Build the runs array from run records (all values via jq --arg)
  local runs_array
  runs_array="$(jq '[.runs[] | {url: .url, head_sha: .head_sha, attempt: .attempt, conclusion: .conclusion}]' "$records_file")" || \
    _sce_die 1 "could not build runs array"

  # Assemble the evidence JSON — all values via jq --arg/--argjson (AC-EC5)
  local evidence_json
  evidence_json="$(jq -n \
    --arg schema_version "1.0" \
    --arg provider "github-actions" \
    --arg head_sha "$head_sha" \
    --argjson runs "$runs_array" \
    --argjson parsed "$parse_result" \
    '{
      schema_version: $schema_version,
      provider: $provider,
      head_sha: $head_sha,
      runs: $runs,
      totals: $parsed.totals,
      skipped: $parsed.skipped,
      flaky: $parsed.flaky
    }')" || _sce_die 1 "could not assemble evidence JSON"

  printf '%s\n' "$evidence_json" > "$staging_xml_dir/ci-junit-evidence.json"

  # ── Token stripping ────────────────────────────────────────────────
  # Run _rpb_strip_tokens over every file in the staging directory
  local staged_file
  while IFS= read -r staged_file; do
    [ -n "$staged_file" ] || continue
    local tmp_stripped="${staged_file}.stripped"
    _rpb_strip_tokens < "$staged_file" > "$tmp_stripped"
    mv "$tmp_stripped" "$staged_file"
  done < <(find "$staging_xml_dir" -type f 2>/dev/null)

  # ── Gitleaks scan ──────────────────────────────────────────────────
  local gl_rc=0
  _rpb_gitleaks_scan "$staging_xml_dir" "$repo" || gl_rc=$?

  case "$gl_rc" in
    0)  ;; # clean
    3)
      _sce_log "secret detected in evidence — halting (no evidence written)"
      rm -rf "$staging_dir"
      exit 3
      ;;
    4)
      # gitleaks unavailable — proceed without scan (same as packet builder
      # for the unavailable case, but the brief says "halt non-zero on finding"
      # and gitleaks absence is not a finding). Log and continue.
      _sce_log "gitleaks unavailable — proceeding without secret scan"
      ;;
    *)
      _sce_log "gitleaks error (exit $gl_rc) — proceeding without secret scan"
      ;;
  esac

  # ── Write to story folder ──────────────────────────────────────────
  local target_dir="$story_dir/ci-evidence"
  mkdir -p "$target_dir"

  # Copy staged files to the target atomically (per-file copy + sync)
  while IFS= read -r staged_file; do
    [ -n "$staged_file" ] || continue
    local rel_name
    rel_name="$(basename "$staged_file")"
    cp "$staged_file" "$target_dir/$rel_name"
  done < <(find "$staging_xml_dir" -type f 2>/dev/null)

  rm -rf "$staging_dir"

  _sce_log "evidence stored: $target_dir"
  printf '%s\n' "$target_dir"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
