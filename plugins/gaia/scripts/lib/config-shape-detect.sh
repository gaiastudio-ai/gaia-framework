#!/usr/bin/env bash
# config-shape-detect.sh — Config-shape detector for the 5-case decision
# table that drives /gaia-help routing and /gaia-deploy-checklist
# publish-readiness mode.
#
# Sourceable, NOT executable.
#
# Exposes one function:
#
#   gaia_config_shape_detect <project-config.yaml>
#     Emits exactly one of these stable tokens on stdout:
#       deploy-only        — all envs are deployable AND no distribution: block
#       publish-primary    — no env is deployable AND distribution: is present
#       deploy-and-publish — at least one deployable env AND distribution: is present
#       unknown            — environments[] is missing entirely (caller falls back)
#
# Per the silent default, an env entry with NO `kind:` field resolves to
# `deployable` (matches the dedicated env-kind resolver).
#
# Source guard: _GAIA_CONFIG_SHAPE_DETECT_LOADED=1 after first source.

if [ "${_GAIA_CONFIG_SHAPE_DETECT_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_CONFIG_SHAPE_DETECT_LOADED=1

LC_ALL=C
export LC_ALL

gaia_config_shape_detect() {
  local config="${1:-}"

  if [ -z "$config" ]; then
    printf 'config-shape-detect.sh: usage: gaia_config_shape_detect <project-config.yaml>\n' >&2
    return 2
  fi
  if [ ! -f "$config" ]; then
    printf 'config-shape-detect.sh: config file not found: %s\n' "$config" >&2
    return 2
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'config-shape-detect.sh: yq required but not on PATH\n' >&2
    return 2
  fi

  # Probe 1: is environments[] declared at all?
  local has_envs
  has_envs=$(yq eval 'has("environments")' "$config" 2>/dev/null)
  if [ "$has_envs" != "true" ]; then
    printf 'unknown\n'
    return 0
  fi

  # Probe 2: enumerate kinds (apply silent default to deployable).
  # Output: one kind per line, one per env entry.
  local kinds
  kinds=$(yq eval '.environments[]? | (.kind // "deployable")' "$config" 2>/dev/null)

  # Probe 3: is the distribution: block present?
  local has_dist
  has_dist=$(yq eval 'has("distribution")' "$config" 2>/dev/null)

  # Count deployable envs.
  local deployable_count=0
  local total_envs=0
  local k
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    total_envs=$((total_envs + 1))
    [ "$k" = "deployable" ] && deployable_count=$((deployable_count + 1))
  done <<< "$kinds"

  # Decision matrix.
  if [ "$total_envs" -eq 0 ]; then
    # environments: [] but key is declared.
    if [ "$has_dist" = "true" ]; then
      printf 'publish-primary\n'
    else
      printf 'unknown\n'
    fi
    return 0
  fi

  if [ "$deployable_count" -gt 0 ] && [ "$has_dist" = "true" ]; then
    printf 'deploy-and-publish\n'
  elif [ "$deployable_count" -gt 0 ] && [ "$has_dist" != "true" ]; then
    printf 'deploy-only\n'
  elif [ "$deployable_count" -eq 0 ] && [ "$has_dist" = "true" ]; then
    printf 'publish-primary\n'
  else
    # No deployable envs, no distribution. Edge case — emit publish-primary
    # so the caller surfaces the misconfiguration; the (no-deploy, no-publish)
    # case is genuinely unusual and we fail-open to publish-primary so the
    # /gaia-help text guides the user toward adding either a deployable env
    # or a distribution block.
    printf 'publish-primary\n'
  fi
  return 0
}
