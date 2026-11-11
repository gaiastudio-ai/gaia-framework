#!/usr/bin/env bash
# regression-rule-check.sh — regression-rule gate for the review pipeline.
#
# Ensures that every confirmed critical/high pattern bug ships a regression
# rule with tests, and that the shipped and project rule libraries are
# structurally sound.
#
# Subcommands:
#   enabled       Print "on" or "off" based on the config key
#                 review.regression_rule_gate_enabled.
#   story-check   Verify that each critical/high pattern finding in a
#                 story's register has a linked rule with tests, and the
#                 rule or its tests changed since the finding's round.
#   library-check Validate the shipped and project rule libraries:
#                 every rule must have a test/ directory with at least one
#                 must-fire and one must-not-fire fixture.
#
# Exit codes:
#   0 — all checks pass (or gate turned off)
#   1 — one or more checks failed
#   2 — usage/configuration error

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="regression-rule-check.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"

_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_die() { local rc="$1"; shift; _err "$*"; exit "$rc"; }

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-$(pwd)}}}"
export PROJECT_ROOT

# Shipped rule library (inside the plugin tree).
_SHIPPED_LIB="$SCRIPT_DIR/lint-rules"

# Project rule library (under the project custom directory).
_CUSTOM_DIR="${GAIA_CUSTOM_DIR:-}"
if [ -z "$_CUSTOM_DIR" ]; then
  if [ -x "$SCRIPT_DIR/lib/gaia-paths.sh" ]; then
    # shellcheck source=lib/gaia-paths.sh
    . "$SCRIPT_DIR/lib/gaia-paths.sh" 2>/dev/null || true
    _CUSTOM_DIR="${GAIA_CUSTOM_DIR:-${PROJECT_ROOT}/.gaia/custom}"
  else
    _CUSTOM_DIR="${PROJECT_ROOT}/.gaia/custom"
  fi
fi
_PROJECT_LIB="$_CUSTOM_DIR/lint-rules"

# Config file.
_CONFIG_FILE="${PROJECT_CONFIG:-${PROJECT_ROOT}/.gaia/config/project-config.yaml}"

# ---------------------------------------------------------------------------
# Subcommand: enabled
# ---------------------------------------------------------------------------

_cmd_enabled() {
  # Only boolean false turns the gate off; absent or any other value means on.
  if [ -f "$_CONFIG_FILE" ] && command -v yq >/dev/null 2>&1; then
    local raw
    raw="$(yq -o=json '.review.regression_rule_gate_enabled' "$_CONFIG_FILE" 2>/dev/null)" || raw="null"
    if [ "$raw" = "false" ]; then
      printf 'off\n'
      return 0
    fi
  fi
  printf 'on\n'
}

# ---------------------------------------------------------------------------
# Helpers: rule library validation
# ---------------------------------------------------------------------------

