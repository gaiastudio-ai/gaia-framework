#!/usr/bin/env bash
# detect-ux-scope.sh — deterministic UX scope detection for /gaia-create-story (E54-S5)
#
# Hardens the four-rule UX detection from E54-S2 by:
#   - extracting the rules into a script (so tests can validate behavior, not just
#     SKILL.md content shape);
#   - using word-boundary regex semantics on UI_TERMS to prevent substring matches
#     like "platform" -> "form" or "interaction" -> "action";
#   - applying an explicit exclusion phrase list ("data flow", "control flow",
#     "request flow", "workflow", "git flow") to suppress false-positive `flow`
#     matches in backend stories.
#
# Usage:
#   detect-ux-scope.sh <story_file_path>
#
# Optional environment overrides (used by tests and downstream skills):
#   PLANNING_ARTIFACTS  Override the planning-artifacts dir for rule #4
#                       (default: docs/planning-artifacts).
#   EPICS_FILE          Override the epics-and-stories.md path for rule #3.
#
# Output (stdout, single line of JSON):
#   {"ux_match": <bool>, "rules_fired": [<rule_id>...], "excluded_by": [<phrase>...]}
#
# Exit codes:
#   0  success
#   1  story file missing or unreadable
#   2  malformed frontmatter (no closing `---`)
#
# Rule priority order (always emitted in this order when fired):
#   rule1  figma: frontmatter block present
#   rule2  UI_TERMS word-boundary match in body, with exclusion suppression
#   rule3  Epic has UX classification in epics-and-stories.md
#   rule4  ux-design.md exists AND mentions the story's epic key
#
# Traces to: E54-S5 AC1-AC6, TC-CSE-19..22, E54-S2 (parent rule semantics).

set -euo pipefail

# ---------- argv / preflight ----------

if [ "$#" -lt 1 ]; then
  printf 'usage: detect-ux-scope.sh <story_file_path>\n' >&2
  exit 64
fi

STORY_FILE="$1"

if [ ! -r "$STORY_FILE" ]; then
  printf 'error: cannot read story file: %s\n' "$STORY_FILE" >&2
  exit 1
fi

# ---------- rule data ----------

# UI terms that signal a UX-scoped story when matched on word boundaries in the
# story body. Order is informational only; matching is via grep -E with a
# pipe-joined regex.
UI_TERMS=(screen page modal form button navigation wizard flow interaction accessibility responsive mobile design)

# Phrases that, when present anywhere in the body, suppress UI_TERMS matching.
# Each phrase is a substring (case-insensitive). Used to keep backend-only
# stories that mention "data flow" / "control flow" / "workflow" from
# accidentally tripping rule #2 via the bare word "flow".
UX_EXCLUSIONS=("data flow" "control flow" "request flow" "workflow" "git flow")

# ---------- helpers ----------

# Extract the YAML frontmatter (between the first two `---` markers).
# Exits 2 on malformed input (no closing fence).
extract_frontmatter() {
  awk '
    BEGIN { state = 0 }
    /^---[[:space:]]*$/ {
      if (state == 0) { state = 1; next }
      else if (state == 1) { state = 2; exit }
    }
    state == 1 { print }
    END {
      if (state != 2) exit 2
    }
  ' "$1"
}

# Extract the body (everything after the closing `---` of frontmatter).
# If no frontmatter is present, prints the whole file.
_extract_body() {
  awk '
    BEGIN { state = 0 }
    /^---[[:space:]]*$/ {
      if (state == 0) { state = 1; next }
      else if (state == 1) { state = 2; next }
    }
    state == 2 { print }
    state == 0 { print }   # no frontmatter -> emit everything
  ' "$1"
}

# JSON-encode an array of strings via jq. Empty input -> [].
json_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -s -c .
  fi
}

# ---------- frontmatter parse ----------

frontmatter=$(extract_frontmatter "$STORY_FILE") || {
  printf 'error: malformed frontmatter (no closing `---`) in %s\n' "$STORY_FILE" >&2
  exit 2
}

body=$(_extract_body "$STORY_FILE")

# Epic key (used by rule #4). Optional — absent epic just skips rule #4.
EPIC_KEY=$(printf '%s\n' "$frontmatter" \
  | awk -F: '/^epic:[[:space:]]/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/"/, "", $2); print $2; exit }')

# ---------- detection state ----------

