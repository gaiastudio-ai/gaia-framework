#!/usr/bin/env bash
# scanner-findings-register.sh — write scanner findings to the findings register.
#
# Reads a completed scanner evidence manifest and, for each adapter fragment
# with findings, adds a register entry via register-write.sh. Idempotent:
# the dedup key is run_id + fragment_sha256 + finding_id, so a re-run with
# the same evidence writes nothing new.
#
# Usage:
#   scanner-findings-register.sh --story <key> --manifest <path>
#
# Exit codes:
#   0 — findings registered (or no findings to register)
#   1 — caller error
#   2 — manifest is incomplete (caller should not have called this)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTER_WRITE="$(cd "$SCRIPT_DIR/.." && pwd)/register-write.sh"

die() { printf 'scanner-findings-register: %s\n' "$*" >&2; exit 1; }

STORY_KEY=""
MANIFEST_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --story)    STORY_KEY="$2"; shift 2 ;;
    --manifest) MANIFEST_PATH="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: scanner-findings-register.sh --story <key> --manifest <path>"
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$STORY_KEY" ]    || die "--story required"
[ -n "$MANIFEST_PATH" ] || die "--manifest required"
[ -f "$MANIFEST_PATH" ] || die "manifest not found: $MANIFEST_PATH"
[ -x "$REGISTER_WRITE" ] || die "register-write.sh not found: $REGISTER_WRITE"

# Only process enabled, complete manifests.
enabled="$(jq -r '.enabled // true' "$MANIFEST_PATH")"
[ "$enabled" = "true" ] || exit 0

complete="$(jq -r '.complete // false' "$MANIFEST_PATH")"
if [ "$complete" != "true" ]; then
  printf 'scanner-findings-register: manifest is incomplete, skipping\n' >&2
  exit 2
fi

run_id="$(jq -r '.run_id // ""' "$MANIFEST_PATH")"
evidence_dir="$(dirname "$MANIFEST_PATH")"

# Map scanner severity to register severity.
_map_severity() {
  case "$1" in
    critical) echo "critical" ;;
    high)     echo "high" ;;
    medium)   echo "medium" ;;
    *)        echo "low" ;;
  esac
}

added=0

# Iterate over adapters that are available and have a fragment.
adapter_count="$(jq '.adapters | length' "$MANIFEST_PATH")"
i=0
while [ "$i" -lt "$adapter_count" ]; do
  state="$(jq -r --argjson idx "$i" '.adapters[$idx].state' "$MANIFEST_PATH")"
  frag_name="$(jq -r --argjson idx "$i" '.adapters[$idx].fragment // ""' "$MANIFEST_PATH")"
  frag_sha="$(jq -r --argjson idx "$i" '.adapters[$idx].sha256 // ""' "$MANIFEST_PATH")"
  adapter_name="$(jq -r --argjson idx "$i" '.adapters[$idx].name' "$MANIFEST_PATH")"

  if [ "$state" != "available" ] || [ -z "$frag_name" ]; then
    i=$((i + 1))
    continue
  fi

  frag_path="$evidence_dir/$frag_name"
  [ -f "$frag_path" ] || { i=$((i + 1)); continue; }

  # Read findings from the fragment.
  finding_count="$(jq '.findings | length' "$frag_path" 2>/dev/null)" || finding_count=0
  [ "$finding_count" -gt 0 ] || { i=$((i + 1)); continue; }

  j=0
  while [ "$j" -lt "$finding_count" ]; do
    f_id="$(jq -r --argjson idx "$j" '.findings[$idx].id // "unknown"' "$frag_path")"
    f_sev="$(jq -r --argjson idx "$j" '.findings[$idx].severity // "medium"' "$frag_path")"
    f_msg="$(jq -r --argjson idx "$j" '.findings[$idx].message // "scanner finding"' "$frag_path")"
    f_source="$(jq -r --argjson idx "$j" '.findings[$idx].source // ""' "$frag_path")"

    mapped_sev="$(_map_severity "$f_sev")"

    # Dedup key: run_id + fragment hash + finding id. This ensures
    # idempotency on re-run with the same evidence.
    dedup="scanner:${run_id}:${frag_sha}:${f_id}"

    # Build the evidence string with the scanner source.
    evidence_text="scanner-first evidence: ${adapter_name} finding ${f_id}"

    if ! "$REGISTER_WRITE" add \
      --story "$STORY_KEY" \
      --defect "$f_msg" \
      --type "security" \
      --severity "$mapped_sev" \
      --gate "security-review" \
      --evidence "$evidence_text" \
      --dedup-key "$dedup"; then
      printf 'scanner-findings-register: register-write.sh failed for %s finding %s (rc=%d)\n' "$adapter_name" "$f_id" "$?" >&2
      exit 1
    fi

    added=$((added + 1))
    j=$((j + 1))
  done

  i=$((i + 1))
done

if [ "$added" -gt 0 ]; then
  printf 'scanner-findings-register: added %d finding(s) to register for %s\n' "$added" "$STORY_KEY" >&2
fi

exit 0
