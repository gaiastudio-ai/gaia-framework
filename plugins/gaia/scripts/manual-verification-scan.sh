#!/usr/bin/env bash
# manual-verification-scan.sh — read-only manual_verification frontmatter scan.
#
# Provides public functions for reading the manual_verification frontmatter
# flag on story files and reporting which sprint candidates carry it. Used by
# gaia-sprint-plan SKILL.md to annotate flagged candidates with
# [manual_verification] so the manual-test gate is a visible, bound part of the
# sprint rather than a silent frontmatter flag discovered only at review.
#
# Public functions:
#   mverify_read       <story_file>          — print the flag value (true/false/"")
#   mverify_enabled    <story_file>          — exit 0 iff the flag is true
#   mverify_annotate   <story_file>          — print "[manual_verification]" iff true
#   mverify_scan_keys  <impl_dir> <keys...>  — list keys whose story has the flag
#
# Contract: NO set/write function. The flag is set at authoring time by
# /gaia-create-story (surface-aware, opt-in) and /gaia-add-feature (carried
# through the cascade). This script only READS it for display — symmetric with
# priority-flag.sh's read/clear-only contract.

set -euo pipefail
SCRIPT_NAME="${SCRIPT_NAME:-manual-verification-scan.sh}"

# ---------------------------------------------------------------------------
# _mverify_fm_field — extract a YAML frontmatter field value (private helper).
#   $1 = field name, $2 = file path.
# Prints the unquoted value. Empty when absent.
#
# This reader is intentionally byte-for-byte equivalent to the CANONICAL gate
# reader (`read_frontmatter_field` in manual-test-review-dispatch.sh /
# transition-story-status.sh) so the sprint-plan display annotation can NEVER
# disagree with the enforcement gate. Two properties matter:
#   - Line 1 MUST be the opening `---` fence (NR==1 && $0 != "---" → exit). A
#     story with a leading blank line or no frontmatter reads as empty — same as
#     the gate — instead of the lenient "first --- anywhere" that could read a
#     body block and disagree with the gate in the dangerous direction.
#   - An unquoted trailing `# comment` on the value is stripped, so an author
#     who annotates `manual_verification: true  # user-facing` is read as `true`
#     by BOTH this reader and the gate (avoids a silent opt-in loss).
# ---------------------------------------------------------------------------
_mverify_fm_field() {
  local field="$1" file="$2"
  [ -r "$file" ] || return 0
  awk -v field="$field" '
    BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34) }
    NR==1 && $0 != "---" { exit }
    NR==1 { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm {
      if ($0 ~ "^"field"[[:space:]]*:") {
        v=$0; sub("^"field"[[:space:]]*:[[:space:]]*", "", v)
        # Strip an unquoted trailing "# comment" so an annotated value matches
        # the bare scalar. ONLY for an UNQUOTED value — a quoted value carries
        # `#` as literal data (keeps this reader byte-equivalent to the gate).
        # Quote chars come from sprintf to avoid brittle shell/awk escaping.
        vstart = substr(v, 1, 1)
        if (vstart != dq && vstart != sq) {
          sub(/[[:space:]]+#.*$/, "", v)
        }
        cls = "^[" dq sq "[:space:]]+|[" dq sq "[:space:]]+$"
        gsub(cls, "", v)
        print v; exit
      }
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# mverify_read <story_file> — print the manual_verification value verbatim
#   ("true", "false", or empty when the field is absent).
# ---------------------------------------------------------------------------
mverify_read() {
  local file="$1" value
  value="$(_mverify_fm_field "manual_verification" "$file")"
  # Trim surrounding whitespace so " true" / "true " normalize.
  value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# mverify_enabled <story_file> — exit 0 iff manual_verification is true.
#   Absent or false → exit 1. Any value other than the literal "true" is
#   treated as not-enabled (fail-safe: only an explicit opt-in annotates).
# ---------------------------------------------------------------------------
mverify_enabled() {
  local value
  value="$(mverify_read "$1")"
  [ "$value" = "true" ]
}

# ---------------------------------------------------------------------------
# mverify_annotate <story_file> — print "[manual_verification]" iff the flag
#   is true, else print nothing. The display annotation sprint-plan appends to
#   a candidate row, mirroring the [priority_flag: next-sprint] pattern.
# ---------------------------------------------------------------------------
mverify_annotate() {
  if mverify_enabled "$1"; then
    printf '[manual_verification]'
  fi
}

# ---------------------------------------------------------------------------
# mverify_scan_keys <impl_dir> <key...> — for each story key, resolve its
#   story file under <impl_dir> and print the key on its own line iff the
#   story carries manual_verification: true. Keys with no resolvable file or
#   without the flag are silently skipped (read-only, best-effort display aid).
# ---------------------------------------------------------------------------
mverify_scan_keys() {
  local impl_dir="$1"; shift
  local key file
  for key in "$@"; do
    # Resolve the story file across the three canonical layouts (nested
    # per-story dir, legacy nested stories/, legacy flat). First match wins.
    file=""
    for cand in \
      "$impl_dir"/epic-*/"$key"-*/story.md \
      "$impl_dir"/epic-*/stories/"$key"-*.md \
      "$impl_dir"/"$key"-*.md; do
      if [ -f "$cand" ]; then file="$cand"; break; fi
    done
    [ -n "$file" ] || continue
    if mverify_enabled "$file"; then
      printf '%s\n' "$key"
    fi
  done
}

# Library-or-CLI dual mode: when executed directly, expose a thin CLI.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    read)       mverify_read "$@" ;;
    enabled)    mverify_enabled "$@" && echo true || { echo false; exit 1; } ;;
    annotate)   mverify_annotate "$@" ;;
    scan-keys)  mverify_scan_keys "$@" ;;
    *)
      printf '%s: usage: %s {read|enabled|annotate <story_file>|scan-keys <impl_dir> <key...>}\n' \
        "$SCRIPT_NAME" "$SCRIPT_NAME" >&2
      exit 2 ;;
  esac
fi
