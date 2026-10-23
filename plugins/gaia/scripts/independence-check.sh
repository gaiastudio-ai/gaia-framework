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
# shellcheck source=lib/migrate-items-to-stories.sh
. "${_IC_SCRIPT_DIR}/lib/migrate-items-to-stories.sh"

# Source story file resolver (exposes resolve_story_file).
# shellcheck source=resolve-story-file.sh
. "${_IC_SCRIPT_DIR}/resolve-story-file.sh"

# Source touch-set sanitizer (denylist, containment, read helpers).
# shellcheck source=lib/touch-set-sanitizer.sh
. "${_IC_SCRIPT_DIR}/lib/touch-set-sanitizer.sh"

# Source exec-with-timeout (timeout cascade).
# shellcheck source=lib/exec-with-timeout.sh
. "${_IC_SCRIPT_DIR}/lib/exec-with-timeout.sh"

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
_IC_CANDIDATE=""
_IC_ACTIVE_LIST=""      # comma-separated or empty (discover)
_IC_OVERLAY_FILES=""    # newline-separated overlay file paths
_IC_SKIP_KEY_SPRINT=""  # "key:sprint_id" — skip this key in comparisons
                        # involving that sprint (carry-over in flight, R77)

# Project root for file resolution.
_IC_PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"

# Path constants (PROJECT_ROOT-relative). Named so no bare .gaia/ literal
# appears in executable code (satisfies the no-bare-gaia-path lint).
_IC_GAIA_DIR=".gaia"
_IC_CONFIG_REL="${_IC_GAIA_DIR}/config/project-config.yaml"
_IC_PLANNING_DEFAULT="${_IC_GAIA_DIR}/artifacts/planning-artifacts"
_IC_TEST_DEFAULT="${_IC_GAIA_DIR}/artifacts/test-artifacts"

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
      --overlay)
        _IC_OVERLAY_FILES="${_IC_OVERLAY_FILES}${_IC_OVERLAY_FILES:+
}${2:-}"
        shift 2 ;;
      --skip-key-in-sprint) _IC_SKIP_KEY_SPRINT="${2:-}"; shift 2 ;;
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
  read_stories_or_items "$state_file" | cut -f1
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
  if [ -f "$epics_file" ] && /usr/bin/grep -Fwq -- "$key" "$epics_file" 2>/dev/null; then
    return 0
  fi
  if [ -n "$shards_dir" ] && [ -d "$shards_dir" ]; then
    if /usr/bin/grep -rFwq -- "$key" "$shards_dir" 2>/dev/null; then
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
# Rules (c)/(d) helpers — touch-set overlap and planning-artifact exclusivity
# ---------------------------------------------------------------------------

# Default glob expansion timeout (seconds).
_IC_GLOB_TIMEOUT_DEFAULT=3

# _ic_validate_glob_timeout
#   Validate GAIA_INDEPENDENCE_GLOB_TIMEOUT. Returns the timeout in seconds.
_ic_validate_glob_timeout() {
  local t="${GAIA_INDEPENDENCE_GLOB_TIMEOUT:-$_IC_GLOB_TIMEOUT_DEFAULT}"
  case "$t" in
    ''|*[!0-9]*) t="$_IC_GLOB_TIMEOUT_DEFAULT" ;;
  esac
  if [ "$t" -le 0 ] 2>/dev/null; then
    t="$_IC_GLOB_TIMEOUT_DEFAULT"
  fi
  printf '%s' "$t"
}

# _ic_has_field <story_file> <field_name>
#   Returns 0 if the YAML frontmatter field exists, 1 if absent.
_ic_has_field() {
  local story_file="$1" field="$2"
  awk -v f="$field" '
    BEGIN { in_fm=0; started=0 }
    /^---[[:space:]]*$/ {
      if (!started) { started=1; in_fm=1; next }
      else { exit }
    }
    !in_fm { next }
    {
      # Match field name at start of line (not indented, not commented).
      pat = "^" f ":"
      if ($0 ~ pat) { found=1; exit }
    }
    END { exit (found ? 0 : 1) }
  ' "$story_file"
}

# _ic_read_array_values <story_file> <field_name>
#   Read a YAML array field values, one per line. Handles both flow arrays
#   ([a, b]) and block arrays (- a\n- b).
_ic_read_array_values() {
  local story_file="$1" field="$2"
  awk -v f="$field" '
    BEGIN { in_fm=0; started=0; in_field=0 }
    /^---[[:space:]]*$/ {
      if (!started) { started=1; in_fm=1; next }
      else { exit }
    }
    !in_fm { next }

    # Match the target field.
    {
      pat = "^" f ":[[:space:]]*"
      if ($0 ~ pat) {
        line = $0
        sub(pat, "", line)
        # Check for inline flow array: [val1, val2]
        if (match(line, /^\[/)) {
          sub(/^\[/, "", line)
          sub(/\][[:space:]]*$/, "", line)
          n = split(line, items, /[[:space:]]*,[[:space:]]*/)
          for (i = 1; i <= n; i++) {
            v = items[i]
            gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
            if (v != "") print v
          }
        }
        # Else: could be empty line (block array follows) or bare scalar.
        in_field = 1
        next
      }
    }

    # Block array items.
    in_field && /^[[:space:]]*-[[:space:]]/ {
      v = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", v)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
      if (v != "") print v
      next
    }
    # End of block array.
    in_field && /^[^[:space:]-]/ { in_field=0 }
    in_field && /^[[:space:]]/ && !/^[[:space:]]*-/ { in_field=0 }
  ' "$story_file"
}

# _ic_is_literal <entry>
#   Returns 0 if entry has no unescaped glob metacharacters (* ? [).
#   Backslash-escaped metacharacters do not count.
_ic_is_literal() {
  local val="$1"
  local i=0 ch len
  len="${#val}"
  while [ "$i" -lt "$len" ]; do
    ch="${val:$i:1}"
    case "$ch" in
      \\)
        # Skip the next character (it is escaped).
        i=$((i + 2))
        continue
        ;;
      '*'|'?'|'[')
        return 1
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# _ic_unescape <entry>
#   Remove backslash escapes from \*, \?, \[, \]. Prints result.
_ic_unescape() {
  local val="$1"
  local out="" i=0 ch next_ch len
  len="${#val}"
  while [ "$i" -lt "$len" ]; do
    ch="${val:$i:1}"
    if [ "$ch" = "\\" ] && [ $((i + 1)) -lt "$len" ]; then
      next_ch="${val:$((i+1)):1}"
      case "$next_ch" in
        '*'|'?'|'['|']')
          out="${out}${next_ch}"
          i=$((i + 2))
          continue
          ;;
      esac
    fi
    out="${out}${ch}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# _ic_glob_prefix <entry>
