#!/usr/bin/env bash
# escalation-halt.sh — Action-item escalation halt predicate
#
# Read-only library. Used by the gaia-sprint-plan SKILL Step 1.5 to detect
# HIGH-priority action items that have been open for two or more sprints
# (escalation_count >= 2) and halt sprint planning before any sprint-status
# mutation or story-selection prompt occurs. Writes (override recording)
# go through sprint-state.sh.
#
# Public functions:
#   esch_scan                    <action_items_yaml>
#   esch_filter_blocking         (stdin: records)
#   esch_format_halt_message     (stdin: blocking records)
#   esch_check_override_recorded <sprint_status_yaml> <comma_or_space_sep_ids>
#   esch_check_blocking          <action_items_yaml> <sprint_status_yaml>
#
# Environment:
#   GAIA_ESCALATION_HALT=off    kill switch — esch_check_blocking auto-proceeds
#                               (rollback toggle per Dev Notes §Rollback)
#
# Record shape: pipe-delimited text, one item per line:
#   <id>|<title>|<priority>|<status>|<escalation_count>
#
# Schema contract (action_items block):
#   action_items:
#     - id: AI-42
#       title: "Long-running action item"
#       classification: process
#       priority: HIGH
#       status: open
#       escalation_count: 2
#
# Filter predicate: priority == "HIGH" AND escalation_count >= 2 AND status == "open"
# (case-sensitive per story §Technical Notes).
#
# Sibling of: priority-flag.sh, sprint-state.sh.

set -euo pipefail
SCRIPT_NAME="${SCRIPT_NAME:-escalation-halt.sh}"

# ---------------------------------------------------------------------------
# esch_scan — read action-items.yaml and emit pipe-delimited records
# $1 = path to action-items.yaml
# On missing/unreadable/empty file: emit single-line warning to stderr,
# print nothing to stdout, exit 0 (non-blocking by design).
# ---------------------------------------------------------------------------
esch_scan() {
  local file="$1"
  if [ ! -e "$file" ]; then
    printf 'NOTE: action-items.yaml not found at %s — escalation halt skipped\n' \
      "$file" >&2
    return 0
  fi
  if [ ! -s "$file" ]; then
    # Empty file is treated identically to missing file.
    return 0
  fi

  # Parse each action_items entry block. Pure awk, bash 3.2 compatible.
  awk '
    BEGIN { in_list = 0; have = 0; id = ""; title = ""; priority = ""; status = ""; esc = "" }
    function emit() {
      if (id != "") {
        printf "%s|%s|%s|%s|%s\n", id, title, priority, status, esc
      }
      id = ""; title = ""; priority = ""; status = ""; esc = ""; have = 0
    }
    function strip(v) {
      gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", v)
      return v
    }
    {
      raw = $0
      sub(/\r$/, "", raw)
    }
    raw ~ /^action_items:[[:space:]]*$/ { in_list = 1; next }
    # action_items: [] (empty list) — nothing to emit
    raw ~ /^action_items:[[:space:]]*\[\][[:space:]]*$/ { in_list = 0; next }
    !in_list { next }
    # Top-level (zero-indent, non-list) key closes the list section.
    raw ~ /^[^[:space:]-]/ { emit(); in_list = 0; next }
    # A new list entry starts with "  - id:".
    raw ~ /^[[:space:]]+-[[:space:]]+id:[[:space:]]*/ {
      emit()
      v = raw
      sub(/^[[:space:]]+-[[:space:]]+id:[[:space:]]*/, "", v)
      id = strip(v)
      have = 1
      next
    }
    have && raw ~ /^[[:space:]]+title:[[:space:]]*/ {
      v = raw; sub(/^[[:space:]]+title:[[:space:]]*/, "", v); title = strip(v); next
    }
    have && raw ~ /^[[:space:]]+priority:[[:space:]]*/ {
      v = raw; sub(/^[[:space:]]+priority:[[:space:]]*/, "", v); priority = strip(v); next
    }
    have && raw ~ /^[[:space:]]+status:[[:space:]]*/ {
      v = raw; sub(/^[[:space:]]+status:[[:space:]]*/, "", v); status = strip(v); next
    }
    have && raw ~ /^[[:space:]]+escalation_count:[[:space:]]*/ {
      v = raw; sub(/^[[:space:]]+escalation_count:[[:space:]]*/, "", v); esc = strip(v); next
    }
    END { emit() }
  ' "$file"
}

