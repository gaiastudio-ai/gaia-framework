#!/usr/bin/env bash
# append-edge-case-tests.sh — gaia-create-story Step 3d deterministic
#                             test-plan TC-row appender
#
# Purpose:
#   Append edge-case TC rows to a test-plan.md story section with dedup keyed
#   on (story_key, scenario) and strictly increasing TC IDs scoped to the
#   target story's section. Non-blocking when test-plan.md is missing.
#   Replaces the LLM prose at SKILL.md Step 3d with a deterministic script.
#
# Consumer skill:
#   - /gaia-create-story Step 3d — replaces the dedup-by-(story_key, scenario)
#     prose with a single `!scripts/append-edge-case-tests.sh ...` invocation.
#
# Upstream sibling:
#   - append-edge-case-acs.sh — establishes the JSON-driven append-with-dedup
#     pattern, mktemp+atomic-rename posture, missing-target non-blocking
#     branch, and bats fixture style. This script reuses that scaffolding.
#     The structural difference: dedup key is (story_key, scenario) here vs
#     scenario-only in the sibling, and there is NO hash check (test-plan rows
#     have no immutability contract — downstream tooling may legitimately edit
#     them, e.g. severity reclassification by /gaia-edit-test-plan).
#
# Contract source:
#   - Status-edit discipline: this script never reads or writes
#     sprint-status.yaml, epics-and-stories.md, story files, or
#     story-index.yaml. Its scope is strictly the file passed via --test-plan.
#   - Scripts-over-LLM rationale applies throughout.
#   - .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md —
#     script migration of test-plan TC append.
#
# Algorithm (in order):
#   1. Parse CLI: --test-plan <path>, --story-key <key>, --edge-cases <json>.
#      Reject unknown flags with a clear error.
#   2. If --test-plan path does not exist, write a WARNING to stderr and
#      exit 0 (non-blocking; mirrors SKILL.md Step 3d posture).
#   3. Validate the JSON input is a well-formed array via `jq -e .`.
#   4. Locate the story section by searching for either `^## ${STORY_KEY}\b`
#      or `^### ${STORY_KEY}\b`. If no heading matches, hand off to the
#      missing-section branch.
#   5. Within the located range, parse rows matching the canonical format
#      `| TC-{N} | <scenario> | <type> | <severity> | <story_key> |`. Build:
#      (a) a dedup set of existing scenario strings; (b) the maximum TC-{N}
#      numeric suffix scoped to this section.
#   6. Iterate the JSON entries. Skip entries whose scenario is already in
#      the dedup set; format new rows with `next_tc_id = max + 1` and add
#      the scenario to the dedup set so within-batch duplicates also collapse.
#   7. Insert the new TC rows at the end of the target story's section
#      (immediately before the next `^##\?\? ` heading or at EOF). Atomic
#      write: stage to a workspace tmp file, then `mv` over the original.
#   8. Missing-section branch: append a new heading at EOF using the heading
#      depth that matches existing story sections (`## ` by default, `### `
#      if the file's first existing story heading uses `### `). Append the
#      canonical column header + alignment row, then TC rows starting at TC-1.
#   9. On success, emit the integer count of TC rows actually appended
#      (post-dedup) on stdout.
#
# Exit codes:
#   0 — success, OR --test-plan path does not exist (non-blocking)
#   1 — usage error, malformed JSON, or other deterministic failure
#
# Locale invariance:
#   `LC_ALL=C` is set so awk pattern matching, sort/grep character classes,
#   and tr/sed semantics behave identically on macOS BSD and Linux GNU.
#
# macOS / Linux portability:
#   No GNU-only sed/awk flags. No `-i` without backup. No `\<`/`\>` word
#   boundaries. Awk uses `match()` + `substr()` for portable parsing.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="append-edge-case-tests.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: append-edge-case-tests.sh --test-plan <path> --story-key <key> --edge-cases <json-array>

  --test-plan <path>        Path to a test-plan.md file. Required.
  --story-key <key>         Story key (e.g. E1-S1). Required.
  --edge-cases <json>       JSON array of edge-case entries. Required.
                            Each entry: {id, scenario, input, expected,
                            category, severity?}. Only `scenario` (dedup
                            key) and `severity` (defaults to "medium") are
                            used for the test-plan row; the remaining fields
                            are tolerated for sibling-script JSON shape
                            compatibility with append-edge-case-acs.sh.

Appends one `| TC-{N} | {scenario} | edge-case | {severity} | {story_key} |`
row per entry to the target story's section in test-plan.md. Dedups against
existing rows by (story_key, scenario). TC IDs are strictly increasing —
`next_tc_id = max(existing TC-{N} in this section) + 1`. Gaps in existing
numbering are NOT backfilled.

