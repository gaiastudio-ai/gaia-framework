#!/usr/bin/env bash
# append-edge-case-acs.sh — gaia-create-story Step 3c deterministic
#                          edge-case-AC appender (E63-S7 / Work Items 6.7 + 4)
#
# Purpose:
#   Append edge-case acceptance criteria (AC-EC entries) to a story file
#   AFTER computing SHA-256 hashes of every primary AC line, perform the
#   append, re-hash, and revert atomically on any drift. Restores V1's
#   full-text immutability guarantee for primary ACs deterministically
#   (replacing the V2 count-drift check at SKILL.md Step 3c).
#
# Consumer skill:
#   - /gaia-create-story Step 3c — replaces the count-drift prose with a
#     single `!scripts/append-edge-case-acs.sh ...` invocation.
#
# Upstream dependency:
#   - E63-S6 validate-ac-format.sh — establishes the AC-section extraction
#     pattern (`## Acceptance Criteria` → next `## ` heading; lines
#     matching `- [ ]`). This script extends that pattern with primary-vs-
#     AC-EC partitioning and SHA-256 hash verification.
#
# Contract source:
#   - ADR-074 contract C2 — AC immutability hash check (the contractual
#     home for the SHA-256 mechanism replacing the count-drift check).
#   - ADR-042            — Scripts-over-LLM rationale.
#   - .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md — Work
#     Item 4 (hash check) + Work Item 6.7 (script migration).
#
# Algorithm (in order):
#   1. Parse CLI: --file <path> (required), --edge-cases <json-array>
#      (required). Reject unknown flags with a clear error.
#   2. If --file path does not exist, write a WARNING to stderr and exit 0
#      (non-blocking, mirrors Step 3d's missing-test-plan posture per
#      source spec 6.7).
#   3. Validate the JSON input is a well-formed array via `jq -e .`.
#   4. Extract primary AC lines (lines matching `^- \[ \] AC` AND NOT
#      matching `^- \[ \] AC-EC`) via an awk state-machine on
#      `## Acceptance Criteria` → next `## ` heading.
#   5. Compute ordered pre_hashes (one SHA-256 per primary AC line).
#   6. Snapshot the original file via `mktemp` BEFORE any mutation.
#   7. Iterate the JSON edge-cases. Build the AC-EC tail block, deduping
#      against existing AC-EC `scenario` substrings.
#   8. Insert the new tail in a single awk pass after the LAST primary AC
#      line and before the next `## ` heading (or EOF).
#   9. Recompute post_hashes from the modified file. Compare element-wise.
#   10. On drift, atomically `mv` the snapshot back over the target file
#       and exit non-zero with a stderr error naming the offending line.
#   11. On success, emit the count of AC-EC entries actually appended
#       (post-dedup) on stdout. Clean up the snapshot.
#
# Exit codes:
#   0 — success, OR --file path does not exist (non-blocking)
#   1 — usage error, malformed JSON, mutation drift detected (and reverted),
#       or any other deterministic failure
#   2 — catastrophic revert failure (file may be inconsistent)
#
# Locale invariance:
#   `LC_ALL=C` is set so awk pattern matching, sort/grep character classes,
#   and tr/sed semantics behave identically on macOS BSD and Linux GNU.
#
# macOS / Linux portability:
#   sha256 hashing: prefer `sha256sum`, fall back to `shasum -a 256`.
#   No GNU-only sed/awk flags.
#
# Fault injection (test-only):
#   GAIA_APPEND_EC_FAULT_INJECT_MUTATE_PRIMARY=1 forces a primary-AC
#   mutation between pre-hash and post-hash to exercise the revert path.
#   Used exclusively by the bats test suite.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="append-edge-case-acs.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: append-edge-case-acs.sh --file <story-file> --edge-cases <json-array>

  --file <path>             Path to a story file. Required.
  --edge-cases <json>       JSON array of edge-case entries. Required.
                            Each entry: {id, scenario, input, expected,
                            category, severity?}.

Appends one `- [ ] AC-EC{N}: Given {input}, when {scenario}, then {expected}`
row per entry to the story's `## Acceptance Criteria` section, after the
last primary AC and before the next `## ` heading. Dedups against existing
AC-EC entries by exact `scenario` substring match.

Computes SHA-256 over every primary AC line BEFORE the append, recomputes
AFTER, and atomically reverts the file if any primary AC line drifted.
This restores V1's full-text immutability guarantee for primary ACs.