# ---------------------------------------------------------------------------
# esch_filter_blocking — filter stdin records to HIGH + esc>=2 + open
# stdin: <id>|<title>|<priority>|<status>|<escalation_count> lines
# stdout: same shape, filtered
# Case-sensitive on "HIGH" and "open" per story §Technical Notes.
# ---------------------------------------------------------------------------
esch_filter_blocking() {
  awk -F'|' '
    NF >= 5 && $3 == "HIGH" && $4 == "open" && ($5 + 0) >= 2 { print }
  '
}

# ---------------------------------------------------------------------------
# esch_format_halt_message — format blocking items + exit guidance
# stdin: blocking records (output of esch_filter_blocking)
# stdout: human-readable halt message with ids, titles, counts, and the
# exit-guidance block referencing /gaia-action-items and the override flag.
# ---------------------------------------------------------------------------
esch_format_halt_message() {
  awk -F'|' '
    BEGIN {
      printf "HALT: sprint planning blocked by HIGH-priority action items with escalation_count >= 2.\n\n"
      printf "BLOCKING ITEMS:\n"
    }
    NF >= 5 {
      printf "  - %s  (escalation_count=%s, priority: HIGH)  %s\n", $1, $5, $2
    }
    END {
      printf "\n"
      printf "Resolution:\n"
      printf "  1. Run /gaia-action-items to triage and resolve the blocking items.\n"
      printf "  2. OR re-invoke /gaia-sprint-plan with the explicit override:\n"
      printf "       --override-escalation-halt --reason \"<your reason>\"\n"
      printf "     The override is recorded in sprint-status.yaml and is idempotent\n"
      printf "     for the same (sprint, items) pair.\n"
    }
  '
}

# ---------------------------------------------------------------------------
# _esch_normalize_ids — sort + dedupe a comma-or-space-separated id list.
# stdin: <no stdin>; $1 = raw id list
# stdout: newline-separated sorted unique ids, joined by comma on one line.
# Internal helper — not exported as a public API.
# ---------------------------------------------------------------------------
_esch_normalize_ids() {
  local raw="$1"
  printf '%s' "$raw" \
    | tr ',' '\n' \
    | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }' \
    | sort -u \
    | awk 'BEGIN{first=1} { if (!first) printf ","; printf "%s", $0; first=0 } END { printf "\n" }'
}