If the target story section is missing, a new section is appended at EOF
with a heading depth matching the file's existing story sections (`## ` by
default; `### ` if existing siblings use that depth).

If --test-plan does not exist, the script writes a WARNING to stderr and
exits 0 (non-blocking — mirrors SKILL.md Step 3d posture).

Output (stdout, success only): the integer count of TC rows actually
appended (post-dedup), on a single line.

Exit codes:
  0 — success, OR --test-plan does not exist (non-blocking)
  1 — usage error, malformed JSON, or other deterministic failure
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 1; }
die_input() { log "$*"; exit 1; }

# ---------- CLI parsing ----------

test_plan=""
story_key=""
edge_cases_raw=""
have_edge_cases=0

while [ $# -gt 0 ]; do
  case "$1" in
    --test-plan)
      [ $# -ge 2 ] || die_usage "--test-plan requires a value"
      test_plan="$2"; shift 2 ;;
    --story-key)
      [ $# -ge 2 ] || die_usage "--story-key requires a value"
      story_key="$2"; shift 2 ;;
    --edge-cases)
      [ $# -ge 2 ] || die_usage "--edge-cases requires a value"
      edge_cases_raw="$2"; have_edge_cases=1; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$test_plan" ] || die_usage "--test-plan is required"
[ -n "$story_key" ] || die_usage "--story-key is required"
[ "$have_edge_cases" -eq 1 ] || die_usage "--edge-cases is required"

# ---------- Missing-target file (non-blocking branch) ----------

if [ ! -f "$test_plan" ]; then
  log "WARNING test-plan.md not found at $test_plan"
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

# ---------- Allocate workspace + cleanup trap ----------

workspace="$(mktemp -d -t append-ec-tests-workspace.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf '$workspace'" EXIT

new_entries_file="$workspace/new-entries"
existing_scenarios_file="$workspace/existing-scenarios"
modified_file="$workspace/modified"
tail_block_file="$workspace/tail-block"

# ---------- Detect target section + extract dedup state ----------
#
# Walk the file once. Within the target section (between `^##\??\? STORY_KEY`
# and the next `^##\??\? ` heading), emit a state-summary block (found,
# max_tc, heading_depth) plus one `SCEN:<scenario>` line per existing TC
# row. Bash then parses that single stream.
#
# The state machine flips `in_sec` on the matched heading and back off on
# the next `## ` or `### ` heading. We use a `match() + substr()` parser
# plus `split()` for portable BSD/GNU awk operation; no GNU-only flags.

state_file="$workspace/section-state"
awk -v key="$story_key" '
  function strip_heading(line,    s) {
    s = line
    sub(/^##+[[:space:]]+/, "", s)
    return s
  }
  BEGIN {
    in_sec = 0
    found = 0
    max_tc = 0
    heading_depth_seen = ""
  }
  /^##+[[:space:]]/ {
    h = strip_heading($0)
    # Track the first existing story-style heading depth (## or ###) so the
    # missing-section branch can match it. Any heading whose text begins
    # with E[0-9]+-S[0-9]+ is a "story section" candidate.
    if (heading_depth_seen == "" && h ~ /^E[0-9]+-S[0-9]+/) {
      if ($0 ~ /^### /) heading_depth_seen = "###"
      else if ($0 ~ /^## /) heading_depth_seen = "##"
    }
    if (h == key) { in_sec = 1; found = 1; next }
    if (in_sec) in_sec = 0
  }
  in_sec {
    if (match($0, /^\| TC-[0-9]+ \|/)) {
      # Extract the digit run between "TC-" (5 chars from RSTART) and the
      # trailing " |" (2 chars). Length = RLENGTH - 7.
      tc_str = substr($0, RSTART + 5, RLENGTH - 7)
      tc_n = tc_str + 0
      if (tc_n > max_tc) max_tc = tc_n
      # Split the row on `|`. Indices: 1="" (pre-first), 2=" TC-N ",
      # 3=" scenario ", 4=" type ", 5=" severity ", 6=" story_key ", 7="".
      n = split($0, parts, "|")
      if (n >= 3) {
        scen = parts[3]
        sub(/^[[:space:]]+/, "", scen)
        sub(/[[:space:]]+$/, "", scen)
        print "SCEN:" scen
      }
    }
  }
  END {
    print "found=" found
    print "max_tc=" max_tc
    print "heading_depth=" heading_depth_seen
  }
' "$test_plan" > "$state_file"

# Parse the state file: SCEN: lines into existing-scenarios file; final
# three k=v lines into bash variables.
section_found=0
max_tc=0
heading_depth=""
: > "$existing_scenarios_file"
while IFS= read -r line; do
  case "$line" in
    SCEN:*) printf '%s\n' "${line#SCEN:}" >> "$existing_scenarios_file" ;;
    found=*) section_found="${line#found=}" ;;
    max_tc=*) max_tc="${line#max_tc=}" ;;
    heading_depth=*) heading_depth="${line#heading_depth=}" ;;
  esac