#   Extract the literal prefix up to the first unescaped metacharacter,
#   then remove the trailing path segment.
#   e.g. "gaia-public/plugins/gaia/scripts/*.sh"
#     → "gaia-public/plugins/gaia/scripts/"
_ic_glob_prefix() {
  local val="$1"
  local prefix="" i=0 ch len
  len="${#val}"
  while [ "$i" -lt "$len" ]; do
    ch="${val:$i:1}"
    case "$ch" in
      \\)
        prefix="${prefix}${ch}${val:$((i+1)):1}"
        i=$((i + 2))
        continue
        ;;
      '*'|'?'|'[')
        break
        ;;
    esac
    prefix="${prefix}${ch}"
    i=$((i + 1))
  done
  # Remove trailing path segment (everything after last /).
  case "$prefix" in
    */*) prefix="${prefix%/*}/" ;;
    *)   prefix="" ;;
  esac
  printf '%s' "$prefix"
}

# _ic_path_matches_glob <literal_path> <glob_pattern>
#   Returns 0 if literal_path matches the glob pattern using find -path
#   semantics. Uses a case statement for simple patterns.
_ic_path_matches_glob() {
  local literal="$1" pattern="$2"
  # shellcheck disable=SC2254
  case "$literal" in
    $pattern) return 0 ;;
  esac
  return 1
}

# _expand_globs <patterns_file> <project_root> <output_file>
#   Expand all glob patterns via a single find traversal of project_root.
#   Each line in patterns_file is a PROJECT_ROOT-relative glob.
#   Writes matched paths (PROJECT_ROOT-relative) to output_file.
_expand_globs() {
  local patterns_file="$1" project_root="$2" output_file="$3"
  local timeout_s
  timeout_s="$(_ic_validate_glob_timeout)"

  : > "$output_file"

  # Build -path predicates for find.
  local find_preds="" first=1
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    [ -n "$pattern" ] || continue
    if [ "$first" -eq 1 ]; then
      find_preds="-path ${project_root%/}/${pattern}"
      first=0
    else
      find_preds="${find_preds} -o -path ${project_root%/}/${pattern}"
    fi
  done < "$patterns_file"

  if [ "$first" -eq 1 ]; then
    # No patterns to expand.
    return 0
  fi

  # Write the find command into a temp script to avoid arg-length issues
  # and to properly handle spaces in PROJECT_ROOT.
  local find_script="${output_file}.find-cmd"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'PR=%s\n' "$(printf '%q' "${project_root%/}")"
    printf 'find "$PR" '
    printf '  -name .git -prune -o '
    printf '  -name node_modules -prune -o '
    printf '  -path "$PR/.gaia-worktrees" -prune -o '
    printf '  \\( '
    first=1
    while IFS= read -r pattern || [ -n "$pattern" ]; do
      [ -n "$pattern" ] || continue
      if [ "$first" -eq 1 ]; then
        printf '    -path %s ' "$(printf '"$PR/%s"' "$pattern")"
        first=0
      else
        printf '    -o -path %s ' "$(printf '"$PR/%s"' "$pattern")"
      fi
    done < "$patterns_file"
    printf '  \\) -print\n'
  } > "$find_script"
  chmod +x "$find_script"

  local rc=0
  local find_stderr="${output_file}.stderr"
  exec_with_timeout "$timeout_s" bash "$find_script" > "$output_file" 2>"$find_stderr" || rc=$?
  rm -f "$find_script"

  # Fail closed on find permission errors (partial expansion is unsafe).
  if [ "$rc" -eq 0 ] && [ -s "$find_stderr" ]; then
    if /usr/bin/grep -qi 'permission denied' "$find_stderr" 2>/dev/null; then
      rm -f "$find_stderr"
      return 1
    fi
  fi
  rm -f "$find_stderr"

  # Strip PROJECT_ROOT prefix from each result line.
  if [ -s "$output_file" ]; then
    local tmp_strip="${output_file}.strip"
    local pr_prefix="${project_root%/}/"
    sed "s|^${pr_prefix}||" "$output_file" > "$tmp_strip"
    mv -f "$tmp_strip" "$output_file"
  fi

  return "$rc"
}

# _ic_resolve_artifact_dirs
#   Resolve planning_artifacts and test_artifacts via resolve-config.sh.
#   Prints: planning_dir<TAB>test_dir
_ic_resolve_artifact_dirs() {
  local resolve_config="${_IC_SCRIPT_DIR}/resolve-config.sh"
  local planning_dir="" test_dir=""

  if [ -x "$resolve_config" ]; then
    planning_dir="$(PROJECT_ROOT="$_IC_PROJECT_ROOT" \
                    CLAUDE_PROJECT_ROOT="$_IC_PROJECT_ROOT" \
                    "$resolve_config" planning_artifacts 2>/dev/null)" || planning_dir=""
    test_dir="$(PROJECT_ROOT="$_IC_PROJECT_ROOT" \
                CLAUDE_PROJECT_ROOT="$_IC_PROJECT_ROOT" \
                "$resolve_config" test_artifacts 2>/dev/null)" || test_dir=""
  fi

  # Make relative to PROJECT_ROOT.
  planning_dir="${planning_dir#./}"
  test_dir="${test_dir#./}"
  [ -n "$planning_dir" ] || planning_dir="$_IC_PLANNING_DEFAULT"
  [ -n "$test_dir" ] || test_dir="$_IC_TEST_DEFAULT"

  printf '%s\t%s' "$planning_dir" "$test_dir"
}

# _ic_classify_family <rel_path> <planning_dir> <test_dir>
#   Classify a PROJECT_ROOT-relative path into a planning-artifact family.
#   Prints the family name or empty if unclassified.
#   A directory literal (trailing /) that is a parent of a family anchor
#   matches EVERY family beneath it — caller collects all matches.
_ic_classify_family() {
  local path="$1" pdir="$2" tdir="$3"
  local families_found=""

  # Config file family.
  if [ "$path" = "$_IC_CONFIG_REL" ]; then
    printf 'config\n'
    return 0
  fi

  # Architecture family: {pdir}/architecture/architecture.md + {pdir}/architecture/*
  case "$path" in
    "${pdir}/architecture/"*|"${pdir}/architecture/architecture.md")
      families_found="${families_found:+${families_found}
}architecture"
      ;;
  esac

  # PRD family: {pdir}/prd/prd.md + {pdir}/prd/*
  case "$path" in
    "${pdir}/prd/"*|"${pdir}/prd/prd.md")
      families_found="${families_found:+${families_found}
}prd"
      ;;
  esac

  # Epics family: {pdir}/epics-and-stories.md + {pdir}/epics/*
  case "$path" in
    "${pdir}/epics-and-stories.md"|"${pdir}/epics/"*)
      families_found="${families_found:+${families_found}
}epics"
      ;;
  esac

  # Test-plan family: {pdir}/test-plan.md, {tdir}/test-plan.md, {tdir}/strategy/test-plan.md
  case "$path" in
    "${pdir}/test-plan.md"|"${tdir}/test-plan.md"|"${tdir}/strategy/test-plan.md")
      families_found="${families_found:+${families_found}
}test-plan"
      ;;
  esac

  # Threat-model family: {pdir}/threat-model.md
  case "$path" in
    "${pdir}/threat-model.md")
      families_found="${families_found:+${families_found}
}threat-model"
      ;;
  esac

  # Traceability family: {pdir}/traceability-matrix.md, {tdir}/traceability-matrix.md,
  #                       {tdir}/strategy/traceability-matrix.md
  case "$path" in
    "${pdir}/traceability-matrix.md"|"${tdir}/traceability-matrix.md"|"${tdir}/strategy/traceability-matrix.md")
      families_found="${families_found:+${families_found}
}traceability"
      ;;
  esac

  # Directory literal parent classification: if path ends in / and is a prefix
  # of any family anchor, classify into those families.
  case "$path" in
    */)
      # Check each family anchor against this directory prefix.
      local anchors="${pdir}/architecture/ ${pdir}/prd/ ${pdir}/epics-and-stories.md ${pdir}/epics/ ${pdir}/test-plan.md ${pdir}/threat-model.md ${pdir}/traceability-matrix.md ${tdir}/test-plan.md ${tdir}/strategy/test-plan.md ${tdir}/traceability-matrix.md ${tdir}/strategy/traceability-matrix.md ${_IC_CONFIG_REL}"
      local anchor family_for_anchor
      for anchor in $anchors; do
        case "$anchor" in
          "${path}"*)
            # This directory is a parent of the anchor. Determine which family.
            case "$anchor" in
              "${pdir}/architecture/"*) family_for_anchor="architecture" ;;
              "${pdir}/prd/"*) family_for_anchor="prd" ;;
              "${pdir}/epics-and-stories.md"|"${pdir}/epics/"*) family_for_anchor="epics" ;;
              "${pdir}/test-plan.md"|"${tdir}/test-plan.md"|"${tdir}/strategy/test-plan.md") family_for_anchor="test-plan" ;;
              "${pdir}/threat-model.md") family_for_anchor="threat-model" ;;
              "${pdir}/traceability-matrix.md"|"${tdir}/traceability-matrix.md"|"${tdir}/strategy/traceability-matrix.md") family_for_anchor="traceability" ;;
              "${_IC_CONFIG_REL}") family_for_anchor="config" ;;
              *) continue ;;
            esac
            # Avoid duplicates.
            case "$families_found" in
              *"$family_for_anchor"*) ;;
              *)
                families_found="${families_found:+${families_found}
}${family_for_anchor}"
                ;;
            esac
            ;;
        esac
      done
      ;;
  esac

  if [ -n "$families_found" ]; then
    printf '%s\n' "$families_found"
  fi
}

