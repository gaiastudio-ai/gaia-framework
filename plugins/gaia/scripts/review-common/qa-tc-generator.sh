#!/usr/bin/env bash
# qa-tc-generator.sh — deterministic TC-row generator for /gaia-review-qa Phase 3C.
#
# Reads a story file, extracts its `key:` frontmatter and `## Acceptance Criteria`
# section, and emits a JSON array of TC-row scaffolds conforming to
# plugins/gaia/schemas/qa-test-cases.schema.json. The script is the boilerplate
# layer — it never invokes an LLM. Phase 3C's LLM scenario authoring runs on top
# of this output and refines `given/when/then` text.
#
# Public API:
#   qa-tc-generator.sh --story <story.md> --output <out.json>
#   qa-tc-generator.sh --help
#
# Output:
#   <out.json> — JSON array of {tc_id, ac_ref, description, given, when, then, type}.
#                Default type is "Unit"; LLM may upgrade later.
#
# Idempotent merge: if --output exists and is a valid JSON array, ACs already
# present (matched by ac_ref) are preserved verbatim. Only missing ACs are
# appended. New tc_ids continue from max(existing tc_id suffix) + 1.
#
# Exit codes:
#   0  one valid TC array written / no-op
#   2  caller error (missing flag, missing story file, malformed frontmatter)
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="qa-tc-generator.sh"

err()  { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { err "$*"; exit 2; }

usage() {
  cat <<EOF
$SCRIPT_NAME — deterministic TC-row generator for /gaia-review-qa Phase 3C.

Usage:
  $SCRIPT_NAME --story <story.md> --output <out.json>
  $SCRIPT_NAME --help

Required:
  --story  <path>   Story markdown file (must have YAML frontmatter with key:).
  --output <path>   Output JSON file (created or merged idempotently).

Behavior:
  - Parses '## Acceptance Criteria' section for lines beginning with
    '- **AC<N>:**' or '- AC<N>:' and emits one TC scaffold per AC.
  - Default type is 'Unit'. Phase 3C LLM scenario authoring may upgrade
    later to Integration or E2E.
  - Idempotent: existing entries (matched by ac_ref) are preserved.
EOF
}

# ---------- arg parsing ----------

STORY=""
OUTPUT=""

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --story)
      [ "$#" -ge 2 ] || die "--story requires a path"
      STORY="$2"; shift 2 ;;
    --output)
      [ "$#" -ge 2 ] || die "--output requires a path"
      OUTPUT="$2"; shift 2 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

[ -n "$STORY" ]  || die "missing --story flag"
[ -n "$OUTPUT" ] || die "missing --output flag"
[ -f "$STORY" ]  || die "story file not found: $STORY"

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

# ---------- frontmatter extraction ----------

# Extract the YAML frontmatter block (between the first two '---' lines).
# Then read the value of the `key:` field (quoted or unquoted).
extract_frontmatter() {
  awk '
    BEGIN { state = 0 }
    /^---[[:space:]]*$/ {
      if (state == 0) { state = 1; next }
      else if (state == 1) { state = 2; exit }
    }
    state == 1 { print }
  ' "$STORY"
}

FRONTMATTER="$(extract_frontmatter)"

if [ -z "$FRONTMATTER" ]; then
  die "missing key: in frontmatter (no frontmatter block found in $STORY)"
fi

# Match: optional whitespace, key:, optional whitespace, optional quote, value.
STORY_KEY="$(printf '%s\n' "$FRONTMATTER" \
  | awk -F': *' '/^[[:space:]]*key[[:space:]]*:/ { val=$2; gsub(/^["'"'"']|["'"'"'][[:space:]]*$/, "", val); print val; exit }')"

if [ -z "$STORY_KEY" ]; then
  die "missing key: in frontmatter ($STORY)"
fi

# Validate STORY_KEY shape (defensive against frontmatter typos).
case "$STORY_KEY" in
  E[0-9]*-S[0-9]*) ;;
  *) die "invalid story key in frontmatter: '$STORY_KEY' (expected E<N>-S<M>)" ;;
esac

# ---------- AC extraction ----------

# Read the '## Acceptance Criteria' section body and extract one AC per line
# matching '- **AC<N>:**' or '- AC<N>:'. Each AC's text content is the remainder
# of the line after the prefix.
extract_acs() {
  awk '
    BEGIN { in_section = 0 }
    /^## / {
      if ($0 ~ /^## Acceptance Criteria/) { in_section = 1; next }
      else if (in_section == 1) { in_section = 0 }
    }
    in_section == 1 {
      # Match: optional leading "- ", then optional "**", then "AC<N>:"
      # then optional "**", then optional space, then the AC text.
      line = $0
      if (match(line, /^[[:space:]]*-[[:space:]]+\*\*AC[0-9]+:\*\*[[:space:]]*/)) {
        prefix = substr(line, RSTART, RLENGTH)
        text   = substr(line, RSTART + RLENGTH)
        if (match(prefix, /AC[0-9]+/)) {
          ac_id = substr(prefix, RSTART, RLENGTH)
          printf "%s\t%s\n", ac_id, text
        }
        next
      }
      if (match(line, /^[[:space:]]*-[[:space:]]+AC[0-9]+:[[:space:]]*/)) {
        prefix = substr(line, RSTART, RLENGTH)
        text   = substr(line, RSTART + RLENGTH)
        if (match(prefix, /AC[0-9]+/)) {
          ac_id = substr(prefix, RSTART, RLENGTH)
          printf "%s\t%s\n", ac_id, text
        }
        next
      }
    }
  ' "$STORY"
}

AC_LINES="$(extract_acs)"