done < "$state_file"

# Default heading depth for the missing-section branch.
if [ -z "$heading_depth" ]; then
  heading_depth="##"
fi

# ---------- Iterate JSON entries → build new rows with dedup ----------
#
# Each new entry is formatted via jq into TSV: scenario \t severity. Then
# bash filters by dedup set and by within-batch dedup, formatting each
# surviving row.

printf '%s' "$edge_cases_raw" \
  | jq -r '.[] | [.scenario // "", (.severity // "medium")] | @tsv' \
  > "$new_entries_file"

next_tc_id=$((max_tc + 1))
appended_count=0
: > "$tail_block_file"
: > "$tail_block_file.scenarios"

while IFS=$'\t' read -r scenario severity; do
  [ -n "$scenario" ] || continue
  # Cross-run dedup: scenario already present in the section.
  if grep -Fxq -- "$scenario" "$existing_scenarios_file"; then
    continue
  fi
  # Within-batch dedup: scenario already appended earlier in this run.
  if [ "$appended_count" -gt 0 ] && grep -Fxq -- "$scenario" "$tail_block_file.scenarios"; then
    continue
  fi
  printf '| TC-%d | %s | edge-case | %s | %s |\n' \
    "$next_tc_id" "$scenario" "$severity" "$story_key" >> "$tail_block_file"
  printf '%s\n' "$scenario" >> "$tail_block_file.scenarios"
  next_tc_id=$((next_tc_id + 1))
  appended_count=$((appended_count + 1))
done < "$new_entries_file"

# ---------- No-op short-circuit ----------

if [ "$appended_count" -eq 0 ]; then
  printf '%d\n' "$appended_count"
  exit 0
fi

# ---------- Insertion path: section exists ----------

if [ "$section_found" = "1" ]; then
  # Single-pass awk: copy lines unchanged, flip in_sec at the matching
  # heading, on the next `^##+[[:space:]]` heading inject the tail block
  # immediately BEFORE that heading. If EOF is reached while still in_sec,
  # inject at EOF.
  awk -v key="$story_key" -v tail_file="$tail_block_file" '
    function strip_heading(line,    s) {
      s = line
      sub(/^##+[[:space:]]+/, "", s)
      return s
    }
    BEGIN {
      in_sec = 0
      injected = 0
      tail = ""
      while ((getline line < tail_file) > 0) {
        tail = tail line "\n"
      }
      close(tail_file)
    }
    /^##+[[:space:]]/ {
      h = strip_heading($0)
      if (h == key) {
        in_sec = 1
        print
        next
      }
      if (in_sec && !injected) {
        # End of target section reached. Inject tail before this heading.
        # Strip a single trailing blank line if present so the tail does not
        # introduce extra blank-line drift.
        printf "%s", tail
        injected = 1
        in_sec = 0
        print
        next
      }
    }
    { print }
    END {
      if (in_sec && !injected) {
        printf "%s", tail
      }
    }
  ' "$test_plan" > "$modified_file"

  mv "$modified_file" "$test_plan"
else
  # ---------- Insertion path: missing section ----------
  #
  # Append a new section at EOF: heading + column-header row + alignment row
  # + TC rows. The tail block built above used `next_tc_id = max+1 = 1`
  # since max_tc was 0 (no rows in a non-existent section), but we built
  # those rows with the existing-row dedup set empty and TC IDs starting
  # from 1 already.

  {
    cat "$test_plan"
    # Ensure a trailing newline before the new section.
    if [ -n "$(tail -c 1 "$test_plan")" ]; then
      printf '\n'
    fi
    printf '\n'
    printf '%s %s\n' "$heading_depth" "$story_key"
    printf '\n'
    printf '| TC ID | Scenario | Type | Severity | Story Key |\n'
    printf '|-------|----------|------|----------|-----------|\n'
    cat "$tail_block_file"
  } > "$modified_file"

  mv "$modified_file" "$test_plan"
fi

# ---------- Success ----------

printf '%d\n' "$appended_count"
exit 0
