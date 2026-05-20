#!/usr/bin/env bash
# gate-predicates.sh — E45-S2 (FR-347, FR-358, ADR-060)
#
# Shared library sourced by setup.sh / finalize.sh of any V2 skill that
# declares a `quality_gates` block in its SKILL.md frontmatter. Provides:
#
#   _gate_extract_block <skill_md> <which>      — extract pre_start or
#                                                 post_complete YAML list
#   _gate_evaluate_entry <condition> <message>  — evaluate one predicate;
#                                                 0 on pass, 1 on fail
#   _gate_run_pre_start <skill_md> <prefix>     — iterate pre_start list,
#                                                 halt on first failure
#   _gate_run_post_complete <skill_md> <artifact> <prefix>
#                                              — iterate post_complete
#                                                 list, accumulate misses
#
# Predicate vocabulary (locked by Task 1.2):
#   file_exists:{glob}        — glob matches >= 1 file under PWD
#   file_missing:{glob}       — inverse of file_exists
#   section_present:{header}  — artifact contains "## {header}" (case-
#                               sensitive, whitespace-trimmed)
#   section_count:{n}         — artifact contains >= n H2 headers
#   story_status:{key}:{state} — story file has the given status
#   env_var_set:{var}         — env var is set and non-empty
#
# All functions are private (leading underscore) so the NFR-052 coverage
# gate does not require dedicated bats tests for them — they are
# exercised end-to-end via the public setup.sh / finalize.sh contracts.
#
# POSIX discipline: bash 3.2 compatible. No associative arrays, no
# bashisms that break under BSD awk/sed. LC_ALL=C is the caller's
# responsibility (already pinned by setup.sh / finalize.sh).

