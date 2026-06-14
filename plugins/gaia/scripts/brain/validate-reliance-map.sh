#!/usr/bin/env bash
# validate-reliance-map.sh — structural validation for a brain-reliance-map.yaml
# (the hand-authored consultation policy: the single stage -> required-node
# source of truth).
#
# Unlike the brain index, this file is hand-authored policy the reindex sweep
# never regenerates, so it lacks the correct-by-construction overwrite backstop
# every other knowledge-store file enjoys. Its tamper-evidence controls are
# therefore external: it is git-tracked, CODEOWNERS-protected, and — enforced
# here — closed-enum schema-validated. The single load-bearing structural
# invariant is the CLOSED obligation enum: every reliance's `obligation` MUST be
# one of {MANDATORY, OPTIONAL}; an out-of-enum value is a tamper signal and a
# schema violation.
#
# The check delegates to the shared scripts/lib/validate-artifact-schema.sh
# primitive against schemas/brain-reliance-map.schema.json (ajv -> python3 +
# jsonschema -> graceful SKIP), exactly mirroring validate-brain-index.sh. The
# schema's `additionalProperties: false` on each reliance entry rejects stray
# fields, and the obligation `enum` rejects out-of-enum values.
#
# Exit-code contract (matches the shared schema primitive):
#   0 — map VALID (structural pass)
#   1 — map INVALID (structural finding, e.g. an out-of-enum obligation)
#   2 — usage error (missing/unreadable args)
#   3 — SKIP (no JSON-schema validator backend available; structural check skipped)
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags. LC_ALL=C. set -euo pipefail.

set -euo pipefail
LC_ALL=C
export LC_ALL

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_LIB_DIR="$(cd "$_SELF_DIR/../lib" && pwd)"
_SCHEMA_DIR="$(cd "$_SELF_DIR/../../schemas" && pwd)"
_SCHEMA="$_SCHEMA_DIR/brain-reliance-map.schema.json"

_vrm_die() {
  printf 'validate-reliance-map.sh: %s\n' "$1" >&2
  return "${2:-2}"
}

_vrm_main() {
  local map="${1:-}"

  if [ -z "$map" ]; then
    _vrm_die "usage: validate-reliance-map.sh <brain-reliance-map.yaml>" 2
    return 2
  fi
  if [ ! -r "$map" ]; then
    _vrm_die "reliance map not readable: $map" 2
    return 2
  fi
  if [ ! -r "$_SCHEMA" ]; then
    _vrm_die "schema not readable: $_SCHEMA" 2
    return 2
  fi

  # Source the shared schema validator (idempotent, sourceable-not-executable).
  # shellcheck source=../lib/validate-artifact-schema.sh
  . "$_LIB_DIR/validate-artifact-schema.sh" \
    || { _vrm_die "could not source validate-artifact-schema.sh" 2; return 2; }

  local schema_rc=0
  validate_artifact_schema "$_SCHEMA" "$map" || schema_rc=$?
  return "$schema_rc"
}

_vrm_main "$@"
exit $?
