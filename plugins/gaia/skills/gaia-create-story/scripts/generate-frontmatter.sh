#!/usr/bin/env bash
# generate-frontmatter.sh — gaia-create-story Step 4 deterministic frontmatter
#                          emitter
#
# Purpose:
#   Emit the canonical 15-field YAML frontmatter for a story by parsing
#   `epics-and-stories.md` (title, epic, priority, size, risk, depends_on,
#   blocks, traces_to), mapping `size` -> `points` via
#   `resolve-config.sh sizing_map`, and setting the remaining fields
#   (`status: backlog`, `sprint_id: null`, `priority_flag: null`,
#   `origin`/`origin_ref`, `date`, `author`).
#
# Consumers:
#   - validate-frontmatter.sh  — validates this script's output schema
#   - SKILL.md thin-orchestrator rewrite — invokes this script inline
#
# Contract source:
#   - .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md#Work-Item-6.1
#
# Algorithm (in order):
#   1. Parse CLI flags: --story-key, --epics-file, --project-config (required);
#      --origin, --origin-ref (optional).
#   2. Locate the target story block in the epics-file using awk: from the
#      `### Story <key>:` heading through the next `---` HR or the next
#      `### Story ` heading. Reject zero or multiple matches.
#   3. Extract the eight epic-derived fields from the block's bullet lines.
#      Title comes from the heading; the rest come from `- **Label:** value`
#      bullets. Depends on / Blocks / Traces to default to `[]` when absent
#      or set to em-dash / empty.
#   4. Validate required fields (title, epic, priority, size, risk). On any
#      missing field, write `missing field 'X' for story <key>` to stderr
#      and exit 1 with empty stdout.
#   5. Resolve `points` via `resolve-config.sh sizing_map --shared <project-
#      config>`. Look up the story's size in the resolved S=…/M=…/L=…/XL=…
#      block. HALT on resolver non-zero or unknown size.
#   6. Resolve `author`: `git config user.name` -> `resolve-config.sh author`
#      -> hard fallback `"gaia-create-story"`.
#   7. Buffer the YAML output into a shell variable; flush only on success.
#      This guarantees no partial frontmatter on stderr exit.
#
# Exit codes:
#   0 — success
#   1 — malformed input (missing required field, story not found, unknown
#       size, resolver failure)
#   2 — usage error (missing required flag, unknown flag)
#
# Locale invariance:
#   `LC_ALL=C` is set so awk pattern matching, sort/grep character classes,
#   and tr/sed semantics behave identically on macOS BSD and Linux GNU.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="generate-frontmatter.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage: generate-frontmatter.sh \
         --story-key <KEY> \
         --epics-file <path> \
         --project-config <path> \
         [--origin <s>] \
         [--origin-ref <s>]

  --story-key <KEY>          Story key (e.g., E1-S2). Required.
  --epics-file <path>        Path to epics-and-stories.md. Required.
  --project-config <path>    Path to project-config.yaml (passed to
                             resolve-config.sh --shared). Required.
  --origin <s>               Optional origin id (e.g., AF-2026-04-28-7).
                             Emitted as `null` when omitted.
  --origin-ref <s>           Optional origin reference (e.g., "Work Item 6.1").
                             Emitted as `null` when omitted.
  --manual-verification      Opt the story into manual verification. Sets the
                             `manual_verification: true` frontmatter flag so the
                             per-story-review manual-test gate is required. When
                             omitted the flag defaults to `false` (no
                             verification required), symmetric with how the
                             acceptance-test offer is opt-in by risk.

Output (stdout): YAML frontmatter block delimited by `---` lines, in the
canonical 15-field order matching story-template.md.

Exit codes: 0 success | 1 malformed input | 2 usage error.
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 2; }
die_input() { log "$*"; exit 1; }

# ---------- CLI parsing ----------

