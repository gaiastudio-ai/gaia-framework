#!/usr/bin/env bash
# ci-regen-backup.sh — copy a generated CI workflow file to .gaia-backup/ (E71-S4).
#
# Usage: ci-regen-backup.sh <ci-file-path>
#
# Creates `.gaia-backup/{basename}-{ISO-8601-timestamp}/` at the project root
# (current working directory) and copies the workflow file into it preserving
# the original filename. The original file is NOT moved or modified — the
# caller decides whether to replace it with the regenerated content.
#
# Stdout: relative path of the created backup directory.
# Exit:   0 on success, non-zero on missing source / write failure.
#
# Refs: AC4 (TS-04), FR-RSV2-37.

set -euo pipefail
LC_ALL=C
export LC_ALL

src="${1:-}"
if [ -z "$src" ]; then
  echo "ci-regen-backup.sh: missing source file argument" >&2
  exit 64
fi
if [ ! -f "$src" ]; then
  echo "ci-regen-backup.sh: source file not found: $src" >&2
  exit 1
fi

base="$(basename "$src")"
ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
# Filename-safe timestamp: keep colons (matches AC4 "ISO-8601 timestamp"). The
# grep in tests permits both colons and bare digits.
backup_dir=".gaia-backup/${base}-${ts}"

mkdir -p "$backup_dir"
cp "$src" "$backup_dir/$base"

printf '%s\n' "$backup_dir"
