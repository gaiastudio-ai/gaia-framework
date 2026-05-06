#!/usr/bin/env bash
# ci-regen-user-steps.sh — *.user-steps.yml include helper for /gaia-config-ci (E71-S4).
#
# Subcommands:
#   discover <ci-file>           Print the sibling *.user-steps.yml path if it exists
#                                next to <ci-file>; exit 1 if absent.
#   extract-before <user-file>   Emit the YAML block under `steps_before_gaia:` on
#                                stdout (without the key itself), suitable for
#                                stitching into the generated workflow.
#   extract-after <user-file>    Same as extract-before but for `steps_after_gaia:`.
#   scaffold <ci-file>           Create a sibling *.user-steps.yml scaffold next
#                                to <ci-file> with empty arrays + commented usage
#                                instructions. No-op when the file already exists.
#   assert-protected <user-file> Exit non-zero with an explanatory message — the
#                                caller uses this as a guard before any write op.
#
# Write protection: the discover/extract-before/extract-after subcommands
# never modify the *.user-steps.yml file. Callers MUST pass any prospective
# write target through `assert-protected` first; the script refuses every
# *.user-steps.yml path so the caller cannot "forget" the rule.
#
# Refs: AC6 (TS-06), AC7 (TS-07), AC8 (TS-08), FR-RSV2-38.

set -euo pipefail
LC_ALL=C
export LC_ALL

cmd="${1:-}"
shift || true

user_steps_path() {
  # Convert .github/workflows/foo.yml -> .github/workflows/foo.user-steps.yml
  local ci="$1"
  local dir base name
  dir="$(dirname "$ci")"
  base="$(basename "$ci")"
  name="${base%.*}"
  printf '%s/%s.user-steps.yml\n' "$dir" "$name"
}

discover() {
  local ci="${1:-}"
  if [ -z "$ci" ]; then
    echo "ci-regen-user-steps.sh discover: missing ci-file argument" >&2
    exit 64
  fi
  local sibling
  sibling="$(user_steps_path "$ci")"
  if [ -f "$sibling" ]; then
    printf '%s\n' "$sibling"
    exit 0
  fi
  exit 1
}

# Extract a YAML list under a top-level key. Stops at the next top-level key
# or end-of-file. Designed for the canonical user-steps.yml shape:
#   steps_before_gaia:
#     - name: ...
#       run: ...
#   steps_after_gaia:
#     - name: ...
extract_block() {
  local file="$1"
  local key="$2"
  if [ ! -f "$file" ]; then
    echo "ci-regen-user-steps.sh: file not found: $file" >&2
    exit 1
  fi
  awk -v k="$key" '
    BEGIN { in_block = 0 }
    # Top-level key match — start the block.
    $0 ~ "^"k":" {
      in_block = 1
      # If the value is on the same line (e.g. "steps_after_gaia: []"), emit
      # nothing (no list entries) and stop.
      if ($0 ~ /:[[:space:]]*\[\]/) { in_block = 0 }
      next
    }
    # End the block when another top-level key starts (no leading whitespace
    # AND not a comment or blank line).
    in_block && /^[A-Za-z_][A-Za-z0-9_-]*:/ { in_block = 0 }
    in_block && /^[^ \t#]/ && !/^$/ { in_block = 0 }
    in_block { print }
  ' "$file"
}

scaffold() {
  local ci="${1:-}"
  if [ -z "$ci" ]; then
    echo "ci-regen-user-steps.sh scaffold: missing ci-file argument" >&2
    exit 64
  fi
  local sibling
  sibling="$(user_steps_path "$ci")"
  if [ -f "$sibling" ]; then
    # No-op — never overwrite an existing user-steps file.
    return 0
  fi
  cat > "$sibling" <<'YAML'
# User-steps include for /gaia-config-ci.
#
# Add custom CI steps here. The /gaia-config-ci --regenerate command stitches
# `steps_before_gaia` BEFORE the GAIA-generated steps and `steps_after_gaia`
# AFTER them. This file is NEVER overwritten by --regenerate — it is yours
# to edit and commit alongside the generated workflow.
#
# Example:
#   steps_before_gaia:
#     - name: Custom pre-step
#       run: echo before
#   steps_after_gaia:
#     - name: Custom post-step
#       run: echo after
steps_before_gaia: []
steps_after_gaia: []
YAML
}

assert_protected() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    echo "ci-regen-user-steps.sh assert-protected: missing path argument" >&2
    exit 64
  fi
  case "$path" in
    *.user-steps.yml|*.user-steps.yaml)
      echo "ci-regen-user-steps.sh: $path is a user-steps file and must never be modified by /gaia-config-ci (write protected)" >&2
      exit 1
      ;;
  esac
  exit 0
}

case "$cmd" in
  discover)         discover "$@" ;;
  extract-before)   extract_block "${1:?missing user-steps file}" "steps_before_gaia" ;;
  extract-after)    extract_block "${1:?missing user-steps file}" "steps_after_gaia" ;;
  scaffold)         scaffold "$@" ;;
  assert-protected) assert_protected "$@" ;;
  ""|-h|--help)
    sed -n '1,30p' "$0"
    ;;
  *)
    echo "ci-regen-user-steps.sh: unknown subcommand: $cmd" >&2
    exit 64
    ;;
esac