# Guard against double-source so callers can `. gate-predicates.sh`
# unconditionally.
if [ "${_GATE_PREDICATES_SH_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GATE_PREDICATES_SH_LOADED=1

# _gate_log <prefix> <message>
# Print a quality-gate diagnostic line to stderr. The prefix is the
# caller's tag (e.g. "gaia-product-brief: quality-gate") so consumers can
# grep for "quality-gate" deterministically.
_gate_log() {
  printf '[%s] %s\n' "$1" "$2" >&2
}

# _gate_extract_block <skill_md> <which>
# Extract the named sub-block (pre_start or post_complete) from the
# quality_gates frontmatter. Emits one line per list entry in the form:
#
#   <condition>\t<error_message>
#
# Tab-separated so the message can contain colons, parentheses, etc.
# Returns 0 always; prints zero lines if the block is absent or empty
# (the no-op case — backward-compatible with skills that have not yet
# adopted the schema).
_gate_extract_block() {
  local skill_md="$1" which="$2"
  [ -f "$skill_md" ] || return 0
  awk -v which="$which" '
    BEGIN { in_fm=0; in_qg=0; in_block=0; cond=""; msg="" }
    # Track frontmatter delimiters (--- ... ---).
    /^---[[:space:]]*$/ {
      if (in_fm == 0) { in_fm = 1; next }
      else { exit }   # End of frontmatter — stop scanning.
    }
    in_fm == 0 { next }
    # Top-level quality_gates: marker.
    /^quality_gates:[[:space:]]*$/ { in_qg=1; in_block=0; next }
    # Any other top-level key closes the block.
    /^[A-Za-z_][A-Za-z0-9_-]*:/ && !/^[[:space:]]/ {
      if ($0 !~ /^quality_gates:/) { in_qg=0; in_block=0 }
    }
    in_qg == 0 { next }
    # Sub-blocks: pre_start: / post_complete:
    /^[[:space:]]+pre_start:[[:space:]]*$/ {
      if (which == "pre_start") { in_block=1 } else { in_block=0 }
      next
    }
    /^[[:space:]]+post_complete:[[:space:]]*$/ {
      if (which == "post_complete") { in_block=1 } else { in_block=0 }
      next
    }
    in_block == 0 { next }
    # List item: "  - condition: <value>"
    /^[[:space:]]+-[[:space:]]+condition:[[:space:]]*/ {
      # Flush prior pair if both fields were captured.
      if (cond != "" && msg != "") { print cond "\t" msg }
      cond = $0
      sub(/^[[:space:]]+-[[:space:]]+condition:[[:space:]]*/, "", cond)
      # Strip optional surrounding quotes.
      sub(/^"/, "", cond); sub(/"$/, "", cond)
      sub(/^\x27/, "", cond); sub(/\x27$/, "", cond)
      msg = ""
      next
    }
    # Continuation field: "    error_message: <value>"
    /^[[:space:]]+error_message:[[:space:]]*/ {
      msg = $0
      sub(/^[[:space:]]+error_message:[[:space:]]*/, "", msg)
      sub(/^"/, "", msg); sub(/"$/, "", msg)
      sub(/^\x27/, "", msg); sub(/\x27$/, "", msg)
      next
    }
    END {
      if (cond != "" && msg != "") { print cond "\t" msg }
    }
  ' "$skill_md"
}

# _gate_check_file_exists <glob>
# Return 0 if the glob matches >= 1 path. Relative globs are anchored to
# $PROJECT_ROOT when set (set by setup.sh after resolve-config.sh runs);
# otherwise to the current PWD. The glob is expanded by bash, not by
# find, to keep the hot path lightweight.
_gate_check_file_exists() {
  local glob="$1" f base
  # Anchor relative globs to PROJECT_ROOT when set so audit/e2e
  # harnesses that don't cd into the project root still resolve
  # correctly. Absolute globs are left alone.
  # Resolve project root from the conventions used across GAIA:
  #   1. project_root (lowercase, exported by resolve-config.sh)
  #   2. PROJECT_ROOT (uppercase, set by e2e harnesses)
  #   3. CLAUDE_PROJECT_ROOT (Claude Code plugin harness convention)
  case "$glob" in
    /*) ;;  # absolute — use as-is
    *)
      base="${project_root:-${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}}"
      if [ -n "$base" ] && [ -d "$base" ]; then
        glob="$base/$glob"
      fi
      ;;
  esac
  set +o noglob 2>/dev/null || true
  for f in $glob; do
    if [ -e "$f" ]; then return 0; fi
  done
  return 1
}

# _gate_check_file_missing <glob>
_gate_check_file_missing() {
  if _gate_check_file_exists "$1"; then return 1; fi
  return 0
}

# _gate_check_section_present <artifact> <header>
# H2 (## ) match — case-sensitive, whitespace-trimmed on the header
# token. Tolerates trailing characters on the markdown line.
_gate_check_section_present() {
  local artifact="$1" header="$2"
  [ -f "$artifact" ] || return 1
  # Use awk to avoid grep -F vs -E ambiguity on special characters.
  awk -v hdr="$header" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "## " hdr) { found=1; exit }
      # Tolerate trailing punctuation/whitespace (e.g. "## Vision Statement — note").
      target = "## " hdr
      if (substr(line, 1, length(target)) == target) {
        rest = substr(line, length(target) + 1)
        if (rest == "" || rest ~ /^[[:space:]]/ || rest ~ /^[[:punct:]]/) {
          found=1; exit
        }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$artifact"
}

# _gate_check_section_count <artifact> <n>
_gate_check_section_count() {
  local artifact="$1" n="$2" count
  [ -f "$artifact" ] || return 1
  count=$(grep -cE '^## [^[:space:]]' "$artifact" 2>/dev/null || echo 0)
  [ "${count:-0}" -ge "$n" ]
}

# _gate_check_story_status <key> <state>
_gate_check_story_status() {
  local key="$1" want="$2"
  local impl_dir="${IMPLEMENTATION_ARTIFACTS:-docs/implementation-artifacts}"
  local f
  for f in "$impl_dir"/"$key"-*.md "$impl_dir"/"$key".md; do
    [ -f "$f" ] || continue
    local got
    got=$(awk '
      BEGIN { in_fm=0 }
      /^---[[:space:]]*$/ { in_fm = !in_fm; if (!in_fm) exit; next }
      in_fm && /^status:[[:space:]]*/ {
        v=$0; sub(/^status:[[:space:]]*/, "", v)
        gsub(/["\047]/, "", v); print v; exit
      }
    ' "$f")
    [ "$got" = "$want" ] && return 0
    return 1
  done
  return 1
}

# _gate_check_env_var_set <var>
_gate_check_env_var_set() {
  local v="$1" val
  eval "val=\${$v:-}"
  [ -n "$val" ]
}

# _gate_evaluate_entry <condition> <error_message>
# Dispatch on the predicate prefix, evaluate, and on failure print the
# error_message verbatim to stderr. Returns 0 on pass, 1 on fail.
# The error_message is printed via printf '%s' to ensure shell
# metacharacters are NOT interpreted (AC-EC5).
_gate_evaluate_entry() {
  local cond="$1" msg="$2"
  local prefix="${cond%%:*}"
  local arg="${cond#*:}"
  local rc=0
  case "$prefix" in
    file_exists)      _gate_check_file_exists "$arg" || rc=1 ;;
    file_missing)     _gate_check_file_missing "$arg" || rc=1 ;;
    section_present)
      # The artifact path must be supplied via the env var
      # _GATE_ARTIFACT — set by _gate_run_post_complete.
      _gate_check_section_present "${_GATE_ARTIFACT:-}" "$arg" || rc=1
      ;;
    section_count)
      _gate_check_section_count "${_GATE_ARTIFACT:-}" "$arg" || rc=1
      ;;
    story_status)
      local key="${arg%%:*}"
      local state="${arg#*:}"
      _gate_check_story_status "$key" "$state" || rc=1
      ;;
    env_var_set)      _gate_check_env_var_set "$arg" || rc=1 ;;
    *)
      _gate_log "${_GATE_PREFIX:-quality-gate}" "unknown predicate: $prefix"
      rc=1
      ;;
  esac
  if [ $rc -ne 0 ]; then
    # Print message LITERALLY — no eval, no expansion.
    printf '[%s] %s\n' "${_GATE_PREFIX:-quality-gate}" "$msg" >&2
  fi
  return $rc
}

