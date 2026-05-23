#!/usr/bin/env bash
# verify-backup-integrity.sh — Verify the integrity of a .gaia-backup/
# ci-regen-{timestamp}/ directory against its .sha256-manifest.
#
# E98-S6 / SR-84 / ADR-114 §(g) / FR-528.
#
# Usage:
#   verify-backup-integrity.sh <backup-dir>
#
# Behaviour:
#   - Reads <backup-dir>/.sha256-manifest (one `<sha256>  <relpath>` line per
#     backed-up file).
#   - Re-computes the sha256 of every file in the directory (excluding the
#     manifest itself).
#   - Compares each computed hash against the manifest entry.
#   - Detects three drift classes:
#       * mismatch — file present in both, hashes differ
#       * missing  — file in manifest, absent on disk
#       * extra    — file on disk, absent from manifest
#   - Exits 0 if and only if all three drift classes are empty.
#   - On drift, emits the canonical SR-84 HALT message + per-file detail.
#
# Exit codes:
#   0 — clean (no drift)
#   1 — drift detected (mismatch, missing, or extra files)
#   2 — usage error (missing arg, no such directory, missing manifest)

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="$(basename "$0")"

if [ $# -lt 1 ]; then
  printf '%s: usage: %s <backup-dir>\n' "$prog" "$prog" >&2
  exit 2
fi

backup_dir="$1"

if [ ! -d "$backup_dir" ]; then
  printf '%s: backup directory not found: %s\n' "$prog" "$backup_dir" >&2
  exit 2
fi

manifest="$backup_dir/.sha256-manifest"
if [ ! -f "$manifest" ]; then
  printf '%s: manifest not found: %s\n' "$prog" "$manifest" >&2
  exit 2
fi

# Build two sorted, comparable lists:
#   - expected: from the manifest (sha256 + path)
#   - actual:   re-computed from the on-disk files (excluding the manifest)
expected_list=$(mktemp -t verify-backup-expected.XXXXXX)
actual_list=$(mktemp -t verify-backup-actual.XXXXXX)
trap 'rm -f "$expected_list" "$actual_list"' EXIT

# Expected: skip blank lines + comments
awk 'NF >= 2 && $1 !~ /^#/ { print $1 "  " $2 }' "$manifest" | sort > "$expected_list"

# Actual: iterate every regular file under backup_dir, hash, emit "<hash>  <relpath>"
(
  cd "$backup_dir"
  find . -type f ! -name '.sha256-manifest' -print0 | \
    while IFS= read -r -d '' f; do
      # Strip the leading "./" to make the relpath match the manifest's form
      relpath="${f#./}"
      hash=$(shasum -a 256 "$f" | awk '{print $1}')
      printf '%s  %s\n' "$hash" "$relpath"
    done | sort
) > "$actual_list"

# Compute the three drift classes.
drift=0
drift_messages=()

# Mismatches + missing — files in expected, absent or different in actual.
# Sort by path so we can join.
expected_by_path=$(awk '{ print $2 "\t" $1 }' "$expected_list" | sort)
actual_by_path=$(awk '{ print $2 "\t" $1 }' "$actual_list" | sort)

# Detect mismatches and missing entries from the expected side.
while IFS=$'\t' read -r path exp_hash; do
  [ -z "$path" ] && continue
  act_hash=$(printf '%s\n' "$actual_by_path" | awk -v p="$path" -F'\t' '$1 == p { print $2; exit }')
  if [ -z "$act_hash" ]; then
    drift=1
    drift_messages+=("missing: $path (in manifest but absent on disk)")
  elif [ "$exp_hash" != "$act_hash" ]; then
    drift=1
    drift_messages+=("mismatch: $path (expected $exp_hash, got $act_hash)")
  fi
done <<< "$expected_by_path"

# Detect extras — files on disk, absent from the manifest.
while IFS=$'\t' read -r path act_hash; do
  [ -z "$path" ] && continue
  exp_hash=$(printf '%s\n' "$expected_by_path" | awk -v p="$path" -F'\t' '$1 == p { print $2; exit }')
  if [ -z "$exp_hash" ]; then
    drift=1
    drift_messages+=("extra: $path (on disk but not in manifest)")
  fi
done <<< "$actual_by_path"

if [ "$drift" -eq 0 ]; then
  printf '%s: backup integrity verified — %d file(s) match manifest in %s\n' \
    "$prog" "$(wc -l < "$expected_list" | tr -d ' ')" "$backup_dir" >&2
  exit 0
fi

# Drift detected — emit canonical HALT + per-file detail.
printf 'HALT: backup integrity check failed — .gaia-backup contents tampered (per SR-84)\n' >&2
printf 'Backup directory: %s\n' "$backup_dir" >&2
for m in "${drift_messages[@]}"; do
  printf '  - %s\n' "$m" >&2
done
exit 1