# ---------------------------------------------------------------------------
# esch_check_override_recorded — idempotency predicate
# $1 = sprint-status.yaml path
# $2 = comma-or-space-separated list of item ids to match
# Exit 0 if an `overrides:` entry with override_type: escalation_halt and
# the same sorted-unique id set already exists. Exit 1 otherwise.
# ---------------------------------------------------------------------------
esch_check_override_recorded() {
  local yaml="$1" ids_raw="$2"
  if [ ! -r "$yaml" ]; then
    return 1
  fi
  local wanted
  wanted="$(_esch_normalize_ids "$ids_raw")"
  [ -n "$wanted" ] || return 1

  # Walk `overrides:` entries. Two-pass approach: first extract entry blocks
  # (each separated by "  - " at the section's entry-indent), then check each
  # block for override_type: escalation_halt and matching id set.
  local found
  found="$(awk -v wanted="$wanted" '
    function trim(v) {
      gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", v)
      return v
    }
    function check_entry(buf,    lines, n, i, ot, ids_list, in_ids, j, arr, m, out, prev, line, v) {
      # Parse one override entry buffer
      n = split(buf, lines, /\n/)
      ot = ""
      ids_list = ""
      in_ids = 0
      for (i = 1; i <= n; i++) {
        line = lines[i]
        sub(/\r$/, "", line)
        if (line ~ /override_type:[[:space:]]*/) {
          v = line; sub(/.*override_type:[[:space:]]*/, "", v)
          ot = trim(v)
          in_ids = 0
          continue
        }
        if (line ~ /overridden_item_ids:[[:space:]]*\[/) {
          v = line; sub(/.*overridden_item_ids:[[:space:]]*\[/, "", v)
          sub(/\][[:space:]]*$/, "", v)
          gsub(/["'\'']/, "", v)
          ids_list = v
          in_ids = 0
          continue
        }
        if (line ~ /overridden_item_ids:[[:space:]]*$/) {
          in_ids = 1
          continue
        }
        if (in_ids && line ~ /^[[:space:]]+-[[:space:]]+/) {
          v = line; sub(/^[[:space:]]+-[[:space:]]+/, "", v)
          v = trim(v)
          ids_list = (ids_list == "" ? v : ids_list "," v)
          continue
        }
        if (in_ids && line !~ /^[[:space:]]*-/ && line !~ /^[[:space:]]*$/) {
          in_ids = 0
        }
      }
      if (ot != "escalation_halt" || ids_list == "") return 0
      # Normalize ids_list: split on comma, trim, sort, dedupe
      m = split(ids_list, arr, /,/)
      for (j = 1; j <= m; j++) arr[j] = trim(arr[j])
      # Sort
      for (j = 1; j <= m; j++) {
        for (k = j+1; k <= m; k++) {
          if (arr[k] < arr[j]) { t = arr[j]; arr[j] = arr[k]; arr[k] = t }
        }
      }
      prev = ""
      out = ""
      for (j = 1; j <= m; j++) {
        if (arr[j] == "" || arr[j] == prev) continue
        out = out == "" ? arr[j] : out "," arr[j]
        prev = arr[j]
      }
      return (out == wanted)
    }
    BEGIN { in_over = 0; buf = ""; have_buf = 0; entry_indent = -1 }
    {
      raw = $0
      sub(/\r$/, "", raw)
    }
    raw ~ /^overrides:[[:space:]]*$/ { in_over = 1; entry_indent = -1; next }
    # Top-level (column 0, non-dash) line closes the section
    in_over && raw ~ /^[^[:space:]-]/ {
      if (have_buf && check_entry(buf)) { print "MATCH"; exit }
      in_over = 0; buf = ""; have_buf = 0; entry_indent = -1
      next
    }
    !in_over { next }
    # Determine indent width of this line for dash lines
    raw ~ /^[[:space:]]+-[[:space:]]/ {
      match(raw, /^[[:space:]]+/)
      this_indent = RLENGTH
      # First dash under overrides: establishes the entry indent
      if (entry_indent < 0) {
        entry_indent = this_indent
        buf = raw
        have_buf = 1
        next
      }
      # Dash at the entry indent level: start of a new override entry.
      if (this_indent == entry_indent) {
        if (have_buf && check_entry(buf)) { print "MATCH"; exit }
        buf = raw
        have_buf = 1
        next
      }
      # Deeper dash — part of a nested list (e.g., overridden_item_ids)
      if (have_buf) { buf = buf "\n" raw }
      next
    }
    have_buf { buf = buf "\n" raw; next }
    END {
      if (have_buf && check_entry(buf)) print "MATCH"
    }
  ' "$yaml")"

  [ "$found" = "MATCH" ]
}

# ---------------------------------------------------------------------------
# esch_check_blocking — top-level SKILL Step 1.5 predicate.
# $1 = action-items.yaml path
# $2 = sprint-status.yaml path
# Exit 0 (proceed) if:
#   - GAIA_ESCALATION_HALT=off (kill switch)
#   - OR no blocking items exist
#   - OR all blocking items have a recorded override for this sprint
# Exit 1 (halt) with formatted halt message on stdout otherwise.
# Emits the missing-file / empty-file NOTE on stderr as esch_scan does.
# ---------------------------------------------------------------------------
esch_check_blocking() {
  local ai="$1" ss="$2"

  # Kill switch (Dev Notes §Rollback toggle)
  if [ "${GAIA_ESCALATION_HALT:-on}" = "off" ]; then
    return 0
  fi

  local records blocking
  records="$(esch_scan "$ai")"
  if [ -z "$records" ]; then
    return 0
  fi
  blocking="$(printf '%s\n' "$records" | esch_filter_blocking)"
  if [ -z "$blocking" ]; then
    return 0
  fi

  # Extract just the ids from blocking items
  local ids
  ids="$(printf '%s\n' "$blocking" | awk -F'|' '{ print $1 }' | paste -sd',' -)"

  if [ -n "$ids" ] && esch_check_override_recorded "$ss" "$ids"; then
    # Override already recorded — idempotent proceed
    return 0
  fi

  printf '%s\n' "$blocking" | esch_format_halt_message
  return 1
}
