#!/usr/bin/env bash
# independence-check.sh — concurrent sprint independence checker
#
# Evaluates independence rules between a candidate sprint and all active
# sprints to determine whether the candidate can safely activate.
#
# Rules implemented by this script:
#   (a) No transitive dependency edge between candidate and active sprint
#       stories (BFS on the direction-agnostic depends_on/blocks adjacency).
#   (b) No shared epics between sprints (excluding catch-all epics).
#
# Rules (c) and (d) — touch-set overlap — are added by a sibling story.
#
# CLI:
#   independence-check.sh --candidate <sprint_id> [--active <id>[,<id>...]]
#
# When --active is omitted, active sprints are discovered from the
# per-sprint state files.
#
# Exit codes:
#   0 — PASS (per-comparison PASS lines on stdout; nothing on stderr)
#   1 — FAIL (per-comparison lines on stdout; FAIL lines on stderr;
#         fail-closed diagnostics on both stdout and stderr)
#
# Bash 3.2 compatible (macOS default). No local -A, mapfile, readarray.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="independence-check.sh"

# Resolve script directory for sourcing siblings.
_IC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source catch-all flag parser (exposes catch_all_epics).
# shellcheck source=lib/catch-all-flag.sh
. "${_IC_SCRIPT_DIR}/lib/catch-all-flag.sh"

# Source story file resolver (exposes resolve_story_file).
# shellcheck source=resolve-story-file.sh
. "${_IC_SCRIPT_DIR}/resolve-story-file.sh"

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
_IC_CANDIDATE=""
_IC_ACTIVE_LIST=""      # comma-separated or empty (discover)

# Project root for file resolution.
_IC_PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"

# Temp directory for graph data (set in main, cleaned on exit).
_IC_TMPDIR=""
_ic_cleanup() { [ -z "$_IC_TMPDIR" ] || rm -rf "$_IC_TMPDIR" 2>/dev/null || true; }
trap '_ic_cleanup' EXIT INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ic_die() {
  local msg="$1"
  local diag="FAIL indeterminate: $msg"
  printf '%s\n' "$diag"
  printf '%s\n' "$diag" >&2
  exit 1
}

_ic_usage() {
  cat <<'USAGE'
Usage: independence-check.sh --candidate <sprint_id> [--active <id>[,<id>...]]

Options:
  --candidate <id>       Sprint to check for activation (required)
  --active <id>[,<id>]   Active sprints to check against (discovered if omitted)
  -h, --help             Show this help
USAGE
  exit 0
}

# ---------------------------------------------------------------------------
# Parse CLI
# ---------------------------------------------------------------------------
_ic_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --candidate) _IC_CANDIDATE="${2:-}"; shift 2 ;;
      --active)    _IC_ACTIVE_LIST="${2:-}"; shift 2 ;;
      -h|--help)   _ic_usage ;;
      *)           printf '%s: unknown option: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
    esac
  done
  if [ -z "$_IC_CANDIDATE" ]; then
    printf '%s: --candidate is required\n' "$SCRIPT_NAME" >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Resolve sprint state file via sprint-state.sh resolve-file
# ---------------------------------------------------------------------------
_ic_resolve_state_file() {
  local sprint_id="$1"
  local sprint_state_sh="${_IC_SCRIPT_DIR}/sprint-state.sh"
  local result
  result="$(PROJECT_ROOT="$_IC_PROJECT_ROOT" \
            CLAUDE_PROJECT_ROOT="$_IC_PROJECT_ROOT" \
            "$sprint_state_sh" resolve-file --sprint "$sprint_id" 2>/dev/null)" || {
    _ic_die "unable to read dependency structure"
  }
  if [ ! -f "$result" ]; then
    _ic_die "unable to read dependency structure"
  fi
  printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# Discover active sprints from per-sprint state files
# ---------------------------------------------------------------------------
_ic_discover_active_sprints() {
  local state_dir="${_IC_PROJECT_ROOT:+${_IC_PROJECT_ROOT%/}/}.gaia/state"
  if [ ! -d "$state_dir" ]; then
    _ic_die "unable to read dependency structure"
  fi
  local active_ids=""
  local f
  for f in "${state_dir}"/sprint-status-*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.lock|*.result) continue ;; esac
    local sid="" st=""
    sid="$(awk '/^sprint_id:[[:space:]]*/ {
        v = $0; sub(/^sprint_id:[[:space:]]*/, "", v)
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        print v; exit
      }' "$f" 2>/dev/null)" || continue
    st="$(awk '/^status:[[:space:]]*/ {
        v = $0; sub(/^status:[[:space:]]*/, "", v)
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        print v; exit
      }' "$f" 2>/dev/null)" || continue
    if [ "$st" = "active" ] && [ "$sid" != "$_IC_CANDIDATE" ]; then
      if [ -n "$active_ids" ]; then
        active_ids="${active_ids},${sid}"
      else
        active_ids="$sid"
      fi
    fi
  done
  printf '%s' "$active_ids"
}