If --file does not exist, the script writes a WARNING to stderr and exits
0 (non-blocking — mirrors Step 3d's missing-test-plan posture).

Output (stdout, success only): the integer count of AC-EC entries actually
appended (post-dedup), on a single line.

Exit codes:
  0 — success, OR --file does not exist (non-blocking)
  1 — usage error, malformed JSON, drift detected (and reverted)
  2 — catastrophic revert failure
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 1; }
die_input() { log "$*"; exit 1; }

# ---------- CLI parsing ----------

file=""
edge_cases_raw=""
have_edge_cases=0

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die_usage "--file requires a value"
      file="$2"; shift 2 ;;
    --edge-cases)
      [ $# -ge 2 ] || die_usage "--edge-cases requires a value"
      edge_cases_raw="$2"; have_edge_cases=1; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$file" ] || die_usage "--file is required"
[ "$have_edge_cases" -eq 1 ] || die_usage "--edge-cases is required"

# ---------- Missing-target file (non-blocking branch, AC4) ----------

if [ ! -f "$file" ]; then
  log "WARNING file not found: $file"
  exit 0
fi

# ---------- Validate JSON shape ----------

if ! command -v jq >/dev/null 2>&1; then
  die_input "jq is required but not installed on PATH"
fi

if ! printf '%s' "$edge_cases_raw" | jq -e . >/dev/null 2>&1; then
  die_input "malformed JSON for --edge-cases (jq parse failed)"
fi

if ! printf '%s' "$edge_cases_raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
  die_input "--edge-cases must be a JSON array"
fi

# ---------- sha256 helper (portable) ----------

if command -v sha256sum >/dev/null 2>&1; then
  sha256_cmd=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  sha256_cmd=(shasum -a 256)
else
  die_input "neither sha256sum nor shasum found on PATH"
fi

# Hash a single string (read from stdin), emitting only the hex digest.
hash_string() {
  "${sha256_cmd[@]}" | awk '{print $1}'
}

# ---------- Extract primary AC lines (state-machine awk) ----------
#
# Walk the file once. Flip in_ac on the literal `## Acceptance Criteria`
# heading; flip it off on the next `## ` heading. Within the AC section,
# emit lines that match `^- \[ \] AC` and NOT `^- \[ \] AC-EC`.

extract_primary_acs() {
  awk '
    /^## Acceptance Criteria[[:space:]]*$/ { in_ac = 1; next }
    /^## / && in_ac { in_ac = 0 }
    in_ac && /^- \[ \] AC/ && !/^- \[ \] AC-EC/ { print }
  ' "$1"
}

# Extract existing AC-EC scenario substrings (between `, when ` and `, then`)
# for dedup. One scenario per output line; empty if no AC-EC entries.
extract_existing_ec_scenarios() {
  awk '
    /^## Acceptance Criteria[[:space:]]*$/ { in_ac = 1; next }
    /^## / && in_ac { in_ac = 0 }
    in_ac && /^- \[ \] AC-EC/ { print }
  ' "$1" | sed -n 's/.*, when \(.*\), then .*/\1/p'
}

# ---------- Allocate workspace + single cleanup trap ----------
#
# All temp files live in a single workspace directory so cleanup is
# unconditional and trap re-installation is unnecessary.

workspace="$(mktemp -d -t append-ec-workspace.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf '$workspace'" EXIT

pre_hashes_file="$workspace/pre-hashes"
post_hashes_file="$workspace/post-hashes"
snapshot="$workspace/snapshot"
existing_scenarios_file="$workspace/existing-scenarios"
new_entries_file="$workspace/new-entries"
tail_block_file="$workspace/tail-block"
modified_file="$workspace/modified"

# ---------- Pre-hash computation ----------

primary_count=0
while IFS= read -r line; do
  printf '%s' "$line" | hash_string >> "$pre_hashes_file"
  primary_count=$((primary_count + 1))
done < <(extract_primary_acs "$file")
# Ensure the file exists even when there are zero primary ACs.
[ -f "$pre_hashes_file" ] || : > "$pre_hashes_file"

# ---------- Snapshot for revert ----------

cp "$file" "$snapshot"

# ---------- Build the new AC-EC tail (with dedup) ----------

extract_existing_ec_scenarios "$file" > "$existing_scenarios_file"

# Iterate the JSON entries with jq, emitting one tab-separated record per
# entry: `<scenario>\t<input>\t<expected>`. We do not pre-assign AC-EC{N}
# numbers in jq because dedup may filter entries; the index is assigned in
# bash after dedup.
printf '%s' "$edge_cases_raw" \
  | jq -r '.[] | [.scenario, .input, .expected] | @tsv' \
  > "$new_entries_file"

# Determine the next available AC-EC index by counting existing AC-EC lines.
existing_ec_count="$(awk '
  /^## Acceptance Criteria[[:space:]]*$/ { in_ac = 1; next }
  /^## / && in_ac { in_ac = 0 }
  in_ac && /^- \[ \] AC-EC/ { count++ }
  END { print count + 0 }
' "$file")"

next_index=$((existing_ec_count + 1))

# Build the dedup'd tail. One AC-EC line per entry that survives the
# dedup filter.
appended_count=0
: > "$tail_block_file"
: > "$tail_block_file.scenarios"
while IFS=$'\t' read -r scenario input expected; do
  [ -n "$scenario" ] || continue
  # Dedup: scenario already present in existing AC-EC block.
  if grep -Fxq -- "$scenario" "$existing_scenarios_file"; then
    continue
  fi
  # Dedup against scenarios appended earlier in this run as well.
  if [ "$appended_count" -gt 0 ] && grep -Fxq -- "$scenario" "$tail_block_file.scenarios"; then
    continue
  fi
  printf -- '- [ ] AC-EC%d: Given %s, when %s, then %s\n' \
    "$next_index" "$input" "$scenario" "$expected" >> "$tail_block_file"
  printf '%s\n' "$scenario" >> "$tail_block_file.scenarios"
  next_index=$((next_index + 1))
  appended_count=$((appended_count + 1))
done < "$new_entries_file"

# ---------- Insert the tail block into the file ----------

if [ "$appended_count" -gt 0 ]; then
  # Single-pass awk: track the AC section, find the position AFTER the last
  # primary or AC-EC line within it, and inject the tail block there. The
  # "tail goes at the end of the AC section" rule means: emit the tail
  # immediately before the line that ends the AC section (the next `## `
  # heading) OR at EOF if no further heading exists.
  awk -v tail_file="$tail_block_file" '
    BEGIN {
      # Read the tail block into memory.
      tail = ""
      while ((getline line < tail_file) > 0) {
        tail = tail line "\n"
      }
      close(tail_file)
      in_ac = 0
      injected = 0
    }
    /^## Acceptance Criteria[[:space:]]*$/ {
      in_ac = 1
      print
      next
    }
    /^## / && in_ac && !injected {
      # End of AC section reached. Inject the tail before this heading.
      printf "%s", tail
      injected = 1
      in_ac = 0
      print
      next
    }
    { print }
    END {
      # AC section ran to EOF — inject the tail at the very end.
      if (in_ac && !injected) {
        printf "%s", tail
      }
    }
  ' "$file" > "$modified_file"

  # Atomically replace the target file with the modified content.
  mv "$modified_file" "$file"
