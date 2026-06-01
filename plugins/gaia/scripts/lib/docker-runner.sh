#!/usr/bin/env bash
# docker-runner.sh — AF-2026-05-30-3 / Test10 §7 Component 2.
#
# Shared dispatcher used by Tier 2 brownfield adapters when
# brownfield.tools.runner == "docker". Wraps `docker run` with the
# canonical volume-mount + output layout the gaia-tools image expects
# so individual adapters (grype, syft, spotbugs, mobsf, …) don't each
# re-implement the same plumbing.
#
# Mount contract:
#   /workspace   <- ${PROJECT_ROOT}              read-only project source
#   /out         <- ${ADAPTER_OUT_DIR}           SARIF + JSON output sink
#
# Image resolution:
#   1. ${GAIA_TOOLS_IMAGE} (explicit override; honored verbatim — pin in CI)
#   2. brownfield.tools.image  (read from project-config.yaml via yq)
#   3. ghcr.io/gaiastudio-ai/gaia-tools:latest  (last-resort default; not
#      recommended in production — operators should pin a versioned tag)
#
# Usage:
#   source docker-runner.sh
#   docker_runner_dispatch grype dir:/workspace -o sarif -f /out/grype.sarif
#
# Or as a CLI:
#   docker-runner.sh dispatch grype dir:/workspace -o sarif -f /out/grype.sarif
#
# Exit codes:
#   0   tool executed successfully
#   125 docker daemon unreachable / image pull failed (NOT a tool failure)
#   *   underlying tool exit code (passthrough)
#
# The 125 boundary matters: brownfield adapters that wrap this helper
# should distinguish "tool said nothing was wrong (exit 0)" from "the
# runner couldn't even invoke the tool (exit 125)" — the latter MUST
# downgrade gracefully to native dispatch or surface a Tier-banner
# warning, never silently false-PASS.

set -euo pipefail
LC_ALL=C
export LC_ALL

_dr_log() { printf 'docker-runner: %s\n' "$*" >&2; }
_dr_die() { _dr_log "$*"; exit 1; }

# ---------------------------------------------------------------------------
# docker_runner_image
# ---------------------------------------------------------------------------
# Echo the resolved gaia-tools image tag. Honors:
#   GAIA_TOOLS_IMAGE env override > brownfield.tools.image > last-resort.
docker_runner_image() {
  if [ -n "${GAIA_TOOLS_IMAGE:-}" ]; then
    printf '%s\n' "$GAIA_TOOLS_IMAGE"
    return 0
  fi
  local config="${PROJECT_CONFIG:-${CLAUDE_PROJECT_ROOT:-${PWD}}/.gaia/config/project-config.yaml}"
  local image=""
  if [ -f "$config" ] && command -v yq >/dev/null 2>&1; then
    image=$(yq -r '.brownfield.tools.image // ""' "$config" 2>/dev/null || echo "")
  fi
  if [ -n "$image" ] && [ "$image" != "null" ]; then
    printf '%s\n' "$image"
    return 0
  fi
  printf '%s\n' "ghcr.io/gaiastudio-ai/gaia-tools:latest"
}

