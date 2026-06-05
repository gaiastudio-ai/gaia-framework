#!/usr/bin/env bash
# template-overrides.sh — ci_cd.template_overrides interpreter.
#
# Sourceable, NOT executable. Exposes:
#
#   gaia_apply_template_overrides <managed-yml> <project-config-yaml>
#     Reads ci_cd.template_overrides from <project-config-yaml> and applies
#     the three override passes against <managed-yml>, emitting the resulting
#     workflow on stdout:
#       (1) disable: [...]         — remove named jobs from jobs: map
#       (2) timeout_overrides:{}   — rewrite timeout-minutes per job
#       (3) adapter_versions:{}    — pin adapter version in job invocations
#
# Security-critical job enforcement: the canonical 5-name closed enum
# of security-critical jobs is hard-coded below. Any disable: entry that
# matches (after hyphen+case canonicalization) is REJECTED with a non-zero
# exit and an actionable stderr message.
#
# Per-field validation:
#   - Unknown disable name              → WARNING (graceful)
#   - timeout out of 1..360             → HARD ERROR
#   - Unknown adapter_versions key      → HARD ERROR (typo guard)
#   - Unparseable semver in adapter_v   → HARD ERROR
#
# Source guard: _GAIA_TEMPLATE_OVERRIDES_LOADED=1 after first source.

if [ "${_GAIA_TEMPLATE_OVERRIDES_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_TEMPLATE_OVERRIDES_LOADED=1

LC_ALL=C
export LC_ALL

# Canonical closed enum of security-critical job names (per threat-model.md:1473).
# Stored as a string of space-separated names so we can iterate without
# requiring bash arrays in callers.
_GAIA_SR78_CRITICAL="commitlint adr-048-guard no-claude-attribution secrets-scan nfr-082-credential-audit"

# Canonicalize a job name for security-critical enum check: lowercase + strip hyphens.
# So `commit-lint`, `commitlint`, and `Commit-Lint` all collapse to the
# same token (refusal-bypass guard).
_gaia_to_canonical() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '-'
}

# Check: is the given disable-entry security-critical?
# Exits 0 (true) on match, 1 (false) otherwise.
_gaia_is_sr78_critical() {
  local input="$1"
  local input_canon
  input_canon=$(_gaia_to_canonical "$input")
  local n n_canon
  for n in $_GAIA_SR78_CRITICAL; do
    n_canon=$(_gaia_to_canonical "$n")
    [ "$input_canon" = "$n_canon" ] && return 0
  done
  return 1
}

# Semver match (loose: MAJOR.MINOR.PATCH with optional prerelease/build).
_gaia_is_semver() {
  printf '%s' "$1" \
    | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
}

# Internal: known adapter names. Closed list — unknown adapter name
# → HARD ERROR (pinning to a non-existent adapter is always a typo).
_GAIA_KNOWN_ADAPTERS="markdownlint shellcheck bats yq jq actionlint"

_gaia_is_known_adapter() {
  local input="$1"
  local n
  for n in $_GAIA_KNOWN_ADAPTERS; do
    [ "$input" = "$n" ] && return 0
  done
  return 1
}

# Remove a single named job from a workflow's jobs: map. Pure yq.
_gaia_remove_job() {
  local file="$1"
  local job="$2"
  yq eval "del(.jobs.\"${job}\")" "$file"
}

# Set timeout-minutes for a single named job. Pure yq.
_gaia_set_timeout() {
  local file="$1"
  local job="$2"
  local minutes="$3"
  yq eval ".jobs.\"${job}\".\"timeout-minutes\" = ${minutes}" "$file"
}

# Pin adapter version. Applies a per-adapter sed rule on the workflow text
# so the pin survives even if the canonical template uses a non-yq-traversable
# shape (e.g., `run: npm install markdownlint@latest` → `npm install markdownlint@<ver>`).
_gaia_pin_adapter() {
  local content="$1"
  local adapter="$2"
  local version="$3"
  # Match adapter@<anything-non-space> and replace with adapter@<version>.
  printf '%s' "$content" \
    | sed -E "s|${adapter}@[^[:space:]\"]+|${adapter}@${version}|g"
}

