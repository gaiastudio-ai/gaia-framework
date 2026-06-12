#!/usr/bin/env bash
# validate-brain-index.sh — structural + index-in-place validation for a
# brain-index.yaml manifest (the brain knowledge layer's single source of
# truth).
#
# Two checks:
#   1. Structural — delegate to the shared scripts/lib/validate-artifact-schema.sh
#      primitive against schemas/brain-index.schema.json (ajv → python3 +
#      jsonschema → graceful SKIP). This enforces the closed enums (source_type,
#      edge type), the required entry fields, and the required trust block.
#   2. Index-in-place guard — a JSON-Schema-inexpressible runtime check: every
#      `project-artifact` entry's `path`, resolved against the project root,
#      MUST NOT fall inside ${GAIA_KNOWLEDGE_DIR}. The Brain indexes artifacts
#      IN PLACE and never copies bytes into the knowledge namespace.
#
# Path resolution and canonicalization route through scripts/lib/gaia-paths.sh
# (no hard-coded .gaia/ literals); the manifest's relative entry paths resolve
# against the project root that helper computes.
#
# Exit-code contract (matches the shared schema primitive):
#   0 — manifest VALID (structural pass AND no project-artifact path inside knowledge)
#   1 — manifest INVALID (structural finding OR an index-in-place violation)
#   2 — usage error (missing/unreadable args, parse failure, missing YAML tooling)
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
_SCHEMA="$_SCHEMA_DIR/brain-index.schema.json"

_vbi_die() {
  printf 'validate-brain-index.sh: %s\n' "$1" >&2
  return "${2:-2}"
}

_vbi_main() {
  local manifest="${1:-}"

  if [ -z "$manifest" ]; then
    _vbi_die "usage: validate-brain-index.sh <brain-index.yaml>" 2
    return 2
  fi
  if [ ! -r "$manifest" ]; then
    _vbi_die "manifest not readable: $manifest" 2
    return 2
  fi
  if [ ! -r "$_SCHEMA" ]; then
    _vbi_die "schema not readable: $_SCHEMA" 2
    return 2
  fi

  # Source the canonical path helper (canonicalize + under-root primitives,
  # GAIA_KNOWLEDGE_DIR) and the shared schema validator. Both are idempotent
  # and sourceable-not-executable.
  # shellcheck source=../lib/gaia-paths.sh
  . "$_LIB_DIR/gaia-paths.sh" || { _vbi_die "could not source gaia-paths.sh" 2; return 2; }
  # shellcheck source=../lib/validate-artifact-schema.sh
  . "$_LIB_DIR/validate-artifact-schema.sh" || { _vbi_die "could not source validate-artifact-schema.sh" 2; return 2; }

  # ---- 1. Structural validation (delegated) ----
  # The index-in-place guard (step 2) is independent of the JSON-schema backend
  # — it only needs python3+PyYAML. So when the structural check SKIPs (no
  # backend, exit 3) we still run the path guard; an index-in-place violation is
  # exit 1 regardless, and a clean guard under a skipped structural check
  # propagates the SKIP (exit 3) so callers do not treat it as a full pass.
  local schema_rc=0
  validate_artifact_schema "$_SCHEMA" "$manifest" || schema_rc=$?
  case "$schema_rc" in
    0) : ;;                       # structurally valid — run the path guard, pass on clean
    1) return 1 ;;                # structural finding
    3) : ;;                       # no backend — still run the path guard below
    *) return "$schema_rc" ;;     # usage/parse error
  esac

  # ---- 2. Index-in-place guard ----
  # Read each entry's (source_type, path) pair. Reuse the schema primitive's
  # python3+PyYAML path rather than adding a yq host dependency.
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    _vbi_die "python3+PyYAML required for the index-in-place guard" 2
    return 2
  fi

  local pairs
  pairs="$(python3 - "$manifest" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
for entry in (doc.get("entries") or []):
    st = entry.get("source_type", "")
    path = entry.get("path", "")
    # Tab-separated; paths in a YAML manifest never contain tabs.
    sys.stdout.write("%s\t%s\n" % (st, path))
PYEOF
)" || { _vbi_die "could not parse manifest YAML: $manifest" 2; return 2; }

  local knowledge_canon
  knowledge_canon="$(_gaia_paths_canonicalize "$GAIA_KNOWLEDGE_DIR")"

  local st path resolved cand
  # Iterate without mapfile (bash 3.2). The trailing printf keeps the last line
  # even when it lacks a newline.
  while IFS="$(printf '\t')" read -r st path; do
    [ -n "$st" ] || continue
    [ "$st" = "project-artifact" ] || continue
    [ -n "$path" ] || continue

    case "$path" in
      /*) resolved="$path" ;;                                  # already absolute
      *)  resolved="${CLAUDE_PROJECT_ROOT:-$PWD}/$path" ;;     # relative to project root
    esac
    cand="$(_gaia_paths_canonicalize "$resolved")"

    if _gaia_paths_under_root "$cand" "$knowledge_canon"; then
      _vbi_die "index-in-place violation: project-artifact path '$path' resolves inside the knowledge store ($GAIA_KNOWLEDGE_DIR); the Brain indexes artifacts in place and never copies them" 1
      return 1
    fi
  done <<EOF
$pairs
EOF

  # Path guard clean. If the structural check was skipped (no backend), propagate
  # the SKIP so the caller knows the structural invariants were not asserted.
  if [ "$schema_rc" -eq 3 ]; then
    return 3
  fi
  return 0
}

_vbi_main "$@"
exit $?