# _gate_run_pre_start <skill_md> <prefix>
# Iterate the pre_start list. HALT on first failure (returns 1).
# Returns 0 on no-op (empty block) or all-pass.
_gate_run_pre_start() {
  local skill_md="$1"
  export _GATE_PREFIX="$2"
  local cond msg
  while IFS=$'\t' read -r cond msg; do
    [ -z "$cond" ] && continue
    if ! _gate_evaluate_entry "$cond" "$msg"; then
      return 1
    fi
  done <<EOF
$(_gate_extract_block "$skill_md" pre_start)
EOF
  return 0
}

# _gate_run_post_complete <skill_md> <artifact> <prefix>
# Iterate the post_complete list. ACCUMULATE failures so the user gets
# the full list of missing sections in one error message (AC4).
# Returns 0 if all entries pass, 1 if any entry failed.
_gate_run_post_complete() {
  local skill_md="$1"
  export _GATE_ARTIFACT="$2"
  export _GATE_PREFIX="$3"
  local cond msg
  local missing=""
  local rc=0
  while IFS=$'\t' read -r cond msg; do
    [ -z "$cond" ] && continue
    local prefix="${cond%%:*}"
    local arg="${cond#*:}"
    case "$prefix" in
      section_present)
        if ! _gate_check_section_present "$_GATE_ARTIFACT" "$arg"; then
          if [ -z "$missing" ]; then
            missing="$arg"
          else
            missing="$missing, $arg"
          fi
          rc=1
        fi
        ;;
      *)
        # Non-section predicates evaluate one-by-one with their own
        # error messages, like pre_start.
        if ! _gate_evaluate_entry "$cond" "$msg"; then
          rc=1
        fi
        ;;
    esac
  done <<EOF
$(_gate_extract_block "$skill_md" post_complete)
EOF
  if [ -n "$missing" ]; then
    printf '[%s] Missing required sections: %s\n' "$_GATE_PREFIX" "$missing" >&2
  fi
  return $rc
}
