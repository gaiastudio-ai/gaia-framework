#!/usr/bin/env bash
# validate-frontmatter.sh — gaia-create-story Step 6 deterministic
#                          frontmatter validator
#
# Purpose:
#   Verify a story file's YAML frontmatter satisfies the canonical 15-field
#   schema produced by `generate-frontmatter.sh`: required fields
#   present and non-empty (with `null` allowed only for the four nullable
#   fields), enumeration constraints on `status` / `priority` / `size` /
#   `risk`, and the canonical filename invariant `{key}-{slugify(title)}.md`.
#   Surfaces schema-level drift deterministically BEFORE Val dispatch in
#   Step 6 of /gaia-create-story, saving Val tokens on the trivial mismatch
#   class and feeding the 3-attempt fix loop with structured findings.
#
# Consumers:
#   - The SKILL.md thin-orchestrator rewrite — invokes this script
#     inline at the start of Step 6 before the Val dispatch.
#   - The 3-attempt fix loop consumes this script's CRITICAL
#     findings to re-prompt the SM auto-fixer with concrete field names.
#
# Folded source:
#   - validate-canonical-filename.sh — the canonical-filename
#     check is folded in here (subsumes the standalone sibling).
#
# Contract source:
#   - .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log
#     (gaia-create-story Hardening Bundle, contract C3 status-edit discipline)
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log
#     (Scripts-over-LLM rationale)
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log
#     (Shared Val + SM Fix-Loop Dispatch Pattern, severity vocabulary)
#
# Algorithm (in order):
#   1. Parse CLI: `--file <path>` (single required flag).
#   2. Verify the target file exists and is readable; on failure, exit 2
#      (usage / argument error — distinguishable from CRITICAL findings).
#   3. Extract YAML frontmatter (block between the first two `---` lines)
#      via an awk state-machine (NOT a range pattern — see gaia-shell-idioms
#      for the awk range-bug rationale). Reject (exit 2) if delimiters are
#      missing or unbalanced; this is a malformed-file error, not a CRITICAL
#      finding.
#   4. Parse `key: value` pairs into a flat associative buffer.
#      Quote-tolerant (handles `"x"`, `'x'`, bare `x`, and bare `null`).
#   5. Validate presence + non-emptiness of the 15 required fields. Bare
#      `null` is the empty-but-valid sentinel for the four nullable fields
#      (sprint_id, priority_flag, origin, origin_ref).
#   6. Validate enumeration constraints for `status`, `priority`, `size`,
#      `risk`.
#   7. Compute canonical filename via sibling `slugify.sh` and compare
#      against `basename "$file"`. Skip when key/title were already missing.
#   8. Buffer all findings; emit on stdout. Exit 1 when at least one
#      CRITICAL finding was emitted; exit 0 on clean.
#
# Findings format (stdout, one per line):
#   <severity>|<field>|<message>
#   - severity: literal `CRITICAL` (uppercase). `WARNING` and `INFO` are
#     reserved for future expansion.
#   - field:    the offending field name; `filename` for the canonical
#     basename mismatch.
#   - message:  human-readable explanation.
#
# Exit codes:
#   0 — every check passed (silent success)
#   1 — one or more CRITICAL findings emitted to stdout
#   2 — usage error, missing/unreadable file, or malformed frontmatter
#       (delimiters missing or unbalanced)
#
# Status-edit discipline:
#   This script reads `status:` only for enumeration validation. It NEVER
#   writes to status surfaces (sprint-status.yaml, epics-and-stories.md,
#   story-index.yaml) — all status mutations flow through
#   transition-story-status.sh outside this script's scope.
#
# Locale invariance:
#   `LC_ALL=C` is set so awk/grep/sed character classes and regex semantics
#   are byte-level and identical on macOS BSD and Linux GNU userland.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="validate-frontmatter.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUGIFY="${SCRIPT_DIR}/slugify.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: validate-frontmatter.sh --file <story-file>
       validate-frontmatter.sh <story-file>          (deprecated positional form — emits NOTICE)

  --file <path>  Path to a story file. Required.

