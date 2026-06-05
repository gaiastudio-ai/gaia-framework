#!/usr/bin/env bash
# migrate-test-environment-path.sh — backward-compat detect-and-move helper
#
# Backward-compat detect-and-move helper for projects upgraded from earlier
# versions. Migrates `docs/test-artifacts/test-environment.yaml` to
# the canonical `.gaia/config/test-environment.yaml` location
# or the legacy `config/test-environment.yaml` location on older
# projects (positive-evidence guard).
#
# Semantics:
#   - Legacy file exists AND canonical absent: move legacy → canonical;
#     emit one-time stderr deprecation warning; touch sentinel.
#   - Both files exist: prefer canonical (do NOT touch legacy); emit INFO log.
#   - Only canonical exists OR neither exists: no-op (exit 0).
#
# The sentinel file lives at `.gaia/memory/.test-environment-path-migrated`
# so the deprecation warning + INFO log are emitted at most once per project.
#
# Usage:
#   migrate-test-environment-path.sh --target <project-root>
#   migrate-test-environment-path.sh --help
#
# Exit codes:
#   0  success (migrated, or no-op)
#   1  filesystem failure (rare — e.g., cross-filesystem move + cp fallback fail)
#   2  usage error
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="migrate-test-environment-path.sh"

# CANONICAL_REL + SENTINEL_REL resolved after $target
# is validated (positive-evidence guards). LEGACY_REL is invariant.
LEGACY_REL="docs/test-artifacts/test-environment.yaml"
CANONICAL_REL=""
SENTINEL_REL=""

target=""

usage() {
  cat <<'USAGE'
Usage: migrate-test-environment-path.sh --target <project-root>

Detect-and-move helper for canonical-path relocation. Moves
a legacy docs/test-artifacts/test-environment.yaml to .gaia/config/test-environment.yaml
(canonical) or config/test-environment.yaml (legacy layout)
when the canonical location is empty. No-op otherwise.

Exit codes:
  0  success
  1  filesystem failure
  2  usage error
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { printf '%s: --target requires a value\n' "$SCRIPT_NAME" >&2; exit 2; }
      target="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf '%s: unexpected argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
done

[ -n "${target}" ] || { printf '%s: --target is required\n' "$SCRIPT_NAME" >&2; usage >&2; exit 2; }
[ -d "${target}" ] || { printf '%s: target directory does not exist: %s\n' "$SCRIPT_NAME" "${target}" >&2; exit 2; }

# Resolve CANONICAL_REL with positive-evidence guard.
if [ -d "${target}/config" ] && [ ! -d "${target}/.gaia/config" ]; then
  CANONICAL_REL="config/test-environment.yaml"
else
  CANONICAL_REL=".gaia/config/test-environment.yaml"
fi
# The migration sentinel lives under .gaia/memory;
# legacy _memory fallback removed with the consolidation migration.
SENTINEL_REL=".gaia/memory/.test-environment-path-migrated"

legacy="${target}/${LEGACY_REL}"
canonical="${target}/${CANONICAL_REL}"
sentinel="${target}/${SENTINEL_REL}"

# Idempotency — if sentinel exists AND the state is "settled" (canonical exists,
# legacy absent), do nothing. This is the standard hot path after first migration.
if [ -f "${sentinel}" ] && [ -f "${canonical}" ] && [ ! -f "${legacy}" ]; then
  exit 0
fi

# Both files exist — prefer canonical, leave legacy alone, INFO log once
if [ -f "${legacy}" ] && [ -f "${canonical}" ]; then
  if [ ! -f "${sentinel}" ]; then
    printf '%s: INFO: both %s and %s exist; canonical is preferred. The legacy file at %s is untouched — manual cleanup recommended.\n' \
      "$SCRIPT_NAME" "${LEGACY_REL}" "${CANONICAL_REL}" "${legacy}" >&2
    mkdir -p "$(dirname "${sentinel}")"
    : > "${sentinel}"
  fi
  exit 0
fi

# Legacy present, canonical absent → migrate
if [ -f "${legacy}" ] && [ ! -f "${canonical}" ]; then
  canonical_dir="$(dirname "${canonical}")"
  mkdir -p "${canonical_dir}"

  if ! mv "${legacy}" "${canonical}" 2>/dev/null; then
    # Cross-filesystem fallback
    if cp "${legacy}" "${canonical}" && rm "${legacy}"; then
      :
    else
      printf '%s: ERROR: failed to migrate %s -> %s (mv + cp fallback both failed).\n' \
        "$SCRIPT_NAME" "${legacy}" "${canonical}" >&2
      exit 1
    fi
  fi

  printf '%s: DEPRECATION: test-environment.yaml moved from %s to %s. Legacy path will be removed in the release following the one that introduced this migration.\n' \
    "$SCRIPT_NAME" "${LEGACY_REL}" "${CANONICAL_REL}" >&2

  mkdir -p "$(dirname "${sentinel}")"
  : > "${sentinel}"
  exit 0
fi

# Neither file exists — no-op
exit 0
