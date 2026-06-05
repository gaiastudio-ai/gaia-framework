#!/usr/bin/env bash
# triage-guard.sh — done-story immutability guard for /gaia-triage-findings
#
# Done-Story Immutability Guard:
#   /gaia-triage-findings MUST halt on ADD TO EXISTING classifications that
#   target a story with `status: done`, with an explicit override flag that
#   records the override in the triage report for retrospective review.
#
# CLI contract:
#   triage-guard.sh check <story_file>
#     Exit 0 — proceed (status in [in-progress, review, ready-for-dev,
#                                   validating, backlog])
#     Exit 2 — HALT with done-story guidance emitted on stdout
#     Exit 1 — error (missing file, malformed frontmatter)
#
#   triage-guard.sh check --override --user <u> --date <d> --finding <fid> \
#                         --reason <r> --report <path> <story_file>
#     Exit 0 — override recorded in triage report; proceed
#     Exit 1 — error (missing required flag, write failure)
#
# Non-mutation invariant: this script NEVER writes to the story file. Only
# the triage report (passed via --report) is written on the override path.
#
# Shared with gaia-triage-findings/SKILL.md Step 3 (ADD TO EXISTING branch).
# Deterministic guard logic lives in a testable shell script rather than
# SKILL.md prose.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="triage-guard.sh"

