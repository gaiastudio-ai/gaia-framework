#!/usr/bin/env bash
# audit-silent-val-bypass.sh — audit for silently bypassed Val subagent checkpoints.
#
# Scans _memory/checkpoints/ for checkpoint files matching the empty-state
# signature that indicates the Val subagent was silently bypassed under the
# legacy plugin-fork model. The signature is a YAML checkpoint with:
#   - `variables: {}` (literal empty mapping)
#   - `files_touched: []` (literal empty sequence)
#   - NO `verdict:` field
#   - NO `final_status:` field
#
# Valid checkpoints from a real Val dispatch carry verdict/final_status plus
# at least one entry in files_touched (the artifact under validation), so
# the empty signature is a clear distinguishing marker.
#
# Default scan window: last 90 days. Files older than the window are
# excluded by mtime.
#
# Output:
#   - stdout: a Markdown table with columns
#       | File Path | mtime (UTC) | Hypothesized Skill | Recommended Action |
#   - stderr: per-file diagnostic lines (warnings, skipped files)
#
# Exit codes:
#   0 — scan completed (with or without findings)
#   2 — usage error or checkpoint dir missing
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_NAME="audit-silent-val-bypass.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  audit-silent-val-bypass.sh [--checkpoint-path <dir>] [--days <N>]

Defaults:
  --checkpoint-path: ./_memory/checkpoints
  --days:            90 (scan window in days, by mtime)

Emits a Markdown table to stdout. One row per affected checkpoint file.
USAGE
}

# .gaia/memory/checkpoints is the only location;
# the legacy _memory/checkpoints fallback was removed with the migration.
checkpoint_path="./.gaia/memory/checkpoints"
days="90"

while [ $# -gt 0 ]; do
  case "$1" in
    --checkpoint-path) checkpoint_path="${2:-}"; shift 2 ;;
    --checkpoint-path=*) checkpoint_path="${1#--checkpoint-path=}"; shift ;;
    --days) days="${2:-}"; shift 2 ;;
    --days=*) days="${1#--days=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2; usage; exit 2 ;;
  esac
done

[ -d "$checkpoint_path" ] || {
  printf '%s: checkpoint-path does not exist: %s\n' "$SCRIPT_NAME" "$checkpoint_path" >&2
  exit 2
}

case "$days" in
  ''|*[!0-9]*)
    printf '%s: --days must be a positive integer: %s\n' "$SCRIPT_NAME" "$days" >&2
    exit 2 ;;
esac

# _is_empty_state <file>
# Returns 0 if the YAML file matches the empty-state signature, 1 otherwise.
# All four conditions must hold:
#   - file contains a line exactly matching `variables: {}` (allowing trailing whitespace)
#   - file contains a line exactly matching `files_touched: []` (allowing trailing whitespace)
#   - file does NOT contain a `verdict:` line at column 0
#   - file does NOT contain a `final_status:` line at column 0
_is_empty_state() {
  local f="$1"
  grep -qE '^variables:[[:space:]]*\{\}[[:space:]]*$' "$f" 2>/dev/null || return 1
  grep -qE '^files_touched:[[:space:]]*\[\][[:space:]]*$' "$f" 2>/dev/null || return 1
  if grep -qE '^verdict:' "$f" 2>/dev/null; then return 1; fi
  if grep -qE '^final_status:' "$f" 2>/dev/null; then return 1; fi
  return 0
}

# _hypothesized_skill <file>
# Extract the `workflow:` value from the YAML, or fall back to basename-derived.
_hypothesized_skill() {
  local f="$1" w
  w="$(awk -F: '/^workflow:[[:space:]]*/{sub(/^workflow:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}' "$f" 2>/dev/null)"
  if [ -n "$w" ]; then
    printf '%s' "$w"
  else
    basename "$f" .yaml
  fi
}

# _file_mtime_iso <file>
# Portable mtime read in ISO-8601 UTC. Tries BSD stat (macOS) then GNU stat.
_file_mtime_iso() {
  local f="$1" ts
  # BSD stat: -f "%Sm" with -t "%FT%TZ" gives ISO-8601 UTC when TZ=UTC.
  if ts="$(TZ=UTC stat -f '%Sm' -t '%FT%TZ' "$f" 2>/dev/null)"; then
    printf '%s' "$ts"; return 0
  fi
  # GNU stat: -c "%y" gives local mtime; use --printf "%Y" for epoch + format.
  if ts="$(stat -c '%Y' "$f" 2>/dev/null)"; then
    printf '%s' "$(TZ=UTC date -u -d "@$ts" +'%FT%TZ' 2>/dev/null || printf 'unknown')"
    return 0
  fi
  printf 'unknown'
}

# ---- Emit Markdown table header ----
printf '# Silent-Val-Bypass Audit Report\n\n'
printf 'Scan path: `%s`\n' "$checkpoint_path"
printf 'Scan window: last %s days\n' "$days"
printf 'Generated: %s\n\n' "$(TZ=UTC date -u +'%FT%TZ')"
printf '| File Path | mtime (UTC) | Hypothesized Skill | Recommended Action |\n'
printf '|-----------|-------------|--------------------|--------------------|\n'

found=0
scanned=0

# Find YAML checkpoints within the scan window.
# Use -mtime -<days> for relative time (BSD/GNU compatible).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  if _is_empty_state "$f"; then
    found=$((found + 1))
    skill="$(_hypothesized_skill "$f")"
    mtime="$(_file_mtime_iso "$f")"
    rel="${f#./}"
    printf '| `%s` | %s | `%s` | re-validate if `status: done` story exists; archive otherwise |\n' \
      "$rel" "$mtime" "$skill"
  fi
done <<EOF
$(find "$checkpoint_path" -maxdepth 1 -type f -name '*.yaml' -mtime "-${days}" 2>/dev/null | sort)
EOF

printf '\n## Summary\n\n'
printf -- '- Files scanned: %s\n' "$scanned"
printf -- '- Empty-state matches: %s\n' "$found"
printf -- '- Source-of-truth: canonical Val dispatch contract\n'

exit 0
