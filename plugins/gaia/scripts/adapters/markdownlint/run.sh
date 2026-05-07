#!/usr/bin/env bash
# adapters/markdownlint/run.sh — FR-415 + ADR-078 contract entry.
#
# Runs `markdownlint-cli2` (preferred) or `markdownlint` (fallback) against the
# .md files listed via --input. Honours the ADR-078 run.sh flag-form interface:
#
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#
# stdout is the canonical analysis-results fragment:
#   { "name": "markdownlint",
#     "status": "passed" | "failed",
#     "findings": [ { rule, severity, file, line, message, blocking }, ... ] }
#
# Exit codes:
#   0  - run completed cleanly (no findings, or no .md files)
#   2  - run completed with findings present (blocking)
#   1  - adapter execution error (bad input, jq missing, no markdownlint binary)

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
adapters/markdownlint/run.sh — FR-415 + ADR-078 contract.
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

# Filter input to .md files.
TARGETS=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    *.md) TARGETS+=("$path") ;;
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

# Auto-skip when no .md files match.
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "run.sh: No .md files found -- skipping markdownlint" >&2
  fragment="$(jq -nc \
    --arg name "markdownlint" \
    '{name: $name, status: "passed", findings: []}')"
  emit_fragment "$fragment"
  exit 0
fi

# Resolve provider binary: markdownlint-cli2 (preferred) or markdownlint.
bin=""
if command -v markdownlint-cli2 >/dev/null 2>&1; then
  bin="markdownlint-cli2"
elif command -v markdownlint >/dev/null 2>&1; then
  bin="markdownlint"
else
  echo "run.sh: neither markdownlint-cli2 nor markdownlint found on PATH" >&2
  exit 1
fi

# --- Run markdownlint and collect raw output ------------------------------
# Both CLIs share the same output convention: one finding per line in the form
#   <file>:<line>[:col] <RULE>/<rule-name> <message>
# or for markdownlint-cli2 default:
#   <file>:<line>:<col> <RULE>/<rule-name> <message>

raw_output=""
provider_rc=0
if [ -n "$CONFIG" ]; then
  if [ "$bin" = "markdownlint-cli2" ]; then
    raw_output="$("$bin" --config "$CONFIG" "${TARGETS[@]}" 2>&1)" || provider_rc=$?
  else
    raw_output="$("$bin" --config "$CONFIG" "${TARGETS[@]}" 2>&1)" || provider_rc=$?
  fi
else
  raw_output="$("$bin" "${TARGETS[@]}" 2>&1)" || provider_rc=$?
fi

# --- Parse raw output into findings ---------------------------------------
#
# Match the canonical form: <file>:<line>[:<col>] <rest>
# where <rest> begins with the rule id (e.g. MD022/blanks-around-headings).

findings_json="[]"

if [ "$provider_rc" -ne 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Skip banner / summary lines that do not match the file:line: pattern.
    case "$line" in
      *.md:*) ;;
      *) continue ;;
    esac

    # Extract file, line-number, rule, message via awk for portability.
    parsed="$(printf '%s' "$line" | awk -F: '
      {
        file = $1
        ln = $2
        # Reconstruct rest = everything after the first <file>:<line>: prefix.
        rest = ""
        for (i = 3; i <= NF; i++) {
          if (i > 3) rest = rest ":"
          rest = rest $i
        }
        # rest is either ":<col> <rule> <msg>" (cli2) or " <rule>/<name> <msg>".
        # Strip leading column indicator and whitespace.
        sub(/^[0-9]+[[:space:]]*/, "", rest)
        sub(/^[[:space:]]+/, "", rest)
        # Split rule (first whitespace-delimited token) from message.
        n = split(rest, parts, /[[:space:]]+/)
        rule = parts[1]
        msg = ""
        for (i = 2; i <= n; i++) {
          if (i > 2) msg = msg " "
          msg = msg parts[i]
        }
        gsub(/\t/, " ", file)
        printf "%s\t%s\t%s\t%s\n", file, ln, rule, msg
      }
    ')"

    [ -n "$parsed" ] || continue

    f_file="$(printf '%s' "$parsed" | cut -f1)"
    f_line_raw="$(printf '%s' "$parsed" | cut -f2)"
    f_rule="$(printf '%s' "$parsed" | cut -f3)"
    f_msg="$(printf '%s' "$parsed" | cut -f4-)"

    # Coerce line number to integer; fall back to 0.
    case "$f_line_raw" in
      ''|*[!0-9]*) f_line=0 ;;
      *) f_line="$f_line_raw" ;;
    esac
    [ -n "$f_rule" ] || f_rule="markdownlint"

    findings_json="$(jq -c \
      --arg rule "$f_rule" \
      --arg severity "error" \
      --arg file "$f_file" \
      --argjson line "$f_line" \
      --arg message "$f_msg" \
      '. + [{rule: $rule, severity: $severity, file: $file, line: $line, message: $message, blocking: true}]' \
      <<< "$findings_json")"
  done <<< "$raw_output"

  # If non-zero exit but no parseable findings, roll up under adapter-error.
  count="$(jq 'length' <<< "$findings_json")"
  if [ "$count" -eq 0 ]; then
    findings_json="$(jq -c \
      --arg rule "adapter-error" \
      --arg severity "error" \
      --arg file "" \
      --argjson line 0 \
      --arg message "$bin exited rc=$provider_rc: $raw_output" \
      '. + [{rule: $rule, severity: $severity, file: $file, line: $line, message: $message, blocking: true}]' \
      <<< "$findings_json")"
  fi
fi

finding_count="$(jq 'length' <<< "$findings_json")"
if [ "$finding_count" -gt 0 ]; then
  status="failed"
else
  status="passed"
fi

fragment="$(jq -nc \
  --arg name "markdownlint" \
  --arg status "$status" \
  --argjson findings "$findings_json" \
  '{name: $name, status: $status, findings: $findings}')"

emit_fragment "$fragment"

if [ "$finding_count" -gt 0 ]; then
  exit 2
fi
exit 0