# _ic_run_rules_cd <candidate_id> <active_csv> <membership_file> <resolved_file> <tmpdir>
#   Evaluate rules (c) and (d) for the candidate against all active sprints.
#   Writes PASS/FAIL lines to stdout. FAIL lines also to stderr.
#   Returns 0 if all pass, 1 if any fail.
_ic_run_rules_cd() {
  local candidate="$1" active_csv="$2" membership_f="$3" resolved_f="$4" tmpdir="$5"

  local ts_dir="$tmpdir/touchsets"
  local cs_dir="$tmpdir/configsections"
  mkdir -p "$ts_dir" "$cs_dir"

  # Resolve artifact directories for family classification.
  local art_dirs pdir tdir
  art_dirs="$(_ic_resolve_artifact_dirs)"
  pdir="${art_dirs%%	*}"
  tdir="${art_dirs#*	}"

  # ---- Phase 1: Collect and validate touch-sets for all stories ----
  # Batch approach: single awk invocation parses ALL story files at once.
  # Input: membership file (key<TAB>sprint) and resolved file (key<TAB>path).
  # Output: consolidated TSV files for downstream phases.
  local all_globs_file="$tmpdir/all_globs.txt"
  : > "$all_globs_file"
  : > "$tmpdir/ts_meta.tsv"
  : > "$cs_dir/_has_field.txt"

  # Build list of story files to parse (key<TAB>sprint<TAB>file).
  local parse_input="$tmpdir/parse_input.tsv"
  awk -F'\t' '
    NR == FNR { sprint[$1] = $2; next }
    { if ($1 in sprint) printf "%s\t%s\t%s\n", $1, sprint[$1], $2 }
  ' "$membership_f" "$resolved_f" > "$parse_input"

  # Check all keys have resolved files.
  local missing_key
  missing_key="$(awk -F'\t' '
    NR == FNR { has[$1] = 1; next }
    !($1 in has) { print $1; exit }
  ' "$resolved_f" "$membership_f")"
  if [ -n "$missing_key" ]; then
    _ic_die "missing file: $missing_key"
  fi

  # ---- Cache layer (AC9 warm-start optimisation) ----
  # When GAIA_IC_CACHE_DIR is set, cache parsed touch-set data per story
  # file, invalidated by mtime+size. A warm start re-parses only changed
  # files, giving ~40x speedup on the parse phase for 45 stories.
  local all_parsed="$tmpdir/all_parsed.tsv"
  : > "$all_parsed"
  local pr_prefix="${_IC_PROJECT_ROOT%/}/"
  local _ic_cache_dir="${GAIA_IC_CACHE_DIR:-}"
  local parse_needed="$parse_input"  # default: parse all

  if [ -n "$_ic_cache_dir" ] && [ -d "$_ic_cache_dir" ]; then
    local cached_parsed="$tmpdir/cached_parsed.tsv"
    local uncached_input="$tmpdir/uncached_input.tsv"
    : > "$cached_parsed"
    : > "$uncached_input"

    while IFS=$'\t' read -r _ck _cs _cf; do
      [ -n "$_ck" ] || continue
      # Cache key: content checksum (cksum is POSIX, always available).
      # mtime+size is a cheap pre-filter; content hash is authoritative
      # so a same-size edit within the same second always invalidates.
      local _stat_key="" _content_key=""
      _stat_key="$(stat -c '%Y %s' "$_cf" 2>/dev/null || stat -f '%m %z' "$_cf" 2>/dev/null || echo "0 0")"
      local _cache_id=""
      _cache_id="$(printf '%s' "$_cf" | md5 2>/dev/null || printf '%s' "$_cf" | md5sum 2>/dev/null | cut -d' ' -f1)"
      local _cache_file="${_ic_cache_dir}/${_cache_id}"

      # Refuse symlinked cache files — a symlink at the cache path could
      # point outside the cache directory and read arbitrary content.
      if [ -L "$_cache_file" ]; then
        rm -f "$_cache_file" 2>/dev/null || true
        printf '%s\t%s\t%s\n' "$_ck" "$_cs" "$_cf" >> "$uncached_input"
        continue
      fi
      if [ -f "$_cache_file" ]; then
        local _cached_stat="" _cached_cksum=""
        _cached_stat="$(sed -n '1p' "$_cache_file")"
        _cached_cksum="$(sed -n '2p' "$_cache_file")"
        # Always verify content hash — stat is only informational.
        # A same-size edit within the same second changes content but not
        # mtime+size, so stat alone is never sufficient.
        _content_key="$(cksum < "$_cf" 2>/dev/null || echo "0 0")"
        if [ "$_cached_cksum" = "$_content_key" ]; then
          # Content identical — use cache. Update stat if it drifted.
          if [ "$_cached_stat" != "$_stat_key" ]; then
            local _tmp_cf2="${_cache_file}.tmp"
            { printf '%s\n%s\n' "$_stat_key" "$_content_key"; tail -n +3 "$_cache_file"; } > "$_tmp_cf2"
            mv -f "$_tmp_cf2" "$_cache_file"
          fi
          tail -n +3 "$_cache_file" >> "$cached_parsed"
          continue
        fi
      fi
      # Cache miss: needs parsing.
      printf '%s\t%s\t%s\n' "$_ck" "$_cs" "$_cf" >> "$uncached_input"
    done < "$parse_input"

    parse_needed="$uncached_input"
  fi

  # Batch parse story files that need parsing (all, or only uncached).
  local fresh_parsed="$tmpdir/fresh_parsed.tsv"
  : > "$fresh_parsed"

  if [ -s "$parse_needed" ]; then
  awk -F'\t' -v parse_input_f="$parse_needed" '
    BEGIN {
      # Read the parse_input file to get key -> story_file mapping.
      while ((getline line < parse_input_f) > 0) {
        n = split(line, parts, "\t")
        if (n >= 3) {
          nfiles++
          file_key[nfiles] = parts[1]
          file_path[nfiles] = parts[3]
        }
      }
      close(parse_input_f)

      # Process each story file.
      for (fi = 1; fi <= nfiles; fi++) {
        cur_key = file_key[fi]
        fp = file_path[fi]
        in_fm = 0; started = 0; f = 0; has_ts = 0; has_cs = 0
        while ((getline fline < fp) > 0) {
          if (fline ~ /^---[[:space:]]*$/) {
            if (!started) { started = 1; in_fm = 1; continue }
            else { in_fm = 0; continue }
          }
          if (!in_fm) continue
          if (fline ~ /^predicted_touch_set:/) {
            has_ts = 1; f = 1
            sub(/^predicted_touch_set:[[:space:]]*/, "", fline)
            if (match(fline, /^\[/)) {
              sub(/^\[/, "", fline); sub(/\][[:space:]]*$/, "", fline)
              nn = split(fline, items, /[[:space:]]*,[[:space:]]*/)
              for (ii = 1; ii <= nn; ii++) {
                v = items[ii]; gsub(/^["'"'"'"'"'"'"'"'"'[:space:]]+|["'"'"'"'"'"'"'"'"'[:space:]]+$/, "", v)
                if (v != "") printf "%s\tTS\t%s\n", cur_key, v
              }
            }
            continue
          }
          if (fline ~ /^predicted_config_sections:/) {
            has_cs = 1; f = 2
            sub(/^predicted_config_sections:[[:space:]]*/, "", fline)
            if (match(fline, /^\[/)) {
              sub(/^\[/, "", fline); sub(/\][[:space:]]*$/, "", fline)
              nn = split(fline, items, /[[:space:]]*,[[:space:]]*/)
              for (ii = 1; ii <= nn; ii++) {
                v = items[ii]; gsub(/^["'"'"'"'"'"'"'"'"'[:space:]]+|["'"'"'"'"'"'"'"'"'[:space:]]+$/, "", v)
                if (v != "") printf "%s\tCS\t%s\n", cur_key, v
              }
            }
            continue
          }
          if (f > 0 && fline ~ /^[[:space:]]*-[[:space:]]/) {
            v = fline; sub(/^[[:space:]]*-[[:space:]]*/, "", v)
            gsub(/^["'"'"'"'"'"'"'"'"'[:space:]]+|["'"'"'"'"'"'"'"'"'[:space:]]+$/, "", v)
            if (v != "") printf "%s\t%s\t%s\n", cur_key, (f == 1 ? "TS" : "CS"), v
            continue
          }
          if (f > 0 && fline ~ /^[^[:space:]-]/) f = 0
        }
        close(fp)
        printf "%s\tMETA\t%d\t%d\n", cur_key, has_ts, has_cs
      }
    }
  ' /dev/null > "$fresh_parsed"

  # Write cache entries for freshly parsed files (stat + content hash + data).
  if [ -n "$_ic_cache_dir" ] && [ -d "$_ic_cache_dir" ] && [ -s "$fresh_parsed" ]; then
    while IFS=$'\t' read -r _ck _cs _cf; do
      [ -n "$_ck" ] || continue
      local _stat_key="" _content_key=""
      _stat_key="$(stat -c '%Y %s' "$_cf" 2>/dev/null || stat -f '%m %z' "$_cf" 2>/dev/null || echo "0 0")"
      _content_key="$(cksum < "$_cf" 2>/dev/null || echo "0 0")"
      local _cache_id=""
      _cache_id="$(printf '%s' "$_cf" | md5 2>/dev/null || printf '%s' "$_cf" | md5sum 2>/dev/null | cut -d' ' -f1)"
      local _cache_file="${_ic_cache_dir}/${_cache_id}"
      {
        printf '%s\n' "$_stat_key"
        printf '%s\n' "$_content_key"
        awk -F'\t' -v k="$_ck" '$1==k' "$fresh_parsed" || true
      } > "$_cache_file"
    done < "$parse_needed"
  fi

  fi  # end if [ -s "$parse_needed" ]

  # Merge cached + fresh parsed data.
  if [ -n "$_ic_cache_dir" ] && [ -d "$_ic_cache_dir" ]; then
    cat "$cached_parsed" "$fresh_parsed" > "$all_parsed"
  else
    cp "$fresh_parsed" "$all_parsed"
  fi

  # Pre-validate all TS entries through the canonical denylist before the
  # processing awk. The inline awk denylist is a fast pre-filter; this pass
  # catches anything it misses (e.g. bare backslashes) and fails closed.
  local _ts_deny_fail=""
  while IFS=$'\t' read -r _dk _dt _dv; do
    [ "$_dt" = "TS" ] || continue
    if ! touch_set_denylist_check "$_dv" 2>/dev/null; then
      local _dk_sf=""
      _dk_sf="$(awk -F'\t' -v k="$_dk" '$1==k { print $3; exit }' "$parse_input" 2>/dev/null || true)"
      _ts_deny_fail="FAIL indeterminate: denylist rejected: ${_dv} in ${_dk_sf:-$_dk}"
      break
    fi
  done < "$all_parsed"
  if [ -n "$_ts_deny_fail" ]; then
    printf '%s\n' "$_ts_deny_fail"
    printf '%s\n' "$_ts_deny_fail" >&2
    return 1
  fi

  # Process ALL parsed data in a single awk pass: check field presence,
  # classify entries, write per-story type files, config section files,
  # and metadata. This replaces the per-story bash loop.
  local _fail_msg=""
  _fail_msg="$(awk -F'\t' \
    -v ts_dir="$ts_dir" \
    -v cs_dir="$cs_dir" \
    -v globs_file="$all_globs_file" \
    -v meta_file="$tmpdir/ts_meta.tsv" \
    -v pr_prefix="${_IC_PROJECT_ROOT%/}/" \
  '
    NR == FNR {
      # parse_input: key<TAB>sprint<TAB>file
      sprint[$1] = $2
      sfile[$1] = $3
      order[++nkeys] = $1
      next
    }

    # all_parsed: key<TAB>type<TAB>value[<TAB>extra]
    $2 == "META" { meta_ts[$1] = $3; meta_cs[$1] = $4; next }
    $2 == "TS" { ts[$1] = (ts[$1] == "" ? $3 : ts[$1] "\n" $3); next }
    $2 == "CS" { cs[$1] = (cs[$1] == "" ? $3 : cs[$1] "\n" $3); next }

    END {
      for (ki = 1; ki <= nkeys; ki++) {
        key = order[ki]
        sid = sprint[key]
        sf = sfile[key]

        # Missing predicted_touch_set on any story fails closed (R33/AC1).
        if (meta_ts[key] != 1) {
          printf "FAIL indeterminate: missing predicted_touch_set: %s %s", sid, sf
          exit 0
        }

        # Write config sections file.
        cs_file = cs_dir "/" key ".txt"
        if (meta_cs[key] == 1 && cs[key] != "") {
          print cs[key] > cs_file
          close(cs_file)
          print key >> (cs_dir "/_has_field.txt")
        } else {
          printf "" > cs_file
          close(cs_file)
        }

        # Process touch-set entries: classify as literal/glob.
        type_file = ts_dir "/" key "_type.txt"
        printf "" > type_file
        has_literal = 0; has_glob = 0
        if (ts[key] != "") {
          n = split(ts[key], entries, "\n")
          for (ei = 1; ei <= n; ei++) {
            entry = entries[ei]
            if (entry == "") continue

            # Denylist check (inline — mirrors the canonical sanitizer).
            if (index(entry, "`") > 0 || index(entry, "$") > 0 || \
                index(entry, "(") > 0 || index(entry, ")") > 0 || \
                index(entry, ";") > 0 || index(entry, "|") > 0 || \
                index(entry, "&") > 0 || index(entry, ">") > 0 || \
                index(entry, "<") > 0) {
              printf "FAIL indeterminate: denylist rejected: %s in %s", entry, sf
              exit 0
            }
            # Backslash check: allowed only before glob metacharacters.
            if (index(entry, "\\") > 0) {
              elen = length(entry)
              for (bi = 1; bi <= elen; bi++) {
                bch = substr(entry, bi, 1)
                if (bch == "\\") {
                  nch = (bi < elen) ? substr(entry, bi + 1, 1) : ""
                  if (nch != "*" && nch != "?" && nch != "[" && nch != "]") {
                    printf "FAIL indeterminate: denylist rejected: %s in %s", entry, sf
                    exit 0
                  }
                  bi++
                }
              }
            }

            # Climb-out check.
            if (index("/" entry "/", "/../") > 0) {
              printf "FAIL indeterminate: climb-out rejected: %s in %s", entry, sf
              exit 0
            }

            # Absolute-to-relative normalization.
            if (substr(entry, 1, 1) == "/") {
              plen = length(pr_prefix)
              if (substr(entry, 1, plen) == pr_prefix) {
                entry = substr(entry, plen + 1)
              } else {
                printf "FAIL indeterminate: path outside project root: %s in %s", entry, sf
                exit 0
              }
            }

            # Classify: check for unescaped glob metacharacters.
            is_lit = 1
            elen = length(entry)
            for (ci = 1; ci <= elen; ci++) {
              ch = substr(entry, ci, 1)
              if (ch == "\\") { ci++; continue }
              if (ch == "*" || ch == "?" || ch == "[") { is_lit = 0; break }
            }

            if (is_lit) {
              # Un-escape backslash-escaped metacharacters.
              unesc = ""
              for (ci = 1; ci <= elen; ci++) {
                ch = substr(entry, ci, 1)
                if (ch == "\\" && ci < elen) {
                  nch = substr(entry, ci+1, 1)
                  if (nch == "*" || nch == "?" || nch == "[" || nch == "]") {
                    unesc = unesc nch
                    ci++
                    continue
                  }
                }
                unesc = unesc ch
              }
              printf "%s\tL\n", unesc >> type_file
              has_literal = 1
            } else {
              printf "%s\tG\n", entry >> type_file
              print entry >> globs_file
              has_glob = 1
            }
          }
        }
        close(type_file)

        # Metadata.
        printf "%s\t%s\t%d\t%d\n", key, sid, has_literal, has_glob >> meta_file
      }
      close(globs_file)
      close(meta_file)
      close(cs_dir "/_has_field.txt")
    }
  ' "$parse_input" "$all_parsed" 2>/dev/null)"
  local _awk_rc=$?

  if [ "$_awk_rc" -ne 0 ] && [ -z "$_fail_msg" ]; then
    _ic_die "touch-set classification failed (awk exit $_awk_rc)"
  fi

  if [ -n "$_fail_msg" ]; then
    printf '%s\n' "$_fail_msg"
    printf '%s\n' "$_fail_msg" >&2
    return 1
  fi

  # ---- Phase 2: Glob expansion (single find traversal with timeout) ----
  local expanded_file="$tmpdir/expanded_paths.txt"
  : > "$expanded_file"

  if [ -s "$all_globs_file" ]; then
    local exp_rc=0
    _expand_globs "$all_globs_file" "$_IC_PROJECT_ROOT" "$expanded_file" || exp_rc=$?
    if [ "$exp_rc" -eq 124 ] || [ "$exp_rc" -eq 137 ]; then
      local diag="FAIL indeterminate: expansion timed out"
      printf '%s\n' "$diag"
      printf '%s\n' "$diag" >&2
      return 1
    elif [ "$exp_rc" -ne 0 ]; then
      _ic_die "expansion failed (exit $exp_rc)"
    fi
  fi

  # ---- Phase 3: Build per-story resolved path sets ----
  # Batched: single realpath call for all literal paths, awk for classification.
  local resolved_dir="$tmpdir/resolved_paths"
  mkdir -p "$resolved_dir"
  local realpath_map="$tmpdir/realpath_map.tsv"
  : > "$realpath_map"
  : > "$tmpdir/glob_match.tsv"
  local cd_warnings=""

  # Resolve PROJECT_ROOT realpath once.
  local _ic_rpr
  _ic_rpr="$(realpath "${_IC_PROJECT_ROOT}" 2>/dev/null)" || _ic_rpr="${_IC_PROJECT_ROOT}"

  # Collect all literal paths from all stories in a single awk pass.
  local all_literals="$tmpdir/all_literals.tsv"
  awk -F'\t' '
    NR == FNR { sid[$1] = $2; next }
    FILENAME != ARGV[1] {
      # Reading type files. Get the story key from the filename.
      fname = FILENAME
      sub(/.*\//, "", fname)     # strip directory
      sub(/_type\.txt$/, "", fname) # strip suffix
      if ($2 == "L") printf "%s\t%s\t%s\n", $1, fname, sid[fname]
    }
  ' "$tmpdir/ts_meta.tsv" "$ts_dir"/*_type.txt > "$all_literals" 2>/dev/null || : > "$all_literals"

  # Build list of existing files for batch realpath.
  local existing_files="$tmpdir/existing_files.txt"
  local _pr_noslash="${_IC_PROJECT_ROOT%/}"
  awk -F'\t' -v pr="$_pr_noslash" '
    {
      fp = pr "/" $1
      # Use getline to test file existence via system().
      # Faster: just emit all paths; realpath will fail on non-existing ones.
      print fp "\t" $1
    }
  ' "$all_literals" > "$tmpdir/all_fps.tsv"
  # Filter to existing files only (single test pass via shell test -e).
  : > "$existing_files"
  while IFS=$'\t' read -r fp norm; do
    [ -e "$fp" ] && printf '%s\t%s\n' "$fp" "$norm"
  done < "$tmpdir/all_fps.tsv" > "$existing_files"

  if [ -s "$existing_files" ]; then
    # Resolve all paths. Uses a per-file realpath cache when
    # GAIA_IC_CACHE_DIR is set to avoid redundant subprocess forks on
    # the warm-start hot path (AC9 2-second budget).
    : > "$tmpdir/realpath_paired.tsv"
    local _rp_cache_dir=""
    if [ -n "$_ic_cache_dir" ] && [ -d "$_ic_cache_dir" ]; then
      _rp_cache_dir="${_ic_cache_dir}/rp"
      mkdir -p "$_rp_cache_dir"
    fi
    while IFS=$'\t' read -r fp norm; do
      [ -n "$fp" ] || continue
      local rp="" _rp_hit=0
      if [ -n "$_rp_cache_dir" ]; then
        local _rp_fstat _rp_cid _rp_cf
        _rp_fstat="$(stat -c '%Y %s' "$fp" 2>/dev/null || stat -f '%m %z' "$fp" 2>/dev/null || echo "0 0")"
        _rp_cid="$(printf '%s' "$fp" | md5 2>/dev/null || printf '%s' "$fp" | md5sum 2>/dev/null | cut -d' ' -f1)"
        _rp_cf="${_rp_cache_dir}/${_rp_cid}"
        if [ -f "$_rp_cf" ]; then
          local _rp_cs
          _rp_cs="$(head -1 "$_rp_cf")"
          if [ "$_rp_cs" = "$_rp_fstat" ]; then
            rp="$(tail -1 "$_rp_cf")"
            _rp_hit=1
          fi
        fi
      fi
      if [ "$_rp_hit" -eq 0 ]; then
        rp="$(realpath "$fp" 2>&1)" || {
          _ic_die "realpath failed for ${fp}: ${rp}"
        }
        if [ -n "$_rp_cache_dir" ]; then
          { printf '%s\n%s\n' "$_rp_fstat" "$rp"; } > "$_rp_cf"
        fi
      fi
      printf '%s\t%s\n' "$norm" "$rp"
    done < "$existing_files" > "$tmpdir/realpath_paired.tsv"
  else
    : > "$tmpdir/realpath_paired.tsv"
  fi

  # Build resolved paths using awk on the paired data.
  # Also build per-sprint consolidated paths for Phase 4 (avoids per-story
  # cat loops later).
  local sprint_paths_dir="$tmpdir/sprint_paths"
  local sprint_types_dir="$tmpdir/sprint_types"
  mkdir -p "$sprint_paths_dir" "$sprint_types_dir"

  awk -F'\t' -v rpr="$_ic_rpr" -v rdir="$resolved_dir" -v rmapf="$realpath_map" \
              -v spdir="$sprint_paths_dir" '
    # Load realpath pairs: original<TAB>resolved
    NR == FNR {
      rp[$1] = $2
      next
    }
    # all_literals: norm<TAB>skey<TAB>sid
    {
      norm = $1; skey = $2; sid = $3
      outf = rdir "/" skey ".txt"
      spf = spdir "/" sid ".txt"
      if (norm in rp) {
        resolved = rp[norm]
        if (index(resolved, rpr "/") == 1) {
          rel = substr(resolved, length(rpr) + 2)
          print rel >> outf
          print rel >> spf
          if (rel != norm) printf "%s\t%s\t%s\n", norm, rel, skey >> rmapf
        } else if (resolved == rpr) {
          print "." >> outf
          print "." >> spf
        } else {
          printf "WARN\t%s\t%s\t%s\n", norm, sid, skey >> (rdir "/_warnings.txt")
        }
      } else {
        print norm >> outf
        print norm >> spf
      }
    }
  ' "$tmpdir/realpath_paired.tsv" "$all_literals"

  # Build per-sprint type files by reading meta + type files in awk.
  awk -F'\t' -v tsdir="$ts_dir" -v stdir="$sprint_types_dir" '
    { sid[$1] = $2 }
    END {
      for (key in sid) {
        tf = tsdir "/" key "_type.txt"
        sf = stdir "/" sid[key] ".txt"
        while ((getline line < tf) > 0) print line >> sf
        close(tf)
      }
      # Close all output files.
      for (key in sid) close(stdir "/" sid[key] ".txt")
    }
  ' "$tmpdir/ts_meta.tsv"

  # Read any warnings.
  if [ -f "$resolved_dir/_warnings.txt" ]; then
    while IFS=$'\t' read -r wtype wnorm wsid wskey; do
      cd_warnings="${cd_warnings}WARN out-of-root path excluded: ${wnorm} (${wsid})
"
    done < "$resolved_dir/_warnings.txt"
    rm -f "$resolved_dir/_warnings.txt"
  fi

  # Handle glob entries: single awk pass matches all expanded paths against
  # all glob patterns. Converts find-path globs to awk regexes.
  # Output: per-story resolved paths and per-story glob-match status.
  if [ -s "$expanded_file" ] && [ -s "$all_globs_file" ]; then
    # Build a combined glob-to-story mapping from all type files.
    local glob_map="$tmpdir/glob_map.tsv"
    awk -F'\t' '
      NR == FNR { sid[$1] = $2; next }
      FILENAME != ARGV[1] {
        fname = FILENAME; sub(/.*\//, "", fname); sub(/_type\.txt$/, "", fname)
        if ($2 == "G" && fname in sid) printf "%s\t%s\t%s\n", $1, fname, sid[fname]
      }
    ' "$tmpdir/ts_meta.tsv" "$ts_dir"/*_type.txt > "$glob_map" 2>/dev/null || : > "$glob_map"

    # Single awk pass: load globs, convert to regexes, match expanded paths.
    awk -F'\t' -v rdir="$resolved_dir" -v spdir="$sprint_paths_dir" \
               -v gmatch_f="$tmpdir/glob_match.tsv" '
      function glob_to_regex(g,    r, i, ch, len) {
        r = "^"
        len = length(g)
        for (i = 1; i <= len; i++) {
          ch = substr(g, i, 1)
          if (ch == "*") { r = r ".*" }
          else if (ch == "?") { r = r "." }
          else if (ch == "[") {
            # Pass character class through (find-path semantics).
            r = r "["
            i++
            while (i <= len) {
              ch = substr(g, i, 1)
              if (ch == "]") { r = r "]"; break }
              r = r ch
              i++
            }
          }
          else if (ch == ".") { r = r "\\." }
          else if (ch == "\\") { r = r "\\\\" }
          else if (ch == "^") { r = r "\\^" }
          else if (ch == "$") { r = r "\\$" }
          else if (ch == "+") { r = r "\\+" }
          else if (ch == "(") { r = r "\\(" }
          else if (ch == ")") { r = r "\\)" }
          else if (ch == "{") { r = r "\\{" }
          else if (ch == "}") { r = r "\\}" }
          else if (ch == "|") { r = r "\\|" }
          else { r = r ch }
        }
        r = r "$"
        return r
      }

      # Phase 1: load glob patterns and their story/sprint mappings.
      NR == FNR {
        nglobs++
        glob_pattern[nglobs] = $1
        glob_regex[nglobs] = glob_to_regex($1)
        glob_story[nglobs] = $2
        glob_sprint[nglobs] = $3
        next
      }

      # Phase 2: for each expanded path, check against all glob regexes.
      {
        path = $0
        for (gi = 1; gi <= nglobs; gi++) {
          if (path ~ glob_regex[gi]) {
            key = glob_story[gi]
            sid = glob_sprint[gi]
            # Record match.
            print path >> (rdir "/" key ".txt")
            print path >> (spdir "/" sid ".txt")
            matched[gi] = 1
          }
        }
      }

      END {
        # Report which stories had glob matches.
        for (gi = 1; gi <= nglobs; gi++) {
          key = glob_story[gi]
          if (matched[gi]) {
            story_matched[key] = 1
            # Record matched glob patterns per sprint for shared-prefix eval.
            sid = glob_sprint[gi]
            print glob_pattern[gi] >> (rdir "/_matched_globs_" sid ".txt")
          }
        }
        # Write glob_match status.
        for (gi = 1; gi <= nglobs; gi++) {
          key = glob_story[gi]
          if (!(key in written)) {
            printf "%s\t%d\n", key, (story_matched[key] ? 1 : 0) >> gmatch_f
            written[key] = 1
          }
        }
        close(gmatch_f)
      }
    ' "$glob_map" "$expanded_file"
  fi

  # Write glob_match=0 for stories without globs.
  while IFS=$'\t' read -r skey sprint_id has_lit has_glb; do
    [ -n "$skey" ] || continue
    if [ "$has_glb" -eq 0 ]; then
      printf '%s\t0\n' "$skey" >> "$tmpdir/glob_match.tsv"
    fi
    # Check for all-zero-match-glob stories.
    if [ "$has_lit" -eq 0 ] && [ "$has_glb" -ne 0 ]; then
      local gm
      gm="$(awk -F'\t' -v k="$skey" '$1 == k { print $2; exit }' "$tmpdir/glob_match.tsv" 2>/dev/null)" || gm="0"
      if [ "${gm:-0}" -eq 0 ]; then
        local sf
        sf="$(awk -F'\t' -v k="$skey" '$1 == k { print $2; exit }' "$resolved_f")"
        local diag="FAIL indeterminate: all entries zero-match globs: ${sprint_id} ${sf}"
        printf '%s\n' "$diag"
        printf '%s\n' "$diag" >&2
        return 1
      fi
    fi
  done < "$tmpdir/ts_meta.tsv"

  # Emit collected warnings (stdout only).
  if [ -n "$cd_warnings" ]; then
    printf '%s' "$cd_warnings"
  fi

  # ---- Phase 4: Per-active-sprint rules (c)/(d) evaluation ----
  # Pre-build per-sprint consolidated data in a single pass to minimize
  # subprocess spawns during the comparison loop.
  local _ic_config_path="$_IC_CONFIG_REL"

  # Use pre-built per-sprint files from Phase 3.
  # Pre-build candidate keys list once.
  local cand_keys_f="$tmpdir/cand_keys.txt"
  awk -F'\t' -v s="$candidate" '$2 == s { print $1 }' "$membership_f" > "$cand_keys_f"

  # Filter config path once for candidate sprint.
  local cand_paths_filtered="$tmpdir/cand_paths_f.txt"
  local cand_types_filtered="$tmpdir/cand_types_f.txt"
  local _cand_sp="$sprint_paths_dir/${candidate}.txt"
  local _cand_st="$sprint_types_dir/${candidate}.txt"
  [ -f "$_cand_sp" ] || : > "$_cand_sp"
  [ -f "$_cand_st" ] || : > "$_cand_st"
  /usr/bin/grep -Fxv -- "$_ic_config_path" "$_cand_sp" > "$cand_paths_filtered" 2>/dev/null || : > "$cand_paths_filtered"
  /usr/bin/grep -Fv -- "$_ic_config_path" "$_cand_st" > "$cand_types_filtered" 2>/dev/null || : > "$cand_types_filtered"

  local cd_overall_rc=0
  local active_id

  while IFS= read -r active_id; do
    [ -n "$active_id" ] || continue
    local rule_c_fail=0 rule_d_fail=0
    local rule_c_diag="" rule_d_diag=""

    # Use pre-built per-sprint files; filter config path.
    # R77: skip the carried-over key in this sprint's comparison.
    local act_keys_f="$tmpdir/act_keys_${active_id}.txt"
    local _skip_key="" _skip_sprint=""
    if [ -n "$_IC_SKIP_KEY_SPRINT" ]; then
      _skip_key="${_IC_SKIP_KEY_SPRINT%%:*}"
      _skip_sprint="${_IC_SKIP_KEY_SPRINT#*:}"
    fi
    if [ -n "$_skip_key" ] && [ "$_skip_sprint" = "$active_id" ]; then
      awk -F'\t' -v s="$active_id" -v sk="$_skip_key" \
        '$2 == s && $1 != sk { print $1 }' "$membership_f" > "$act_keys_f"
    else
      awk -F'\t' -v s="$active_id" '$2 == s { print $1 }' "$membership_f" > "$act_keys_f"
    fi

    local _act_sp="$sprint_paths_dir/${active_id}.txt"
    local _act_st="$sprint_types_dir/${active_id}.txt"
    [ -f "$_act_sp" ] || : > "$_act_sp"
    [ -f "$_act_st" ] || : > "$_act_st"

    local act_paths_filtered="$tmpdir/act_paths_f_${active_id}.txt"
    local act_types_filtered="$tmpdir/act_types_f_${active_id}.txt"
    /usr/bin/grep -Fxv -- "$_ic_config_path" "$_act_sp" > "$act_paths_filtered" 2>/dev/null || : > "$act_paths_filtered"
    /usr/bin/grep -Fv -- "$_ic_config_path" "$_act_st" > "$act_types_filtered" 2>/dev/null || : > "$act_types_filtered"

    local cand_all_paths="$cand_paths_filtered"
    local cand_all_types="$cand_types_filtered"
    local act_all_paths="$act_paths_filtered"
    local act_all_types="$act_types_filtered"

    # 1. Direct path overlap (resolved paths).
    local overlap_path=""
    overlap_path="$(sort "$cand_all_paths" "$act_all_paths" 2>/dev/null | uniq -d | head -1)" || true
    if [ -n "$overlap_path" ]; then
      # Find which stories own this path.
      local ck_owner ak_owner
      ck_owner="$(for k in $(cat "$cand_keys_f"); do /usr/bin/grep -Fxq -- "$overlap_path" "$resolved_dir/${k}.txt" 2>/dev/null && printf '%s' "$k" && break; done)"
      ak_owner="$(for k in $(cat "$act_keys_f"); do /usr/bin/grep -Fxq -- "$overlap_path" "$resolved_dir/${k}.txt" 2>/dev/null && printf '%s' "$k" && break; done)"
      rule_c_fail=1
      rule_c_diag="FAIL rule (c): paths overlap ${ck_owner:-?} and ${ak_owner:-?}: ${overlap_path} (${candidate} -> ${active_id})"
    fi

    # 2. Realpath-based overlap (symlinks resolving to same path).
    if [ "$rule_c_fail" -eq 0 ] && [ -s "$realpath_map" ]; then
      local cand_reals="$tmpdir/cand_reals_${active_id}.txt"
      local act_reals="$tmpdir/act_reals_${active_id}.txt"
      awk -F'\t' -v cfg="$_ic_config_path" '
        NR == FNR { want[$1] = 1; next }
        ($3 in want) && $2 != cfg { print $2 }
      ' "$cand_keys_f" "$realpath_map" | sort -u > "$cand_reals"
      awk -F'\t' -v cfg="$_ic_config_path" '
        NR == FNR { want[$1] = 1; next }
        ($3 in want) && $2 != cfg { print $2 }
      ' "$act_keys_f" "$realpath_map" | sort -u > "$act_reals"
      local real_overlap
      real_overlap="$(sort "$cand_reals" "$act_reals" 2>/dev/null | uniq -d | head -1)" || true
      if [ -n "$real_overlap" ]; then
        local ck_owner ak_owner
        ck_owner="$(awk -F'\t' -v p="$real_overlap" '$2 == p { print $3; exit }' "$realpath_map")"
        ak_owner="$(awk -F'\t' -v p="$real_overlap" '$2 == p && NR > 1 { print $3; exit }' "$realpath_map")"
        rule_c_fail=1
        rule_c_diag="FAIL rule (c): paths overlap ${ck_owner:-?} and ${ak_owner:-?}: ${real_overlap} (${candidate} -> ${active_id})"
      fi
    fi

    # 3. Directory-literal prefix containment and literal-vs-glob overlap.
    if [ "$rule_c_fail" -eq 0 ]; then
      # Collect all directory literals and all entries per sprint.
      local cdir_lits act_lits
      cdir_lits="$(awk -F'\t' '$2=="L" && $1 ~ /\/$/ { print $1 }' "$cand_all_types" 2>/dev/null)"
      act_lits="$(awk -F'\t' '$2=="L" && $1 ~ /\/$/ { print $1 }' "$act_all_types" 2>/dev/null)"

      # Dir literal from candidate contains active entry?
      if [ -n "$cdir_lits" ]; then
        while IFS= read -r dlit; do
          [ -n "$dlit" ] || continue
          local contained
          contained="$(awk -F'\t' -v p="$dlit" 'index($1, p) == 1 { print $1; exit }' "$act_all_types" 2>/dev/null)"
          if [ -n "$contained" ]; then
            rule_c_fail=1
            rule_c_diag="FAIL rule (c): paths overlap ? and ?: ${dlit} contains ${contained} (${candidate} -> ${active_id})"
            break
          fi
        done <<< "$cdir_lits"
      fi
      # Dir literal from active contains candidate entry?
      if [ "$rule_c_fail" -eq 0 ] && [ -n "$act_lits" ]; then
        while IFS= read -r dlit; do
          [ -n "$dlit" ] || continue
          local contained
          contained="$(awk -F'\t' -v p="$dlit" 'index($1, p) == 1 { print $1; exit }' "$cand_all_types" 2>/dev/null)"
          if [ -n "$contained" ]; then
            rule_c_fail=1
            rule_c_diag="FAIL rule (c): paths overlap ? and ?: ${dlit} contains ${contained} (${candidate} -> ${active_id})"
            break
          fi
        done <<< "$act_lits"
      fi
    fi

    # 4. Literal vs glob pattern match.
    if [ "$rule_c_fail" -eq 0 ]; then
      local cand_lits_f="$tmpdir/cand_lits_${active_id}.txt"
      local act_globs_f="$tmpdir/act_globs_${active_id}.txt"
      local act_lits_f="$tmpdir/act_lits2_${active_id}.txt"
      local cand_globs_f="$tmpdir/cand_globs_${active_id}.txt"
      awk -F'\t' '$2=="L" { print $1 }' "$cand_all_types" > "$cand_lits_f" 2>/dev/null || true
      awk -F'\t' '$2=="G" { print $1 }' "$act_all_types" > "$act_globs_f" 2>/dev/null || true
      awk -F'\t' '$2=="L" { print $1 }' "$act_all_types" > "$act_lits_f" 2>/dev/null || true
      awk -F'\t' '$2=="G" { print $1 }' "$cand_all_types" > "$cand_globs_f" 2>/dev/null || true

      # Check candidate literals against active globs.
      if [ -s "$cand_lits_f" ] && [ -s "$act_globs_f" ]; then
        while IFS= read -r clit; do
          [ -n "$clit" ] || continue
          while IFS= read -r aglob; do
            [ -n "$aglob" ] || continue
            # shellcheck disable=SC2254
            case "$clit" in $aglob)
              rule_c_fail=1
              rule_c_diag="FAIL rule (c): paths overlap ? and ?: ${clit} matches ${aglob} (${candidate} -> ${active_id})"
              break 2 ;; esac
          done < "$act_globs_f"
        done < "$cand_lits_f"
      fi
      # Check active literals against candidate globs.
      if [ "$rule_c_fail" -eq 0 ] && [ -s "$act_lits_f" ] && [ -s "$cand_globs_f" ]; then
        while IFS= read -r alit; do
          [ -n "$alit" ] || continue
          while IFS= read -r cglob; do
            [ -n "$cglob" ] || continue
            # shellcheck disable=SC2254
            case "$alit" in $cglob)
              rule_c_fail=1
              rule_c_diag="FAIL rule (c): paths overlap ? and ?: ${alit} matches ${cglob} (${candidate} -> ${active_id})"
              break 2 ;; esac
          done < "$cand_globs_f"
        done < "$act_lits_f"
      fi
    fi

    # 5. Shared-prefix glob overlap (only between matched globs).
    # Uses pre-computed matched-glob files from Phase 3 awk.
    if [ "$rule_c_fail" -eq 0 ]; then
      local cand_matched_globs="$resolved_dir/_matched_globs_${candidate}.txt"
      local act_matched_globs="$resolved_dir/_matched_globs_${active_id}.txt"
      [ -f "$cand_matched_globs" ] || : > "$cand_matched_globs"
      [ -f "$act_matched_globs" ] || : > "$act_matched_globs"

      if [ -s "$cand_matched_globs" ] && [ -s "$act_matched_globs" ]; then
        while IFS= read -r cg; do
          [ -n "$cg" ] || continue
          local cp
          cp="$(_ic_glob_prefix "$cg")"
          [ -n "$cp" ] || continue
          while IFS= read -r ag; do
            [ -n "$ag" ] || continue
            local ap
            ap="$(_ic_glob_prefix "$ag")"
            [ -n "$ap" ] || continue
            case "$cp" in "${ap}"*) rule_c_fail=1; rule_c_diag="FAIL rule (c): shared prefix overlap ? and ?: ${cp} vs ${ap} (${candidate} -> ${active_id})"; break 2 ;; esac
            case "$ap" in "${cp}"*) rule_c_fail=1; rule_c_diag="FAIL rule (c): shared prefix overlap ? and ?: ${cp} vs ${ap} (${candidate} -> ${active_id})"; break 2 ;; esac
          done < "$act_matched_globs"
        done < "$cand_matched_globs"
      fi
    fi

    # ---- Rule (d): Planning-artifact family exclusivity ----
    # Collect families touched by candidate and active stories.
    local cand_families_f="$tmpdir/cand_fam_${active_id}.txt"
    local act_families_f="$tmpdir/act_fam_${active_id}.txt"
    : > "$cand_families_f"
    : > "$act_families_f"

    # Candidate families.
    while IFS= read -r ck; do
      [ -n "$ck" ] || continue
      local type_f="$ts_dir/${ck}_type.txt"
      [ -f "$type_f" ] || continue
      while IFS=$'\t' read -r entry etype; do
        [ -n "$entry" ] || continue
        local fams
        fams="$(_ic_classify_family "$entry" "$pdir" "$tdir")"
        if [ -n "$fams" ]; then
          while IFS= read -r fam; do
            [ -n "$fam" ] || continue
            printf '%s\t%s\t%s\n' "$fam" "$ck" "$entry" >> "$cand_families_f"
          done <<< "$fams"
        fi
      done < "$type_f"
      # Also classify resolved/expanded paths for globs.
      local rpf="$resolved_dir/${ck}.txt"
      if [ -f "$rpf" ]; then
        while IFS= read -r rpath; do
          [ -n "$rpath" ] || continue
          local rfams
          rfams="$(_ic_classify_family "$rpath" "$pdir" "$tdir")"
          if [ -n "$rfams" ]; then
            while IFS= read -r rfam; do
              [ -n "$rfam" ] || continue
              printf '%s\t%s\t%s\n' "$rfam" "$ck" "$rpath" >> "$cand_families_f"
            done <<< "$rfams"
          fi
        done < "$rpf"
      fi
    done < "$cand_keys_f"

    # Active families.
    while IFS= read -r ak; do
      [ -n "$ak" ] || continue
      local type_f="$ts_dir/${ak}_type.txt"
      [ -f "$type_f" ] || continue
      while IFS=$'\t' read -r entry etype; do
        [ -n "$entry" ] || continue
        local fams
        fams="$(_ic_classify_family "$entry" "$pdir" "$tdir")"
        if [ -n "$fams" ]; then
          while IFS= read -r fam; do
            [ -n "$fam" ] || continue
            printf '%s\t%s\t%s\n' "$fam" "$ak" "$entry" >> "$act_families_f"
          done <<< "$fams"
        fi
      done < "$type_f"
      local rpf="$resolved_dir/${ak}.txt"
      if [ -f "$rpf" ]; then
        while IFS= read -r rpath; do
          [ -n "$rpath" ] || continue
          local rfams
          rfams="$(_ic_classify_family "$rpath" "$pdir" "$tdir")"
          if [ -n "$rfams" ]; then
            while IFS= read -r rfam; do
              [ -n "$rfam" ] || continue
              printf '%s\t%s\t%s\n' "$rfam" "$ak" "$rpath" >> "$act_families_f"
            done <<< "$rfams"
          fi
        done < "$rpf"
      fi
    done < "$act_keys_f"

    # Check for family intersection (excluding config with section granularity).
    if [ -s "$cand_families_f" ] && [ -s "$act_families_f" ]; then
      local cand_fam_names act_fam_names
      cand_fam_names="$(awk -F'\t' '{ print $1 }' "$cand_families_f" | sort -u)"
      act_fam_names="$(awk -F'\t' '{ print $1 }' "$act_families_f" | sort -u)"

      local cfam
      while IFS= read -r cfam; do
        [ -n "$cfam" ] || continue
        [ "$rule_d_fail" -eq 0 ] || break
        # Check if this family appears in both.
        if printf '%s\n' "$act_fam_names" | /usr/bin/grep -qxF -- "$cfam" 2>/dev/null; then
          # Config family: check section granularity.
          if [ "$cfam" = "config" ]; then
            # Get candidate and active story keys that touch config.
            local cand_cfg_keys act_cfg_keys
            cand_cfg_keys="$(awk -F'\t' '$1 == "config" { print $2 }' "$cand_families_f" | sort -u)"
            act_cfg_keys="$(awk -F'\t' '$1 == "config" { print $2 }' "$act_families_f" | sort -u)"

            # Check section granularity for each pair.
            local cck ack
            local config_overlap=0
            while IFS= read -r cck; do
              [ -n "$cck" ] || continue
              while IFS= read -r ack; do
                [ -n "$ack" ] || continue
                # Do both stories have predicted_config_sections?
                local cck_has_cs=0 ack_has_cs=0
                if [ -f "$cs_dir/_has_field.txt" ]; then
                  /usr/bin/grep -qxF -- "$cck" "$cs_dir/_has_field.txt" 2>/dev/null && cck_has_cs=1
                  /usr/bin/grep -qxF -- "$ack" "$cs_dir/_has_field.txt" 2>/dev/null && ack_has_cs=1
                fi

                if [ "$cck_has_cs" -eq 1 ] && [ "$ack_has_cs" -eq 1 ]; then
                  # Per-key comparison.
                  local section_overlap
                  section_overlap="$(sort "$cs_dir/${cck}.txt" "$cs_dir/${ack}.txt" 2>/dev/null | uniq -d | head -1)"
                  if [ -n "$section_overlap" ]; then
                    config_overlap=1
                    rule_d_fail=1
                    rule_d_diag="FAIL rule (d): config section \"${section_overlap}\" (${candidate} -> ${active_id})"
                    break
                  fi
                else
                  # Conservative: either lacks the field.
                  config_overlap=1
                  rule_d_fail=1
                  rule_d_diag="FAIL rule (d): config file \"${_IC_CONFIG_REL}\" (${candidate} -> ${active_id})"
                  break
                fi
              done <<< "$act_cfg_keys"
              [ "$rule_d_fail" -eq 0 ] || break
            done <<< "$cand_cfg_keys"
          else
            # Non-config family overlap.
            rule_d_fail=1
            rule_d_diag="FAIL rule (d): planning-artifact conflict on ${cfam} (${candidate} -> ${active_id})"
          fi
        fi
      done <<< "$cand_fam_names"
    fi

    # ---- Emit results ----
    if [ "$rule_c_fail" -ne 0 ]; then
      printf '%s\n' "$rule_c_diag"
      printf '%s\n' "$rule_c_diag" >&2
      cd_overall_rc=1
    fi
    if [ "$rule_d_fail" -ne 0 ]; then
      printf '%s\n' "$rule_d_diag"
      printf '%s\n' "$rule_d_diag" >&2
      cd_overall_rc=1
    fi
    if [ "$rule_c_fail" -eq 0 ] && [ "$rule_d_fail" -eq 0 ]; then
      printf 'PASS rules (c),(d): %s vs %s\n' "$candidate" "$active_id"
    fi

  done <<< "$(printf '%s' "$active_csv" | tr ',' '\n')"

  return "$cd_overall_rc"
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
  # Apply overlays: each overlay replaces the on-disk story with the
  # same key, or adds a new story to the candidate sprint.
  # -------------------------------------------------------------------
  if [ -n "$_IC_OVERLAY_FILES" ]; then
    local _ov_file _ov_key
    while IFS= read -r _ov_file; do
      [ -n "$_ov_file" ] || continue
      [ -f "$_ov_file" ] || _ic_die "overlay file not found: $_ov_file"
      # Read key from overlay frontmatter.
      _ov_key="$(awk '
        BEGIN { in_fm=0; started=0 }
        /^---[[:space:]]*$/ {
          if (!started) { started=1; in_fm=1; next }
          else exit
        }
        !in_fm { next }
        /^key:[[:space:]]*/ {
          v = $0; sub(/^key:[[:space:]]*/, "", v)
          gsub(/^["'"'"'"'"'"'[:space:]]+|["'"'"'"'"'"'[:space:]]+$/, "", v)
          print v; exit
        }
      ' "$_ov_file")" || true
      [ -n "$_ov_key" ] || _ic_die "overlay file has no key: $_ov_file"

      # Validate overlay key format (reject regex metacharacters).
      case "$_ov_key" in
        *"."*|*"^"*|*'$'*|*"["*|*"]"*|*"+"*|*"?"*|*"{"*|*"}"*|*"\\"*|*"|"*)
          _ic_die "overlay key contains invalid characters: $_ov_key" ;;
      esac

      # Check if key exists in resolved_f (exact first-field match).
      if awk -F'\t' -v k="$_ov_key" '$1==k { found=1; exit } END { exit !found }' "$resolved_f" 2>/dev/null; then
        # Replace the resolved path with the overlay path.
        local _ov_tmp="${resolved_f}.ovtmp"
        awk -F'\t' -v k="$_ov_key" -v p="$_ov_file" \
          '{ if ($1 == k) printf "%s\t%s\n", k, p; else print }' \
          "$resolved_f" > "$_ov_tmp"
        mv -f "$_ov_tmp" "$resolved_f"
      else
        # Add to resolved_f and membership (candidate sprint).
        printf '%s\t%s\n' "$_ov_key" "$_ov_file" >> "$resolved_f"
        printf '%s\t%s\n' "$_ov_key" "$_IC_CANDIDATE" >> "$membership"
        printf '%s\n' "$_ov_key" >> "$all_keys_file"
      fi
    done <<< "$_IC_OVERLAY_FILES"
  fi

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
  # _IC_GRAPH_AWK: test-only override for the graph-analysis awk command.
  local graph_awk="${_IC_GRAPH_AWK:-awk}"
  local awk_result awk_rc
  local _skip_key_ab="" _skip_sprint_ab=""
  if [ -n "$_IC_SKIP_KEY_SPRINT" ]; then
    _skip_key_ab="${_IC_SKIP_KEY_SPRINT%%:*}"
    _skip_sprint_ab="${_IC_SKIP_KEY_SPRINT#*:}"
  fi
  awk_result="$($graph_awk -F'\t' \
    -v candidate="$_IC_CANDIDATE" \
    -v active_list="$active_csv" \
    -v skip_key="$_skip_key_ab" \
    -v skip_sprint="$_skip_sprint_ab" \
  '
    # ---- Phase 1: load data ----
    FILENAME == ARGV[1] {
      # membership.tsv: KEY<TAB>SPRINT
      # R77: skip the carried-over key in the named sprint.
      if (skip_key != "" && $1 == skip_key && $2 == skip_sprint) next
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

  # Validate the zero-exit path: every candidate-vs-active comparison must
  # have produced at least one verdict line (PASS or FAIL). A truncated or
  # empty result from the graph analysis silently passes activation without
  # this guard. Line-by-line exact matching prevents prefix-related sprint
  # ids (sprint-90 vs sprint-900) from satisfying each other.
  if [ "$awk_rc" -eq 0 ]; then
    local expected_id
    while IFS= read -r expected_id; do
      [ -n "$expected_id" ] || continue
      local _ic_covered=0
      local _ic_vline
      while IFS= read -r _ic_vline; do
        [ -n "$_ic_vline" ] || continue
        # PASS line: exact match on the full formatted line.
        if [ "$_ic_vline" = "PASS rules (a),(b): ${_IC_CANDIDATE} vs ${expected_id}" ]; then
          _ic_covered=1; break
        fi
        # FAIL rule (a): ... (<candidate> -> <active>)
        # The active id is the last token before the closing paren.
        case "$_ic_vline" in
          "FAIL rule (a):"*"(${_IC_CANDIDATE} -> ${expected_id})")
            _ic_covered=1; break ;;
        esac
        # FAIL rule (b): ... between <candidate> and <active>
        # or: ... between <candidate> and <active>; exempted ...
        case "$_ic_vline" in
          "FAIL rule (b):"*"between ${_IC_CANDIDATE} and ${expected_id}"|\
"FAIL rule (b):"*"between ${_IC_CANDIDATE} and ${expected_id};"*)
            _ic_covered=1; break ;;
        esac
      done <<< "$awk_result"
      if [ "$_ic_covered" -eq 0 ]; then
        _ic_die "incomplete independence result"
      fi
    done <<< "$active_ids"
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

  # -------------------------------------------------------------------
  # Rules (c)/(d): Touch-set overlap + planning-artifact exclusivity
  # -------------------------------------------------------------------
  local cd_rc=0
  _ic_run_rules_cd "$_IC_CANDIDATE" "$active_csv" "$membership" "$resolved_f" "$tmpdir" || cd_rc=$?

  # Final exit code: non-zero if ANY rule set failed.
  local final_rc=0
  if [ "$awk_rc" -ne 0 ] || [ "$cd_rc" -ne 0 ]; then
    final_rc=1
  fi
  exit "$final_rc"
}

# Run main only when executed as a script (not sourced).
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]}" = "${0##*/}" ]; then
  main "$@"
fi