fi

# ---------- Fault injection (test-only mutation) ----------

if [ "${GAIA_APPEND_EC_FAULT_INJECT_MUTATE_PRIMARY:-0}" = "1" ]; then
  # Mutate the FIRST primary AC line (replace `AC1:` with `AC1-MUTATED:`).
  fault_tmp="$workspace/fault-injection"
  awk '
    /^- \[ \] AC1:/ && !mutated { sub(/^- \[ \] AC1:/, "- [ ] AC1-MUTATED:"); mutated = 1 }
    { print }
  ' "$file" > "$fault_tmp"
  mv "$fault_tmp" "$file"
fi

# ---------- Post-hash + comparison ----------

post_count=0
while IFS= read -r line; do
  printf '%s' "$line" | hash_string >> "$post_hashes_file"
  post_count=$((post_count + 1))
done < <(extract_primary_acs "$file")
[ -f "$post_hashes_file" ] || : > "$post_hashes_file"

drift_detected=0
drift_reason=""

if [ "$primary_count" -ne "$post_count" ]; then
  drift_detected=1
  drift_reason="primary AC count changed ($primary_count -> $post_count)"
elif ! cmp -s "$pre_hashes_file" "$post_hashes_file"; then
  drift_detected=1
  # Find the first index where hashes differ.
  drift_index="$(awk 'NR==FNR { pre[NR]=$0; next } pre[FNR] != $0 { print FNR; exit }' \
    "$pre_hashes_file" "$post_hashes_file")"
  # Read the corresponding mutated line content for the error message.
  mutated_line="$(extract_primary_acs "$file" | awk -v idx="$drift_index" 'NR==idx { print; exit }')"
  drift_reason="primary AC drift detected at line index $drift_index: $mutated_line"
fi

if [ "$drift_detected" -eq 1 ]; then
  # Atomically restore the snapshot.
  if ! mv "$snapshot" "$file"; then
    log "revert failed — file may be inconsistent: $file"
    exit 2
  fi
  log "$drift_reason"
  exit 1
fi

# ---------- Success ----------

printf '%d\n' "$appended_count"
exit 0
