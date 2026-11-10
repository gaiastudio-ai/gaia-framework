#!/usr/bin/env bash
# check-scanner-pins.sh — CI check for scanner version pins in the Dockerfile.
#
# Verifies that every scanner listed in the scanner manifest has:
#   - An exact version pin in the Dockerfile (not a range or floating tag)
#   - A sha256 entry in the manifest for each architecture (binary scanners)
#   - Matching version between Dockerfile ARG and manifest
#   - Every FROM line has an @sha256: digest
#   - Sarif.Multitool install uses an exact --version matching the manifest
#   - The pip lock file exists and contains --hash lines
#   - apt-pinned scanners have an exact version in the Dockerfile
#   - No loose version pins (>=, ~=, ^, :latest) in Dockerfile instructions
#
# Exit codes:
#   0 — all pins verified
#   1 — one or more pins are loose, missing, or mismatched

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools/gaia-tools" && pwd)"

DOCKERFILE="$TOOLS_DIR/Dockerfile"
MANIFEST="$TOOLS_DIR/scanner-manifest.json"

errors=0

_err() {
  printf 'FAIL: %s\n' "$*" >&2
  errors=$((errors + 1))
}

[ -f "$DOCKERFILE" ] || { _err "Dockerfile not found: $DOCKERFILE"; exit 1; }
[ -f "$MANIFEST" ]   || { _err "scanner-manifest.json not found: $MANIFEST"; exit 1; }

# ---------------------------------------------------------------------------
# Check 1: Every FROM line must have @sha256: digest.
# ---------------------------------------------------------------------------
while IFS= read -r line; do
  case "$line" in
    \#*|"") continue ;;
  esac
  case "$line" in
    FROM*)
      case "$line" in
        *@sha256:*) ;;
        *) _err "FROM without @sha256: digest: $line" ;;
      esac
      ;;
  esac
done < "$DOCKERFILE"

# ---------------------------------------------------------------------------
# Check 2: Per-scanner checks by install type.
# ---------------------------------------------------------------------------
scanner_count="$(jq '.scanners | length' "$MANIFEST")"
i=0
while [ "$i" -lt "$scanner_count" ]; do
  name="$(jq -r --argjson idx "$i" '.scanners[$idx].name' "$MANIFEST")"
  version="$(jq -r --argjson idx "$i" '.scanners[$idx].version' "$MANIFEST")"
  install="$(jq -r --argjson idx "$i" '.scanners[$idx].install' "$MANIFEST")"

  case "$install" in
    binary)
      name_upper="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
      arg_version="$(grep -E "^ARG ${name_upper}_VERSION=" "$DOCKERFILE" | head -1 | sed 's/.*=//' | tr -d '[:space:]')" || arg_version=""
      if [ -z "$arg_version" ]; then
        _err "no ARG ${name_upper}_VERSION= found in Dockerfile for $name"
      elif [ "$arg_version" != "$version" ]; then
        _err "$name version mismatch: Dockerfile=$arg_version, manifest=$version"
      fi
      for arch in amd64 arm64; do
        sha="$(jq -r --argjson idx "$i" --arg arch "$arch" '.scanners[$idx].artifacts[$arch].sha256 // ""' "$MANIFEST")"
        if [ -z "$sha" ]; then
          _err "$name missing sha256 for $arch in manifest"
        elif [ "${#sha}" -ne 64 ]; then
          _err "$name sha256 for $arch is not 64 characters: $sha"
        fi
      done
      ;;
    pip)
      lock_file="$(jq -r --argjson idx "$i" '.scanners[$idx].lock_file // ""' "$MANIFEST")"
      if [ -n "$lock_file" ]; then
        if [ ! -f "$TOOLS_DIR/$lock_file" ]; then
          _err "$name lock file not found: $lock_file"
        else
          if ! grep -qF "${name}==${version}" "$TOOLS_DIR/$lock_file"; then
            _err "$name version $version not found in $lock_file"
          fi
          if ! grep -qF -- "--hash=" "$TOOLS_DIR/$lock_file"; then
            _err "$lock_file has no --hash lines (--require-hashes will fail)"
          fi
        fi
      fi
      ;;
    apt)
      apt_pin="$(jq -r --argjson idx "$i" '.scanners[$idx].apt_pin // ""' "$MANIFEST")"
      if [ -n "$apt_pin" ]; then
        if ! grep -qE "${name}=${apt_pin}" "$DOCKERFILE"; then
          _err "$name apt install not pinned to $apt_pin in Dockerfile"
        fi
      else
        if ! grep -qE "\\b${name}\\b" "$DOCKERFILE"; then
          _err "$name not found in Dockerfile apt install"
        fi
      fi
      ;;
    dotnet)
      sarif_version="$(grep -oE 'dotnet tool install.*--version[[:space:]]+[0-9][0-9.]*' "$DOCKERFILE" | grep -oE '[0-9][0-9.]*$' | head -1)" || sarif_version=""
      if [ -z "$sarif_version" ]; then
        _err "Sarif.Multitool install does not use --version"
      elif [ "$sarif_version" != "$version" ]; then
        _err "Sarif.Multitool version mismatch: Dockerfile=$sarif_version, manifest=$version"
      fi
      ;;
  esac

  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Check 3: No loose version pins in Dockerfile instructions.
# ---------------------------------------------------------------------------
while IFS= read -r line; do
  instr="$(printf '%s' "$line" | sed 's/[[:space:]]*#.*//')"
  [ -n "$instr" ] || continue
  case "$instr" in
    *'>='*|*'~='*|*'^'*|*':latest'*)
      _err "loose version pin in Dockerfile: $line" ;;
  esac
done < "$DOCKERFILE"

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
if [ "$errors" -gt 0 ]; then
  printf '\ncheck-scanner-pins: %d error(s) found\n' "$errors" >&2
  exit 1
fi

printf 'check-scanner-pins: all pins verified\n'
exit 0