# ---------- logging helpers ----------
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------------------------------------------------------------------------
# _tg_fm_field — extract a single frontmatter scalar value
#
# Usage: _tg_fm_field <file> <field>
# Reads YAML frontmatter (the block between the first two --- markers)
# and prints the value of <field>. Trims surrounding whitespace and
# quotes. Returns non-zero if file missing. Prints empty if field absent.
# ---------------------------------------------------------------------------
_tg_fm_field() {
  local file="$1" field="$2"
  [ -f "$file" ] || return 1
  awk -v f="$field" '
    BEGIN { in_fm = 0; seen_open = 0 }
    /^---[[:space:]]*$/ {
      if (!seen_open) { in_fm = 1; seen_open = 1; next }
      else if (in_fm) { in_fm = 0; exit }
    }
    in_fm {
      # Match "<field>:" at the start of the line.
      if (match($0, "^" f "[[:space:]]*:[[:space:]]*")) {
        val = substr($0, RSTART + RLENGTH)
        # Strip trailing comment.
        sub(/[[:space:]]+#.*$/, "", val)
        # Strip surrounding whitespace.
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        # Strip matching surrounding single or double quotes.
        if (match(val, /^".*"$/) || match(val, /^'"'"'.*'"'"'$/)) {
          val = substr(val, 2, length(val) - 2)
        }
        print val
        exit
      }
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# tg_read_status — read the `status` field from story frontmatter
#
# Usage: tg_read_status <story_file>
# Returns 0 on success (prints status value; empty if field absent).
# Returns 1 if story_file is missing.
# ---------------------------------------------------------------------------
tg_read_status() {
  local file="${1:-}"
  [ -n "$file" ] || { log "tg_read_status: missing story_file argument"; return 1; }
  [ -f "$file" ] || { log "tg_read_status: file not found: $file"; return 1; }
  _tg_fm_field "$file" "status"
}

# ---------------------------------------------------------------------------
# tg_is_done — predicate: is the story in `status: done`?
#
# Usage: tg_is_done <story_file>
# Returns 0 if status == "done", 1 otherwise (or on read error).
# ---------------------------------------------------------------------------
tg_is_done() {
  local file="${1:-}"
  local status
  status="$(tg_read_status "$file" 2>/dev/null || printf '')"
  [ "$status" = "done" ]
}

# ---------------------------------------------------------------------------
# tg_render_guidance — emit the halt guidance message for a done-story
# target. Includes story key, sprint ID, retrospective linkage, and the
# sanctioned redirect commands (/gaia-create-story, /gaia-add-feature).
#
# Usage: tg_render_guidance <story_key> <sprint_id>
# Prints multi-line guidance to stdout. Always returns 0.
# ---------------------------------------------------------------------------
tg_render_guidance() {
  local story_key="${1:-<unknown-story>}"
  local sprint_id="${2:-<unknown-sprint>}"
  cat <<EOF
HALT — Done-story guard fired.

Target story ${story_key} (sprint: ${sprint_id}) is in status: done.
Done stories are immutable institutional artifacts — they preserve the
retrospective signal for the sprint they shipped in. Mutating them
silently merges retro-blind regressions back into closed work.

Sanctioned paths:
  - /gaia-create-story   — create a new story (with origin=triage-findings)
  - /gaia-add-feature    — open a change request if the finding implies
                           a spec-level amendment

If the finding genuinely must be merged into the done story (rare),
re-run with the explicit override flag. Override entries are recorded
in the triage report and flagged for retrospective review.
EOF
}

# ---------------------------------------------------------------------------
# tg_record_override — append an override record to the triage report.
#
# Usage: tg_record_override <report_path> <user> <date> <finding_id> \
#                           <target_story_key> <reason>
# Creates <report_path> if missing. Appends a YAML-block entry with
# retro_flag: true so /gaia-retro surfaces it. Returns 0 on success,
# 1 on missing args or write failure.
# ---------------------------------------------------------------------------
tg_record_override() {
  local report="${1:-}"
  local user="${2:-}"
  local date="${3:-}"
  local finding="${4:-}"
  local target="${5:-}"
  local reason="${6:-}"

  if [ -z "$report" ] || [ -z "$user" ] || [ -z "$date" ] \
      || [ -z "$finding" ] || [ -z "$target" ] || [ -z "$reason" ]; then
    log "tg_record_override: missing required argument(s) — need report, user, date, finding, target, reason"
    return 1
  fi

  # Create report scaffold if missing.
  if [ ! -f "$report" ]; then
    mkdir -p "$(dirname "$report")"
    cat > "$report" <<'EOF'
# Triage Report

> Generated by /gaia-triage-findings. Override records are flagged for
> retrospective review (retro_flag: true).

## Done-Story Guard Overrides

EOF
  elif ! grep -q '^## Done-Story Guard Overrides' "$report"; then
    printf '\n## Done-Story Guard Overrides\n\n' >> "$report"
  fi

  # Escape any literal double quotes in the reason string.
  local escaped_reason="${reason//\"/\\\"}"

  {
    printf -- '- user: "%s"\n' "$user"
    printf -- '  date: "%s"\n' "$date"
    printf -- '  finding_id: "%s"\n' "$finding"
    printf -- '  target_story_key: "%s"\n' "$target"
    printf -- '  reason: "%s"\n' "$escaped_reason"
    printf -- '  retro_flag: true\n'
    printf -- '\n'
  } >> "$report"
}

# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  triage-guard.sh check <story_file>
  triage-guard.sh check --override --user <u> --date <d> --finding <fid> \
                        --reason <r> --report <path> <story_file>

Exit codes:
  0   proceed (non-done status, or override recorded)
  1   error (missing file, missing required flag, malformed frontmatter)
  2   HALT — target is in status: done and no override was provided
EOF
}

# _resolve_story_key — return the story `key` frontmatter value, falling
# back to the file basename (minus .md) when the field is absent.
_resolve_story_key() {
  local file="$1"
  local key
  key="$(_tg_fm_field "$file" "key")"
  if [ -z "$key" ]; then
    key="$(basename "$file" .md)"
  fi
  printf '%s' "$key"
}

_cmd_check() {
  local override=0
  local user="" date="" finding="" reason="" report=""
  local story=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --override)  override=1; shift ;;
      --user)      user="${2:-}";     shift 2 ;;
      --date)      date="${2:-}";     shift 2 ;;
      --finding)   finding="${2:-}";  shift 2 ;;
      --reason)    reason="${2:-}";   shift 2 ;;
      --report)    report="${2:-}";   shift 2 ;;
      -h|--help)   usage; return 0 ;;
      --) shift; story="${1:-}"; shift || true; break ;;
      -*) die "unknown flag: $1" ;;
      *)  story="$1"; shift ;;
    esac
  done

  [ -n "$story" ] || { usage >&2; return 1; }
  [ -f "$story" ] || { log "story file not found: $story"; return 1; }

  local status
  status="$(tg_read_status "$story")" || return 1

  if [ "$status" != "done" ]; then
    # Non-done target: proceed.
    return 0
  fi

  # Done-story branch.
  if [ "$override" -eq 1 ]; then
    if [ -z "$user" ] || [ -z "$date" ] || [ -z "$finding" ] \
        || [ -z "$reason" ] || [ -z "$report" ]; then
      log "override requires --user, --date, --finding, --reason, --report"
      return 1
    fi
    local story_key
    story_key="$(_resolve_story_key "$story")"
    if ! tg_record_override "$report" "$user" "$date" "$finding" "$story_key" "$reason"; then
      log "failed to record override to $report"
      return 1
    fi
    log "override recorded for $story_key (finding=$finding) by $user — flagged for retro review"
    return 0
  fi

  # No override: render guidance, HALT.
  local story_key sprint_id
  story_key="$(_resolve_story_key "$story")"
  sprint_id="$(_tg_fm_field "$story" "sprint_id")"
  [ -n "$sprint_id" ] || sprint_id="unknown"
  tg_render_guidance "$story_key" "$sprint_id"
  return 2
}

main() {
  if [ $# -lt 1 ]; then
    usage >&2
    return 1
  fi
  local subcmd="$1"; shift
  case "$subcmd" in
    check)         _cmd_check "$@" ;;
    -h|--help)     usage ;;
    *)             log "unknown subcommand: $subcmd"; usage >&2; return 1 ;;
  esac
}

# Execute main only when invoked directly (allow library-style sourcing in tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
