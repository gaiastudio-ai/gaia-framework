#!/usr/bin/env bash
# artifact-three-tier-resolve.sh — Three-tier path resolver for the four
# artifact families (adversarial, sprint-plan, sprint-review, retrospective).
#
# Resolution order:
#   Tier 1 — Env-var override wins.
#   Tier 2 — Positive legacy-flat evidence: file exists at the legacy flat
#            location AND no nested-dir variant present. Selects legacy.
#   Tier 3 — Canonical nested default. Wins in all other cases.
#
# Usage:
#   artifact-three-tier-resolve.sh \
#       --family <retro|sprint-plan|sprint-review|adversarial> \
#       --id <sprint_id-or-artifact-name> \
#       [--project-root <dir>]   # default: $PWD
#
# Prints the resolved directory (NOT a file path) on stdout — caller globs
# inside it. Exit codes:
#   0 — resolved (stdout = directory)
#   1 — unknown family / missing args
#
# This helper is intentionally read-only: producers always write to the
# canonical nested directory regardless of what the resolver returns
# (no legacy-writes fallback).

set -euo pipefail

usage() {
  echo "usage: artifact-three-tier-resolve.sh --family <name> --id <key> [--project-root <dir>]" >&2
  echo "  family: retro | sprint-plan | sprint-review | adversarial" >&2
  exit 1
}

FAMILY=""
ARTIFACT_ID=""
PROJECT_ROOT="${PWD}"
while [ $# -gt 0 ]; do
  case "$1" in
    --family) FAMILY="$2"; shift 2 ;;
    --id) ARTIFACT_ID="$2"; shift 2 ;;
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$FAMILY" ] || usage
[ -n "$ARTIFACT_ID" ] || usage

# Map family → (env-var, nested dir, legacy dir, filename prefix).
case "$FAMILY" in
  retro)
    ENV_VAR="RETRO_DIR"
    NESTED_DIR="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/retrospective"
    LEGACY_DIR="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts"
    NAME_PREFIX="retrospective-${ARTIFACT_ID}-"
    ;;
  sprint-plan)
    ENV_VAR="SPRINT_PLAN_DIR"
    NESTED_DIR="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/sprint-plan"
    LEGACY_DIR="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts"
    NAME_PREFIX="${ARTIFACT_ID}-plan"
    ;;
  sprint-review)
    ENV_VAR="SPRINT_REVIEW_DIR"
    NESTED_DIR="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/sprint-review"
    LEGACY_DIR="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts"
    NAME_PREFIX="sprint-review-${ARTIFACT_ID}-"
    ;;
  adversarial)
    ENV_VAR="ADVERSARIAL_DIR"
    NESTED_DIR="${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts/adversarial"
    LEGACY_DIR="${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts"
    NAME_PREFIX="adversarial-review-${ARTIFACT_ID}-"
    ;;
  *)
    echo "unknown family: $FAMILY" >&2
    exit 1
    ;;
esac

# Tier 1 — env-var override.
override="$(eval echo "\${$ENV_VAR:-}")"
if [ -n "$override" ]; then
  printf '%s\n' "$override"
  exit 0
fi

# Tier 2 — positive legacy-flat evidence (flat exists AND no nested dir).
nested_has_file=0
if [ -d "$NESTED_DIR" ]; then
  if find "$NESTED_DIR" -maxdepth 1 -type f -name "${NAME_PREFIX}*" 2>/dev/null | grep -q .; then
    nested_has_file=1
  fi
fi

legacy_has_file=0
if [ -d "$LEGACY_DIR" ]; then
  if find "$LEGACY_DIR" -maxdepth 1 -type f -name "${NAME_PREFIX}*" 2>/dev/null | grep -q .; then
    legacy_has_file=1
  fi
fi

if [ "$legacy_has_file" -eq 1 ] && [ "$nested_has_file" -eq 0 ]; then
  printf '%s\n' "$LEGACY_DIR"
  exit 0
fi

# Tier 3 — canonical nested default (wins when both exist, or neither does).
printf '%s\n' "$NESTED_DIR"
exit 0
