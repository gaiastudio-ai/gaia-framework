#!/usr/bin/env bash
# gaia-doctor — install-tools.sh
#
# Install dispatcher for MISSING applicable tools. Reads the JSON output
# of check-tools.sh, prompts per tool (skips prompt under --yes), runs the
# OS-appropriate install command from the registry, and re-probes at end.
#
# Usage:
#   install-tools.sh [--yes] [--stack NAME] [--project-root DIR]
#
# Exit codes:
#   0  every attempted install succeeded (or user skipped all)
#   1  one or more attempted installs failed
#   2  argument / IO error

set -euo pipefail
LC_ALL=C
export LC_ALL

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_TOOLS="${SKILL_DIR}/scripts/check-tools.sh"

_die() {
  echo "gaia-doctor/install-tools: $*" >&2
  exit 2
}

_host_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

YES_FLAG="false"
DOCKER_FLAG="auto"   # auto | force | off
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES_FLAG="true"; shift ;;
    --docker) DOCKER_FLAG="force"; shift ;;
    --no-docker) DOCKER_FLAG="off"; shift ;;
    --stack)  EXTRA_ARGS+=("--stack" "${2:-}"); shift 2 ;;
    --project-root) EXTRA_ARGS+=("--project-root" "${2:-}"); shift 2 ;;
    -h|--help)
      cat <<EOF
gaia-doctor install-tools.sh — interactive install dispatcher

Usage:
  $0 [--yes] [--docker | --no-docker] [--stack NAME] [--project-root DIR]

Flags:
  --yes, -y         Non-interactive; auto-accept every prompt
  --docker          Pull the bundled gaia-tools OCI image instead of
                    installing Tier 2 tools individually.
                    Forces docker mode even if brownfield.tools.runner
                    is unset.
  --no-docker       Disable the docker path even if brownfield.tools.runner=docker.
                    Forces per-tool host installs.
  --stack NAME      Limit to a single named stack
  --project-root D  Override project root
EOF
      exit 0
      ;;
    *) _die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || _die "jq is required"
[ -x "$CHECK_TOOLS" ] || _die "check-tools.sh not found or not executable"

_prompt_yn() {
  # $1 = question; returns 0 on yes, 1 on no
  if [ "$YES_FLAG" = "true" ]; then
    return 0
  fi
  local reply
  printf '%s [Y/n] ' "$1" >&2
  read -r reply || reply="n"
  case "$reply" in
    ""|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

_run_install() {
  # $1 = tool id, $2 = command string
  local tid="$1" cmd="$2"
  echo "→ installing $tid via: $cmd" >&2
  if bash -c "$cmd"; then
    echo "✓ $tid installed" >&2
    return 0
  else
    echo "✗ $tid install failed" >&2
    return 1
  fi
}

_resolve_docker_mode() {
  # Explicit --docker / --no-docker beat config; otherwise
  # consult brownfield.tools.runner via the docker-runner.sh helper.
  case "$DOCKER_FLAG" in
    force) printf 'docker\n' ;;
    off)   printf 'native\n' ;;
    *)
      local helper="${SKILL_DIR}/../../scripts/lib/docker-runner.sh"
      if [ -f "$helper" ]; then
        bash "$helper" mode 2>/dev/null || printf 'native\n'
      else
        printf 'native\n'
      fi
      ;;
  esac
}

_install_docker_image() {
  # When runner=docker, replace the per-tool install cascade with a single
  # `docker pull` of the bundled gaia-tools image. The pull pre-warms the
  # local cache so the next /gaia-brownfield invocation sees
  # `docker_runner_available` succeed and dispatches all Tier 2 adapters
  # through the image.
  local helper="${SKILL_DIR}/../../scripts/lib/docker-runner.sh"
  if [ ! -f "$helper" ]; then
    echo "gaia-doctor: docker-runner.sh helper not found at $helper" >&2
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "gaia-doctor: docker not on PATH — install Docker Desktop / Engine first:" >&2
    echo "  macOS:  brew install --cask docker" >&2
    echo "  linux:  curl -fsSL https://get.docker.com | sh" >&2
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "gaia-doctor: docker daemon not reachable (try: docker ps)" >&2
    return 1
  fi
  local image
  image=$(bash "$helper" image 2>/dev/null || echo "ghcr.io/gaiastudio-ai/gaia-tools:latest")
  echo "gaia-doctor: docker runner — pulling bundled tools image" >&2
  echo "  image: $image" >&2
  if ! _prompt_yn "Pull $image now?"; then
    echo "– pull skipped by user" >&2
    return 0
  fi
  if bash "$helper" pull; then
    echo "✓ image pulled — Tier 2 adapters will now dispatch through gaia-tools" >&2
    echo "" >&2
    echo "gaia-doctor: verifying image bill-of-materials…" >&2
    docker run --rm "$image" --bom 2>&1 | head -15 || true
    return 0
  fi
  echo "✗ image pull failed" >&2
  return 1
}

main() {
  local host
  host="$(_host_os)"

  # Runner-aware dispatch.
  local mode
  mode="$(_resolve_docker_mode)"
  if [ "$mode" = "docker" ]; then
    echo "gaia-doctor: runner=docker (per --docker / brownfield.tools.runner)" >&2
    if _install_docker_image; then
      # Still re-probe so the operator sees the post-install readiness table.
      echo "" >&2
      echo "gaia-doctor: re-probing after image pull…" >&2
      "$CHECK_TOOLS" "${EXTRA_ARGS[@]}"
      exit 0
    else
      echo "" >&2
      echo "gaia-doctor: docker-mode install failed — falling back to per-tool host install" >&2
      echo "  (override with --no-docker to skip this fallback)" >&2
      echo "" >&2
    fi
  fi

  local probe_json
  probe_json="$("$CHECK_TOOLS" --json "${EXTRA_ARGS[@]}")"

  # Include "below-min-version" tools in the install candidates so a
  # present-but-stale binary (e.g. macOS bash below the min_version) is
  # offered an upgrade. Without this, --install only iterated state=="missing"
  # tools; a present-but-too-old binary fell through silently.
  local missing
  missing="$(echo "$probe_json" | jq -r '.tools[] | select(.state == "missing" or .state == "outdated") | .id')"

  if [ -z "$missing" ]; then
    echo "gaia-doctor: no missing or outdated tools — nothing to install." >&2
    exit 0
  fi

  local failed=0 attempted=0
  while IFS= read -r tid; do
    [ -z "$tid" ] && continue
    local cmd
    cmd="$(echo "$probe_json" | jq -r --arg t "$tid" --arg o "$host" \
      '(.tools[] | select(.id == $t) | .registry.install[$o]) // (.tools[] | select(.id == $t) | .registry.install.macos) // empty')"
    if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
      echo "– $tid: no install command for host=$host; skipping" >&2
      continue
    fi
    if _prompt_yn "Install $tid via '$cmd'?"; then
      attempted=$((attempted + 1))
      if ! _run_install "$tid" "$cmd"; then
        failed=$((failed + 1))
      fi
    else
      echo "– $tid: skipped by user" >&2
    fi
  done <<< "$missing"

  echo "" >&2
  echo "gaia-doctor: re-probing after install pass…" >&2
  "$CHECK_TOOLS" "${EXTRA_ARGS[@]}"

  if [ "$failed" -gt 0 ]; then
    echo "gaia-doctor: ${failed}/${attempted} installs failed" >&2
    exit 1
  fi
  exit 0
}

main
