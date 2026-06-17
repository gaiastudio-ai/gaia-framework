#!/usr/bin/env bash
# cross-refs-walk.sh — inverted cross_refs index + transitive DAG walk + cycle detection
#
# Purpose:
#   Builds an inverted index of the cross_refs dependency graph declared in a
#   project-config.yaml, then performs a transitive BFS walk from a seed set of
#   affected stacks, expanding to all downstream consumers.  A DFS pre-pass
#   detects any cycle in the graph; on detection the walk escalates to ["*"]
#   (full-suite fail-safe) and reports the cycle path to stderr.
#
# Usage:
#   cross-refs-walk.sh --config <project-config.yaml> \
#                      --stacks <json-array> \
#                      [--help]
#
# Flags:
#   --config PATH   Required. Path to project-config.yaml (must exist).
#   --stacks JSON   Required. JSON array of seed stack names, e.g. '["stack-a","stack-b"]'.
#                   Special values:
#                     ["*"] — full suite; pass through immediately as ["*"], exit 0.
#                     []    — empty seed; emit [], exit 0.
#   --help          Print usage and exit 0.
#
# Output: a well-formed JSON array of all transitively reachable stack names
#         (consumers of the seed stacks, plus the seeds themselves), deduplicated,
#         on stdout.  Cycle detection output goes to stderr only.
#
# Exit codes:
#   0 — success (["*"] when cycle detected; [] when empty seed)
#   1 — caller error (missing --config, file not found, bad usage)
#
# Design notes:
#   - parse_cross_refs reads BOTH block-list and inline (flow) cross_refs YAML
#     forms using POSIX awk only (no gensub, no 3-arg match).
#   - The inverted index is stored in parallel bash arrays _INV_KEYS / _INV_VALS
#     (same-process; private _ prefix convention).
#   - _dfs_cycle_check iterates ALL stacks declared in config as DFS entry points,
#     maintaining a gray-set (on-stack) and black-set (done) to find back-edges.
#   - bfs_walk implements a FIFO queue with a visited-set for O(N+M) traversal.
#   - build_json_array is copied verbatim from detect-affected.sh (bash fn, not awk).

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# usage — print help to stdout and exit 0
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  cross-refs-walk.sh --config <project-config.yaml> \
                     --stacks <json-array> \
                     [--help]

Options:
  --config PATH    Required. Path to project-config.yaml (must exist).
  --stacks JSON    Required. JSON array of seed stack names.
                   Use ["*"] to pass through full-suite immediately.
                   Use [] to emit an empty result immediately.
  --help           Print this message and exit.

Exit codes:
  0  Success.
  1  Caller error (missing args, file not found).
USAGE
}

