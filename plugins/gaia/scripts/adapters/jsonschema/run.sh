#!/usr/bin/env bash
# adapters/jsonschema/run.sh — contract entry.
#
# Validates JSON instance documents against a JSON Schema using
# `check-jsonschema`. Honours the run.sh flag-form interface:
#
#   run.sh --input <file-list> [--config <schema.json>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#
# When --config is provided, `check-jsonschema --schemafile <schema>` is
# invoked against each JSON file from --input. When --config is absent,
# `check-jsonschema` falls back to per-file mode (validates against schemas
# referenced via $schema in the document, or skips when none).
#
# stdout is the canonical analysis-results fragment:
#   { "name": "jsonschema",
#     "status": "passed" | "failed",
#     "findings": [ { rule, severity, file, line, message, blocking }, ... ] }
#
# Exit codes:
#   0  - run completed cleanly (no findings, or no .json files)
#   2  - run completed with findings present (blocking)
#   1  - adapter execution error (bad input, jq missing, check-jsonschema missing)

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
adapters/jsonschema/run.sh — contract.
Usage:
  run.sh --input <file-list> [--config <schema.json>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required but not on PATH" >&2; exit 1; }

# Filter input to .json files.
TARGETS=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    *.json) TARGETS+=("$path") ;;
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

# Auto-skip when no .json files match.
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "run.sh: No .json files found -- skipping jsonschema validation" >&2
  fragment="$(jq -nc \
    --arg name "jsonschema" \
    '{name: $name, status: "passed", findings: []}')"
  emit_fragment "$fragment"
  exit 0
fi

# Provider check.
if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "run.sh: check-jsonschema not found on PATH" >&2
  exit 1
fi

# --- Run check-jsonschema and collect raw output ---------------------------

raw_output=""
provider_rc=0
if [ -n "$CONFIG" ]; then
  if [ ! -r "$CONFIG" ]; then
    echo "run.sh: schema file not readable: $CONFIG" >&2
    exit 1
  fi
  raw_output="$(check-jsonschema --schemafile "$CONFIG" "${TARGETS[@]}" 2>&1)" || provider_rc=$?
else
  # No schema supplied — best-effort per-file with default behaviour.
  raw_output="$(check-jsonschema "${TARGETS[@]}" 2>&1)" || provider_rc=$?
fi

# --- Parse raw output into findings ---------------------------------------
#
# `check-jsonschema` default text output emits, for each failure:
#   <path/to/file.json>::<jsonpath>: <message>
# or, with multi-line headers when --output-format is default. We extract
# error lines via a permissive regex: any line that contains the file path
# of one of our targets followed by a colon-prefixed message. Lines that do
# not match any target are skipped.
#
# Each finding maps to {rule: "schema-violation", severity: "error",
# file: <path>, line: 0, message: <full text>, blocking: true}.

findings_json="[]"

if [ "$provider_rc" -ne 0 ]; then
  # Scan each non-empty stderr/stdout line; emit one finding per line that
  # references a known target file. Any other lines (banner, summary) are
  # captured under a fallback finding so we never silently swallow errors.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    matched_file=""
    for t in "${TARGETS[@]}"; do
      case "$line" in
        *"$t"*) matched_file="$t" ;;
      esac
    done
    if [ -n "$matched_file" ]; then
      # Extract message after first colon following the file path. Best-effort.
      msg="${line#*"$matched_file"}"
      msg="${msg#:}"
      msg="${msg# }"
      [ -n "$msg" ] || msg="$line"
      findings_json="$(jq -c \
        --arg rule "schema-violation" \
        --arg severity "error" \
        --arg file "$matched_file" \
        --argjson line 0 \
        --arg message "$msg" \
        '. + [{rule: $rule, severity: $severity, file: $file, line: $line, message: $message, blocking: true}]' \
        <<< "$findings_json")"
    fi
  done <<< "$raw_output"

  # If non-zero exit but no per-file lines parsed, emit a single rolled-up
  # finding so the failure is not silently masked.
  count="$(jq 'length' <<< "$findings_json")"
  if [ "$count" -eq 0 ]; then
    findings_json="$(jq -c \
      --arg rule "adapter-error" \
      --arg severity "error" \
      --arg file "" \
      --argjson line 0 \
      --arg message "check-jsonschema exited rc=$provider_rc: $raw_output" \
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
  --arg name "jsonschema" \
  --arg status "$status" \
  --argjson findings "$findings_json" \
  '{name: $name, status: $status, findings: $findings}')"

emit_fragment "$fragment"

if [ "$finding_count" -gt 0 ]; then
  exit 2
fi
exit 0
