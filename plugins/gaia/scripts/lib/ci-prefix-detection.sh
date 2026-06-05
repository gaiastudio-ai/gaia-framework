#!/usr/bin/env bash
# ci-prefix-detection.sh — CI workflow filename classifier for the
# CI customization layered model.
#
# Sourceable, NOT executable.
#
# Exposes a single pure function:
#   gaia_ci_classify <path>
#     Prints exactly one of: generated | user-authored | overlay | unprefixed
#     Exit 0 on classification; 2 on usage error (missing arg).
#
# Classification rules (first match wins):
#   1. overlay        — basename matches gaia-*.user-jobs.yml OR
#                       gaia-*.user-steps.yml
#   2. generated      — basename starts with `gaia-` (regen-ownable)
#   3. user-authored  — basename starts with `user-` (never touched by regen)
#   4. unprefixed     — anything else (auto-rename migration trigger)
#
# Fail-safe contract: rule ordering above is exhaustive over the
# {gaia-*, user-*, else} partition. The four-value enum surfaces the
# migration-trigger state (`unprefixed`) distinctly from
# user-owned standalone files (`user-authored`); collapsing the two
# would silently absorb the migration-trigger surface.
#
# Purity contract:
#   - No global-state mutation outside the source-guard sentinel.
#   - No filesystem reads, no subshells, no network.
#   - Operates on basename($1) only.
#
# Source guard: _GAIA_CI_PREFIX_DETECTION_LOADED=1 after first source;
# subsequent sources are no-ops.

if [ "${_GAIA_CI_PREFIX_DETECTION_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_CI_PREFIX_DETECTION_LOADED=1

gaia_ci_classify() {
  if [ $# -lt 1 ]; then
    printf 'ci-prefix-detection.sh: gaia_ci_classify requires a path argument\n' >&2
    return 2
  fi

  local base="${1##*/}"

  # Rule 1: overlay — gaia-*.user-jobs.yml OR gaia-*.user-steps.yml
  case "$base" in
    gaia-*.user-jobs.yml|gaia-*.user-steps.yml)
      printf 'overlay\n'
      return 0
      ;;
  esac

  # Rule 2: generated — basename starts with `gaia-`
  case "$base" in
    gaia-*)
      printf 'generated\n'
      return 0
      ;;
  esac

  # Rule 3: user-authored — basename starts with `user-`
  case "$base" in
    user-*)
      printf 'user-authored\n'
      return 0
      ;;
  esac

  # Rule 4: unprefixed — migration-eligible
  printf 'unprefixed\n'
  return 0
}
