#!/usr/bin/env bash
# validate-adr037-envelope.sh — Validate an ADR-037 envelope JSON file.
#
# Per ADR-113 §clause (b), publish adapters write a findings.json file whose
# shape MUST match the canonical ADR-037 envelope:
#   { verdict, evidence, summary, adapter_metadata }
# where:
#   verdict           ∈ {PASSED, FAILED, UNVERIFIED}
#   evidence          array of {type, content, source}
#   summary           non-empty string
#   adapter_metadata  object with {adapter_name, adapter_version, channel, action}
#
# Usage: validate-adr037-envelope.sh <findings.json>
# Exit codes:
#   0 — envelope is well-formed
#   1 — schema violation (stderr names JSONPath + reason)
#   2 — file unreadable / malformed JSON

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="$(basename "$0")"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

[ $# -eq 1 ] || { err "usage: $prog <findings.json>"; exit 2; }
findings="$1"

[ -f "$findings" ] || { err "ADR-037 envelope file not found: $findings"; exit 2; }
[ -s "$findings" ] || { err "ADR-037 envelope file empty: $findings"; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
  err "jq required for ADR-037 envelope validation but not on PATH"
  exit 2
fi

# Parse the file once. Malformed JSON → exit 2.
if ! jq -e . "$findings" >/dev/null 2>&1; then
  err "envelope-schema-violation: malformed JSON in $findings"
  exit 1
fi

# Required top-level fields.
for field in verdict evidence summary adapter_metadata; do
  if ! jq -e --arg f "$field" 'has($f)' "$findings" >/dev/null 2>&1; then
    err "envelope-schema-violation: required field missing at \$.$field"
    exit 1
  fi
done

# verdict ∈ closed enum.
verdict=$(jq -r '.verdict' "$findings")
case "$verdict" in
  PASSED|FAILED|UNVERIFIED) ;;
  *)
    err "envelope-schema-violation: \$.verdict='$verdict' outside closed enum {PASSED,FAILED,UNVERIFIED}"
    exit 1
    ;;
esac

# evidence is an array.
if ! jq -e '.evidence | type == "array"' "$findings" >/dev/null 2>&1; then
  err "envelope-schema-violation: \$.evidence must be an array"
  exit 1
fi

# summary is a non-empty string.
if ! jq -e '.summary | type == "string" and length > 0' "$findings" >/dev/null 2>&1; then
  err "envelope-schema-violation: \$.summary must be a non-empty string"
  exit 1
fi

# adapter_metadata is an object with required sub-fields.
for sub in adapter_name adapter_version channel action; do
  if ! jq -e --arg s "$sub" '.adapter_metadata | has($s)' "$findings" >/dev/null 2>&1; then
    err "envelope-schema-violation: required field missing at \$.adapter_metadata.$sub"
    exit 1
  fi
done

exit 0
