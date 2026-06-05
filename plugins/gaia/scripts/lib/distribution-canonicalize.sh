#!/usr/bin/env bash
# distribution-canonicalize.sh — distribution.* path + string validators
# for manifest path traversal and shell-metachar denylist +
# URL-shape validation on distribution.registry.
#
# Sourceable, NOT executable.
#
# Exposes three functions:
#
#   gaia_distribution_canonicalize_manifest <project-root> <manifest-path>
#     - Refuses absolute paths outside the project root (pre-canon)
#     - Refuses paths containing `..` segments (pre-canon, defense-in-depth)
#     - realpath-canonicalizes the path (cross-platform Linux + macOS)
#     - String-prefix-checks the result against the canonical project root
#     - Emits the absolute canonical path on stdout on success; HALT on failure
#
#   gaia_distribution_validate_string <value>
#     - Refuses any value containing characters from the shell-metachar denylist:
#       `;`, `&&`, `||`, `|`, backtick, `$(`, `>`, `>>`, `<`, `\n`
#
#   gaia_distribution_validate_url <url>
#     - First runs gaia_distribution_validate_string (shell-metachar)
#     - Then enforces `^https://[a-zA-Z0-9.-]+(/.*)?$` URL-shape
#
# Source guard: _GAIA_DISTRIBUTION_CANONICALIZE_LOADED=1 after first source.

if [ "${_GAIA_DISTRIBUTION_CANONICALIZE_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_DISTRIBUTION_CANONICALIZE_LOADED=1

LC_ALL=C
export LC_ALL

# Cross-platform realpath. macOS's stock readlink lacks -f; Linux's realpath
# is widely available. Fall back to python3 if neither is workable.
_gaia_dc_realpath() {
  local target="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null
    return
  fi
  if command -v readlink >/dev/null 2>&1; then
    local out
    out=$(readlink -f "$target" 2>/dev/null)
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$target" 2>/dev/null
    return
  fi
  printf 'distribution-canonicalize.sh: no realpath / readlink -f / python3 available\n' >&2
  return 1
}

# Shell-metacharacter denylist. Anything matching ANY of these
# patterns is rejected:
#   `;`, `&&`, `||`, `|`, backtick, `$(`, `>`, `>>`, `<`, `\n`
gaia_distribution_validate_string() {
  local value="$1"
  # Empty is permitted (caller decides non-empty separately).
  if [ -z "$value" ]; then
    return 0
  fi
  # Check for newline embedded in the value.
  case "$value" in
    *$'\n'*)
      printf 'distribution-canonicalize.sh: shell-metacharacter (newline) in value\n' >&2
      return 1
      ;;
  esac
  # Check for each denylist token.
  case "$value" in
    *";"*|*"&&"*|*"||"*|*"|"*|*'`'*|*'$('*|*">"*|*"<"*)
      printf 'distribution-canonicalize.sh: shell-metacharacter in value: %s\n' "$value" >&2
      return 1
      ;;
  esac
  return 0
}

# URL-shape: https + hostname + optional path.
gaia_distribution_validate_url() {
  local url="$1"
  # First catch the easy shell-metachar wins.
  if ! gaia_distribution_validate_string "$url"; then
    return 1
  fi
  # Then enforce URL shape.
  if ! printf '%s' "$url" | grep -Eq '^https://[a-zA-Z0-9.-]+(/.*)?$'; then
    printf 'distribution-canonicalize.sh: URL-shape rejected — expected https://<host>[/<path>], got: %s\n' "$url" >&2
    return 1
  fi
  return 0
}

gaia_distribution_canonicalize_manifest() {
  local project_root="${1:-}"
  local manifest="${2:-}"

  if [ -z "$project_root" ] || [ -z "$manifest" ]; then
    printf 'distribution-canonicalize.sh: usage: gaia_distribution_canonicalize_manifest <project-root> <manifest-path>\n' >&2
    return 2
  fi
  if [ ! -d "$project_root" ]; then
    printf 'distribution-canonicalize.sh: project root not found: %s\n' "$project_root" >&2
    return 2
  fi

  # Refuse absolute paths and `..` segments PRE-canonicalization
  # (defense in depth — realpath would still catch the outside-root case
  # via the prefix check, but rejecting early gives a clearer error and
  # closes the partial-resolution race).
  case "$manifest" in
    /*)
      # Absolute path is allowed ONLY if it already starts with the
      # canonical project root prefix.
      local canon_root
      canon_root=$(_gaia_dc_realpath "$project_root")
      if [ -z "$canon_root" ]; then
        printf 'distribution-canonicalize.sh: cannot canonicalize project root\n' >&2
        return 1
      fi
      case "$manifest" in
        "$canon_root"*) ;;
        *)
          printf 'distribution-canonicalize.sh: absolute path outside project root: %s\n' "$manifest" >&2
          return 1
          ;;
      esac
      ;;
  esac
  case "$manifest" in
    *..*)
      printf 'distribution-canonicalize.sh: traversal (..) segment refused pre-canonicalization: %s\n' "$manifest" >&2
      return 1
      ;;
  esac

  # Resolve the canonical project root once.
  local canon_root
  canon_root=$(_gaia_dc_realpath "$project_root")
  if [ -z "$canon_root" ]; then
    printf 'distribution-canonicalize.sh: cannot canonicalize project root\n' >&2
    return 1
  fi

  # Compose the candidate full path and canonicalize.
  local candidate
  if [ "${manifest:0:1}" = "/" ]; then
    candidate="$manifest"
  else
    candidate="$canon_root/$manifest"
  fi
  local canon_manifest
  canon_manifest=$(_gaia_dc_realpath "$candidate")
  if [ -z "$canon_manifest" ]; then
    # Non-existent file is acceptable for the validate-only path; fall
    # back to lexical normalization for the prefix check.
    canon_manifest="$candidate"
  fi

  # String-prefix check.
  case "$canon_manifest" in
    "$canon_root"/*|"$canon_root") ;;
    *)
      printf 'HALT: distribution.manifest resolves outside project root: %s\n' "$canon_manifest" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$canon_manifest"
  return 0
}
