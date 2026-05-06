#!/usr/bin/env bash
# validate-platform-stack.sh — reject configs that declare a mobile platform
# without any stack capable of building for it.
# Story: E71-S1 (FR-RSV2-34, AC5). Deterministic per ADR-042.
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

stack_supports() {
  # $1 = platform; returns 0 if any language in $normalized_langs supports it.
  local platform="$1" wanted
  case "$platform" in
    ios)     wanted="swift|objective-c|react-native|flutter" ;;
    android) wanted="kotlin|java|react-native|flutter" ;;
    web)     return 0 ;;
    *)       printf '%s: unknown platform: %s\n' "$SCRIPT_NAME" "$platform" >&2; return 1 ;;
  esac
  printf '%s\n' "$normalized_langs" | grep -Eq "^($wanted)$"
}

while IFS= read -r p; do
  [ -z "$p" ] && continue
  if ! stack_supports "$p"; then
    cat <<MSG >&2
$SCRIPT_NAME: platform '$p' declared but no stack language supports it.
  Capable languages for $p: $(case "$p" in
    ios) printf "swift, objective-c, react-native, flutter" ;;
    android) printf "kotlin, java, react-native, flutter" ;;
  esac)
  Add a stack with one of those languages, or remove '$p' from platforms.
MSG
    exit 1
  fi
done <<< "$platforms"

exit 0
