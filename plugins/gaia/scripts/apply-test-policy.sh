#!/usr/bin/env bash
# apply-test-policy.sh — per-trigger scope narrowing + always-run merge
#
# Purpose:
#   Reads the test_policy section from project-config.yaml and:
#   (a) applies per-trigger scope narrowing (--trigger pr|push|schedule),
#   (b) merges the always-run critical/smoke set into the affected-set, or
#   (c) overrides the affected-set to ["*"] when --force-full-run is passed.
#
# Usage:
#   apply-test-policy.sh \
#     --config <project-config.yaml> \
#     --affected-set <json-array> \
#     [--trigger <pr|push|schedule>] \
#     [--force-full-run] \
#     [--help]
#
# Flags:
#   --config PATH         Path to project-config.yaml.
#   --affected-set JSON   JSON array of affected stack names, e.g.
#                         '["stack-a","stack-b"]' or '["*"]'.
#   --trigger TYPE        CI trigger type for per-trigger scope filtering.
#                         When set, applies include/exclude stack rules from
#                         test_policy.triggers.<type>. When absent, no
#                         trigger-specific filtering occurs.
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
#   - ["*"] input passes through immediately (no merge needed). Per-trigger
#     scope narrowing NEVER overrides the wildcard — safety-first precedence.
#   - Missing/empty always_run → affected-set passthrough (no injection).
#   - Missing/empty trigger config → no scope narrowing (no injection).
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
# read_trigger_scope — read scope rule for a given trigger from config
#
# Args: $1=config_file  $2=trigger_name (pr|push|schedule)
# Output: two lines on stdout:
#   Line 1: filter type — "include", "exclude", or "none"
#   Line 2: comma-separated stack names (empty when type is "none")
#
# Parses the nested YAML path test_policy.triggers.<trigger>.include_stacks
# or test_policy.triggers.<trigger>.exclude_stacks using awk.
# ---------------------------------------------------------------------------
read_trigger_scope() {
  local config_file="$1"
  local trigger_name="$2"

  if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
    printf 'none\n\n'
    return 0
  fi

  local include_items exclude_items
  include_items="$(_parse_trigger_list "$config_file" "$trigger_name" "include_stacks")"
  exclude_items="$(_parse_trigger_list "$config_file" "$trigger_name" "exclude_stacks")"

  if [ -n "$include_items" ]; then
    printf 'include\n%s\n' "$include_items"
  elif [ -n "$exclude_items" ]; then
    printf 'exclude\n%s\n' "$exclude_items"
  else
    printf 'none\n\n'
  fi
}

# ---------------------------------------------------------------------------
# _parse_trigger_list — awk parser for nested trigger scope list
#
# Args: $1=config_file  $2=trigger_name  $3=field_name
# Output: one id per line on stdout; empty output when absent/empty.
#
# Parses: test_policy: > triggers: > <trigger_name>: > <field_name>:
# Handles both inline [a, b] and block-list YAML forms.
# ---------------------------------------------------------------------------
_parse_trigger_list() {
  local config_file="$1"
  local trigger_name="$2"
  local field_name="$3"

  awk -v trigger="$trigger_name" -v field="$field_name" '
  BEGIN {
    in_test_policy = 0
    in_triggers    = 0
    in_trigger     = 0
    in_field_block = 0
    tp_indent      = 0
    trig_indent    = 0
    trg_indent     = 0
  }

  # Enter test_policy: section
  /^test_policy:/ { in_test_policy = 1; tp_indent = 0; next }

  # Any top-level key exits test_policy
  in_test_policy && /^[a-zA-Z_]/ { in_test_policy = 0; in_triggers = 0; in_trigger = 0; in_field_block = 0; next }

  # Enter triggers: subsection
  in_test_policy && /^[[:space:]]+triggers:/ {
    in_triggers = 1
    match($0, /^[[:space:]]+/)
    trig_indent = RLENGTH
    next
  }

  # Exit triggers if we see a sibling key at triggers indent level
  in_triggers && !in_trigger && /^[[:space:]]+[a-zA-Z_]+:/ {
    match($0, /^[[:space:]]+/)
    if (RLENGTH <= trig_indent) {
      in_triggers = 0
      next
    }
  }

  # Enter the target trigger subsection
  in_triggers && $0 ~ "^[[:space:]]+" trigger ":" {
    in_trigger = 1
    match($0, /^[[:space:]]+/)
    trg_indent = RLENGTH
    next
  }

  # Exit the target trigger on a sibling key at same or lesser indent
  in_trigger && /^[[:space:]]+[a-zA-Z_]+:/ && !in_field_block {
    match($0, /^[[:space:]]+/)
    if (RLENGTH <= trg_indent) {
      in_trigger = 0
      in_field_block = 0
    }
  }

  # Match the target field within the trigger
  in_trigger && $0 ~ "^[[:space:]]+" field ":" {
    # Inline list: field: [a, b]
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
      next
    }

    # Check for empty value or empty list
    val = $0
    sub(/^[[:space:]]*[a-zA-Z_]+:[[:space:]]*/, "", val)
    gsub(/^[[:space:]]+/, "", val)
    gsub(/[[:space:]]+$/, "", val)
    if (val == "" || val == "[]") {
      if (val == "[]") { next }
      in_field_block = 1
      next
    }
    next
  }

  # Block-list items within the field
  in_trigger && in_field_block && /^[[:space:]]+-[[:space:]]/ {
    val = $0
    sub(/^[[:space:]]*-[[:space:]]*/, "", val)
    gsub(/^[[:space:]]+/, "", val)
    gsub(/[[:space:]]+$/, "", val)
    gsub(/^"/, "", val); gsub(/"$/, "", val)
    gsub(/^'"'"'/, "", val); gsub(/'"'"'$/, "", val)
    if (val != "") print val
    next
  }

  # Any non-list line exits the field block
  in_trigger && in_field_block && /^[[:space:]]+[a-zA-Z_]+:/ {
    in_field_block = 0
  }
  ' "$config_file"
}

