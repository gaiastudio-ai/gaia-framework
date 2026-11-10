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
      if [ -n "$arg_version" ] && [ "$arg_version" != "$version" ]; then
        _err "$name version mismatch: Dockerfile=$arg_version, manifest=$version"
      fi
      # Check sha256 for each architecture. Support "all" for arch-independent.
      _found_arch=false
      for arch in amd64 arm64 all; do
        sha="$(jq -r --argjson idx "$i" --arg arch "$arch" '.scanners[$idx].artifacts[$arch].sha256 // ""' "$MANIFEST")"
        if [ -n "$sha" ]; then
          _found_arch=true
          if [ "${#sha}" -ne 64 ]; then
            _err "$name sha256 for $arch is not 64 characters: $sha"
          fi
        fi
      done
      if [ "$_found_arch" = "false" ]; then
        _err "$name has no sha256 for any architecture in manifest"
      fi
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
# Check 4: Unversioned pip installs (pip install <name> without ==).
# Also catches bare package specs after "pip install -r <file> <bare>".
# ---------------------------------------------------------------------------
while IFS= read -r line; do
  instr="$(printf '%s' "$line" | sed 's/[[:space:]]*#.*//' | sed 's/\\$//')"
  [ -n "$instr" ] || continue
  case "$instr" in
    *"pip install"*)
      _past_req_file=false
      # Check each word that looks like a package name without ==.
      for word in $instr; do
        case "$word" in
          RUN|pip|pip3|install|--*|python3|*==*|*"'"*|*'"'*) continue ;;
          -r) _past_req_file=true; continue ;;
        esac
        # The word right after -r is the requirements file path; skip it.
        if [ "$_past_req_file" = "true" ]; then
          _past_req_file=false
          continue
        fi
        case "$word" in
          [a-zA-Z][a-zA-Z0-9_-]*)
            _err "unversioned pip install: $word (needs ==version)" ;;
        esac
      done
      ;;
  esac
done < "$DOCKERFILE"

# ---------------------------------------------------------------------------
# Check 5: Dockerfile sha256 values must match the manifest.
# ---------------------------------------------------------------------------
i=0
while [ "$i" -lt "$scanner_count" ]; do
  install="$(jq -r --argjson idx "$i" '.scanners[$idx].install' "$MANIFEST")"
  name="$(jq -r --argjson idx "$i" '.scanners[$idx].name' "$MANIFEST")"
  if [ "$install" = "binary" ]; then
    for arch in amd64 arm64 all; do
      m_sha="$(jq -r --argjson idx "$i" --arg arch "$arch" '.scanners[$idx].artifacts[$arch].sha256 // ""' "$MANIFEST")"
      [ -n "$m_sha" ] || continue
      if ! grep -qF "$m_sha" "$DOCKERFILE"; then
        _err "$name sha256 for $arch in manifest ($m_sha) not found in Dockerfile"
      fi
    done
  fi
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Check 6: Every curl download in the fetcher stage must have a corresponding
# sha256sum -c for the same output file. Joins continuation lines, then
# checks each curl -o. Runtime-stage utility downloads (dotnet, NodeSource)
# are outside the scanner pin scope.
# ---------------------------------------------------------------------------
# Join continuation lines (trailing backslash) portably.
_joined_dockerfile="$(awk '/\\$/ {sub(/\\$/,""); buf=buf $0; next} {print buf $0; buf=""}
  END {if (buf) print buf}' "$DOCKERFILE")"
# For each curl download (with -o), verify a sha256sum -c references the same file.
while IFS= read -r _dl_line; do
  [ -n "$_dl_line" ] || continue
  # Extract the -o target: the word after -o.
  _out_file="$(printf '%s' "$_dl_line" | grep -oE -- '-o[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $2}')" || _out_file=""
  [ -n "$_out_file" ] || continue
  # Strip quotes around the filename.
  _out_file="$(printf '%s' "$_out_file" | tr -d '"'"'")"
  # The basename is what sha256sum -c checks against.
  _out_base="${_out_file##*/}"
  # Look for a sha256sum -c line that references this file (by path or basename).
  _found=false
  if printf '%s\n' "$_joined_dockerfile" | grep -F "$_out_base" | grep -q 'sha256sum -c' 2>/dev/null; then
    _found=true
  fi
  if [ "$_found" = "false" ] && printf '%s\n' "$_joined_dockerfile" | grep -F "$_out_file" | grep -q 'sha256sum -c' 2>/dev/null; then
    _found=true
  fi
  if [ "$_found" = "false" ]; then
    _err "curl download to $_out_file has no sha256sum -c verification"
  fi
done < <(awk 'BEGIN{s=0} /^FROM.*AS fetcher/{s=1; next} /^FROM/{s=0} s{print}' "$DOCKERFILE" | \
  awk '/\\$/ {sub(/\\$/,""); buf=buf $0; next} {print buf $0; buf=""}
    END {if (buf) print buf}' | grep 'curl.*-o ')

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
if [ "$errors" -gt 0 ]; then
  printf '\ncheck-scanner-pins: %d error(s) found\n' "$errors" >&2
  exit 1
fi

printf 'check-scanner-pins: all pins verified\n'
exit 0