Validates the YAML frontmatter of a story file against the canonical 15-field
schema produced by generate-frontmatter.sh:

  Required (non-nullable): key, title, epic, status, priority, size, points,
                            risk, depends_on, blocks, traces_to, date, author
  Required (nullable):     sprint_id, priority_flag

  Enumerations:
    status   ∈ {backlog, ready-for-dev, in-progress, review,
                validating, done, blocked}
    priority ∈ {P0, P1, P2}
    size     ∈ {S, M, L, XL}
    risk     ∈ {high, medium, low}

  Canonical filename invariant: basename(<file>) == "{key}-{slug(title)}.md"
  where slug is computed by the sibling slugify.sh.

Findings (stdout, one per line): CRITICAL|<field>|<message>

Exit codes:
  0 — every check passed (silent success)
  1 — one or more CRITICAL findings emitted to stdout
  2 — usage error, missing/unreadable file, or malformed frontmatter
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 2; }
die_input() { log "$*"; exit 2; }

# ---------- CLI parsing ----------

file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die_usage "--file requires a value"
      file="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --*)
      die_usage "unknown argument: $1" ;;
    *)
      # Positional path form is accepted with a deprecation NOTICE. Canonical
      # form is `--file <path>`. The positional form is preserved for
      # compatibility with hand-driven scripts. Reject only when --file is
      # also supplied (no silent precedence).
      if [ -n "$file" ]; then
        die_usage "positional path '$1' supplied after --file '$file' — use only one form"
      fi
      log "NOTICE: positional path is deprecated; prefer '--file $1'"
      file="$1"; shift ;;
  esac
done

[ -n "$file" ] || die_usage "--file is required (or pass a positional path; --file is canonical)"
if [ ! -r "$file" ]; then
  die_input "file not readable: $file"
fi

# ---------- Frontmatter extraction (awk state-machine) ----------
#
# Walk the file line-by-line. State 0 = looking for opening fence; allow
# leading blank lines. State 1 = inside frontmatter; capture lines until the
# closing fence. State 2 = closed cleanly. Any other terminal state means
# the file is malformed (no frontmatter, or fence opened but never closed).

fm_status=0
frontmatter="$(awk '
  BEGIN { state = 0 }
  {
    if (state == 0) {
      if ($0 == "---") { state = 1; next }
      if ($0 ~ /^[[:space:]]*$/) next
      state = 99  # never opened
      exit
    }
    if (state == 1) {
      if ($0 == "---") { state = 2; exit }
      print
    }
  }
  END {
    if (state == 2) exit 0
    exit 4
  }
' "$file")" || fm_status=$?

if [ "$fm_status" -ne 0 ]; then
  die_input "malformed frontmatter (missing or unbalanced '---' delimiters): $file"
fi

# ---------- Field extraction (quote-tolerant) ----------
#
# extract_field <label>: emit the trimmed value of `<label>: <value>` from
# the frontmatter. Strips one pair of surrounding single or double quotes.
# Emits an empty string when the field is absent.