# ---------------------------------------------------------------------------
# docker_runner_available
# ---------------------------------------------------------------------------
# Exit 0 if docker is on PATH AND the daemon is reachable AND the resolved
# image is present in the local cache (or pullable). Non-zero otherwise
# with a stderr explanation. Callers that want to gate dispatch on runner
# availability should check this first.
docker_runner_available() {
  if ! command -v docker >/dev/null 2>&1; then
    _dr_log "docker not on PATH"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    _dr_log "docker daemon not reachable (try: docker ps)"
    return 1
  fi
  local image
  image=$(docker_runner_image)
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    _dr_log "image not cached locally: $image (pull via /gaia-doctor --install)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# docker_runner_pull
# ---------------------------------------------------------------------------
# Pull the resolved image. Used by /gaia-doctor --install when the
# brownfield runner is set to docker.
docker_runner_pull() {
  local image
  image=$(docker_runner_image)
  _dr_log "pulling: $image"
  docker pull "$image"
}

# ---------------------------------------------------------------------------
# docker_runner_dispatch <subcommand> [args...]
# ---------------------------------------------------------------------------
# Invoke the gaia-tools image with the canonical mount layout. Caller
# supplies the subcommand (one of: grype, syft, osv-scanner, spotbugs,
# vulture, pip-audit, cyclonedx-bom, cdxgen, yamllint, yq) and any args.
#
# Args may reference the in-container paths /workspace (read-only project
# source) and /out (output sink). The host workspace is taken from
# ${PROJECT_ROOT} (default $PWD); the output sink from ${ADAPTER_OUT_DIR}
# (REQUIRED — adapters MUST set this so SARIF lands in the right place).
docker_runner_dispatch() {
  [ $# -ge 1 ] || _dr_die "docker_runner_dispatch: subcommand required"
  local subcmd="$1"
  shift

  local proj_root="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-$PWD}}"
  local out_dir="${ADAPTER_OUT_DIR:-}"
  [ -n "$out_dir" ] || _dr_die "docker_runner_dispatch: ADAPTER_OUT_DIR not set (where should SARIF/JSON land?)"
  mkdir -p "$out_dir"

  if ! docker_runner_available >/dev/null 2>&1; then
    _dr_log "docker runner unavailable — dispatch refused"
    return 125
  fi

  local image
  image=$(docker_runner_image)

  # --network=host is intentionally NOT passed by default — the image
  # bundles its own grype DB pre-warmed at build time, and offline runs
  # are the canonical safer default. Adopters that need network (e.g. to
  # `grype db update` on the fly) can set GAIA_TOOLS_NETWORK=host.
  local net_arg="--network=none"
  if [ "${GAIA_TOOLS_NETWORK:-none}" != "none" ]; then
    net_arg="--network=${GAIA_TOOLS_NETWORK}"
  fi

  # Wall-clock cap: brownfield adapters already enforce their own per-tool
  # cap, but we add a runner-level guard to prevent a runaway container
  # from outlasting the parent. Defaults to 600s; overridable via env.
  local timeout_s="${GAIA_TOOLS_TIMEOUT:-600}"

  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_s}s" docker run --rm \
      "${net_arg}" \
      -v "${proj_root}:/workspace:ro" \
      -v "${out_dir}:/out" \
      -w /workspace \
      "${image}" \
      "${subcmd}" "$@"
  else
    docker run --rm \
      "${net_arg}" \
      -v "${proj_root}:/workspace:ro" \
      -v "${out_dir}:/out" \
      -w /workspace \
      "${image}" \
      "${subcmd}" "$@"
  fi
}

# ---------------------------------------------------------------------------
# docker_runner_mode
# ---------------------------------------------------------------------------
# Echo "docker" if brownfield.tools.runner is docker (or GAIA_TOOLS_RUNNER
# env override); else "native". Used by adapters at dispatch time to
# branch between docker_runner_dispatch and direct $PATH invocation.
docker_runner_mode() {
  if [ -n "${GAIA_TOOLS_RUNNER:-}" ]; then
    printf '%s\n' "$GAIA_TOOLS_RUNNER"
    return 0
  fi
  local config="${PROJECT_CONFIG:-${CLAUDE_PROJECT_ROOT:-${PWD}}/.gaia/config/project-config.yaml}"
  if [ -f "$config" ] && command -v yq >/dev/null 2>&1; then
    local v
    v=$(yq -r '.brownfield.tools.runner // "native"' "$config" 2>/dev/null || echo "native")
    case "$v" in
      docker|native) printf '%s\n' "$v"; return 0 ;;
      *)             printf 'native\n'; return 0 ;;
    esac
  fi
  printf 'native\n'
}

# ---------------------------------------------------------------------------
# CLI entry — sourced consumers skip this; direct invocation dispatches.
# ---------------------------------------------------------------------------
# AF-2026-06-01-1 / Test15 L-01: `${BASH_SOURCE[0]:-}` so a `set -u`
# caller that sources this lib doesn't crash with "BASH_SOURCE[0]:
# unbound variable" on bash 3.2 (macOS default). The check semantics
# are unchanged — when sourced, BASH_SOURCE[0] is still set to this
# file's path; when run directly, it equals $0.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  case "${1:-}" in
    image)       shift; docker_runner_image ;;
    available)   shift; docker_runner_available ;;
    pull)        shift; docker_runner_pull ;;
    mode)        shift; docker_runner_mode ;;
    dispatch)    shift; docker_runner_dispatch "$@" ;;
    -h|--help|"")
      cat <<EOF
docker-runner.sh — AF-2026-05-30-3 dispatcher.
Subcommands:
  image                            print resolved gaia-tools image tag
  available                        exit 0 if runner is usable, non-zero otherwise
  pull                             pull the resolved image
  mode                             print "docker" or "native" per project-config
  dispatch <subcmd> [args...]      invoke the image with canonical mount layout

Required env for dispatch:
  ADAPTER_OUT_DIR                  where SARIF/JSON output lands (host path)

Optional env:
  GAIA_TOOLS_IMAGE                 image-tag override (pin in CI)
  GAIA_TOOLS_RUNNER                "docker" | "native" override
  GAIA_TOOLS_NETWORK               "none" (default) | "host" | "bridge"
  GAIA_TOOLS_TIMEOUT               seconds, default 600
  PROJECT_ROOT                     host workspace root, default \$PWD
EOF
      ;;
    *) _dr_die "unknown subcommand: $1" ;;
  esac
fi
