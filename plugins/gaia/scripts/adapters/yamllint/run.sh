#!/usr/bin/env bash
# adapters/yamllint/run.sh — FR-415 + ADR-078 contract entry.
#
# Runs `yamllint -f parsable` against the .yaml/.yml files listed via --input.
# Honours the ADR-078 run.sh flag-form interface:
#
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#
# stdout is the canonical analysis-results fragment:
#   { "name": "yamllint",
#     "status": "passed" | "failed",
#     "findings": [ { rule, severity, file, line, message, blocking }, ... ] }
#
# Exit codes:
#   0  - run completed cleanly (no findings, or no .yaml/.yml files)
#   2  - run completed with findings present (blocking when severity=error)
#   1  - adapter execution error (bad input, jq missing, yamllint missing)

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
# shellcheck disable=SC2034
RUNTIME_PROFILE="subprocess"
# shellcheck disable=SC2034
TIMEOUT=60

# shellcheck disable=SC2034  # RUNTIME_PROFILE/TIMEOUT parsed but unused (canonical flag-form interface).
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/yamllint/run.sh — FR-415 + ADR-078 contract.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required but not on PATH" >&2; exit 1; }

# Filter input to .yaml / .yml files.
TARGETS=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    *.yaml|*.yml) TARGETS+=("$path") ;;
    *) ;;
  esac
done < "$INPUT"

emit_fragment() {
  local fragment="$1"
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$fragment" > "$OUTPUT"
  else
    printf '%s\n' "$fragment"
  fi
}

# Auto-skip when no YAML files match.
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "run.sh: No .yaml/.yml files found -- skipping yamllint" >&2
  fragment="$(jq -nc \
    --arg name "yamllint" \
    '{name: $name, status: "passed", findings: []}')"
  emit_fragment "$fragment"
  exit 0
fi

# Provider check.
if ! command -v yamllint >/dev/null 2>&1; then
  echo "run.sh: yamllint not found on PATH" >&2
  exit 1
fi

# --- Run yamllint with parsable format ------------------------------------
# Parsable format: <file>:<line>:<col>: [<level>] <message> (<rule>)
# Example: config.yaml:4:3: [error] wrong indentation: expected 2 but found 3 (indentation)

raw_output=""
provider_rc=0
if [ -n "$CONFIG" ]; then
  raw_output="$(yamllint -f parsable -c "$CONFIG" "${TARGETS[@]}" 2>&1)" || provider_rc=$?
else
  raw_output="$(yamllint -f parsable "${TARGETS[@]}" 2>&1)" || provider_rc=$?
fi

# --- Parse parsable output into findings ----------------------------------

findings_json="[]"

if [ -n "$raw_output" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue

    # Use awk to split into file, ln, col, level+rule+message.
    parsed="$(printf '%s' "$line" | awk -F: '
      {
        # Need at least file:line:col:rest
        if (NF < 4) { print ""; exit }
        file = $1
        ln = $2
        col = $3
        rest = $4
        for (i = 5; i <= NF; i++) rest = rest ":" $i
        sub(/^[[:space:]]+/, "", rest)
        # rest looks like "[<level>] <message> (<rule>)"
        level = ""
        if (match(rest, /^\[[a-z]+\][[:space:]]/)) {
          level = substr(rest, 2, RLENGTH - 3)
          rest = substr(rest, RLENGTH + 1)
        }
        # Strip trailing "(<rule>)" if present.
        rule = ""
        # Find last "(" -- portable awk lacks 3-arg match; use index/sub.
        if (rest ~ /\([A-Za-z0-9_-]+\)[[:space:]]*$/) {
          # Capture rule between last "(" and ")".
          # Strip trailing whitespace.
          sub(/[[:space:]]+$/, "", rest)
          n = length(rest)
          # Walk backwards to find the final "(".
          for (i = n; i > 0; i--) {
            if (substr(rest, i, 1) == "(") {
              rule = substr(rest, i + 1, n - i - 1)
              rest = substr(rest, 1, i - 1)
              sub(/[[:space:]]+$/, "", rest)
              break
            }
          }
        }
        gsub(/\t/, " ", rest)
        printf "%s\t%s\t%s\t%s\t%s\n", file, ln, level, (rule == "" ? "yamllint" : rule), rest
      }
    ')"

    [ -n "$parsed" ] || continue

    f_file="$(printf '%s' "$parsed" | cut -f1)"
    f_line_raw="$(printf '%s' "$parsed" | cut -f2)"
    f_level="$(printf '%s' "$parsed" | cut -f3)"
    f_rule="$(printf '%s' "$parsed" | cut -f4)"
    f_msg="$(printf '%s' "$parsed" | cut -f5-)"

    case "$f_line_raw" in
      ''|*[!0-9]*) f_line=0 ;;
      *) f_line="$f_line_raw" ;;
    esac

    # Map yamllint level to our severity vocabulary.
    case "$f_level" in
      error) sev="error"; blocking="true" ;;
      warning) sev="warning"; blocking="false" ;;
      *) sev="info"; blocking="false" ;;
    esac

    findings_json="$(jq -c \
      --arg rule "$f_rule" \
      --arg severity "$sev" \
      --arg file "$f_file" \
      --argjson line "$f_line" \
      --arg message "$f_msg" \
      --argjson blocking "$blocking" \
      '. + [{rule: $rule, severity: $severity, file: $file, line: $line, message: $message, blocking: $blocking}]' \
      <<< "$findings_json")"
  done <<< "$raw_output"
fi

# Roll up unparseable adapter errors so they are not silently dropped.
if [ "$provider_rc" -ne 0 ]; then
  count="$(jq 'length' <<< "$findings_json")"
  if [ "$count" -eq 0 ]; then
    findings_json="$(jq -c \
      --arg rule "adapter-error" \
      --arg severity "error" \
      --arg file "" \
      --argjson line 0 \
      --arg message "yamllint exited rc=$provider_rc: $raw_output" \
      '. + [{rule: $rule, severity: $severity, file: $file, line: $line, message: $message, blocking: true}]' \
      <<< "$findings_json")"
  fi
fi

finding_count="$(jq 'length' <<< "$findings_json")"
blocking_count="$(jq '[.[] | select(.blocking == true)] | length' <<< "$findings_json")"

if [ "$finding_count" -gt 0 ]; then
  status="failed"
else
  status="passed"
fi

fragment="$(jq -nc \
  --arg name "yamllint" \
  --arg status "$status" \
  --argjson findings "$findings_json" \
  '{name: $name, status: $status, findings: $findings}')"

emit_fragment "$fragment"

if [ "$blocking_count" -gt 0 ]; then
  exit 2
fi
exit 0