# ---------- existing-output load ----------

EXISTING_JSON='[]'
if [ -f "$OUTPUT" ]; then
  if jq -e 'type == "array"' "$OUTPUT" >/dev/null 2>&1; then
    EXISTING_JSON="$(cat "$OUTPUT")"
  else
    die "existing output is not a valid JSON array: $OUTPUT"
  fi
fi

# Compute starting tc_id N as max(existing suffix) + 1.
NEXT_N="$(printf '%s' "$EXISTING_JSON" \
  | jq --arg key "$STORY_KEY" '
      [.[] | .tc_id
        | capture("^TC-" + ($key|gsub("\\."; "\\.")) + "-(?<n>[0-9]+)$")
        | .n | tonumber] | (max // 0) + 1')"

# ---------- scenario parser ----------

# Split AC text into Given/When/Then triples when the canonical pattern is
# present. Output three NUL-separated fields. Otherwise, emit AC text as
# `given` and use scaffold placeholders for `when`/`then`.
split_gwt() {
  local ac_text="$1"
  # Strip leading whitespace.
  ac_text="${ac_text#"${ac_text%%[![:space:]]*}"}"
  # Try canonical "Given X, when Y, then Z." pattern (case-insensitive).
  local given when then_ rest
  if printf '%s' "$ac_text" \
       | grep -Eqi '^[Gg]iven[[:space:]].*,[[:space:]]*[Ww]hen[[:space:]].*,[[:space:]]*[Tt]hen[[:space:]]'; then
    # Use awk for the split (handles multibyte safely).
    given="$(printf '%s' "$ac_text" | awk 'BEGIN{IGNORECASE=1}
      { if (match($0, /^[Gg]iven[[:space:]]+/)) {
          rest = substr($0, RSTART+RLENGTH)
          # Find ", when "
          if (match(rest, /,[[:space:]]+[Ww]hen[[:space:]]+/)) {
            print substr(rest, 1, RSTART-1)
          }
        }
      }')"
    when="$(printf '%s' "$ac_text" | awk 'BEGIN{IGNORECASE=1}
      { if (match($0, /,[[:space:]]+[Ww]hen[[:space:]]+/)) {
          rest = substr($0, RSTART+RLENGTH)
          if (match(rest, /,[[:space:]]+[Tt]hen[[:space:]]+/)) {
            print substr(rest, 1, RSTART-1)
          }
        }
      }')"
    then_="$(printf '%s' "$ac_text" | awk 'BEGIN{IGNORECASE=1}
      { if (match($0, /,[[:space:]]+[Tt]hen[[:space:]]+/)) {
          rest = substr($0, RSTART+RLENGTH)
          # Trim trailing dot/whitespace.
          sub(/[[:space:]]*\.?[[:space:]]*$/, "", rest)
          print rest
        }
      }')"
    if [ -n "$given" ] && [ -n "$when" ] && [ -n "$then_" ]; then
      printf '%s\t%s\t%s' "$given" "$when" "$then_"
      return 0
    fi
  fi
  # Fallback: full AC body in given, scaffold placeholders.
  # Trim trailing whitespace.
  ac_text="${ac_text%%[[:space:]]}"
  printf '%s\t%s\t%s' "$ac_text" "<TODO: action>" "<TODO: outcome>"
}

# ---------- TC-row emission ----------

# Build a JSON array of new entries. Skip any AC already present in EXISTING_JSON.

NEW_ENTRIES_JSON='[]'
N="$NEXT_N"

while IFS=$'\t' read -r ac_id ac_text; do
  [ -n "$ac_id" ] || continue

  # Skip if already present (idempotent merge).
  if printf '%s' "$EXISTING_JSON" | jq -e --arg ac "$ac_id" 'any(.ac_ref == $ac)' >/dev/null 2>&1; then
    continue
  fi

  # Split AC text into G/W/T (or scaffold).
  local_gwt="$(split_gwt "$ac_text")"
  given_str="$(printf '%s' "$local_gwt" | awk -F'\t' '{print $1}')"
  when_str="$(printf '%s'  "$local_gwt" | awk -F'\t' '{print $2}')"
  then_str="$(printf '%s'  "$local_gwt" | awk -F'\t' '{print $3}')"

  # Description: first sentence of the AC text (trimmed), or the full AC text.
  description="${ac_text%%[[:space:]]}"
  description="${description%%.}"
  if [ -z "$description" ]; then
    description="Scaffold TC for $ac_id"
  fi

  tc_id="TC-${STORY_KEY}-${N}"

  NEW_ENTRIES_JSON="$(printf '%s' "$NEW_ENTRIES_JSON" \
    | jq \
        --arg tc_id "$tc_id" \
        --arg ac_ref "$ac_id" \
        --arg description "$description" \
        --arg given "$given_str" \
        --arg when "$when_str" \
        --arg then_ "$then_str" \
        --arg type "Unit" \
        '. + [{
           tc_id: $tc_id,
           ac_ref: $ac_ref,
           description: $description,
           given: $given,
           when: $when,
           then: $then_,
           type: $type
         }]')"

  N=$((N + 1))
done <<EOF
$AC_LINES
EOF

# ---------- merge + write ----------

MERGED_JSON="$(jq -n \
  --argjson existing "$EXISTING_JSON" \
  --argjson new "$NEW_ENTRIES_JSON" \
  '$existing + $new')"

# Atomic write: tmp + mv.
TMP_OUT="${OUTPUT}.tmp.$$"
printf '%s\n' "$MERGED_JSON" | jq '.' > "$TMP_OUT"
mv "$TMP_OUT" "$OUTPUT"

exit 0
