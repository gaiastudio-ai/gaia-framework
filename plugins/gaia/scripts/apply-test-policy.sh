#!/usr/bin/env bash
# apply-test-policy.sh — merge always-run set + force-full-run escape hatch
#
# Purpose:
#   Reads the test_policy section from project-config.yaml and either:
#   (a) merges the always-run critical/smoke set into the affected-set, or
#   (b) overrides the affected-set to ["*"] when --force-full-run is passed.
#
# Usage:
#   apply-test-policy.sh \
#     --config <project-config.yaml> \
#     --affected-set <json-array> \
#     [--force-full-run] \
#     [--help]
#
# Flags:
#   --config PATH         Path to project-config.yaml.
#   --affected-set JSON   JSON array of affected stack names, e.g.
#                         '["stack-a","stack-b"]' or '["*"]'.
#   --force-full-run      Override: ignore affected-set, output ["*"].
#   --help                Print usage and exit 0.
#
# Output:
#   stdout — well-formed JSON array: merged set, original, or ["*"].
#
# Exit codes:
#   0 — success
#   1 — caller error (missing required args)
#
# Design notes:
#   - The always-run set is additive: it NEVER removes items from affected-set.
#   - ["*"] input passes through immediately (no merge needed).
#   - Missing/empty always_run → affected-set passthrough (no injection).
#   - POSIX awk-compatible (no gensub, no 3-arg match).

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------
_log_info() { printf '[apply-test-policy] INFO: %s\n' "$*" >&2; }
_log_warn() { printf '[apply-test-policy] WARN: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# _parse_yaml_list — shared POSIX awk parser for a list key under test_policy:
#
# Args: $1=config_file  $2=key_name (e.g. "always_run" or "flaky")
# Output: one id per line on stdout; empty output when absent/empty.
#
# Handles both YAML shapes:
#   Inline:  key: [val-a, val-b]
#   Block:   key:\n    - val-a\n    - val-b
# ---------------------------------------------------------------------------
_parse_yaml_list() {
  local config_file="$1"
  local key_name="$2"

  awk -v key="$key_name" '
  BEGIN {
    in_test_policy = 0
    in_key_block   = 0
  }

  # Enter the test_policy: section
  /^test_policy:/ { in_test_policy = 1; next }

  # Any top-level key (no leading whitespace) exits test_policy
  in_test_policy && /^[a-zA-Z_]/ { in_test_policy = 0; in_key_block = 0; next }

  # Match the target key within test_policy
  in_test_policy && $0 ~ "^[[:space:]]+" key ":" {
    # Check for inline list: key: [val-a, val-b]
    start = index($0, "[")
    if (start > 0) {
      end_pos = index($0, "]")
      if (end_pos > start) {
        list = substr($0, start + 1, end_pos - start - 1)
        n = split(list, items, ",")
        for (i = 1; i <= n; i++) {
          gsub(/^[[:space:]]+/, "", items[i])
          gsub(/[[:space:]]+$/, "", items[i])
          gsub(/^"/, "", items[i]); gsub(/"$/, "", items[i])
          gsub(/^'"'"'/, "", items[i]); gsub(/'"'"'$/, "", items[i])
          if (items[i] != "") print items[i]
        }
      }
      # Inline list fully consumed — do not enter block mode.
      next
    }

    # Check for empty after colon (block list follows)
    val = $0
    sub(/^[[:space:]]*[a-zA-Z_]+:[[:space:]]*/, "", val)
    gsub(/^[[:space:]]+/, "", val)
    gsub(/[[:space:]]+$/, "", val)
    if (val == "" || val == "[]") {
      if (val == "[]") { next }
      in_key_block = 1
      next
    }
    next
  }

  # Block-list items: "  - value"
  in_test_policy && in_key_block && /^[[:space:]]+-[[:space:]]/ {
    val = $0
    sub(/^[[:space:]]*-[[:space:]]*/, "", val)
    gsub(/^[[:space:]]+/, "", val)
    gsub(/[[:space:]]+$/, "", val)
    gsub(/^"/, "", val); gsub(/"$/, "", val)
    gsub(/^'"'"'/, "", val); gsub(/'"'"'$/, "", val)
    if (val != "") print val
    next
  }

  # Any non-list line within test_policy exits the block-list
  in_test_policy && in_key_block && /^[[:space:]]+[a-zA-Z_]+:/ {
    in_key_block = 0
    # Fall through so the line can be re-evaluated (it might be the target key
    # for a different call — but since we only have one key per invocation,
    # just exit the block).
  }
  ' "$config_file"
}

# ---------------------------------------------------------------------------
# read_test_policy_always_run — read the always_run list from config
#
# Args: $1=config_file
# Output: one id per line; empty when absent/empty.
# ---------------------------------------------------------------------------
read_test_policy_always_run() {
  _parse_yaml_list "$1" "always_run"
}

# ---------------------------------------------------------------------------
# read_test_policy_flaky — read the flaky list from config
#
# Args: $1=config_file
# Output: one id per line; empty when absent/empty.
# ---------------------------------------------------------------------------
read_test_policy_flaky() {
  _parse_yaml_list "$1" "flaky"
}

# ---------------------------------------------------------------------------
# read_test_policy_retry_limit — read retry_limit from config
#
# Args: $1=config_file
# Output: the configured integer, or 2 if absent.
# ---------------------------------------------------------------------------
read_test_policy_retry_limit() {
  local config_file="$1"
  local val
  val="$(awk '
  BEGIN { in_test_policy = 0 }
  /^test_policy:/ { in_test_policy = 1; next }
  in_test_policy && /^[a-zA-Z_]/ { in_test_policy = 0; next }
  in_test_policy && /^[[:space:]]+retry_limit:/ {
    v = $0
    sub(/^[[:space:]]*retry_limit:[[:space:]]*/, "", v)
    gsub(/^[[:space:]]+/, "", v)
    gsub(/[[:space:]]+$/, "", v)
    print v
    exit
  }
  ' "$config_file")"

  if [ -z "$val" ]; then
    printf '2'
  else
    printf '%s' "$val"
  fi
}

# ---------------------------------------------------------------------------
# merge_always_run — union affected-set JSON + always_run ids
#
# Args: $1=affected_json  $2..$N=always_run ids (one per arg)
# Output: merged JSON array on stdout.
#
# Logic:
#   - ["*"] input → passthrough ["*"]
#   - Empty always_run args → passthrough affected_json
#   - Otherwise: union (dedup) of affected items + always_run items
# ---------------------------------------------------------------------------
merge_always_run() {
  local affected_json="$1"
  shift

  # Collect always_run ids from remaining args
  local -a always_run_ids=()
  while [ $# -gt 0 ]; do
    [ -n "$1" ] && always_run_ids+=("$1")
    shift
  done

  # ["*"] passthrough
  local inner
  inner="$(printf '%s' "$affected_json" | tr -d '[:space:]')"
  if [ "$inner" = '["*"]' ]; then
    printf '["*"]\n'
    return 0
  fi

  # Empty always_run → passthrough
  if [ ${#always_run_ids[@]} -eq 0 ]; then
    printf '%s\n' "$affected_json"
    return 0
  fi

  # Parse affected-set items from JSON
  local -a affected_items=()
  local parsed
  parsed="$(printf '%s' "$affected_json" | tr -d '[]"' | tr ',' '\n' | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  while IFS= read -r line; do
    [ -n "$line" ] && affected_items+=("$line")
  done <<< "$parsed"

  # Union with dedup using associative array
  local -A seen=()
  local -a result=()
  local item

  # Add affected items first (preserves order)
  for item in "${affected_items[@]+"${affected_items[@]}"}"; do
    if [ -n "$item" ] && [ -z "${seen[$item]:-}" ]; then
      seen["$item"]=1
      result+=("$item")
    fi
  done

  # Add always_run items
  for item in "${always_run_ids[@]}"; do
    if [ -n "$item" ] && [ -z "${seen[$item]:-}" ]; then
      seen["$item"]=1
      result+=("$item")
    fi
  done

  # Build JSON array
  if [ ${#result[@]} -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  local json="["
  local first=1
  for item in "${result[@]}"; do
    [ "$first" -eq 0 ] && json+=","
    json+="\"$item\""
    first=0
  done
  json+="]"
  printf '%s\n' "$json"
}

# ---------------------------------------------------------------------------
# apply_force_full_run — output the wildcard set
# ---------------------------------------------------------------------------
apply_force_full_run() {
  printf '["*"]\n'
}

# ---------------------------------------------------------------------------
# parse_args — populate CONFIG, AFFECTED_SET, FORCE_FULL_RUN
# ---------------------------------------------------------------------------
parse_args() {
  CONFIG=""
  AFFECTED_SET=""
  FORCE_FULL_RUN=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)
        CONFIG="$2"; shift 2 ;;
      --affected-set)
        AFFECTED_SET="$2"; shift 2 ;;
      --force-full-run)
        FORCE_FULL_RUN=1; shift ;;
      --help|-h)
        printf 'Usage: apply-test-policy.sh --config <yaml> --affected-set <json> [--force-full-run]\n'
        exit 0 ;;
      *)
        printf 'apply-test-policy.sh: unknown option: %s\n' "$1" >&2
        exit 1 ;;
    esac
  done

  if [ -z "$AFFECTED_SET" ]; then
    printf 'apply-test-policy.sh: --affected-set is required\n' >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # --force-full-run overrides everything
  if [ "$FORCE_FULL_RUN" -eq 1 ]; then
    apply_force_full_run
    return 0
  fi

  # ["*"] passthrough — no merge needed
  local trimmed
  trimmed="$(printf '%s' "$AFFECTED_SET" | tr -d '[:space:]')"
  if [ "$trimmed" = '["*"]' ]; then
    printf '["*"]\n'
    return 0
  fi

  # Read always_run from config (may be empty if no config or no section)
  local -a always_run_items=()
  if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
    local ar_output
    ar_output="$(read_test_policy_always_run "$CONFIG")"
    while IFS= read -r line; do
      [ -n "$line" ] && always_run_items+=("$line")
    done <<< "$ar_output"
  fi

  # Merge
  merge_always_run "$AFFECTED_SET" "${always_run_items[@]+"${always_run_items[@]}"}"
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