# ---------------------------------------------------------------------------
# Read story keys from a per-sprint state file.  One key per line.
# ---------------------------------------------------------------------------
_ic_read_sprint_keys() {
  local state_file="$1"
  if [ ! -r "$state_file" ]; then
    _ic_die "unable to read dependency structure"
  fi
  awk '
    BEGIN { in_s = 0 }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^stories:[[:space:]]*$/ { in_s = 1; next }
    line ~ /^stories:[[:space:]]*\[\][[:space:]]*$/ { next }
    in_s && line ~ /^[^[:space:]-]/ { in_s = 0; next }
    !in_s { next }
    line ~ /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", k)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", k)
      if (k != "") print k
    }
  ' "$state_file"
}

# ---------------------------------------------------------------------------
# Parse a single story file's YAML frontmatter.
# Emits to stdout (TSV):  TYPE\tKEY\tVALUE
#   TYPE = depends_on | blocks | epic | fm_closed
# fm_closed is "yes" when the closing --- is found, "no" otherwise.
# ---------------------------------------------------------------------------
_ic_parse_story_frontmatter() {
  local story_file="$1"
  awk '
    BEGIN { in_fm = 0; started = 0; field = ""; closed = 0 }
    /^---[[:space:]]*$/ {
      if (!started) { started = 1; in_fm = 1; next }
      else { closed = 1; exit }
    }
    !in_fm { next }

    /^depends_on:[[:space:]]*$/ { field = "depends_on"; next }
    /^depends_on:[[:space:]]*\[/ {
      line = $0
      sub(/^depends_on:[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      n = split(line, items, /[[:space:]]*,[[:space:]]*/)
      for (i = 1; i <= n; i++) {
        v = items[i]
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        if (v != "") printf "depends_on\t%s\n", v
      }
      field = ""
      next
    }
    /^blocks:[[:space:]]*$/ { field = "blocks"; next }
    /^blocks:[[:space:]]*\[/ {
      line = $0
      sub(/^blocks:[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      n = split(line, items, /[[:space:]]*,[[:space:]]*/)
      for (i = 1; i <= n; i++) {
        v = items[i]
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        if (v != "") printf "blocks\t%s\n", v
      }
      field = ""
      next
    }
    /^epic:[[:space:]]*/ {
      v = $0
      sub(/^epic:[[:space:]]*/, "", v)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
      printf "epic\t%s\n", v
      field = ""
      next
    }

    field != "" && /^[[:space:]]*-[[:space:]]/ {
      v = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", v)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
      if (v != "") printf "%s\t%s\n", field, v
      next
    }
    field != "" && /^[^[:space:]]/ { field = "" }
    field != "" && /^[[:space:]]/ && !/^[[:space:]]*-/ { field = "" }

    END { printf "fm_closed\t%s\n", (closed ? "yes" : "no") }
  ' "$story_file"
}

# ---------------------------------------------------------------------------
# Batch-resolve story files via a single find pass.
# Writes KEY<TAB>PATH to the given output file.
# ---------------------------------------------------------------------------
_ic_batch_resolve_story_files() {
  local keys_file="$1" out_file="$2"
  local impl_root="${IMPLEMENTATION_ARTIFACTS:-${_IC_PROJECT_ROOT:+${_IC_PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts}"
  : > "$out_file"
  if [ ! -d "$impl_root" ]; then return 1; fi

  # Single find + awk: find all story.md files and extract the key prefix
  # from the parent directory name.
  find "$impl_root" -name 'story.md' -type f 2>/dev/null | \
    awk -F'/' -v kf="$keys_file" '
    BEGIN {
      while ((getline line < kf) > 0) { if (line != "") wanted[line] = 1 }
      close(kf)
    }
    {
      path = $0
      # Skip legacy stories/ paths.
      if (index(path, "/stories/") > 0) next
      # Parent dir is the second-to-last component.
      n = split(path, parts, "/")
      if (n < 2) next
      dir = parts[n-1]
      # Extract key prefix: everything before the first "-" that ends the
      # story-key pattern (E<n>-S<n>). Key format: E<digits>-S<digits>.
      # The dir is KEY-slug, so split on first "-" after the S<digits> part.
      if (match(dir, /^E[0-9]+-S[0-9]+/) > 0) {
        key = substr(dir, RSTART, RLENGTH)
        if (key in wanted && !(key in found)) {
          printf "%s\t%s\n", key, path
          found[key] = 1
        }
      }
    }
  ' > "$out_file"
}

# ---------------------------------------------------------------------------
# Check if a key is "known" (row in epics-and-stories.md, epic shard, or
# resolvable story file).
# ---------------------------------------------------------------------------
_ic_is_known_key() {
  local key="$1" epics_file="$2" shards_dir="$3"
  if [ -f "$epics_file" ] && /usr/bin/grep -q "\\b${key}\\b" "$epics_file" 2>/dev/null; then
    return 0
  fi
  if [ -n "$shards_dir" ] && [ -d "$shards_dir" ]; then
    if /usr/bin/grep -rq "\\b${key}\\b" "$shards_dir" 2>/dev/null; then
      return 0
    fi
  fi
  if resolve_story_file "$key" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Resolve epics file and shards directory paths.
# ---------------------------------------------------------------------------
_ic_resolve_planning_paths() {
  local resolve_config="${_IC_SCRIPT_DIR}/resolve-config.sh"
  local planning_dir=""
  if [ -x "$resolve_config" ]; then
    planning_dir="$(PROJECT_ROOT="$_IC_PROJECT_ROOT" \
                    CLAUDE_PROJECT_ROOT="$_IC_PROJECT_ROOT" \
                    "$resolve_config" planning_artifacts 2>/dev/null)" || planning_dir=""
  fi
  if [ -z "$planning_dir" ]; then
    planning_dir="${_IC_PROJECT_ROOT:+${_IC_PROJECT_ROOT%/}/}.gaia/artifacts/planning-artifacts"
  fi
  printf '%s\t%s' "${planning_dir}/epics-and-stories.md" "${planning_dir}/epics"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  _ic_parse_args "$@"

  # Resolve planning paths.
  local planning_paths epics_file shards_dir
  planning_paths="$(_ic_resolve_planning_paths)"
  epics_file="${planning_paths%%	*}"
  shards_dir="${planning_paths#*	}"

  # Resolve candidate state file and read keys.
  local candidate_state_file candidate_keys
  candidate_state_file="$(_ic_resolve_state_file "$_IC_CANDIDATE")"
  candidate_keys="$(_ic_read_sprint_keys "$candidate_state_file")"

  # Resolve active sprints.
  local active_csv="$_IC_ACTIVE_LIST"
  if [ -z "$active_csv" ]; then
    active_csv="$(_ic_discover_active_sprints)"
  fi

  # No active sprints — candidate passes trivially.
  if [ -z "$active_csv" ]; then
    exit 0
  fi

  local active_ids
  active_ids="$(printf '%s' "$active_csv" | tr ',' '\n')"

  # -------------------------------------------------------------------
  # Temp directory for consolidated data.
  # -------------------------------------------------------------------
  _IC_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/ic-check.XXXXXX")"
  local tmpdir="$_IC_TMPDIR"

  # Consolidated data files (TSV):
  #   membership.tsv:  KEY<TAB>SPRINT_ID
  #   adj.tsv:         FROM<TAB>TO          (direction-agnostic)
  #   directed.tsv:    FROM<TAB>TO          (depends_on direction)
  #   epics.tsv:       KEY<TAB>EPIC
  local membership="$tmpdir/membership.tsv"
  local adj_f="$tmpdir/adj.tsv"
  local directed_f="$tmpdir/directed.tsv"
  local epics_f="$tmpdir/epics.tsv"

  : > "$membership"
  : > "$adj_f"
  : > "$directed_f"
  : > "$epics_f"

  # -------------------------------------------------------------------
  # Register candidate stories.
  # -------------------------------------------------------------------
  local ckey
  while IFS= read -r ckey; do
    [ -n "$ckey" ] || continue
    printf '%s\t%s\n' "$ckey" "$_IC_CANDIDATE" >> "$membership"
  done <<< "$candidate_keys"

  # -------------------------------------------------------------------
  # Register active sprint stories.
  # -------------------------------------------------------------------
  local aid
  while IFS= read -r aid; do
    [ -n "$aid" ] || continue
    local active_state_file active_keys akey
    active_state_file="$(_ic_resolve_state_file "$aid")"
    active_keys="$(_ic_read_sprint_keys "$active_state_file")"
    while IFS= read -r akey; do
      [ -n "$akey" ] || continue
      printf '%s\t%s\n' "$akey" "$aid" >> "$membership"
    done <<< "$active_keys"
  done <<< "$active_ids"

  # -------------------------------------------------------------------
  # Batch-resolve all story file paths (single find pass).
  # -------------------------------------------------------------------
  local all_keys_file="$tmpdir/all_keys.txt"
  awk -F'\t' '{ print $1 }' "$membership" | sort -u > "$all_keys_file"

  local resolved_f="$tmpdir/resolved.tsv"
  : > "$tmpdir/ext_refs.txt"
  _ic_batch_resolve_story_files "$all_keys_file" "$resolved_f"

  # -------------------------------------------------------------------
  # Parse all story files and build consolidated data.
  # -------------------------------------------------------------------
  local skey
  while IFS= read -r skey; do
    [ -n "$skey" ] || continue
    local story_file
    story_file="$(awk -F'\t' -v k="$skey" '$1 == k { print $2; exit }' "$resolved_f")"
    if [ -z "$story_file" ] || [ ! -f "$story_file" ]; then
      _ic_die "missing file: $skey"
    fi

    local fm_data
    fm_data="$(_ic_parse_story_frontmatter "$story_file")" || {
      _ic_die "unparseable file: $story_file"
    }

    # Check frontmatter is closed.
    local fm_closed
    fm_closed="$(printf '%s\n' "$fm_data" | awk -F'\t' '$1 == "fm_closed" { print $2; exit }')"
    if [ "$fm_closed" != "yes" ]; then
      _ic_die "unparseable file: $story_file"
    fi

    # Extract epic.
    local epic_val
    epic_val="$(printf '%s\n' "$fm_data" | awk -F'\t' '$1 == "epic" { print $2; exit }')"
    if [ -z "$epic_val" ]; then
      _ic_die "missing epic: $story_file"
    fi
    printf '%s\t%s\n' "$skey" "$epic_val" >> "$epics_f"

    # Build adjacency and directed graphs from depends_on and blocks.
    local dep_field dep_target
    while IFS=$'\t' read -r dep_field dep_target; do
      [ -n "$dep_target" ] || continue
      case "$dep_field" in
        depends_on)
          printf '%s\t%s\n' "$skey" "$dep_target" >> "$adj_f"
          printf '%s\t%s\n' "$dep_target" "$skey" >> "$adj_f"
          printf '%s\t%s\n' "$skey" "$dep_target" >> "$directed_f"
          ;;
        blocks)
          printf '%s\t%s\n' "$skey" "$dep_target" >> "$adj_f"
          printf '%s\t%s\n' "$dep_target" "$skey" >> "$adj_f"
          printf '%s\t%s\n' "$dep_target" "$skey" >> "$directed_f"
          ;;
      esac
    done <<< "$fm_data"

    # Collect referenced keys outside any sprint for batch checking later.
    while IFS=$'\t' read -r dep_field dep_target; do
      [ -n "$dep_target" ] || continue
      case "$dep_field" in depends_on|blocks) ;; *) continue ;; esac
      if ! /usr/bin/grep -q "^${dep_target}	" "$membership" 2>/dev/null; then
        printf '%s\n' "$dep_target" >> "$tmpdir/ext_refs.txt"
      fi
    done <<< "$fm_data"
  done < "$all_keys_file"

  # Batch-check unknown external references.
  if [ -s "$tmpdir/ext_refs.txt" ]; then
    while IFS= read -r ext_key; do
      [ -n "$ext_key" ] || continue
      if ! _ic_is_known_key "$ext_key" "$epics_file" "$shards_dir"; then
        _ic_die "unknown key: $ext_key"
      fi
    done < <(sort -u "$tmpdir/ext_refs.txt")
  fi

  # -------------------------------------------------------------------
  # Catch-all epic set (for rule b).
  # -------------------------------------------------------------------
  local catch_all_set=""
  if [ -f "$epics_file" ] && [ -r "$epics_file" ]; then
    catch_all_set="$(catch_all_epics "$epics_file" "$shards_dir" 2>/dev/null)" || {
      _ic_die "unable to read dependency structure"
    }
  else
    _ic_die "unable to read dependency structure"
  fi
  # Write catch-all set to a file for awk consumption.
  local catch_all_f="$tmpdir/catch_all.txt"
  printf '%s\n' "$catch_all_set" > "$catch_all_f"

  # -------------------------------------------------------------------
  # Run ALL graph analysis in a single awk program.
  # Input files: membership.tsv, adj.tsv, directed.tsv, epics.tsv,
  #              catch_all.txt
  # Output: PASS/FAIL/WARN lines on stdout; STDERR lines prefixed with
  #         "STDERR:" so the shell can route them.
  # -------------------------------------------------------------------
  # _IC_GRAPH_AWK: test seam — override the awk command for graph analysis.
  local graph_awk="${_IC_GRAPH_AWK:-awk}"
  local awk_result awk_rc
  awk_result="$($graph_awk -F'\t' \
    -v candidate="$_IC_CANDIDATE" \
    -v active_list="$active_csv" \
  '
    # ---- Phase 1: load data ----
    FILENAME == ARGV[1] {
      # membership.tsv: KEY<TAB>SPRINT
      key_sprint[$1] = $2
      all_keys[$1] = 1
      if ($2 == candidate) cand_keys[$1] = 1
      next
    }
    FILENAME == ARGV[2] {
      # adj.tsv: FROM<TAB>TO (direction-agnostic)
      adj[$1] = (adj[$1] == "" ? $2 : adj[$1] SUBSEP $2)
      next
    }
    FILENAME == ARGV[3] {
      # directed.tsv: FROM<TAB>TO (depends_on direction)
      dir_adj[$1] = (dir_adj[$1] == "" ? $2 : dir_adj[$1] SUBSEP $2)
      next
    }
    FILENAME == ARGV[4] {
      # epics.tsv: KEY<TAB>EPIC
      key_epic[$1] = $2
      next
    }
    FILENAME == ARGV[5] {
      # catch_all.txt: one epic key per line
      if ($0 != "") catch_all[$0] = 1
      next
    }

    END {
      exit_code = 0

      # ---- BFS reachability from candidate (direction-agnostic) ----
      # Seeds: all candidate-sprint keys.
      bfs_n = 0
      for (k in cand_keys) {
        bfs_queue[bfs_n++] = k
        cand_reachable[k] = 1
      }
      qi = 0
      while (qi < bfs_n) {
        node = bfs_queue[qi++]
        if (adj[node] == "") continue
        split(adj[node], nbrs, SUBSEP)
        for (i in nbrs) {
          nb = nbrs[i]
          if (nb == "") continue
          if (!(nb in all_keys)) continue
          if (nb in cand_reachable) continue
          cand_reachable[nb] = 1
          bfs_queue[bfs_n++] = nb
        }
      }

      # ---- DFS cycle detection on directed graph ----
      # 0=white, 1=gray, 2=black
      for (k in all_keys) color[k] = 0

      for (start in all_keys) {
        if (color[start] != 0) continue
        # Iterative DFS using explicit stack.
        sp = 0
        stack[sp] = start
        stack_type[sp] = "enter"
        sp++
        while (sp > 0) {
          sp--
          cur = stack[sp]
          ctype = stack_type[sp]

          if (ctype == "exit") {
            color[cur] = 2
            continue
          }

          # "enter" type
          if (color[cur] == 2) continue
          if (color[cur] == 1) {
            # Re-entered a gray node from the stack — just mark it black.
            color[cur] = 2
            continue
          }

          color[cur] = 1
          # Push exit marker.
          stack[sp] = cur
          stack_type[sp] = "exit"
          sp++

          if (dir_adj[cur] != "") {
            split(dir_adj[cur], dnbrs, SUBSEP)
            for (i in dnbrs) {
              nb = dnbrs[i]
              if (nb == "") continue
              if (!(nb in all_keys)) continue
              if (color[nb] == 1) {
                # Back edge — cycle.
                # Build cycle path.
                cycle_path = nb " -> " cur " -> " nb
                if (nb in cand_reachable) {
                  printf "FAIL indeterminate: cycle detected: %s\n", cycle_path
                  printf "STDERR:FAIL indeterminate: cycle detected: %s\n", cycle_path
                  exit 1
                } else {
                  # Unreachable cycle — warning only.
                  cyc_sprint = key_sprint[nb]
                  printf "WARN cycle (unreachable from candidate): %s (%s)\n", cycle_path, cyc_sprint
                }
              } else if (color[nb] == 0) {
                dfs_parent[nb] = cur
                stack[sp] = nb
                stack_type[sp] = "enter"
                sp++
              }
            }
          }
        }
      }

      # ---- Per-active-sprint rule evaluation ----
      n_active = split(active_list, active_arr, /,/)

      for (ai = 1; ai <= n_active; ai++) {
        act = active_arr[ai]
        rule_a_fail = 0
        rule_a_diag = ""
        rule_b_fail = 0
        rule_b_diag = ""

        # Collect active sprint keys for this comparison.
        delete act_keys
        for (k in all_keys) {
          if (key_sprint[k] == act) act_keys[k] = 1
        }

        # ---- Rule (a): BFS from each candidate story individually ----
        # Individual BFS per candidate key so the reported path is the
        # full chain from the originating candidate story.
        found_target = ""
        for (ck in cand_keys) {
          if (rule_a_fail) break
          delete bfs_v
          delete bfs_par
          delete ra_q
          bn = 0
          ra_q[bn++] = ck
          bfs_v[ck] = 1
          rqi = 0
          while (rqi < bn) {
            node = ra_q[rqi++]
            if (node != ck && (node in act_keys)) {
              rule_a_fail = 1
              found_target = node
              break
            }
            if (adj[node] == "") continue
            split(adj[node], nbrs, SUBSEP)
            for (i in nbrs) {
              nb = nbrs[i]
              if (nb == "") continue
              if (!(nb in all_keys)) continue
              if (nb in bfs_v) continue
              bfs_v[nb] = 1
              bfs_par[nb] = node
              ra_q[bn++] = nb
            }
          }
        }

        if (rule_a_fail && found_target != "") {
          # Build path by tracing parents.
          path = found_target
          trace = found_target
          while (trace in bfs_par) {
            path = bfs_par[trace] " -> " path
            trace = bfs_par[trace]
          }
          rule_a_diag = "FAIL rule (a): " path " (" candidate " -> " act ")"
        }

        # ---- Rule (b): Epic-set intersection ----
        delete cand_epics
        delete act_epics
        for (k in cand_keys) {
          e = key_epic[k]
          if (e != "") cand_epics[e] = 1
        }
        for (k in act_keys) {
          e = key_epic[k]
          if (e != "") act_epics[e] = 1
        }

        shared = ""
        exempted = ""
        for (e in cand_epics) {
          if (e in act_epics) {
            if (e in catch_all) {
              exempted = (exempted == "" ? e : exempted ", " e)
            } else {
              shared = (shared == "" ? e : shared ", " e)
            }
          }
        }

        if (shared != "") {
          rule_b_fail = 1
          rule_b_diag = "FAIL rule (b): shared epic " shared " between " candidate " and " act
          if (exempted != "") {
            rule_b_diag = rule_b_diag "; exempted catch-all: " exempted
          }
        }

        # ---- Emit results ----
        if (rule_a_fail) {
          printf "%s\n", rule_a_diag
          printf "STDERR:%s\n", rule_a_diag
          exit_code = 1
        }
        if (rule_b_fail) {
          printf "%s\n", rule_b_diag
          printf "STDERR:%s\n", rule_b_diag
          exit_code = 1
        }
        if (!rule_a_fail && !rule_b_fail) {
          printf "PASS rules (a),(b): %s vs %s\n", candidate, act
        }
      }

      exit exit_code
    }
  ' "$membership" "$adj_f" "$directed_f" "$epics_f" "$catch_all_f" \
    2>/dev/null)" && awk_rc=0 || awk_rc=$?

  # If awk crashed or exited non-zero without emitting STDERR: markers,
  # fail closed — never silently pass on an internal error.
  if [ "$awk_rc" -ne 0 ]; then
    case "$awk_result" in
      *"STDERR:"*) ;; # awk signalled a rule failure — handled below
      *)
        _ic_die "unable to read dependency structure"
        ;;
    esac
  fi

  # Route awk output: lines starting with "STDERR:" go to stderr (without prefix),
  # all other lines go to stdout.
  local line
  while IFS= read -r line; do
    case "$line" in
      STDERR:*)
        printf '%s\n' "${line#STDERR:}" >&2
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done <<< "$awk_result"

  exit "$awk_rc"
}

# Run main only when executed as a script (not sourced).
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]}" = "${0##*/}" ]; then
  main "$@"
fi