# Validate a single rule directory.
# Usage: _validate_rule_dir <rule_dir> <library_label>
# Appends JSON objects to _LIB_ERRORS on failure.
_validate_rule_dir() {
  local rule_dir="$1" label="$2"
  local rule_id
  rule_id="$(basename "$rule_dir")"

  # Path traversal guard (AC-EC4).
  local real_rule_dir real_lib_dir
  real_rule_dir="$(cd "$rule_dir" 2>/dev/null && pwd -P)" || {
    _LIB_ERRORS="${_LIB_ERRORS:+$_LIB_ERRORS,}{\"rule\":\"${rule_id}\",\"reason\":\"cannot resolve real path\"}"
    return 0
  }
  if [ "$label" = "project" ]; then
    real_lib_dir="$(cd "$_PROJECT_LIB" 2>/dev/null && pwd -P)" || real_lib_dir="$_PROJECT_LIB"
  else
    real_lib_dir="$(cd "$_SHIPPED_LIB" 2>/dev/null && pwd -P)" || real_lib_dir="$_SHIPPED_LIB"
  fi
  case "$real_rule_dir" in
    "$real_lib_dir"/*)
      ;; # inside the library
    *)
      _LIB_ERRORS="${_LIB_ERRORS:+$_LIB_ERRORS,}{\"rule\":\"${rule_id}\",\"reason\":\"path resolves outside the ${label} library (refused)\"}"
      return 0
      ;;
  esac

  # Must have a rule file.
  local has_rule=false
  [ -f "$rule_dir/rule.yml" ] && has_rule=true
  [ -f "$rule_dir/rule.lint" ] && has_rule=true
  if [ "$has_rule" = "false" ]; then
    _LIB_ERRORS="${_LIB_ERRORS:+$_LIB_ERRORS,}{\"rule\":\"${rule_id}\",\"reason\":\"no rule.yml or rule.lint found\"}"
    return 0
  fi

  # Must have a test/ directory.
  if [ ! -d "$rule_dir/test" ]; then
    _LIB_ERRORS="${_LIB_ERRORS:+$_LIB_ERRORS,}{\"rule\":\"${rule_id}\",\"reason\":\"test/ directory missing\"}"
    return 0
  fi

  # For semgrep rules (rule.yml): must have at least one must-fire fixture
  # (containing "ruleid:") and one must-not-fire fixture (containing "ok:").
  if [ -f "$rule_dir/rule.yml" ]; then
    local has_fire=false has_nofire=false
    local f
    for f in "$rule_dir/test"/*; do
      [ -f "$f" ] || continue
      if grep -q 'ruleid:' "$f" 2>/dev/null; then
        has_fire=true
      fi
      if grep -q 'ok:' "$f" 2>/dev/null; then
        has_nofire=true
      fi
    done
    if [ "$has_fire" = "false" ]; then
      _LIB_ERRORS="${_LIB_ERRORS:+$_LIB_ERRORS,}{\"rule\":\"${rule_id}\",\"reason\":\"no must-fire fixture (file with ruleid: annotation) in test/\"}"
    fi
    if [ "$has_nofire" = "false" ]; then
      _LIB_ERRORS="${_LIB_ERRORS:+$_LIB_ERRORS,}{\"rule\":\"${rule_id}\",\"reason\":\"no must-not-fire fixture (file with ok: annotation) in test/\"}"
    fi
  fi

  # For lint-pack rules (rule.lint): must have test/fire.* and test/nofire.*.
  if [ -f "$rule_dir/rule.lint" ]; then
    local has_fire=false has_nofire=false
    local f
    for f in "$rule_dir/test"/fire.*; do
      [ -f "$f" ] && has_fire=true
    done
    for f in "$rule_dir/test"/nofire.*; do
      [ -f "$f" ] && has_nofire=true
    done
    if [ "$has_fire" = "false" ]; then
      _LIB_ERRORS="${_LIB_ERRORS:+$_LIB_ERRORS,}{\"rule\":\"${rule_id}\",\"reason\":\"no must-fire fixture (test/fire.*) found\"}"
    fi
    if [ "$has_nofire" = "false" ]; then
      _LIB_ERRORS="${_LIB_ERRORS:+$_LIB_ERRORS,}{\"rule\":\"${rule_id}\",\"reason\":\"no must-not-fire fixture (test/nofire.*) found\"}"
    fi
  fi
}

# Scan a library directory and validate every rule.
# Usage: _scan_library <lib_dir> <label>
_scan_library() {
  local lib_dir="$1" label="$2"
  [ -d "$lib_dir" ] || return 0
  local d
  for d in "$lib_dir"/*/; do
    [ -d "$d" ] || continue
    _validate_rule_dir "$d" "$label"
  done
}

# ---------------------------------------------------------------------------
# Subcommand: library-check
# ---------------------------------------------------------------------------

