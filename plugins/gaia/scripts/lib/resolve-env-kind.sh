#!/usr/bin/env bash
# resolve-env-kind.sh — env-kind discriminator resolver
# (E99-S1, FR-520, ADR-112 §(a), NFR-080).
#
# Sourceable, NOT executable. Exposes one function:
#
#   gaia_resolve_env_kind <project-config.yaml> <env-id>
#     Looks up environments[] entry by id and returns the resolved kind on
#     stdout. Resolution rules per FR-520 + ADR-112 §(a) + NFR-080:
#       - Field present + value in {deployable, branch-only, distribution-only}
#         → return verbatim, exit 0
#       - Field absent → return "deployable" (read-time default per NFR-080
#         silent back-compat), exit 0, NO stderr WARNING (the WARNING lives
#         in /gaia-config-validate per E99-S6 / TC-EKD-5)
#       - Field present but value NOT in the closed enum → exit 1 with a
#         FATAL stderr message that lists the 3 legal values and cites
#         ADR-112; NEVER silently coerce to deployable
#       - env-id not found in environments[] → exit 1 with a clear error
#
# Separated from lib/gaia-paths.sh per AC7: env-kind is a config concern
# (project-config.yaml semantic discriminator); path resolution
# (lib/gaia-paths.sh) is a separate concern owned by ADR-111.
#
# Source guard: _GAIA_RESOLVE_ENV_KIND_LOADED=1 after first source.

if [ "${_GAIA_RESOLVE_ENV_KIND_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_RESOLVE_ENV_KIND_LOADED=1

LC_ALL=C
export LC_ALL

# The canonical 3-value closed enum per FR-520 + ADR-112 §(a). NEVER extend
# this list inline — a new shape lands via a future ADR amendment + schema
# bump, not a silent code change.
_GAIA_ENV_KIND_LEGAL="deployable branch-only distribution-only"

# Default applied at read time when kind is absent (NFR-080 zero-breakage).
_GAIA_ENV_KIND_DEFAULT="deployable"

# Internal: emit a canonical FATAL error citing the closed enum.
_gaia_env_kind_die_invalid() {
  local config="$1"
  local env_id="$2"
  local actual="$3"
  printf 'resolve-env-kind.sh: invalid kind %s for environment %s in %s — closed enum per ADR-112 §(a) accepts only {deployable, branch-only, distribution-only}\n' \
    "$actual" "$env_id" "$config" >&2
  return 1
}

gaia_resolve_env_kind() {
  local config="${1:-}"
  local env_id="${2:-}"

  if [ -z "$config" ]; then
    printf 'resolve-env-kind.sh: usage: gaia_resolve_env_kind <project-config.yaml> <env-id>\n' >&2
    return 2
  fi
  if [ -z "$env_id" ]; then
    printf 'resolve-env-kind.sh: usage: gaia_resolve_env_kind <project-config.yaml> <env-id>\n' >&2
    return 2
  fi
  if [ ! -f "$config" ]; then
    printf 'resolve-env-kind.sh: config file not found: %s\n' "$config" >&2
    return 2
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'resolve-env-kind.sh: yq required but not on PATH\n' >&2
    return 2
  fi

  # First, verify the env-id exists in environments[].
  local exists
  exists=$(yq eval ".environments[]? | select(.id == \"${env_id}\") | .id" "$config" 2>/dev/null)
  if [ -z "$exists" ]; then
    printf 'resolve-env-kind.sh: environment id %s not found in environments[] of %s\n' \
      "$env_id" "$config" >&2
    return 1
  fi

  # Read the kind value (or "null" sentinel from yq when absent).
  local kind
  kind=$(yq eval ".environments[]? | select(.id == \"${env_id}\") | .kind // \"\"" "$config" 2>/dev/null)

  # Field absent → apply NFR-080 silent default.
  if [ -z "$kind" ] || [ "$kind" = "null" ]; then
    printf '%s\n' "$_GAIA_ENV_KIND_DEFAULT"
    return 0
  fi

  # Field present → must be one of the 3 legal values.
  local n
  for n in $_GAIA_ENV_KIND_LEGAL; do
    if [ "$kind" = "$n" ]; then
      printf '%s\n' "$kind"
      return 0
    fi
  done

  # Unknown value → FATAL (never silently coerce).
  _gaia_env_kind_die_invalid "$config" "$env_id" "$kind"
  return 1
}
