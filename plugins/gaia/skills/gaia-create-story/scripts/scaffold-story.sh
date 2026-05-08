#!/usr/bin/env bash
# scaffold-story.sh — gaia-create-story Step 4 deterministic story-skeleton
#                     emitter (E63-S9 / Work Item 6.4)
#
# Purpose:
#   Render a story file from a template by populating the deterministic
#   structural sections (Review Gate, DoD, Findings, Estimate, Dev Agent
#   Record) with a frontmatter-derived value substitution pass, and replacing
#   the body of every content-bearing section (User Story, Acceptance
#   Criteria, Tasks / Subtasks, Dev Notes, Technical Notes, Dependencies,
#   Test Scenarios) with a single `{CONTENT_PLACEHOLDER}` line under the
#   section heading. The downstream LLM Edit step fills the placeholders.
#
# Consumers:
#   - E63-S11 SKILL.md thin-orchestrator rewrite — invokes this script inline
#     after slug derivation (E63-S1) and frontmatter generation (E63-S3).
#
# Upstream dependencies:
#   - E63-S1 slugify.sh             (caller-side slug derivation)
#   - E63-S3 generate-frontmatter.sh (produces the YAML block this script
#                                     consumes via --frontmatter)
#
# Contract source:
#   - ADR-074 contract C3 — status-edit discipline (force `status: backlog`,
#     never write to sprint-status.yaml, epics-and-stories.md,
#     story-index.yaml, or test-plan.md)
#   - ADR-042            — Scripts-over-LLM rationale
#   - docs/planning-artifacts/feature-create-story-hardening.md#Work-Item-6.4
#
# Algorithm (in order):
#   1. Parse CLI flags: --template, --output, --frontmatter (string or `-`
#      for stdin). All three required.
#   2. Validate inputs before any write: template exists; output parent dir
#      exists; frontmatter parses (minimal awk YAML extractor).
#   3. Build a token-value table from the frontmatter YAML. Force
#      `status: backlog` regardless of caller input.
#   4. Read the template; identify the frontmatter block (between the first
#      two `^---$` markers) and the body.
#   5. Walk the frontmatter region: token-substitute `{placeholder}` tokens.
#   6. Walk the body: emit deterministic sections verbatim with token
#      substitution; for each content-bearing section heading, emit the
#      heading and a single `{CONTENT_PLACEHOLDER}` line, dropping the
#      template's example body.
#   7. Atomic write: assemble into a `mktemp` staging file; `mv` to --output.
#   8. Emit the seven content section names to stdout in declaration order.
#
# Exit codes:
#   0 — success
#   1 — input / runtime error (missing template, malformed YAML, missing
#       parent directory, write failure)
#   2 — usage error (missing required flag, unknown flag)
#
# Locale invariance:
#   `LC_ALL=C` is set so awk pattern matching, sort/grep character classes,
#   and tr/sed semantics behave identically on macOS BSD and Linux GNU.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="scaffold-story.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: scaffold-story.sh \
         --template <path> \
         --output <path> \
         --frontmatter <yaml-block | ->

  --template <path>         Path to the story template (e.g.,
                            story-template.md). Required.
  --output <path>           Path to write the populated story file.
                            Required. Parent directory must exist.
  --frontmatter <yaml | ->  YAML frontmatter block (a single string with
                            embedded newlines), or `-` to read from stdin.
                            Required. Must include the canonical 15
                            frontmatter fields.

Behavior:
  - Frontmatter `{placeholder}` tokens are replaced with caller-supplied
    values from the YAML block.
  - `status:` is FORCED to `backlog` regardless of caller input
    (ADR-074 contract C3).
  - Deterministic body sections (Findings, Review Gate, Estimate,
    Definition of Done, Dev Agent Record skeleton) are emitted verbatim
    with token substitution applied.
  - Content sections (User Story, Acceptance Criteria, Tasks / Subtasks,
    Dev Notes, Technical Notes, Dependencies, Test Scenarios) emit only
    their heading plus a single `{CONTENT_PLACEHOLDER}` line; the
    template's example contents are dropped.
  - On success, stdout lists the seven content section names in
    declaration order.

Exit codes: 0 success | 1 input/runtime error | 2 usage error.
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 2; }
die_input() { log "$*"; exit 1; }

# ---------- CLI parsing ----------

template=""
output=""
frontmatter_arg=""
frontmatter_set=0

