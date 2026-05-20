#!/usr/bin/env bash
# wip-checkpoint-resolve.sh — gaia-quick-dev WIP checkpoint validator (E28-S117)
#
# Reads _memory/checkpoints/quick-dev-{spec_name}.yaml and walks every entry
# under `files_touched:` to verify the recorded sha256 checksum matches the
# file on disk. Emits a table on stdout (path + status) and exits with:
#   0 — no checkpoint, or all entries MATCH
#   1 — one or more entries are MODIFIED or DELETED (AC-EC5)
#
# The sha256 check is deterministic and must never be done by the LLM
# (ADR-042). Surface layer (skill prose) branches on exit code + stdout.
#
# Usage:
#   wip-checkpoint-resolve.sh <spec_name>

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-quick-dev/wip-checkpoint-resolve.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ $# -lt 1 ]; then
  die "usage: wip-checkpoint-resolve.sh <spec_name>"
fi

SPEC_NAME="$1"

WORK_DIR="${PROJECT_PATH:-$PWD}"
# E96-S7 partial-4c: smart-fallback
if [ -n "${CHECKPOINT_PATH:-}" ]; then
  CHECKPOINT_DIR="$CHECKPOINT_PATH"
elif [ -d "$WORK_DIR/.gaia/memory/checkpoints" ]; then
  CHECKPOINT_DIR="$WORK_DIR/.gaia/memory/checkpoints"
else
  CHECKPOINT_DIR="$WORK_DIR/_memory/checkpoints"
fi
CHECKPOINT="$CHECKPOINT_DIR/quick-dev-${SPEC_NAME}.yaml"

if [ ! -f "$CHECKPOINT" ]; then
  echo "NONE"
  exit 0
fi

# Parse the YAML file_touched entries. Pure awk/grep — no yq dependency.
# Expected shape:
#   files_touched:
#     - path: src/a.txt
#       checksum: "sha256:abc..."
#       last_modified: "..."

tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT

# Extract (path, checksum) pairs. Handle both quoted and unquoted values.
awk '
  /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
    sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "")
    gsub(/^["'\'']|["'\'']$/, "")
    path = $0
    next
  }
  /^[[:space:]]*checksum:[[:space:]]*/ {
    sub(/^[[:space:]]*checksum:[[:space:]]*/, "")
    gsub(/^["'\'']|["'\'']$/, "")
    sub(/^sha256:/, "")
    if (path != "") {
      printf "%s\t%s\n", path, $0
      path = ""
    }
  }
' "$CHECKPOINT" > "$tmpfile"

status=0
printf '%-8s %s\n' "STATUS" "PATH"
printf '%-8s %s\n' "------" "----"

while IFS=$'\t' read -r path expected; do
  [ -z "$path" ] && continue
  full="$WORK_DIR/$path"
  if [ ! -f "$full" ]; then
    printf '%-8s %s\n' "DELETED" "$path"
    status=1
    continue
  fi
  actual=$(shasum -a 256 "$full" | awk '{print $1}')
  if [ "$actual" = "$expected" ]; then
    printf '%-8s %s\n' "MATCH" "$path"
  else
    printf '%-8s %s\n' "MODIFIED" "$path"
    status=1
  fi
done < "$tmpfile"

exit "$status"