extract_field() {
  local label="$1" raw value
  raw="$(printf '%s\n' "$frontmatter" | awk -v lab="$label" '
    {
      pat = "^" lab ":[[:space:]]*"
      if (match($0, pat)) {
        v = substr($0, RSTART + RLENGTH)
        sub(/[[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  ')"
  case "$raw" in
    \"*\") value="${raw#\"}"; value="${value%\"}" ;;
    \'*\') value="${raw#\'}"; value="${value%\'}" ;;
    *)     value="$raw" ;;
  esac
  printf '%s' "$value"
}

# field_present <label>: 0 if the label appears at all in the frontmatter
# (even with an empty or `null` value), 1 otherwise.
field_present() {
  local label="$1"
  printf '%s\n' "$frontmatter" | awk -v lab="$label" '
    {
      pat = "^" lab ":"
      if (match($0, pat)) { found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
  '
}

# ---------- Required-field check ----------
#
# The canonical 15 fields per story-template.md. Fields in NULLABLE may be
# the bare value `null`; everything else must be non-empty and not `null`.

REQUIRED_FIELDS="key title epic status priority size points risk sprint_id priority_flag depends_on blocks traces_to date author delivered deferred_implementation"
NULLABLE_FIELDS=" sprint_id priority_flag origin origin_ref "

is_nullable() {
  local field="$1"
  case "$NULLABLE_FIELDS" in
    *" $field "*) return 0 ;;
    *)            return 1 ;;
  esac
}

findings=""

append_finding() {
  local severity="$1" field="$2" message="$3"
  findings="${findings}${severity}|${field}|${message}"$'\n'
}

for field in $REQUIRED_FIELDS; do
  if ! field_present "$field"; then
    append_finding "CRITICAL" "$field" "missing required field"
    continue
  fi
  raw_value="$(extract_field "$field")"
  # Strip whitespace.
  trimmed="$(printf '%s' "$raw_value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$trimmed" ]; then
    if is_nullable "$field"; then
      # Empty string for a nullable field is treated as null-equivalent.
      continue
    fi
    append_finding "CRITICAL" "$field" "required field is empty"
    continue
  fi
  if [ "$trimmed" = "null" ]; then
    if is_nullable "$field"; then
      continue
    fi
    append_finding "CRITICAL" "$field" "required field is null"
    continue
  fi
done

# ---------- Enumeration check ----------
#
# Validate enum-constrained fields independently of presence — if the field
# was missing, the missing-field finding already fires above. We re-extract
# here to inspect the actual value when it IS present.

check_enum() {
  local field="$1" canonical="$2" value
  if ! field_present "$field"; then
    return 0
  fi
  value="$(extract_field "$field")"
  value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  # Empty / null already flagged above; skip enum check on empty values.
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    return 0
  fi
  case " $canonical " in
    *" $value "*) return 0 ;;
    *)
      append_finding "CRITICAL" "$field" "value '$value' not in {$canonical}"
      ;;
  esac
}

check_enum "status"   "backlog ready-for-dev in-progress review validating done blocked"
check_enum "priority" "P0 P1 P2"
check_enum "size"     "S M L XL"
check_enum "risk"     "high medium low"
# priority_flag enum: {null | next-sprint | hotfix}. Hotfix value is
# human-set only. The `null` case is handled above (skips enum check on
# empty/null values).
check_enum "priority_flag" "next-sprint hotfix"

# ---------- Boolean check (`delivered:`) ----------
#
# The `delivered:` field (16th required field) must be a bare `true` or
# `false`. Anything else fires a CRITICAL.

check_boolean() {
  local field="$1" value
  if ! field_present "$field"; then
    return 0
  fi
  value="$(extract_field "$field")"
  value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    return 0
  fi
  case "$value" in
    true|false) return 0 ;;
    *)
      append_finding "CRITICAL" "$field" "must be true or false (got: $value)"
      ;;
  esac
}

check_boolean "delivered"

# ---------- Boolean check (`deferred_implementation:`) ----------
#
# The `deferred_implementation:` field (17th required field) must be a bare
# `true` or `false`. Consumed by /gaia-sprint-review when computing
# sprint-completion deferral signals.
check_boolean "deferred_implementation"

# ---------- Review Gate body-shape check ----------
#
# Enforce the canonical 3-column Review Gate table shape (`Review | Status |
# Report`). A 2-column drift has been known to break the reviews skill;
# this check catches that drift at validation time. The body
# scan runs only after frontmatter parsing has succeeded — malformed-
# frontmatter files have already exited 2 by this point.
#
# Algorithm:
#   1. awk-scan the body for `## Review Gate` (exact, case-sensitive header).
#   2. After the heading, locate the next pipe-table header row (a line that
#      starts with `|` and is NOT the separator `|---|---|...|`).
#   3. Strip the leading/trailing pipes, split on `|`, trim each cell, lower-
#      case, and compare to the literal triple `review|status|report`.
#   4. On mismatch, emit `CRITICAL|review_gate|...`. Heading-missing and
#      table-missing cases each have a distinct message.

REVIEW_GATE_AWK='
  BEGIN { state = 0 }
  state == 0 && /^## Review Gate[[:space:]]*$/ { state = 1; next }
  state == 1 {
    # Skip blank lines and blockquote prose between heading and table.
    if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^>/) next
    # Bail out if a new section starts before any table appears.
    if ($0 ~ /^##[[:space:]]/) { state = 3; exit }
    # Pipe-table header row: starts with `|` and contains a non-separator cell.
    if ($0 ~ /^\|/) {
      # Reject the separator row as the header (all dashes between pipes).
      tmp = $0
      gsub(/[[:space:]|:-]/, "", tmp)
      if (tmp == "") next
      print
      state = 2
      exit
    }
  }
  END {
    if (state == 0) exit 10  # heading missing
    if (state == 1) exit 11  # heading present, no table found before EOF
    if (state == 3) exit 11  # heading present, next ## arrived first
    # state == 2: header row was printed and exit 0
  }
'

review_gate_status=0
review_gate_header="$(awk "$REVIEW_GATE_AWK" "$file")" || review_gate_status=$?

case "$review_gate_status" in
  0)
    # Header row captured — verify the column triple.
    header_trim="$(printf '%s' "$review_gate_header" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    # Strip a single leading and trailing `|` if present.
    header_inner="${header_trim#|}"
    header_inner="${header_inner%|}"
    # Lowercase + per-cell trim.
    normalized="$(printf '%s' "$header_inner" | awk -F'|' '
      {
        out = ""
        for (i = 1; i <= NF; i++) {
          cell = $i
          sub(/^[[:space:]]+/, "", cell)
          sub(/[[:space:]]+$/, "", cell)
          # Lowercase via tr-equivalent.
          cell = tolower(cell)
          if (i > 1) out = out "|"
          out = out cell
        }
        print out
      }
    ')"
    if [ "$normalized" != "review|status|report" ]; then
      # Count the columns for the diagnostic.
      col_count="$(printf '%s\n' "$normalized" | awk -F'|' '{print NF}')"
      append_finding "CRITICAL" "review_gate" \
        "expected 3 columns 'Review|Status|Report', got ${col_count} columns '${header_trim}' (Report column drift breaks the reviews skill)"
    fi
    ;;
  10)
    append_finding "CRITICAL" "review_gate" "missing Review Gate section (expected '## Review Gate' heading)"
    ;;
  11)
    append_finding "CRITICAL" "review_gate" "missing Review Gate table (heading present but no pipe-table follows)"
    ;;