gaia_apply_template_overrides() {
  local workflow="${1:-}"
  local config="${2:-}"

  if [ -z "$workflow" ] || [ -z "$config" ]; then
    printf 'template-overrides.sh: usage: gaia_apply_template_overrides <workflow.yml> <project-config.yaml>\n' >&2
    return 2
  fi
  if [ ! -f "$workflow" ]; then
    printf 'template-overrides.sh: workflow file not found: %s\n' "$workflow" >&2
    return 2
  fi
  if [ ! -f "$config" ]; then
    printf 'template-overrides.sh: project-config file not found: %s\n' "$config" >&2
    return 2
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'template-overrides.sh: yq required but not on PATH\n' >&2
    return 2
  fi

  # ---- Phase A: read ci_cd.template_overrides from project-config ----
  local has_overrides
  has_overrides=$(yq eval '.ci_cd.template_overrides // "null"' "$config" 2>/dev/null)
  if [ "$has_overrides" = "null" ]; then
    # No template_overrides → emit workflow unchanged.
    cat "$workflow"
    return 0
  fi

  # ---- Phase B: security-critical closed-enum check (BEFORE any mutation) ----
  local disable_list
  disable_list=$(yq eval '.ci_cd.template_overrides.disable[]? // ""' "$config" 2>/dev/null)
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if _gaia_is_sr78_critical "$entry"; then
      printf 'template-overrides.sh: refusal: cannot disable security-critical job "%s" — closed enum {commitlint, adr-048-guard, no-claude-attribution, secrets-scan, nfr-082-credential-audit}.\n' \
        "$entry" >&2
      return 1
    fi
  done <<< "$disable_list"

  # ---- Phase C: validate timeout_overrides range (BEFORE any mutation) ----
  local timeout_entries
  timeout_entries=$(yq eval -o=props '.ci_cd.template_overrides.timeout_overrides // {}' "$config" 2>/dev/null)
  local line job_name minutes
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    job_name="${line%% = *}"
    minutes="${line##* = }"
    # Numeric check
    if ! printf '%s' "$minutes" | grep -Eq '^[0-9]+$'; then
      printf 'template-overrides.sh: timeout_overrides[%s]: not an integer: %s\n' \
        "$job_name" "$minutes" >&2
      return 1
    fi
    if [ "$minutes" -lt 1 ] || [ "$minutes" -gt 360 ]; then
      printf 'template-overrides.sh: timeout_overrides[%s]: %s minutes out of range [1, 360]\n' \
        "$job_name" "$minutes" >&2
      return 1
    fi
  done <<< "$timeout_entries"

  # ---- Phase D: validate adapter_versions (BEFORE any mutation) ----
  local adapter_entries
  adapter_entries=$(yq eval -o=props '.ci_cd.template_overrides.adapter_versions // {}' "$config" 2>/dev/null)
  local adapter_name adapter_ver
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    adapter_name="${line%% = *}"
    adapter_ver="${line##* = }"
    if ! _gaia_is_known_adapter "$adapter_name"; then
      printf 'template-overrides.sh: adapter_versions[%s]: unknown adapter name (typo?). Known adapters: %s\n' \
        "$adapter_name" "$_GAIA_KNOWN_ADAPTERS" >&2
      return 1
    fi
    if ! _gaia_is_semver "$adapter_ver"; then
      printf 'template-overrides.sh: adapter_versions[%s]: unparseable semver: %s (expected N.N.N format)\n' \
        "$adapter_name" "$adapter_ver" >&2
      return 1
    fi
  done <<< "$adapter_entries"

  # ---- Phase E: apply disable pass (warn on unknown names) ----
  local current
  current=$(cat "$workflow")
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    # Check whether the job exists in the workflow.
    local exists
    exists=$(printf '%s' "$current" | yq eval ".jobs | has(\"${entry}\")" - 2>/dev/null)
    if [ "$exists" != "true" ]; then
      printf 'template-overrides.sh: WARNING: disable: unknown job name "%s" — skipping\n' \
        "$entry" >&2
      continue
    fi
    current=$(printf '%s' "$current" | yq eval "del(.jobs.\"${entry}\")" -)
  done <<< "$disable_list"

  # ---- Phase F: apply timeout_overrides pass ----
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    job_name="${line%% = *}"
    minutes="${line##* = }"
    local job_exists
    job_exists=$(printf '%s' "$current" | yq eval ".jobs | has(\"${job_name}\")" - 2>/dev/null)
    if [ "$job_exists" != "true" ]; then
      printf 'template-overrides.sh: WARNING: timeout_overrides: unknown job name "%s" — skipping\n' \
        "$job_name" >&2
      continue
    fi
    current=$(printf '%s' "$current" | yq eval ".jobs.\"${job_name}\".\"timeout-minutes\" = ${minutes}" -)
  done <<< "$timeout_entries"

  # ---- Phase G: apply adapter_versions pass (sed-based, on workflow text) ----
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    adapter_name="${line%% = *}"
    adapter_ver="${line##* = }"
    current=$(_gaia_pin_adapter "$current" "$adapter_name" "$adapter_ver")
  done <<< "$adapter_entries"

  printf '%s\n' "$current"
}