ux_match=false
rules_fired=()
excluded_by=()

# ---------- Rule #1: figma: frontmatter block ----------
# Definitive UX signal. Match a top-level `figma:` key in the frontmatter (not
# in the body, which would let prose mentions of the word trigger a false fire).
if printf '%s\n' "$frontmatter" | grep -qE '^figma:'; then
  ux_match=true
  rules_fired+=("rule1")
fi

# ---------- Rule #2: UI_TERMS word-boundary match, with exclusion suppression ----------
# Step 2a: scan for exclusion phrases first and record which fired. Step 2b
# strips matched exclusion phrases out of the body before the UI_TERMS scan
# — this makes "data flow" suppress the bare `flow` term cleanly without
# per-term shadowing arithmetic. Step 2c grep-checks the redacted body.
sanitized_body="$body"
for excl in "${UX_EXCLUSIONS[@]}"; do
  if printf '%s\n' "$body" | grep -qiF "$excl"; then
    excluded_by+=("$excl")
    # Replace every case-insensitive occurrence with whitespace of equal length
    # so token positions are preserved (no accidental new word boundaries).
    sanitized_body=$(printf '%s\n' "$sanitized_body" \
      | awk -v p="$excl" '
          {
            line = $0
            lp = tolower(p)
            ll = tolower(line)
            out = ""
            n = length(p)
            while (1) {
              i = index(ll, lp)
              if (i == 0) { out = out line; break }
              out = out substr(line, 1, i-1) sprintf("%*s", n, "")
              line = substr(line, i+n)
              ll = tolower(line)
            }
            print out
          }')
  fi
done

# Pipe-join the UI_TERMS into an alternation regex. grep -E `\b` is supported
# by both GNU and BSD grep on macOS, so this stays portable.
ui_pipe=$(IFS='|'; printf '%s' "${UI_TERMS[*]}")

if printf '%s\n' "$sanitized_body" | grep -qiE "\\b(${ui_pipe})\\b"; then
  ux_match=true
  rules_fired+=("rule2")
fi

# ---------- Rule #3: epic UX classification ----------
EPICS_FILE="${EPICS_FILE:-${PLANNING_ARTIFACTS:-docs/planning-artifacts}/epics-and-stories.md}"
if [ -n "$EPIC_KEY" ] && [ -r "$EPICS_FILE" ]; then
  # Look for the epic block, then check whether a `tags:` or `classification:`
  # line within ~30 lines of the epic key carries a UX-related token.
  if awk -v key="$EPIC_KEY" '
    BEGIN { in_block = 0; lines = 0 }
    $0 ~ "(^|[^A-Za-z0-9_])" key "([^A-Za-z0-9_]|$)" { in_block = 1; lines = 0; next }
    in_block {
      lines++
      if (tolower($0) ~ /(tags|classification):.*(^|[^A-Za-z0-9])(ux|ui|design)([^A-Za-z0-9]|$)/) { print "HIT"; exit }
      if (lines > 30) { in_block = 0 }
    }
  ' "$EPICS_FILE" | grep -q HIT; then
    ux_match=true
    rules_fired+=("rule3")
  fi
fi

# ---------- Rule #4: ux-design.md exists AND mentions epic key ----------
UX_DESIGN_FILE="${PLANNING_ARTIFACTS:-docs/planning-artifacts}/ux-design.md"
if [ -n "$EPIC_KEY" ] && [ -r "$UX_DESIGN_FILE" ]; then
  if grep -qE "(^|[^A-Za-z0-9_])${EPIC_KEY}([^A-Za-z0-9_]|$)" "$UX_DESIGN_FILE"; then
    ux_match=true
    rules_fired+=("rule4")
  fi
fi
# Missing ux-design.md degrades cleanly — rule #4 is simply not recorded.

# ---------- emit JSON ----------

if [ "${#rules_fired[@]}" -eq 0 ]; then rules_json='[]'; else rules_json=$(json_array "${rules_fired[@]}"); fi
if [ "${#excluded_by[@]}" -eq 0 ]; then excluded_json='[]'; else excluded_json=$(json_array "${excluded_by[@]}"); fi

jq -cn \
  --argjson m "$ux_match" \
  --argjson r "$rules_json" \
  --argjson e "$excluded_json" \
  '{ux_match: $m, rules_fired: $r, excluded_by: $e}'
