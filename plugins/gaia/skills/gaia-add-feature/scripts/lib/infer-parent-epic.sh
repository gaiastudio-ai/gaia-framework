#!/usr/bin/env bash
# infer-parent-epic.sh — Advisory deterministic parent-epic inference for
# /gaia-add-feature Step 8 (E89-S3, FR-AFE-3, AI-2026-05-13-21).
#
# Input
#   --affected-skills <comma-separated list>
#   --affected-skills=<list>
#   --epics-file <path>    (optional override; defaults to
#                           .gaia/artifacts/planning-artifacts/epics-and-stories.md
#                           relative to CWD)
#
# Output (stdout, exactly one of three modes)
#   deterministic <epic_key>
#   ambiguous: <epic_key_1>,<epic_key_2>,...
#   no-match
#
# Exit code
#   0 always — helper is advisory; consumers handle the output.
#
# "Open epic" definition (AC2)
#   An epic detail block is OPEN unless the (case-insensitive) substring
#   `**Status: closed**`, `**Status: retired**`, or `**Status: sunset**`
#   appears within the block.

set -euo pipefail
LC_ALL=C
export LC_ALL

AFFECTED_SKILLS=""
EPICS_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --affected-skills)
      [ $# -ge 2 ] || { echo "no-match"; exit 0; }
      AFFECTED_SKILLS="$2"
      shift 2
      ;;
    --affected-skills=*)
      AFFECTED_SKILLS="${1#*=}"
      shift
      ;;
    --epics-file)
      [ $# -ge 2 ] || { echo "no-match"; exit 0; }
      EPICS_FILE="$2"
      shift 2
      ;;
    --epics-file=*)
      EPICS_FILE="${1#*=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# AC5: empty affected_skills -> no-match (NOT an error)
if [ -z "$AFFECTED_SKILLS" ]; then
  echo "no-match"
  exit 0
fi

# Default epics file (AF-2026-05-21-25 canonical-first with legacy fallback).
if [ -z "$EPICS_FILE" ]; then
  if [ -f ".gaia/artifacts/planning-artifacts/epics-and-stories.md" ]; then
    EPICS_FILE=".gaia/artifacts/planning-artifacts/epics-and-stories.md"
  else
    EPICS_FILE="docs/planning-artifacts/epics-and-stories.md"
  fi
fi
if [ ! -f "$EPICS_FILE" ]; then
  echo "no-match"
  exit 0
fi

# Extract epic detail blocks via awk. An epic block starts at a heading
# that matches `^## E[0-9]+` and ends at the next such heading OR an
# isolated `^---` line. We emit each block prefixed with the epic key
# and the block content, separated by NUL bytes for safe processing.
TMP_BLOCKS="$(mktemp "${TMPDIR:-/tmp}/infer-parent-epic.XXXXXX")"
trap 'rm -f "$TMP_BLOCKS"' EXIT

awk '
  function flush() {
    if (current_key != "") {
      printf "BLOCK_START %s\n%s\nBLOCK_END\n", current_key, current_body
    }
    current_key = ""
    current_body = ""
  }
  /^## E[0-9]+/ {
    flush()
    # Extract the epic key: line is "## E<N>: <title>" or "## E<N> — <title>"
    line = $0
    sub(/^## /, "", line)
    # Take the first separator-delimited token (epic key). Separators are
    # whitespace, colon, en-dash, or em-dash. BSD awk (macOS) and GNU awk
    # both support [: punct :] but the char-class shorthand differs; use
    # an explicit character class.
    n = split(line, parts, /[[:space:]:—–]/)
    current_key = parts[1]
    current_body = $0
    next
  }
  /^---[[:space:]]*$/ && current_key != "" {
    flush()
    next
  }
  current_key != "" {
    current_body = current_body "\n" $0
  }
  END { flush() }
' "$EPICS_FILE" > "$TMP_BLOCKS"

# Walk the blocks; for each, check status + skill matches.
# Convert comma-separated skills to a space-separated list for iteration.
IFS=',' read -ra SKILL_ARRAY <<< "$AFFECTED_SKILLS"
# Trim whitespace from each skill name.
SKILLS_CLEAN=()
for s in "${SKILL_ARRAY[@]}"; do
  s_trimmed="$(printf '%s' "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$s_trimmed" ] && SKILLS_CLEAN+=("$s_trimmed")
done

if [ ${#SKILLS_CLEAN[@]} -eq 0 ]; then
  echo "no-match"
  exit 0
fi

# Parse blocks and match each.
matched_keys=()
current_key=""
current_block=""
in_block=0

while IFS= read -r line; do
  if [[ "$line" =~ ^BLOCK_START\ (.+)$ ]]; then
    current_key="${BASH_REMATCH[1]}"
    current_block=""
    in_block=1
    continue
  fi
  if [ "$line" = "BLOCK_END" ]; then
    # Process completed block
    if [ "$in_block" = "1" ] && [ -n "$current_key" ]; then
      # Check if epic is closed/retired/sunset
      is_closed=0
      for marker in 'status: closed' 'status: retired' 'status: sunset'; do
        if printf '%s' "$current_block" | grep -qi -F "$marker"; then
          is_closed=1
          break
        fi
      done
      if [ "$is_closed" = "0" ]; then
        # Check if any affected skill matches
        for skill in "${SKILLS_CLEAN[@]}"; do
          if printf '%s' "$current_block" | grep -qF "$skill"; then
            matched_keys+=("$current_key")
            break
          fi
        done
      fi
    fi
    current_key=""
    current_block=""
    in_block=0
    continue
  fi
  if [ "$in_block" = "1" ]; then
    current_block+="$line"$'\n'
  fi
done < "$TMP_BLOCKS"

# Emit one of three modes
case ${#matched_keys[@]} in
  0)
    echo "no-match"
    ;;
  1)
    echo "deterministic ${matched_keys[0]}"
    ;;
  *)
    # Join with commas, no spaces.
    joined=""
    for k in "${matched_keys[@]}"; do
      if [ -z "$joined" ]; then
        joined="$k"
      else
        joined+=",${k}"
      fi
    done
    echo "ambiguous: $joined"
    ;;
esac

exit 0