story_key=""
epics_file=""
project_config=""
origin=""
origin_ref=""
origin_set=0
origin_ref_set=0
manual_verification="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --story-key)
      [ $# -ge 2 ] || die_usage "--story-key requires a value"
      story_key="$2"; shift 2 ;;
    --epics-file)
      [ $# -ge 2 ] || die_usage "--epics-file requires a value"
      epics_file="$2"; shift 2 ;;
    --project-config)
      [ $# -ge 2 ] || die_usage "--project-config requires a value"
      project_config="$2"; shift 2 ;;
    --origin)
      [ $# -ge 2 ] || die_usage "--origin requires a value"
      origin="$2"; origin_set=1; shift 2 ;;
    --origin-ref)
      [ $# -ge 2 ] || die_usage "--origin-ref requires a value"
      origin_ref="$2"; origin_ref_set=1; shift 2 ;;
    --manual-verification)
      manual_verification="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$story_key" ]      || die_usage "--story-key is required"
[ -n "$epics_file" ]     || die_usage "--epics-file is required"
[ -n "$project_config" ] || die_usage "--project-config is required"

[ -r "$epics_file" ]     || die_input "epics-file not readable: $epics_file"
[ -r "$project_config" ] || die_input "project-config not readable: $project_config"

# ---------- Locate the target story block ----------
#
# awk state-machine (per gaia-shell-idioms): toggle in_block when the heading
# line matches; emit lines until the terminating boundary (next `### Story `
# heading or HR `---` on its own line). Avoids the awk range-bug.

block="$(awk -v key="$story_key" '
  BEGIN { in_block = 0; matched = 0 }
  {
    line = $0
    # Accept BOTH heading forms:
    #   colon:   `### Story <key>: <title>`
    #   em-dash: `### Story <key> — <title>`  (Unicode U+2014)
    #   ascii:   `### Story <key> - <title>`  (hyphen-minus, defensive)
    # The original awk pattern was `^### Story <key>:(EOL|space)` which
    # rejected the em-dash form that /gaia-create-epics accepts
    # and that the create-epics template/prose leans toward.
    if (match(line, "^### Story " key "[[:space:]]*(:|—|-)")) {
      if (in_block) {
        # We were already inside a different block of the same key — multi-
        # match condition. Flag it and bail.
        print "__GENFM_MULTIPLE_MATCHES__"
        exit 0
      }
      in_block = 1
      matched = 1
      print line
      next
    }
    if (in_block) {
      # Termination: HR `---` on its own line OR next `### Story ` heading.
      if (line == "---" || line ~ /^### Story /) {
        in_block = 0
        next
      }
      print line
    }
  }
  END {
    if (!matched) {
      print "__GENFM_NO_MATCH__"
    }
  }
' "$epics_file")"

case "$block" in
  *"__GENFM_NO_MATCH__"*)
    die_input "story key not found in epics-file: $story_key"
    ;;
  *"__GENFM_MULTIPLE_MATCHES__"*)
    die_input "multiple matches for story key in epics-file: $story_key"
    ;;
esac

# ---------- Field extraction helpers ----------

