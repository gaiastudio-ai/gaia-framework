#!/usr/bin/env bash
# test-env-allowlist.sh — derive tier-directory allowlist from test-environment.yaml
#
# Derivation rule (per approved plan W1 resolution):
#   1. Fixture-tolerance: if top-level tier_directories: is present (ATDD
#      synthetic fixture), use it directly.
#   2. Primary: tiers.stack_hints.bats_test_dirs values — split on whitespace.
#   3. Fallback: extract path args from runners.shell.tier_{N}_* commands.
#
# Output: one directory per line, deduplicated, to stdout.
# Exit codes:
#   0 — at least one directory emitted
#   1 — usage error, missing file, or no directories found
#
# Invocation:
#   test-env-allowlist.sh --test-env <path-to-test-environment.yaml>
#
# The script uses only awk (POSIX) for YAML parsing — no yq/jq dependency.
# macOS /bin/bash 3.2 compatible.

set -euo pipefail

SCRIPT_NAME="test-env-allowlist.sh"

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
usage: test-env-allowlist.sh --test-env <path>

Derives the tier-directory allowlist from a test-environment.yaml file.
Outputs one directory per line (deduplicated) to stdout.
USAGE
}

# Parse --test-env argument.
TEST_ENV_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --test-env)
      [ $# -ge 2 ] || die "--test-env requires a value"
      TEST_ENV_PATH="$2"; shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

if [ -z "$TEST_ENV_PATH" ]; then
  usage >&2
  exit 1
fi

if [ ! -f "$TEST_ENV_PATH" ]; then
  die "test-environment.yaml not found at '$TEST_ENV_PATH'"
fi

if [ ! -s "$TEST_ENV_PATH" ]; then
  die "test-environment.yaml is empty at '$TEST_ENV_PATH'"
fi

# -------------------------------------------------------------------------
# Strategy 1: Fixture tolerance — top-level tier_directories:
# If the YAML has a top-level tier_directories: key, use its list entries
# directly and exit. This supports ATDD synthetic fixtures.
# -------------------------------------------------------------------------

fixture_dirs() {
  awk '
    /^tier_directories:/ { in_td = 1; next }
    in_td && /^[^ ]/ { exit }
    in_td && /^  - / {
      sub(/^  - /, "")
      gsub(/^["\x27]|["\x27]$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if ($0 != "") print
    }
  ' "$TEST_ENV_PATH"
}

fixture_result="$(fixture_dirs)"
if [ -n "$fixture_result" ]; then
  printf '%s\n' "$fixture_result" | sort -u
  exit 0
fi

# -------------------------------------------------------------------------
# Strategy 2: Primary — tiers.stack_hints.bats_test_dirs values
# Parse values under tiers.stack_hints.bats_test_dirs, split on whitespace.
# -------------------------------------------------------------------------

primary_dirs() {
  awk '
    BEGIN { in_bats = 0; indent = 0 }
    /^[[:space:]]*bats_test_dirs:/ {
      in_bats = 1
      # Record the indentation of the bats_test_dirs key itself
      match($0, /^[[:space:]]*/)
      indent = RLENGTH
      next
    }
    in_bats {
      # Check if this line has deeper indentation (child of bats_test_dirs)
      match($0, /^[[:space:]]*/)
      this_indent = RLENGTH
      # If we hit a line at the same or lesser indent (or empty), we left the block
      if ($0 !~ /^[[:space:]]*$/ && this_indent <= indent) {
        in_bats = 0
        next
      }
      # Skip blank lines
      if ($0 ~ /^[[:space:]]*$/) next
      # Extract the value part after the key: prefix
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
      gsub(/^["\x27]|["\x27]$/, "")
      # Split on whitespace and print each dir
      n = split($0, parts, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (parts[i] != "") print parts[i]
      }
    }
  ' "$TEST_ENV_PATH"
}

primary_result="$(primary_dirs)"
if [ -n "$primary_result" ]; then
  printf '%s\n' "$primary_result" | sort -u
  exit 0
fi

# -------------------------------------------------------------------------
# Strategy 3: Fallback — extract path args from runners.shell.tier_* commands
# Each runner command is like "bats dir1 dir2 dir3" — extract dir args.
# -------------------------------------------------------------------------

fallback_dirs() {
  awk '
    BEGIN { in_shell = 0; shell_indent = 0 }
    /^[[:space:]]*shell:/ {
      in_shell = 1
      match($0, /^[[:space:]]*/)
      shell_indent = RLENGTH
      next
    }
    in_shell {
      match($0, /^[[:space:]]*/)
      this_indent = RLENGTH
      if ($0 !~ /^[[:space:]]*$/ && this_indent <= shell_indent) {
        in_shell = 0
        next
      }
      if ($0 ~ /^[[:space:]]*$/) next
      # Match tier_N_* keys
      if ($0 ~ /tier_[0-9]+_[a-z]+:/) {
        sub(/^[[:space:]]*tier_[0-9]+_[a-z]+:[[:space:]]*/, "")
        # Remove the command name (first word, e.g. "bats")
        sub(/^[^ ]+[[:space:]]+/, "")
        # Split remaining into path args
        n = split($0, parts, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          if (parts[i] != "") print parts[i]
        }
      }
    }
  ' "$TEST_ENV_PATH"
}

fallback_result="$(fallback_dirs)"
if [ -n "$fallback_result" ]; then
  printf '%s\n' "$fallback_result" | sort -u
  exit 0
fi

die "no tier directories found in '$TEST_ENV_PATH'"
