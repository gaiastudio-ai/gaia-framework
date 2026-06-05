#!/usr/bin/env bash
# assert-protected-jobs.sh — Reject gaia-*.user-jobs.yml overlays that
# declare a job-name colliding with a GAIA-template (protected) job name.
# Implements collision detection with a fail-closed contract.
#
# Sourceable, NOT executable.
#
# Exposes one function:
#   assert_protected_jobs <user-jobs-yml>
#     Exits 0 when the overlay declares no protected job names.
#     Exits 1 with stderr `assert-protected-jobs.sh: protected job name
#     collision: <job> declared in <file> — rename the user-job to a
#     non-colliding name.` on collision.
#
# Protected-jobs list: ${CLAUDE_PLUGIN_ROOT:-<derived>}/templates/ci/protected-jobs.txt
# One job-name per line. `#` comments and blank lines ignored.
#
# Source guard: _GAIA_ASSERT_PROTECTED_JOBS_LOADED=1 after first source;
# subsequent sources are no-ops.

if [ "${_GAIA_ASSERT_PROTECTED_JOBS_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_ASSERT_PROTECTED_JOBS_LOADED=1

LC_ALL=C
export LC_ALL

# Resolve the protected-jobs list path. Prefer CLAUDE_PLUGIN_ROOT when set
# (production callers), else derive from this script's location.
_gaia_apj_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_GAIA_APJ_LIST_DEFAULT="${_gaia_apj_dir}/../../templates/ci/protected-jobs.txt"

_gaia_apj_load_protected() {
  local list="${GAIA_PROTECTED_JOBS_LIST:-}"
  if [ -z "$list" ]; then
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/templates/ci/protected-jobs.txt" ]; then
      list="${CLAUDE_PLUGIN_ROOT}/templates/ci/protected-jobs.txt"
    else
      list="$_GAIA_APJ_LIST_DEFAULT"
    fi
  fi
  if [ ! -f "$list" ]; then
    printf 'assert-protected-jobs.sh: protected-jobs list not found: %s\n' "$list" >&2
    return 1
  fi
  # Print one job-name per line, stripping comments + blanks.
  awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} {print $1}' "$list"
}

# Extract top-level job-names from a user-jobs.yml file. Uses yq when
# available for correctness, falls back to a tolerant awk parser.
_gaia_apj_extract_job_names() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf 'assert-protected-jobs.sh: overlay file not found: %s\n' "$file" >&2
    return 1
  fi
  if command -v yq >/dev/null 2>&1; then
    # `keys` over .jobs returns one job-name per output line.
    yq eval '.jobs | keys | .[]' "$file" 2>/dev/null || true
    return 0
  fi
  # Fallback: awk-extract job-names under `jobs:` (one indent in, ends at
  # next top-level key or EOF).
  awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs && /^[A-Za-z_][A-Za-z0-9_-]*:/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:/ {
      gsub(/^[[:space:]]+/, "")
      sub(/:.*$/, "")
      print
    }
  ' "$file"
}

assert_protected_jobs() {
  local file="${1:-}"
  if [ -z "$file" ]; then
    printf 'assert-protected-jobs.sh: usage: assert_protected_jobs <user-jobs-yml>\n' >&2
    return 2
  fi

  # Load protected-jobs list into a newline-delimited string.
  local protected
  protected="$(_gaia_apj_load_protected)" || return 2

  # Extract user-jobs names into a newline-delimited string.
  local user_jobs
  user_jobs="$(_gaia_apj_extract_job_names "$file")" || return 2

  if [ -z "$user_jobs" ]; then
    # Empty overlay (no jobs declared) — vacuously safe.
    return 0
  fi

  # Compute the collision set: lines present in both lists.
  local collisions
  collisions="$(printf '%s\n' "$user_jobs" \
    | grep -Fxf <(printf '%s\n' "$protected") 2>/dev/null \
    | sort -u)"

  if [ -z "$collisions" ]; then
    return 0
  fi

  # At least one collision — emit the actionable error and fail-close.
  local short_name
  short_name="$(basename "$file")"
  while IFS= read -r job; do
    [ -z "$job" ] && continue
    printf 'assert-protected-jobs.sh: protected job name collision: %s declared in %s — rename the user-job to a non-colliding name.\n' \
      "$job" "$short_name" >&2
  done <<< "$collisions"
  return 1
}
