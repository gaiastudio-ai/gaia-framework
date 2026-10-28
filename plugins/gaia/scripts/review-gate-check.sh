#!/usr/bin/env bash
# review-gate-check.sh — commit-bound composite Review Gate checker
#
# Reads the Review Gate table from a story file and checks whether every
# canonical row is PASSED and bound to the current head SHA. Returns a
# composite verdict:
#
#   COMPLETE — all 6 rows PASSED, all bound to --bind-head, CI green
#   PENDING  — at least one row is stale (reviewed on an older SHA) or
#              UNVERIFIED, and no row is FAILED
#   BLOCKED  — at least one row is FAILED
#
# Usage:
#   review-gate-check.sh --bind-head <sha> --ci-sha <sha> --story <file>
#   review-gate-check.sh --help
#
# Flags:
#   --bind-head <sha>  The commit SHA that all reviews must be bound to.
#                      Must be a real hex SHA (not "none"). Compared
#                      literally against the stored SHA — callers should
#                      pass the full-length SHA for a reliable match.
#   --ci-sha <sha>     The SHA of the CI run. Must match --bind-head for
#                      COMPLETE, or "none" ONLY when no CI is configured
#                      (no promotion chain in project config).
#   --story <file>     Path to the story markdown file.
#
# Exit codes:
#   0 — COMPLETE
#   1 — BLOCKED or error
#   2 — PENDING
#
# Read-only: this script never writes to the story file.
# POSIX discipline: bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="review-gate-check.sh"

_RGC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source the dual-shape table parser.
# shellcheck source=lib/review-gate-table.sh
. "${_RGC_DIR}/lib/review-gate-table.sh"

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  review-gate-check.sh --bind-head <sha> --ci-sha <sha> --story <file>
  review-gate-check.sh --help

Composite Review Gate check with commit binding.

Flags:
  --bind-head <sha>  The commit SHA that all reviews must be bound to.
                     Must be a real hex SHA, not "none".
  --ci-sha <sha>     CI run SHA; must match --bind-head, or "none" only
                     when no CI is configured.
  --story <file>     Path to the story markdown file.

Exit codes:
  0 — COMPLETE (all rows PASSED and bound to head, CI matches)
  1 — BLOCKED (any row FAILED) or error
  2 — PENDING (any row stale/UNVERIFIED, no FAILED)
USAGE
}

# Canonical gate names.
CANONICAL_GATES=(
  "Code Review"
  "QA Tests"
  "Security Review"
  "Test Automation"
  "Test Review"
  "Performance Review"
)