esac

# ---------- Canonical filename check ----------
#
# Skip when key or title was already flagged missing — emitting a noisy
# filename finding on top would clutter the SM fix-loop output.

key="$(extract_field "key")"
title="$(extract_field "title")"
key_trim="$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
title_trim="$(printf '%s' "$title" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

if [ -n "$key_trim" ] && [ -n "$title_trim" ] && [ "$key_trim" != "null" ] && [ "$title_trim" != "null" ]; then
  if [ ! -x "$SLUGIFY" ]; then
    log "sibling slugify.sh missing or non-executable: $SLUGIFY"
    exit 2
  fi
  slug=""
  if ! slug="$("$SLUGIFY" --title "$title_trim" 2>/dev/null)"; then
    log "slugify.sh failed for title: $title_trim"
    exit 2
  fi
  expected_basename="${key_trim}-${slug}.md"
  actual_basename="$(basename "$file")"
  # Layout-aware canonical check. The per-story layout places the file at
  # `epic-{slug}/{key}-{slug}/story.md`: the basename is the literal
  # `story.md` and the KEY+SLUG identity is carried by the parent directory
  # name. In that layout, validate the parent dir against `{key}-{slug}`
  # instead of the basename (mirrors validate-canonical-filename.sh which
  # already accepts this form). Legacy flat / `stories/` layouts keep the
  # basename invariant.
  if [ "$actual_basename" = "story.md" ]; then
    case "$file" in
      */stories/*)
        # A `story.md` under a legacy `stories/` segment is NOT the new
        # per-story layout — flag it (basename should encode key+slug there).
        append_finding "CRITICAL" "filename" "expected '${expected_basename}', got 'story.md' under a legacy stories/ path"
        ;;
      *)
        actual_dirname="$(basename "$(dirname "$file")")"
        expected_dirname="${key_trim}-${slug}"
        if [ "$expected_dirname" != "$actual_dirname" ]; then
          append_finding "CRITICAL" "filename" "per-story dir expected '${expected_dirname}/', got '${actual_dirname}/' (story.md layout)"
        fi
        ;;
    esac
  elif [ "$expected_basename" != "$actual_basename" ]; then
    append_finding "CRITICAL" "filename" "expected '${expected_basename}', got '${actual_basename}'"
  fi
fi

# ---------- Emit findings + exit ----------

if [ -n "$findings" ]; then
  printf '%s' "$findings"
  exit 1
fi

exit 0