# ---------------------------------------------------------------------------
# parse_args — populate CONFIG, STACKS_JSON
# ---------------------------------------------------------------------------
parse_args() {
  CONFIG=""
  STACKS_JSON=""

  if [[ $# -eq 0 ]]; then
    printf 'cross-refs-walk.sh: --config and --stacks are required\n' >&2
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG="$2"; shift 2 ;;
      --stacks)
        STACKS_JSON="$2"; shift 2 ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        printf 'cross-refs-walk.sh: unknown option: %s\n' "$1" >&2
        exit 1 ;;
    esac
  done

  if [[ -z "$CONFIG" ]]; then
    printf 'cross-refs-walk.sh: --config is required\n' >&2
    exit 1
  fi
  if [[ ! -f "$CONFIG" ]]; then
    printf 'cross-refs-walk.sh: config file not found: %s\n' "$CONFIG" >&2
    exit 1
  fi
  if [[ -z "$STACKS_JSON" ]]; then
    printf 'cross-refs-walk.sh: --stacks is required\n' >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# parse_cross_refs — extract (consumer, dependency) pairs from YAML
#
# Handles BOTH YAML forms for cross_refs:
#   Block-list form:
#     cross_refs:
#       - dep-a
#       - dep-b
#   Inline (flow) form:
#     cross_refs: [dep-a, dep-b]
#
# Output: TSV lines: consumer<TAB>dependency
#
# Token validation: each stack/dep name must match ^[A-Za-z0-9_-]+$.
# Invalid tokens are skipped with a warning to stderr.
#
# Uses POSIX awk only (sub/gsub/index) — no gensub, no 3-arg match.
# ---------------------------------------------------------------------------
parse_cross_refs() {
  local config="$1"
  awk '
  BEGIN {
    in_stacks   = 0
    in_crossref = 0
    cur_name    = ""
  }

  # Enter the top-level stacks: block
  /^stacks:/ { in_stacks = 1; next }

  # Any top-level key (no leading whitespace) exits the stacks block
  in_stacks && /^[a-zA-Z_]/ { in_stacks = 0; in_crossref = 0; cur_name = ""; next }

  # New stack entry: "  - name: <value>"
  in_stacks && /^[[:space:]]+-[[:space:]]+name:/ {
    cur_name    = $0
    sub(/.*name:[[:space:]]*/, "", cur_name)
    gsub(/^[[:space:]]+/, "", cur_name)
    gsub(/[[:space:]]+$/, "", cur_name)
    gsub(/^"/, "", cur_name); gsub(/"$/, "", cur_name)
    gsub(/^'"'"'/, "", cur_name); gsub(/'"'"'$/, "", cur_name)
    in_crossref = 0
    next
  }

  # Inline (flow) form: "    cross_refs: [a, b, c]"
  in_stacks && cur_name != "" && /^[[:space:]]+cross_refs:[[:space:]]*\[/ {
    line = $0
    # Extract everything between [ and ]
    sub(/^[^[]*\[/, "", line)
    sub(/\][^]]*$/, "", line)
    # Split on commas
    n = split(line, tokens, ",")
    for (i = 1; i <= n; i++) {
      dep = tokens[i]
      gsub(/^[[:space:]]+/, "", dep)
      gsub(/[[:space:]]+$/, "", dep)
      gsub(/^"/, "", dep); gsub(/"$/, "", dep)
      gsub(/^'"'"'/, "", dep); gsub(/'"'"'$/, "", dep)
      if (dep == "") { continue }
      # Validate token: only [A-Za-z0-9_-]
      if (dep !~ /^[A-Za-z0-9_-]+$/) {
        printf "cross-refs-walk.sh: warning: invalid cross_ref token skipped: %s\n", dep > "/dev/stderr"
        continue
      }
      print cur_name "\t" dep
    }
    in_crossref = 0
    next
  }

  # Enter the block-list cross_refs:
  in_stacks && cur_name != "" && /^[[:space:]]+cross_refs:[[:space:]]*$/ {
    in_crossref = 1; next
  }

  # Non-list key inside stack entry resets in_crossref
  in_stacks && in_crossref && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]/ && !/^[[:space:]]*-/ {
    in_crossref = 0; next
  }

  # Block-list entry under cross_refs: "      - dep-name"
  in_stacks && in_crossref && cur_name != "" && /^[[:space:]]+-[[:space:]]/ {
    dep = $0
    sub(/^[[:space:]]*-[[:space:]]*/, "", dep)
    gsub(/^[[:space:]]+/, "", dep)
    gsub(/[[:space:]]+$/, "", dep)
    gsub(/^"/, "", dep); gsub(/"$/, "", dep)
    gsub(/^'"'"'/, "", dep); gsub(/'"'"'$/, "", dep)
    if (dep == "") { next }
    # Validate token
    if (dep !~ /^[A-Za-z0-9_-]+$/) {
      printf "cross-refs-walk.sh: warning: invalid cross_ref token skipped: %s\n", dep > "/dev/stderr"
      next
    }
    print cur_name "\t" dep
    next
  }
  ' "$config"
}

# ---------------------------------------------------------------------------
# Private parallel arrays for the inverted index.
# These are same-process globals with a _ prefix (private convention).
# _INV_KEYS[i] = dependency name
# _INV_VALS[i] = space-separated list of consumer names
# ---------------------------------------------------------------------------
_INV_KEYS=()
_INV_VALS=()

# ---------------------------------------------------------------------------
# build_inverted_index — populate _INV_KEYS/_INV_VALS from a TSV file
#
# Input: path to TSV file with lines: consumer<TAB>dependency
# After this call, _consumers_of(dep) returns the space-sep consumer list.
#
# Note: same-process function (no subshell); sets global _INV_KEYS/_INV_VALS.
# ---------------------------------------------------------------------------
build_inverted_index() {
  local tsv_file="$1"
  _INV_KEYS=()
  _INV_VALS=()

  local consumer dep i found idx
  while IFS=$'\t' read -r consumer dep; do
    [[ -z "$consumer" || -z "$dep" ]] && continue
    # Linear scan to find existing entry for dep
    found=0
    for i in "${!_INV_KEYS[@]}"; do
      if [[ "${_INV_KEYS[$i]}" == "$dep" ]]; then
        _INV_VALS[$i]="${_INV_VALS[$i]} $consumer"
        found=1
        break
      fi
    done
    if [[ "$found" -eq 0 ]]; then
      _INV_KEYS+=("$dep")
      _INV_VALS+=("$consumer")
    fi
  done < "$tsv_file"
}

# ---------------------------------------------------------------------------
# _consumers_of — return space-separated consumer list for a dependency
#
# Private function (underscore prefix; not covered by NFR-052 unit test).
# ---------------------------------------------------------------------------
_consumers_of() {
  local dep="$1"
  local i
  for i in "${!_INV_KEYS[@]}"; do
    if [[ "${_INV_KEYS[$i]}" == "$dep" ]]; then
      printf '%s' "${_INV_VALS[$i]}"
      return 0
    fi
  done
  printf ''
}

# ---------------------------------------------------------------------------
# parse_stacks_json — extract stack names from a JSON array string
#
# Handles ["*"], [], ["a","b"] and arbitrary whitespace without jq.
# Outputs one stack name per line to stdout.
# ---------------------------------------------------------------------------
parse_stacks_json() {
  local json="$1"
  # Trim outer whitespace and brackets
  local inner
  inner="${json#"${json%%[! ]*}"}"   # ltrim
  inner="${inner%"${inner##*[! ]}"}" # rtrim
  # Strip surrounding [ ]
  inner="${inner#\[}"
  inner="${inner%\]}"
  # If empty after stripping, output nothing
  if [[ -z "${inner//[[:space:]]/}" ]]; then
    return 0
  fi
  # Split on commas, strip quotes and whitespace from each token
  local IFS=','
  local token
  for token in $inner; do
    # Strip whitespace
    token="${token#"${token%%[! ]*}"}"
    token="${token%"${token##*[! ]}"}"
    # Strip quotes
    token="${token#\"}"
    token="${token%\"}"
    token="${token#\'}"
    token="${token%\'}"
    [[ -n "$token" ]] && printf '%s\n' "$token"
  done
}

# ---------------------------------------------------------------------------
# _parse_all_stack_names — extract all stack names from config YAML
#
# Used by cycle detection to iterate all declared stacks as DFS entry points.
# Output: one name per line.
# ---------------------------------------------------------------------------
_parse_all_stack_names() {
  local config="$1"
  awk '
  BEGIN { in_stacks = 0 }
  /^stacks:/ { in_stacks = 1; next }
  in_stacks && /^[a-zA-Z_]/ { in_stacks = 0; next }
  in_stacks && /^[[:space:]]+-[[:space:]]+name:/ {
    name = $0
    sub(/.*name:[[:space:]]*/, "", name)
    gsub(/^[[:space:]]+/, "", name)
    gsub(/[[:space:]]+$/, "", name)
    gsub(/^"/, "", name); gsub(/"$/, "", name)
    gsub(/^'"'"'/, "", name); gsub(/'"'"'$/, "", name)
    print name
  }
  ' "$config"
}

# ---------------------------------------------------------------------------
# Cycle detection state (globals, set by _dfs_cycle_check)
# ---------------------------------------------------------------------------
_CYCLE_DETECTED=0
_CYCLE_PATH=""

# ---------------------------------------------------------------------------
# _dfs_visit — recursive DFS helper for cycle detection
#
# Uses gray-set (on current path) and black-set (fully processed).
# On back-edge (gray node re-visited), sets _CYCLE_DETECTED=1 and _CYCLE_PATH.
#
# Args:
#   $1 — current node
#   $2 — space-separated path so far (for cycle path string)
# Globals read/written: _GRAY (assoc), _BLACK (assoc), _CYCLE_DETECTED, _CYCLE_PATH
# ---------------------------------------------------------------------------
_dfs_visit() {
  local node="$1"
  local path="$2"

  # Already fully processed — no cycle through here
  if [[ -n "${_BLACK[$node]+x}" ]]; then
    return 0
  fi

  # Back-edge: node is on current path → cycle detected.
  # At this point $path already ends with "-> $node" (appended by the
  # caller before the recursive call), so the loop is already closed.
  # Do NOT append $node again or the closing node appears twice.
  if [[ -n "${_GRAY[$node]+x}" ]]; then
    _CYCLE_DETECTED=1
    _CYCLE_PATH="$path"
    printf 'CYCLE DETECTED: %s\n' "$path" >&2
    return 0
  fi

  # Mark as gray (on current DFS path)
  _GRAY["$node"]=1

  # Visit all consumers of this node
  local consumers_str
  consumers_str="$(_consumers_of "$node")"
  if [[ -n "$consumers_str" ]]; then
    local consumer
    for consumer in $consumers_str; do
      if [[ "$_CYCLE_DETECTED" -eq 1 ]]; then
        break
      fi
      _dfs_visit "$consumer" "${path} -> ${consumer}"
    done
  fi

  # Mark as black (done)
  unset '_GRAY[$node]'
  _BLACK["$node"]=1
}

# ---------------------------------------------------------------------------
# _dfs_cycle_check — iterate ALL stacks as DFS entry points
#
# Sets _CYCLE_DETECTED=1 and _CYCLE_PATH if any cycle is found.
# Must be called AFTER build_inverted_index has populated _INV_KEYS/_INV_VALS.
# ---------------------------------------------------------------------------
_dfs_cycle_check() {
  local config="$1"
  _CYCLE_DETECTED=0
  _CYCLE_PATH=""

  declare -gA _GRAY=()
  declare -gA _BLACK=()

  local node
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    if [[ "$_CYCLE_DETECTED" -eq 1 ]]; then
      break
    fi
    _dfs_visit "$node" "$node"
  done < <(_parse_all_stack_names "$config")
}

# ---------------------------------------------------------------------------
# bfs_walk — FIFO BFS from seed set, expanding via _consumers_of
#
# Args:
#   $@ — seed stack names (one per argument)
#
# Output: each visited node name (including seeds) printed to stdout, one per line.
#         Each node is visited exactly once (O(N+M) guarantee).
# ---------------------------------------------------------------------------
bfs_walk() {
  local -a queue=("$@")
  declare -A visited=()

  # Seed the visited set
  local seed
  for seed in "$@"; do
    visited["$seed"]=1
    printf '%s\n' "$seed"
  done

  local head consumers_str consumer
  while [[ ${#queue[@]} -gt 0 ]]; do
    head="${queue[0]}"
    queue=("${queue[@]:1}")

    consumers_str="$(_consumers_of "$head")"
    if [[ -z "$consumers_str" ]]; then
      continue
    fi

    for consumer in $consumers_str; do
      if [[ -z "${visited[$consumer]+x}" ]]; then
        visited["$consumer"]=1
        printf '%s\n' "$consumer"
        queue+=("$consumer")
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# build_json_array — read stack names one-per-line from stdin, dedup, emit JSON
#
# Copied verbatim from detect-affected.sh (bash fn, not awk).
# ---------------------------------------------------------------------------
build_json_array() {
  local -a seen=()
  local line already s

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    already=0
    for s in "${seen[@]+"${seen[@]}"}"; do
      if [[ "$s" == "$line" ]]; then already=1; break; fi
    done
    if [[ "$already" -eq 0 ]]; then seen+=("$line"); fi
  done

  if [[ ${#seen[@]} -eq 0 ]]; then
    printf '[]'
    return
  fi

  local i
  printf '['
  for i in "${!seen[@]}"; do
    if [[ $i -gt 0 ]]; then printf ','; fi
    printf '"%s"' "${seen[$i]}"
  done
  printf ']'
}

# Global temp file for cross-refs TSV — global so the EXIT trap can reference
# it after main() returns (local vars are out of scope at trap time).
_CROSS_REFS_TSV=""

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Parse seed stacks from --stacks JSON
  local -a seeds=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && seeds+=("$name")
  done < <(parse_stacks_json "$STACKS_JSON")

  # Special case: wildcard ["*"] — pass through immediately
  if [[ ${#seeds[@]} -eq 1 && "${seeds[0]}" == "*" ]]; then
    printf '["*"]\n'
    return 0
  fi

  # Special case: empty seed [] — emit [] immediately
  if [[ ${#seeds[@]} -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi

  # Build cross-refs TSV
  _CROSS_REFS_TSV="$(mktemp)"
  # shellcheck disable=SC2064
  trap 'rm -f "$_CROSS_REFS_TSV"' EXIT

  parse_cross_refs "$CONFIG" > "$_CROSS_REFS_TSV"

  # Build inverted index in-process
  build_inverted_index "$_CROSS_REFS_TSV"

  # Pre-pass: DFS cycle detection across ALL stacks declared in config
  _dfs_cycle_check "$CONFIG"

  if [[ "$_CYCLE_DETECTED" -eq 1 ]]; then
    printf 'cross-refs-walk.sh: cycle detected — escalating to full suite\n' >&2
    printf '["*"]\n'
    return 0
  fi

  # BFS transitive walk from seeds
  bfs_walk "${seeds[@]}" | build_json_array
  printf '\n'
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