# ---------------------------------------------------------------------------
# apply_trigger_scope — filter affected-set JSON by trigger scope rule
#
# Args: $1=affected_json  $2=filter_type (include|exclude|none)  $3..N=stack names
# Output: filtered JSON array on stdout.
#
# Logic:
#   - "none" or empty stack list → passthrough affected_json
#   - "include" → intersection of affected items with the stack list
#   - "exclude" → affected items minus the stack list
#   - Empty include list → passthrough (no filtering)
# ---------------------------------------------------------------------------
apply_trigger_scope() {
  local affected_json="$1"
  local filter_type="$2"
  shift 2

  # Collect stack names from remaining args
  local -a scope_stacks=()
  while [ $# -gt 0 ]; do
    [ -n "$1" ] && scope_stacks+=("$1")
    shift
  done

  # No filtering when type is "none" or stack list is empty
  if [ "$filter_type" = "none" ] || [ ${#scope_stacks[@]} -eq 0 ]; then
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

  local -a result=()
  local item match

  if [ "$filter_type" = "include" ]; then
    # Intersection: keep only items in scope_stacks
    for item in "${affected_items[@]+"${affected_items[@]}"}"; do
      match=0
      for s in "${scope_stacks[@]}"; do
        [ "$item" = "$s" ] && { match=1; break; }
      done
      [ "$match" -eq 1 ] && result+=("$item")
    done
  elif [ "$filter_type" = "exclude" ]; then
    # Difference: keep items NOT in scope_stacks
    for item in "${affected_items[@]+"${affected_items[@]}"}"; do
      match=0
      for s in "${scope_stacks[@]}"; do
        [ "$item" = "$s" ] && { match=1; break; }
      done
      [ "$match" -eq 0 ] && result+=("$item")
    done
  else
    # Unknown filter type — passthrough
    printf '%s\n' "$affected_json"
    return 0
  fi

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
# parse_args — populate CONFIG, AFFECTED_SET, FORCE_FULL_RUN, TRIGGER
# ---------------------------------------------------------------------------
parse_args() {
  CONFIG=""
  AFFECTED_SET=""
  FORCE_FULL_RUN=0
  TRIGGER=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)
        CONFIG="$2"; shift 2 ;;
      --affected-set)
        AFFECTED_SET="$2"; shift 2 ;;
      --force-full-run)
        FORCE_FULL_RUN=1; shift ;;
      --trigger)
        TRIGGER="$2"; shift 2 ;;
      --help|-h)
        printf 'Usage: apply-test-policy.sh --config <yaml> --affected-set <json> [--force-full-run] [--trigger <pr|push|schedule>]\n'
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

  # ["*"] passthrough — no merge needed. This MUST run before trigger-scope
  # narrowing so a promotion-push wildcard is never narrowed by scope rules.
  local trimmed
  trimmed="$(printf '%s' "$AFFECTED_SET" | tr -d '[:space:]')"
  if [ "$trimmed" = '["*"]' ]; then
    printf '["*"]\n'
    return 0
  fi

  # Per-trigger scope narrowing (only when --trigger is set and config exists)
  local scoped_set="$AFFECTED_SET"
  if [ -n "$TRIGGER" ] && [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
    local scope_output filter_type scope_names_raw
    scope_output="$(read_trigger_scope "$CONFIG" "$TRIGGER")"
    filter_type="$(printf '%s' "$scope_output" | head -1)"
    scope_names_raw="$(printf '%s' "$scope_output" | tail -n +2)"

    local -a scope_names=()
    while IFS= read -r line; do
      [ -n "$line" ] && scope_names+=("$line")
    done <<< "$scope_names_raw"

    scoped_set="$(apply_trigger_scope "$AFFECTED_SET" "$filter_type" "${scope_names[@]+"${scope_names[@]}"}")"
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
  merge_always_run "$scoped_set" "${always_run_items[@]+"${always_run_items[@]}"}"
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
