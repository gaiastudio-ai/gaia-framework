#!/usr/bin/env bash
# transcript-fidelity.sh — Mode B transcript superset verification.
# Sourceable, NOT executable.
#
# Exposes 1 public function:
#   verify_transcript_superset  — assert every line in A is present in B
#
# Used to verify that a Mode B transcript is a superset of the equivalent
# Mode A transcript. Mode B adds teammate identity metadata (persona,
# spawn timestamp, turn index) but must preserve every content line from
# the Mode A equivalent.

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Source guard ----------

if [ "${_TF_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

# verify_transcript_superset A_PATH B_PATH
#   Returns 0 if every non-empty line in file A is present in file B.
#   Reports each missing line on stderr and exits non-zero if any are missing.
verify_transcript_superset() {
  local a_path="${1:-}"
  local b_path="${2:-}"

  if [ -z "$a_path" ] || [ -z "$b_path" ]; then
    printf 'verify_transcript_superset: usage: verify_transcript_superset A_PATH B_PATH\n' >&2
    return 1
  fi

  if [ ! -f "$a_path" ]; then
    printf 'verify_transcript_superset: file A not found: %s\n' "$a_path" >&2
    return 1
  fi

  if [ ! -f "$b_path" ]; then
    printf 'verify_transcript_superset: file B not found: %s\n' "$b_path" >&2
    return 1
  fi

  local missing=0
  local line
  while IFS= read -r line; do
    # Skip empty lines — whitespace-only lines are not meaningful content.
    case "$line" in
      '') continue ;;
    esac

    if ! grep -qF -- "$line" "$b_path"; then
      printf 'MISSING in B: %s\n' "$line" >&2
      missing=$((missing + 1))
    fi
  done < "$a_path"

  if [ "$missing" -gt 0 ]; then
    printf 'verify_transcript_superset: %d line(s) from A not found in B\n' "$missing" >&2
    return 1
  fi

  return 0
}

# ---------- Source guard — mark loaded ----------
_TF_LOADED=1
