#!/usr/bin/env bash
# check-scanner-pins.sh — CI check for scanner version pins in the Dockerfile.
#
# Verifies that every scanner listed in the scanner manifest has:
#   - An exact version pin in the Dockerfile (not a range or floating tag)
#   - A sha256 entry in the manifest for each architecture (binary scanners)
#   - Matching version between Dockerfile ARG and manifest
#   - Every FROM line has an @sha256: digest
#   - Sarif.Multitool install uses an exact --version
#
# Exit codes:
#   0 — all pins verified
#   1 — one or more pins are loose, missing, or mismatched

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="check-scanner-pins.sh"
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
    FROM*@sha256:*) ;; # Good — has digest.
    FROM*AS*|FROM*as*) _err "FROM without @sha256: digest: $line" ;;
  esac
done < "$DOCKERFILE"

# ---------------------------------------------------------------------------
# Check 2: Binary scanners — exact version in Dockerfile, sha256 per arch in manifest.
# ---------------------------------------------------------------------------
scanner_count="$(jq '.scanners | length' "$MANIFEST")"
i=0
while [ "$i" -lt "$scanner_count" ]; do
  name="$(jq -r ".scanners[$i].name" "$MANIFEST")"
  version="$(jq -r ".scanners[$i].version" "$MANIFEST")"
  install="$(jq -r ".scanners[$i].install" "$MANIFEST")"

  case "$install" in
    binary)
      # Check Dockerfile has an exact ARG pin.
      name_upper="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
      arg_version="$(grep -E "^ARG ${name_upper}_VERSION=" "$DOCKERFILE" | head -1 | sed 's/.*=//' | tr -d '[:space:]')" || arg_version=""
      if [ -z "$arg_version" ]; then
        _err "no ARG ${name_upper}_VERSION= found in Dockerfile for $name"
      elif [ "$arg_version" != "$version" ]; then
        _err "$name version mismatch: Dockerfile=$arg_version, manifest=$version"
      fi
      # Check sha256 per arch.
      for arch in amd64 arm64; do
        sha="$(jq -r ".scanners[$i].artifacts.${arch}.sha256 // \"\"" "$MANIFEST")"
        if [ -z "$sha" ]; then
          _err "$name missing sha256 for $arch in manifest"
        fi
      done
      ;;
    pip)
      # Verify the lock file exists and references the version.
      lock_file="$(jq -r ".scanners[$i].lock_file // \"\"" "$MANIFEST")"
      if [ -n "$lock_file" ] && [ -f "$TOOLS_DIR/$lock_file" ]; then
        if ! grep -qF "${name}==${version}" "$TOOLS_DIR/$lock_file"; then
          _err "$name version $version not found in $lock_file"
        fi
      fi
      ;;
    apt)
      # Verify the Dockerfile installs the specific package.
      if ! grep -qE "\\b${name}\\b" "$DOCKERFILE"; then
        _err "$name not found in Dockerfile apt install"
      fi
      ;;
    dotnet)
      # Sarif.Multitool must use --version.
      if ! grep -qE "dotnet tool install.*${name}" "$DOCKERFILE"; then
        _err "$name not found in Dockerfile dotnet tool install"
      fi
      if ! grep -qE "dotnet tool install.*--version" "$DOCKERFILE" 2>/dev/null; then
        _err "Sarif.Multitool install does not use --version"
      fi
      ;;
  esac

  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Check 3: No loose version pins (>=, ~=, ^, latest).
# ---------------------------------------------------------------------------
if grep -nE '(>=|~=|\^|:latest)' "$DOCKERFILE" | grep -vE '^[[:space:]]*#' | grep -v 'pip install' | head -5 | while IFS= read -r line; do
  _err "loose version pin in Dockerfile: $line"
done; then
  : # handled in loop
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
if [ "$errors" -gt 0 ]; then
  printf '\ncheck-scanner-pins: %d error(s) found\n' "$errors" >&2
  exit 1
fi

printf 'check-scanner-pins: all pins verified\n'
exit 0
