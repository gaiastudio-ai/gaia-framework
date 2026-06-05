#!/usr/bin/env bash
# validate-platform-stack.sh — reject configs that declare a mobile platform
# without any stack capable of building for it.
# Deterministic output.
#
# Capability matrix:
#   ios:     swift, objective-c, objective_c, react-native, flutter
#   android: kotlin, java, react-native, flutter
#   web:     any stack (no enforcement here — trivially satisfiable)
#
# Usage:
#   validate-platform-stack.sh <config.yaml>
#
# Exit codes:
#   0  All declared platforms have at least one capable stack.
#   1  At least one platform has no capable stack — print the first offender.
#   2  Usage error / unparseable input.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-init/validate-platform-stack.sh"

[ $# -eq 1 ] || { printf '%s: expected one positional argument: <config.yaml>\n' "$SCRIPT_NAME" >&2; exit 2; }
cfg="$1"
[ -r "$cfg" ] || { printf '%s: cannot read %s\n' "$SCRIPT_NAME" "$cfg" >&2; exit 2; }

# Extract platforms[] (top-level YAML list under 'platforms:'). Naive parser:
# look for a 'platforms:' line followed by indented '- value' lines until the
# next non-indented line. Sufficient for /gaia-init's machine-generated YAML.
extract_list() {
  awk -v key="$1" '
    BEGIN { in_section=0 }
    $0 ~ "^"key":[[:space:]]*$" { in_section=1; next }
    in_section && /^[^[:space:]]/ { in_section=0 }
    in_section && /^[[:space:]]+-[[:space:]]+/ {
      v=$0; sub(/^[[:space:]]+-[[:space:]]+/, "", v); sub(/[[:space:]].*$/, "", v); print v
    }
  ' "$cfg"
}

# Extract languages declared in stacks[].*.language. Same naive parser
# operating on indented `language: <value>` lines under stacks:.
extract_stack_languages() {
  awk '
    BEGIN { in_stacks=0 }
    /^stacks:[[:space:]]*$/ { in_stacks=1; next }
    in_stacks && /^[^[:space:]]/ { in_stacks=0 }
    in_stacks && /^[[:space:]]+language:[[:space:]]*/ {
      v=$0; sub(/^[[:space:]]+language:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/"/, "", v); print v
    }
  ' "$cfg"
}

platforms="$(extract_list platforms || true)"
[ -z "$platforms" ] && exit 0  # No platforms declared, nothing to check.

languages="$(extract_stack_languages || true)"

# Normalize: lowercase, replace underscore with hyphen for objective-c variants.
normalize() { tr '[:upper:]' '[:lower:]' | sed 's/_/-/g'; }
normalized_langs="$(printf '%s\n' "$languages" | normalize)"

# Add `server` and its alias `backend` to the recognized platform vocabulary
# so single-backend projects (CLI, library, headless service) can declare
# `platforms: [server]` (the canonical token that generate-config.sh already
# seeds) or `platforms: [backend]` (the natural-language alias users reach for)
# without tripping the "unknown platform" branch. Both are trivially satisfied
# — they require no specific stack language, only that AT LEAST one stack is
# declared.
stack_supports() {
  # $1 = platform; returns 0 if any language in $normalized_langs supports it.
  local platform="$1" wanted
  case "$platform" in
    ios)            wanted="swift|objective-c|react-native|flutter" ;;
    android)        wanted="kotlin|java|react-native|flutter" ;;
    web)            return 0 ;;
    server|backend) return 0 ;;
    *)              printf '%s: unknown platform: %s\n' "$SCRIPT_NAME" "$platform" >&2; return 1 ;;
  esac
  printf '%s\n' "$normalized_langs" | grep -Eq "^($wanted)$"
}

# The prior error-message construction used a `case … esac` inside `$( … )`
# command substitution which bash 3.2.57 (the macOS default) cannot parse —
# it crashed mid-message with "syntax error near unexpected token 'newline'"
# and leaked the literal printf strings into the user-facing output. Replaced
# with a plain shell function so the helper runs unchanged on bash 3.2 and
# bash 4+. The vocabulary itself is fixed at the point of error and is
# mirrored verbatim in the printf strings below.
_capable_langs_for() {
  case "$1" in
    ios)     printf 'swift, objective-c, react-native, flutter' ;;
    android) printf 'kotlin, java, react-native, flutter' ;;
    *)       printf '(none required — any stack satisfies %s)' "$1" ;;
  esac
}

while IFS= read -r p; do
  [ -z "$p" ] && continue
  if ! stack_supports "$p"; then
    _capable="$(_capable_langs_for "$p")"
    cat <<MSG >&2
$SCRIPT_NAME: platform '$p' declared but no stack language supports it.
  Capable languages for $p: $_capable
  Add a stack with one of those languages, or remove '$p' from platforms.
MSG
    exit 1
  fi
done <<< "$platforms"

exit 0