# Resolve the project-config.yaml path by walking up from a given directory.
# Checks PROJECT_CONFIG, then PROJECT_ROOT/CLAUDE_PROJECT_ROOT, then walks up
# from the CWD looking for .gaia/config/project-config.yaml.
# Prints the resolved path or empty if not found.
_resolve_config_path() {
  # Explicit env wins.
  if [ -n "${PROJECT_CONFIG:-}" ] && [ -f "${PROJECT_CONFIG}" ]; then
    printf '%s' "$PROJECT_CONFIG"
    return 0
  fi
  # Try the roots.
  local root
  for root in "${PROJECT_ROOT:-}" "${CLAUDE_PROJECT_ROOT:-}"; do
    if [ -n "$root" ] && [ -f "$root/.gaia/config/project-config.yaml" ]; then
      printf '%s' "$root/.gaia/config/project-config.yaml"
      return 0
    fi
  done
  # Walk up from PROJECT_PATH (or CWD).
  local dir
  dir="$(cd "${PROJECT_PATH:-.}" 2>/dev/null && pwd)" || dir=""
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.gaia/config/project-config.yaml" ]; then
      printf '%s' "$dir/.gaia/config/project-config.yaml"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# Check whether CI is configured by reading the promotion chain from config.
# Fail closed: if the config cannot be found, read, or parsed, treat as CI
# configured (--ci-sha none is refused). This prevents an attacker from
# bypassing the CI check by hiding, corrupting or reshaping the config file.
_has_ci_configured() {
  local config_file
  config_file="$(_resolve_config_path)" || config_file=""
  if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
    # Cannot find config → fail closed: treat as CI configured.
    return 0
  fi

  # Fail closed: unreadable file → treat as CI configured.
  if [ ! -r "$config_file" ]; then
    return 0
  fi

  # Fail closed: binary or garbled content → treat as CI configured.
  # A valid YAML config is always a text file. If it contains NUL bytes
  # or cannot be read, refuse --ci-sha none.
  local content
  content="$(cat "$config_file" 2>/dev/null)" || return 0
  if printf '%s' "$content" | LC_ALL=C /usr/bin/grep -qP '\x00' 2>/dev/null; then
    return 0
  fi

  # Check if GAIA_SHARED_CONFIG also has CI (the framework resolver
  # honours it). If the shared config has a promotion chain, CI is
  # configured even when the walk-up file does not have one.
  local shared_file="${GAIA_SHARED_CONFIG:-}"
  if [ -n "$shared_file" ] && [ -f "$shared_file" ] && [ -r "$shared_file" ]; then
    if _config_has_promotion_chain "$shared_file"; then
      return 0
    fi
  fi

  _config_has_promotion_chain "$config_file"
}

# _config_has_promotion_chain <file>
# Return 0 if the file has a ci_cd.promotion_chain with at least one
# entry (block or flow style). Fail closed: if the key is present but
# the shape is unrecognised, treat as configured (return 0).
_config_has_promotion_chain() {
  local file="$1"

  # First check: does the file mention promotion_chain at all?
  if ! /usr/bin/grep -q 'promotion_chain' "$file" 2>/dev/null; then
    # Also check for ci_cd in any form (quoted, flow-mapped, etc.).
    if ! /usr/bin/grep -q 'ci_cd' "$file" 2>/dev/null; then
      return 1
    fi
    # ci_cd present but no promotion_chain → no CI chain.
    return 1
  fi

  # promotion_chain is mentioned. Now determine if it is null or empty.
  # Check for explicit null / empty list patterns that mean "no CI".
  # Only these exact patterns count as "no CI":
  #   promotion_chain: null
  #   promotion_chain: ~
  #   promotion_chain:           (nothing after colon)
  #   promotion_chain: []
  if /usr/bin/grep -qE 'promotion_chain:[[:space:]]*(null|~|)[[:space:]]*$' "$file" 2>/dev/null; then
    # Could be null or bare empty — check it's not followed by list items.
    # If there are list items after promotion_chain: in the ci_cd section,
    # it is configured. Use awk for context.
    if ! awk '
      /^[[:space:]]*ci_cd[[:space:]]*:/ || /^"ci_cd"[[:space:]]*:/ { in_ci = 1; next }
      in_ci && /^[^ \t]/ && !/^[[:space:]]/ { in_ci = 0 }
      in_ci && /promotion_chain[[:space:]]*:/ {
        # Check same-line for null/empty/~
        if ($0 ~ /promotion_chain[[:space:]]*:[[:space:]]*(null|~|)[[:space:]]*$/) {
          in_pc = 1; next
        }
      }
      in_pc && /^[[:space:]]*-/ { found = 1; exit }
      in_pc && /^[^ \t]/ { exit }
      in_pc && /^[[:space:]]*[A-Za-z_]/ { exit }
      END { exit (found ? 0 : 1) }
    ' "$file" 2>/dev/null; then
      return 1
    fi
  fi

  # Check for explicit empty list: promotion_chain: []
  if /usr/bin/grep -qE 'promotion_chain:[[:space:]]*\[\][[:space:]]*$' "$file" 2>/dev/null; then
    return 1
  fi

  # promotion_chain is present and not provably null or empty.
  # Fail closed: treat as CI configured.
  return 0
}

main() {
  local bind_head="" ci_sha="" story_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --bind-head) [ $# -ge 2 ] || die "--bind-head requires a value"; bind_head="$2"; shift 2 ;;
      --ci-sha)    [ $# -ge 2 ] || die "--ci-sha requires a value";    ci_sha="$2";    shift 2 ;;
      --story)     [ $# -ge 2 ] || die "--story requires a value";     story_file="$2"; shift 2 ;;
      --help|-h)   usage; exit 0 ;;
      *)           die "unknown flag: $1" ;;
    esac
  done

  [ -n "$bind_head" ] || die "--bind-head is required"
  [ -n "$ci_sha" ]    || die "--ci-sha is required"
  [ -n "$story_file" ] || die "--story is required"

  # Validate --bind-head BEFORE file check: must be a real hex SHA, not "none".
  case "$bind_head" in
    -*)  die "--bind-head starts with '-' — potential argument injection" ;;
    none) die "--bind-head must be a real commit SHA, not 'none'" ;;
  esac
  if ! printf '%s' "$bind_head" | grep -qE '^[0-9a-fA-F]{4,40}$'; then
    die "--bind-head must be a hex SHA (4-40 hex chars), got '$bind_head'"
  fi

  # Validate --ci-sha: "none" only allowed in no-CI mode.
  if [ "$ci_sha" = "none" ]; then
    if _has_ci_configured; then
      die "--ci-sha none is not accepted when CI is configured (promotion chain present); pass the CI run SHA"
    fi
  else
    case "$ci_sha" in
      -*) die "--ci-sha starts with '-' — potential argument injection" ;;
    esac
    if ! printf '%s' "$ci_sha" | grep -qE '^[0-9a-fA-F]{4,40}$'; then
      die "--ci-sha must be a hex SHA or 'none', got '$ci_sha'"
    fi
  fi

  [ -f "$story_file" ] || die "story file not found: $story_file"

  # Parse the table.
  local rows_tsv
  rows_tsv="$(parse_review_gate_table "$story_file")" \
    || die "failed to parse Review Gate table in $story_file"

  # Build parallel arrays from parsed rows.
  local -a gates=() statuses=() shas=()
  local gate status _report sha
  while IFS=$'\t' read -r gate status _report sha; do
    [ -z "$gate" ] && continue
    gates+=("$gate")
    statuses+=("$status")
    shas+=("$sha")
  done <<< "$rows_tsv"

  # Verify all 6 canonical gates are present.
  local cg found i
  for cg in "${CANONICAL_GATES[@]}"; do
    found=0
    i=0
    while [ "$i" -lt "${#gates[@]}" ]; do
      if [ "${gates[$i]}" = "$cg" ]; then
        found=1
        break
      fi
      i=$((i + 1))
    done
    if [ "$found" -eq 0 ]; then
      die "missing canonical gate row: $cg"
    fi
  done

  # Classify each row.
  # Binding comes from the table's Reviewed SHA column: carry-forward writes
  # the to-SHA directly into the table row (and the sidecar is the audit record,
  # not the binding source). No sidecar lookup is needed here.
  local has_failed=0 has_pending=0
  local pending_list="" blocked_list=""
  i=0
  while [ "$i" -lt "${#gates[@]}" ]; do
    local g="${gates[$i]}"
    local s="${statuses[$i]}"
    local row_sha="${shas[$i]}"

    # Check if this is a canonical gate.
    local is_canonical=0
    for cg in "${CANONICAL_GATES[@]}"; do
      if [ "$g" = "$cg" ]; then is_canonical=1; break; fi
    done
    if [ "$is_canonical" -eq 0 ]; then
      i=$((i + 1))
      continue
    fi

    if [ "$s" = "FAILED" ]; then
      has_failed=1
      blocked_list="${blocked_list}  - ${g}\n"
    elif [ "$s" = "UNVERIFIED" ] || [ "$s" = "NOT STARTED" ]; then
      has_pending=1
      pending_list="${pending_list}  - ${g} (unverified)\n"
    elif [ "$s" = "PASSED" ]; then
      # Check SHA binding. Binding is determined solely from the table's
      # Reviewed SHA column (carry-forward writes the to-SHA into the table).
      if [ "$row_sha" = "absent" ] || [ -z "$row_sha" ]; then
        has_pending=1
        pending_list="${pending_list}  - ${g} (no SHA — stale)\n"
      elif [ "$row_sha" != "$bind_head" ]; then
        has_pending=1
        pending_list="${pending_list}  - ${g} (reviewed on ${row_sha}, head is ${bind_head} — stale)\n"
      fi
      # If SHA matches bind-head, the row is directly bound.
    else
      has_pending=1
      pending_list="${pending_list}  - ${g} (unknown verdict: ${s})\n"
    fi
    i=$((i + 1))
  done

  # CI SHA check: "none" is only valid when no CI is configured (checked above).
  # When ci_sha is "none" AND no CI is configured, it's acceptable (no CI binding).
  # When ci_sha is a real SHA, it must match bind_head.
  if [ "$ci_sha" != "none" ] && [ "$ci_sha" != "$bind_head" ]; then
    has_pending=1
    pending_list="${pending_list}  - CI SHA mismatch (ci=${ci_sha}, head=${bind_head})\n"
  fi

  # Emit verdict.
  if [ "$has_failed" -eq 1 ]; then
    printf 'Review Gate: BLOCKED\n'
    printf 'Blocking gates:\n'
    printf '%b' "$blocked_list"
    exit 1
  elif [ "$has_pending" -eq 1 ]; then
    printf 'Review Gate: PENDING\n'
    printf 'Pending gates:\n'
    printf '%b' "$pending_list"
    exit 2
  else
    printf 'Review Gate: COMPLETE\n'
    exit 0
  fi
}

main "$@"