while [ $# -gt 0 ]; do
  case "$1" in
    --template)
      [ $# -ge 2 ] || die_usage "--template requires a value"
      template="$2"; shift 2 ;;
    --output)
      [ $# -ge 2 ] || die_usage "--output requires a value"
      output="$2"; shift 2 ;;
    --frontmatter)
      [ $# -ge 2 ] || die_usage "--frontmatter requires a value"
      frontmatter_arg="$2"; frontmatter_set=1; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$template" ]       || die_usage "--template is required"
[ -n "$output" ]         || die_usage "--output is required"
[ "$frontmatter_set" -eq 1 ] || die_usage "--frontmatter is required"

# ---------- Input validation ----------

[ -f "$template" ] || die_input "template not found: $template"

output_dir="$(dirname -- "$output")"
[ -d "$output_dir" ] || die_input "parent directory does not exist: $output_dir"

# Read frontmatter from stdin when `-` is supplied; otherwise use the arg.
if [ "$frontmatter_arg" = "-" ]; then
  frontmatter_yaml="$(cat)"
else
  frontmatter_yaml="$frontmatter_arg"
fi

[ -n "$frontmatter_yaml" ] || die_input "frontmatter YAML is empty"

# ---------- Parse frontmatter YAML into key=value table ----------
#
# Minimal awk-based extractor for the small known field set. We accept
# `key: value`, `key: "value"`, `key: 'value'`, and `key: null`. Values may
# be unquoted scalars, quoted strings, or YAML flow arrays (preserved
# verbatim). Lines starting with `#`, `---`, or blanks are ignored.
#
# Validation: at least one well-formed `key: value` line is required, AND
# at least one of the canonical 15 fields (key, title, epic) must be
# present. This rejects the degenerate `not: : valid: yaml` malformed input.

frontmatter_kv="$(printf '%s\n' "$frontmatter_yaml" | awk '
  BEGIN { ok = 0 }
  /^---$/ { next }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    line = $0
    # Match `key: value` where key is a YAML identifier (letters, digits,
    # underscore, hyphen). Use index-based parsing, not regex range, to
    # avoid awk range-bug surprises.
    pos = index(line, ":")
    if (pos < 2) next
    key = substr(line, 1, pos - 1)
    val = substr(line, pos + 1)
    # Trim leading whitespace from key.
    sub(/^[[:space:]]+/, "", key)
    sub(/[[:space:]]+$/, "", key)
    # Reject keys with whitespace embedded (malformed).
    if (key ~ /[[:space:]]/) next
    # Reject empty key (e.g., `: : valid: yaml` first segment is empty).
    if (key == "") next
    # Trim leading whitespace from value.
    sub(/^[[:space:]]+/, "", val)
    sub(/[[:space:]]+$/, "", val)
    # Print on a single line: key=value (literal; downstream consumes).
    printf "%s=%s\n", key, val
    ok = 1
  }
  END {
    if (!ok) {
      print "__SCAFFOLD_PARSE_FAILED__"
      exit 0
    }
  }
')"

case "$frontmatter_kv" in
  *"__SCAFFOLD_PARSE_FAILED__"*)
    die_input "malformed frontmatter YAML: no parseable key:value pairs found"
    ;;
esac

# Single-pass validation:
#   (a) Reject any value beginning with `:` (after whitespace trim) — the
#       canonical malformed probe `not: : valid: yaml` yields a key `not`
#       whose value starts with `:`, which the awk extractor cannot
#       cleanly parse.
#   (b) Require at least one canonical field — guards against parser
#       success on irrelevant input (e.g., a YAML doc with only `foo: bar`).
canonical_present=0
while IFS= read -r kv; do
  [ -n "$kv" ] || continue
  k_part="${kv%%=*}"
  v_part="${kv#*=}"
  case "$v_part" in
    :*) die_input "malformed frontmatter YAML: value begins with ':' (unparseable)" ;;
  esac
  case "$k_part" in
    key|title|epic|priority|size|risk|points)
      canonical_present=1
      ;;
  esac
done <<EOF
$frontmatter_kv
EOF
[ "$canonical_present" -eq 1 ] || die_input "malformed frontmatter YAML: no canonical fields found"