# extract_bullet <label>: emit the trimmed value of a story-detail bullet,
# accepting BOTH authored forms:
#   - **<label>:** <value>   (bold — the legacy/manually-authored form)
#   - <label>: <value>       (plain — the form gaia-create-epics SKILL.md
#                             instructs authors to use)
# The bold markers are optional so the consumer no longer disagrees with the
# producer on basic field-extraction format. Empty when not present.
extract_bullet() {
  local label="$1"
  printf '%s\n' "$block" | awk -v lab="$label" '
    {
      # Optional `**` around the label and after the colon (\\*\\*)? on each side.
      pat = "^[[:space:]]*-[[:space:]]+(\\*\\*)?" lab ":(\\*\\*)?[[:space:]]*"
      if (match($0, pat)) {
        v = substr($0, RSTART + RLENGTH)
        # Trim trailing whitespace.
        sub(/[[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  '
}

# extract_array <label>: emit a YAML flow sequence like `["A", "B"]`. When the
# label is absent or its value is empty / em-dash, emit `[]`.
extract_array() {
  local label="$1" val
  val="$(extract_bullet "$label")"
  # Strip a parenthesized comment like ` (consumes ...)` from depends_on.
  val="${val%% (*}"
  # Trim whitespace.
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  # The production epics-and-stories.md writes the bracketed YAML flow-sequence
  # form (`[E1-S1, E1-S2]`, `[E9-S11]`, `[]`) almost exclusively. Without
  # stripping the surrounding brackets the comma split embedded them in the
  # first/last element (`["[E1-S1", "E1-S2]"]`) and an empty `[]` produced a
  # phantom dependency `["[]"]`. Strip one leading `[` and one trailing `]`,
  # then re-trim, so both bracketed and unbracketed forms parse identically.
  # No-op on the unbracketed comma form.
  val="${val#[}"
  val="${val%]}"
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$val" ] || [ "$val" = "—" ] || [ "$val" = "-" ] || [ "$val" = "None" ] || [ "$val" = "none" ]; then
    printf '[]'
    return
  fi
  # Split on commas, trim each, emit `["a", "b"]`.
  printf '%s\n' "$val" | awk '
    {
      n = split($0, parts, /,/)
      out = "["
      first = 1
      for (i = 1; i <= n; i++) {
        item = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item == "") continue
        if (!first) out = out ", "
        out = out "\"" item "\""
        first = 0
      }
      out = out "]"
      print out
    }
  '
}

# Title: from `### Story <key>: <title>` OR `### Story <key> — <title>` heading.
# Accept both separators after the key (colon, em-dash, hyphen-minus) so the
# title extracts from either the create-story-shaped or the
# create-epics-shaped heading.
title=""
title="$(printf '%s\n' "$block" | awk -v key="$story_key" '
  {
    pat = "^### Story " key "[[:space:]]*(:|—|-)[[:space:]]*"
    if (match($0, pat)) {
      t = substr($0, RSTART + RLENGTH)
      sub(/[[:space:]]+$/, "", t)
      print t
      exit
    }
  }
')"

# Epic: from `**Epic:**` bullet — strip everything after the em-dash to keep
# only the key portion (e.g., `E99 — Frontmatter generation fixtures` -> `E99`).
# When the create-epics output omits the per-story `Epic:` bullet entirely
# (the SKILL prose neither emits nor requires it; the epic key is only on the
# `## EN —` parent heading), derive the epic from the story-key prefix as a
# non-blocking fallback. Story keys are <epic-key>-S<story-num> by convention
# (validate-canonical-filename.sh enforces this), so the prefix is unambiguous.
epic_raw="$(extract_bullet "Epic")"
epic="${epic_raw%% —*}"
epic="${epic%% --*}"
epic="$(printf '%s' "$epic" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [ -z "$epic" ]; then
  # Derive from story-key prefix: E1-S2 -> E1, E10-S3 -> E10, etc.
  epic="${story_key%%-S*}"
fi

# Accept BOTH Title-case (the create-epics OUTPUT TEMPLATE uses these —
# `Depends on:`, `Risk:`, `Size:`) AND snake_case (the create-epics SKILL.md
# Step 5/6 PROSE instructs `risk_level:`, `depends_on:` — an author following
# the prose produced epics whose stories the generator couldn't parse, blocking
# create-story from materializing any story at all). Each field tries the
# Title-case form first, then falls back to snake_case. The SKILL prose is
# also fixed; this fallback is the read-side belt-and-braces.
_extract_bullet_aliased() {
  # $1 = primary Title-case label; $2..$N = fallback aliases
  local val
  for label in "$@"; do
    val="$(extract_bullet "$label")"
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  done
  printf '\n'
}

_extract_array_aliased() {
  local val
  for label in "$@"; do
    val="$(extract_array "$label")"
    if [ -n "$val" ] && [ "$val" != "[]" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  done
  printf '[]\n'
}

priority="$(_extract_bullet_aliased "Priority" "priority")"

# Size: strip the parenthesized points hint (e.g., `M (3 pts)` -> `M`).
size_raw="$(_extract_bullet_aliased "Size" "size")"
size="${size_raw%% *}"

risk="$(_extract_bullet_aliased "Risk" "risk_level" "risk")"
# Normalize risk to lowercase so the producer satisfies its own
# validate-frontmatter.sh enum check (high|medium|low). The upstream
# /gaia-create-epics emits Title-case `- **Risk:** Low` per create-epics
# convention; passing it through unchanged trips CRITICAL
# `value 'Low' not in {high medium low}` in the validator.
risk="$(printf '%s' "$risk" | tr '[:upper:]' '[:lower:]')"

depends_on_yaml="$(_extract_array_aliased "Depends on" "depends_on")"
blocks_yaml="$(_extract_array_aliased "Blocks" "blocks")"
traces_to_yaml="$(_extract_array_aliased "Traces to" "traces_to")"

# ---------- Validate required fields ----------

[ -n "$title" ]    || die_input "missing field 'title' for story $story_key"
[ -n "$epic" ]     || die_input "missing field 'epic' for story $story_key"
[ -n "$priority" ] || die_input "missing field 'priority' for story $story_key"
[ -n "$size" ]     || die_input "missing field 'size' for story $story_key"
[ -n "$risk" ]     || die_input "missing field 'risk' for story $story_key"

# Validate size is one of the canonical four-tuple.
case "$size" in
  S|M|L|XL) ;;
  *) die_input "unknown size '$size' for story $story_key (expected S/M/L/XL)" ;;
esac

# ---------- Resolve points via resolve-config.sh sizing_map ----------

resolver=""
# Prefer co-located shared scripts dir (gaia-framework/plugins/gaia/scripts/) by
# walking up from this script's directory.
candidate="$(cd "$SCRIPT_DIR/../../../scripts" 2>/dev/null && pwd || true)/resolve-config.sh"
if [ -x "$candidate" ]; then
  resolver="$candidate"
else
  # Fall back to PATH discovery.
  resolver="$(command -v resolve-config.sh 2>/dev/null || true)"
fi
[ -n "$resolver" ] && [ -x "$resolver" ] || \
  die_input "resolve-config.sh not found (looked at $candidate and PATH)"

sizing_map_output=""
if ! sizing_map_output="$("$resolver" --shared "$project_config" sizing_map 2>&1)"; then
  log "resolve-config.sh sizing_map failed: $sizing_map_output"
  exit 1
fi

points=""
points="$(printf '%s\n' "$sizing_map_output" | awk -F= -v k="$size" '$1==k{print $2; exit}')"
[ -n "$points" ] || die_input "resolve-config.sh sizing_map missing key for size '$size'"

# ---------- Resolve author ----------

author=""
if author="$(git config user.name 2>/dev/null)" && [ -n "$author" ]; then
  :
else
  # Try resolve-config.sh author (positional query); ignore failure.
  author="$("$resolver" --shared "$project_config" author 2>/dev/null || true)"
  if [ -z "$author" ]; then
    author="gaia-create-story"
  fi
fi

# ---------- Date ----------

date_today="$(date +%Y-%m-%d)"

# ---------- Origin / origin_ref formatting ----------

if [ "$origin_set" -eq 1 ]; then
  origin_yaml="\"$origin\""
else
  origin_yaml="null"
fi
if [ "$origin_ref_set" -eq 1 ]; then
  origin_ref_yaml="\"$origin_ref\""
else
  origin_ref_yaml="null"
fi

# ---------- Buffer + emit YAML frontmatter ----------
#
# Field order matches story-template.md lines 1-22 (template/version/used_by
# header, then 15 fields). We emit `figma:` only when invoked with future
# Figma flags; this story does not introduce them.

output="$(cat <<EOF
---
template: 'story'
version: 1.4.0
used_by: ['create-story']
key: "$story_key"
title: "$title"
epic: "$epic"
status: backlog
priority: "$priority"
size: "$size"
points: $points
risk: "$risk"
sprint_id: null
priority_flag: null
delivered: false
deferred_implementation: false
manual_verification: $manual_verification
origin: $origin_yaml
origin_ref: $origin_ref_yaml
depends_on: $depends_on_yaml
blocks: $blocks_yaml
traces_to: $traces_to_yaml
date: "$date_today"
author: "$author"
---
EOF
)"

printf '%s\n' "$output"