_cmd_library_check() {
  _LIB_ERRORS=""
  local semgrep_note=""

  _scan_library "$_SHIPPED_LIB" "shipped"
  _scan_library "$_PROJECT_LIB" "project"

  # When semgrep is not installed, note that fixture execution is deferred to CI.
  if ! command -v semgrep >/dev/null 2>&1; then
    semgrep_note="semgrep not installed; structural checks ran but fixture execution deferred to CI"
  fi

  # Build JSON result.
  local errors_json="[]"
  if [ -n "$_LIB_ERRORS" ]; then
    errors_json="[${_LIB_ERRORS}]"
  fi

  local note_field=""
  if [ -n "$semgrep_note" ]; then
    note_field="$(printf ',\"note\":\"%s\"' "$semgrep_note")"
  fi

  printf '{"version":1,"library_errors":%s%s}\n' "$errors_json" "$note_field"

  if [ -n "$_LIB_ERRORS" ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Subcommand: story-check
# ---------------------------------------------------------------------------

_cmd_story_check() {
  local story_key=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) story_key="$2"; shift 2 ;;
      *) _die 2 "story-check: unknown argument: $1" ;;
    esac
  done
  [ -n "$story_key" ] || _die 2 "story-check: --story is required"

  # Resolve register path.
  local reg_path
  reg_path="$("$SCRIPT_DIR/resolve-review-report-path.sh" --key "$story_key" --type findings-register 2>/dev/null)" || _die 2 "story-check: cannot resolve register for $story_key"
  if [ ! -f "$reg_path" ]; then
    # No register = no findings = pass.
    printf '{"version":1,"missing":[],"library_errors":[]}\n'
    return 0
  fi

  command -v yq >/dev/null 2>&1 || _die 2 "story-check: yq is required"
  command -v jq >/dev/null 2>&1 || _die 2 "story-check: jq is required"

  # Read entries with pattern_class and critical/high severity.
  local entries_json
  entries_json="$(yq -o=json '.entries' "$reg_path" 2>/dev/null)" || _die 2 "story-check: cannot read register entries"

  local pattern_entries
  pattern_entries="$(printf '%s' "$entries_json" | jq -c '[.[] | select(.pattern_class != null and .pattern_class != "" and (.severity == "critical" or .severity == "high"))]' 2>/dev/null)" || _die 2 "story-check: jq filter failed"

  local count
  count="$(printf '%s' "$pattern_entries" | jq 'length' 2>/dev/null)" || count=0

  if [ "$count" = "0" ]; then
    printf '{"version":1,"missing":[],"library_errors":[]}\n'
    return 0
  fi

  # Check git availability for the "rule changed since finding" check.
  local in_git=false repo_dir=""
  repo_dir="${PROJECT_PATH:-$PROJECT_ROOT}"
  if command -v git >/dev/null 2>&1; then
    if git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      in_git=true
    fi
  fi

  local missing=""
  local i=0
  while [ "$i" -lt "$count" ]; do
    local entry
    entry="$(printf '%s' "$pattern_entries" | jq -c ".[$i]" 2>/dev/null)"
    local entry_id pattern_class run_id
    entry_id="$(printf '%s' "$entry" | jq -r '.id' 2>/dev/null)"
    pattern_class="$(printf '%s' "$entry" | jq -r '.pattern_class' 2>/dev/null)"
    run_id="$(printf '%s' "$entry" | jq -r '.run_id // ""' 2>/dev/null)"

    # Check for linked rules.
    local rules
    rules="$(printf '%s' "$entry" | jq -c '.regression_rules // []' 2>/dev/null)" || rules="[]"
    local rule_count
    rule_count="$(printf '%s' "$rules" | jq 'length' 2>/dev/null)" || rule_count=0

    if [ "$rule_count" = "0" ]; then
      missing="${missing:+$missing,}{\"entry\":\"${entry_id}\",\"pattern_class\":\"${pattern_class}\",\"reason\":\"no linked rule\"}"
      i=$((i + 1))
      continue
    fi

    # Check each linked rule exists and has changed since the finding.
    local r=0
    while [ "$r" -lt "$rule_count" ]; do
      local rule_id
      rule_id="$(printf '%s' "$rules" | jq -r ".[$r]" 2>/dev/null)"

      # Rule must exist in shipped or project library.
      local rule_found=false
      [ -d "$_SHIPPED_LIB/$rule_id" ] && rule_found=true
      [ -d "$_PROJECT_LIB/$rule_id" ] && rule_found=true

      if [ "$rule_found" = "false" ]; then
        missing="${missing:+$missing,}{\"entry\":\"${entry_id}\",\"pattern_class\":\"${pattern_class}\",\"reason\":\"linked rule ${rule_id} not found in any library\"}"
        r=$((r + 1))
        continue
      fi

      # The rule (or its tests) must have changed since the finding's round.
      if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
        # No run_id on the entry: fail closed (round unknown).
        missing="${missing:+$missing,}{\"entry\":\"${entry_id}\",\"pattern_class\":\"${pattern_class}\",\"reason\":\"round unknown for entry ${entry_id} (no run_id)\"}"
        r=$((r + 1))
        continue
      fi

      if [ "$in_git" = "false" ]; then
        # Non-git workspace: fail closed (AC-EC5).
        missing="${missing:+$missing,}{\"entry\":\"${entry_id}\",\"pattern_class\":\"${pattern_class}\",\"reason\":\"rule change could not be verified (non-git workspace)\"}"
        r=$((r + 1))
        continue
      fi

      # Resolve the round's commit SHA from the register.
      local round_sha=""
      round_sha="$(yq -o=json ".rounds[] | select(.run_id == \"${run_id}\") | .commit_sha" "$reg_path" 2>/dev/null | jq -r '.' 2>/dev/null)" || round_sha=""

      if [ -z "$round_sha" ] || [ "$round_sha" = "null" ]; then
        missing="${missing:+$missing,}{\"entry\":\"${entry_id}\",\"pattern_class\":\"${pattern_class}\",\"reason\":\"round unknown for entry ${entry_id} (round SHA not found for ${run_id})\"}"
        r=$((r + 1))
        continue
      fi

      # Check whether the rule directory changed between round_sha and HEAD.
      local rule_dir_rel=""
      if [ -d "$_SHIPPED_LIB/$rule_id" ]; then
        # Compute relative path from repo root.
        local repo_root
        repo_root="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" || repo_root="$repo_dir"
        local shipped_real
        shipped_real="$(cd "$_SHIPPED_LIB/$rule_id" && pwd -P)"
        rule_dir_rel="${shipped_real#"$repo_root"/}"
      elif [ -d "$_PROJECT_LIB/$rule_id" ]; then
        local repo_root
        repo_root="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" || repo_root="$repo_dir"
        local proj_real
        proj_real="$(cd "$_PROJECT_LIB/$rule_id" && pwd -P)"
        rule_dir_rel="${proj_real#"$repo_root"/}"
      fi

      if [ -n "$rule_dir_rel" ]; then
        local diff_count=0
        diff_count="$(git -C "$repo_dir" log --oneline "${round_sha}..HEAD" -- "$rule_dir_rel" 2>/dev/null | wc -l | tr -d ' ')" || diff_count=0
        if [ "$diff_count" = "0" ]; then
          missing="${missing:+$missing,}{\"entry\":\"${entry_id}\",\"pattern_class\":\"${pattern_class}\",\"reason\":\"rule ${rule_id} not updated in the fix (no changes since round ${run_id})\"}"
        fi
      fi

      r=$((r + 1))
    done

    i=$((i + 1))
  done

  # Build result.
  local missing_json="[]"
  if [ -n "$missing" ]; then
    missing_json="[${missing}]"
  fi

  printf '{"version":1,"missing":%s,"library_errors":[]}\n' "$missing_json"

  if [ -n "$missing" ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

_usage() {
  cat >&2 <<EOF
$SCRIPT_NAME — regression-rule gate for the review pipeline.

Subcommands:
  enabled                          Print "on" or "off"
  story-check --story <key>        Check pattern findings have linked rules
  library-check                    Validate rule libraries

Exit codes:
  0 — all checks pass (or gate turned off)
  1 — one or more checks failed
  2 — usage/configuration error
EOF
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
  enabled) shift; _cmd_enabled "$@" ;;
  story-check) shift; _cmd_story_check "$@" ;;
  library-check) shift; _cmd_library_check "$@" ;;
  -h|--help) _usage; exit 0 ;;
  "") _die 2 "missing subcommand; use --help" ;;
  *) _die 2 "unknown subcommand: $1" ;;
esac