# ---------- Build token-value table ----------
#
# Tokens used in the bundled template:
#   {story_key}       <- key
#   {story_title}     <- title
#   {epic_key}        <- epic
#   {P0/P1/P2}        <- priority
#   {S/M/L/XL}        <- size
#   {story_points}    <- points (frontmatter scalar)
#   {high/medium/low} <- risk
#   {creation_date}   <- date
#   {agent_name}      <- author
#   {story points}    <- points (Estimate body line uses spaced form)
#   {assigned agent}  <- author (Estimate body line)
#   {role}, {action}, {benefit}, {context}, {expected result},
#   {input}, {output}, {happy path}, {edge case},
#   {Implementation guidance, ...}, {Dependency on other story or system},
#   {agent_model_name_version}
#   — these last appear inside CONTENT sections and are dropped wholesale
#     when those sections are replaced by `{CONTENT_PLACEHOLDER}`.
#
# Helper: extract a value for a given key, stripping surrounding quotes.
extract_value() {
  local k="$1" raw v
  raw="$(printf '%s\n' "$frontmatter_kv" | awk -F= -v key="$k" '
    $1 == key { sub(/^[^=]*=/, "", $0); print $0; exit }
  ')"
  v="$raw"
  # Strip matching surrounding double or single quotes.
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# E80-S1: extract a YAML value verbatim — no quote stripping. Used for
# fields whose template tokens have no surrounding quotes (origin,
# origin_ref, depends_on, blocks, traces_to). Preserves the upstream YAML
# shape: bare `null`, quoted `"…"`, or flow array `["a","b"]`.
extract_value_raw() {
  local k="$1"
  printf '%s\n' "$frontmatter_kv" | awk -F= -v key="$k" '
    $1 == key { sub(/^[^=]*=/, "", $0); print $0; exit }
  '
}

key_v="$(extract_value key)"
title_v="$(extract_value title)"
epic_v="$(extract_value epic)"
priority_v="$(extract_value priority)"
size_v="$(extract_value size)"
points_v="$(extract_value points)"
risk_v="$(extract_value risk)"
date_v="$(extract_value date)"
author_v="$(extract_value author)"
# E80-S1: also extract the five fields the template now exposes as tokens.
# Use the RAW extractor so the upstream YAML shape is preserved verbatim —
# bare `null`, quoted `"…"`, or flow array `["a","b"]`. The corresponding
# template tokens have NO surrounding quotes (e.g., `origin: {origin}`), so
# the substituted output is valid YAML in every shape generate-frontmatter.sh
# emits.
origin_v="$(extract_value_raw origin)"
origin_ref_v="$(extract_value_raw origin_ref)"
depends_on_v="$(extract_value_raw depends_on)"
blocks_v="$(extract_value_raw blocks)"
traces_to_v="$(extract_value_raw traces_to)"

# ---------- Read template ----------

template_text="$(cat "$template")"

# ---------- Process the template line-by-line ----------
#
# State machine:
#   region = frontmatter | body
#   in_content_section: 1 when we are inside a heading whose section is
#                       content-bearing; we suppress the body and emit a
#                       single `{CONTENT_PLACEHOLDER}` once.
#   placeholder_emitted: per-section flag to ensure exactly one
#                        `{CONTENT_PLACEHOLDER}` line.
#
# Content-bearing sections (heading text after `## `):
#   User Story
#   Acceptance Criteria
#   Tasks / Subtasks
#   Dev Notes
#   Technical Notes
#   Dependencies
#   Test Scenarios
#
# Non-content (deterministic) sections — emitted verbatim with token
# substitution:
#   Findings
#   Review Gate
#   Estimate
#   Definition of Done
#   Dev Agent Record (and its `### Agent Model Used` etc. subsections)
#
# Headings inside the Test Scenarios block (### Project Structure Notes,
# ### References) are part of the Test Scenarios content — they are
# suppressed entirely along with the rest of the Test Scenarios body.
#
# We emit by region:
#   - Frontmatter region (between first two `---`): token-substitute and
#     emit verbatim, except force `status: backlog`.
#   - Body region (after second `---`): walk; deterministic sections are
#     copied with token substitution; content sections drop their bodies.

scaffold="$(printf '%s\n' "$template_text" | awk \
  -v key_v="$key_v" \
  -v title_v="$title_v" \
  -v epic_v="$epic_v" \
  -v priority_v="$priority_v" \
  -v size_v="$size_v" \
  -v points_v="$points_v" \
  -v risk_v="$risk_v" \
  -v date_v="$date_v" \
  -v author_v="$author_v" \
  -v origin_v="$origin_v" \
  -v origin_ref_v="$origin_ref_v" \
  -v depends_on_v="$depends_on_v" \
  -v blocks_v="$blocks_v" \
  -v traces_to_v="$traces_to_v" '
  function token_sub(s,    out) {
    out = s
    gsub(/\{story_key\}/,         key_v,      out)
    gsub(/\{story_title\}/,       title_v,    out)
    gsub(/\{epic_key\}/,          epic_v,     out)
    gsub(/\{P0\/P1\/P2\}/,        priority_v, out)
    gsub(/\{S\/M\/L\/XL\}/,       size_v,     out)
    gsub(/\{story_points\}/,      points_v,   out)
    gsub(/\{high\/medium\/low\}/, risk_v,     out)
    gsub(/\{creation_date\}/,     date_v,     out)
    gsub(/\{agent_name\}/,        author_v,   out)
    # Estimate body uses spaced forms.
    gsub(/\{story points\}/,      points_v,   out)
    gsub(/\{assigned agent\}/,    author_v,   out)
    # E80-S1: substitute the five frontmatter tokens that previously
    # remained as template defaults (origin: null, depends_on: [], ...).
    gsub(/\{origin\}/,            origin_v,     out)
    gsub(/\{origin_ref\}/,        origin_ref_v, out)
    gsub(/\{depends_on\}/,        depends_on_v, out)
    gsub(/\{blocks\}/,            blocks_v,     out)
    gsub(/\{traces_to\}/,         traces_to_v,  out)
    return out
  }
  function is_content_heading(line,    s) {
    # Match `## <Section>` exactly (no trailing chars).
    if (line == "## User Story")            return 1
    if (line == "## Acceptance Criteria")   return 1
    if (line == "## Tasks / Subtasks")      return 1
    if (line == "## Dev Notes")             return 1
    if (line == "## Technical Notes")       return 1
    if (line == "## Dependencies")          return 1
    if (line == "## Test Scenarios")        return 1
    return 0
  }
  function is_section_heading(line) {
    # Any `## ` heading terminates the prior content section.
    return (substr(line, 1, 3) == "## ")
  }
  BEGIN {
    region = "pre"          # before first ---
    fm_dash_count = 0
    in_content = 0
  }
  {
    line = $0
    if (region == "pre") {
      # Looking for first --- to enter frontmatter region.
      if (line == "---") {
        fm_dash_count = 1
        region = "frontmatter"
        print line
        next
      }
      # Anything before --- (none in template) is passed through.
      print line
      next
    }
    if (region == "frontmatter") {
      if (line == "---") {
        fm_dash_count = 2
        region = "body"
        print line
        next
      }
      # Force status: backlog. Match `status:` at the start (after optional
      # whitespace) and rewrite the entire line.
      if (match(line, /^[[:space:]]*status:[[:space:]]*/)) {
        print "status: backlog"
        next
      }
      print token_sub(line)
      next
    }
    # region == "body"
    if (is_section_heading(line)) {
      # Closing the prior content section if we were in one.
      in_content = is_content_heading(line) ? 1 : 0
      print line
      if (in_content) {
        # Emit the placeholder and then suppress until the next `## `
        # heading. We emit a leading blank line to mirror the template
        # rhythm? — NO: the spec requires the placeholder line immediately
        # under the heading. We keep a blank line above the placeholder
        # for readability and a blank line below to match section spacing.
        print ""
        print "{CONTENT_PLACEHOLDER}"
        print ""
      }
      next
    }
    if (in_content) {
      # Drop the rest of the content section body (including ### subsections
      # like Project Structure Notes / References).
      next
    }
    # Deterministic body line — apply token substitution and emit.
    print token_sub(line)
  }
')"

# Trim trailing whitespace artifacts (defensive — awk emits clean lines).
# We do NOT add a trailing newline beyond what awk produces.

# ---------- Atomic write ----------

tmp_file="$(mktemp "${TMPDIR:-/tmp}/scaffold-story.XXXXXX")"
# Cleanup on any failure.
trap 'rm -f "$tmp_file"' EXIT

printf '%s\n' "$scaffold" >"$tmp_file"

# Move atomically into place. mv across same filesystem is atomic.
if ! mv -f "$tmp_file" "$output"; then
  die_input "failed to write output: $output"
fi
trap - EXIT

# ---------- Emit content section names on stdout ----------

cat <<'NAMES'
User Story
Acceptance Criteria
Tasks / Subtasks
Dev Notes
Technical Notes
Dependencies
Test Scenarios
NAMES
