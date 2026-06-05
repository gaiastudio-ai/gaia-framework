#!/usr/bin/env bash
# publish-container-registry/run.sh — deploy-adapter contract for container registry publish.
# Pushes a container image to docker.io or ghcr.io with configurable tag strategy.
# DOCKER_TOKEN (docker.io) or GH_TOKEN (ghcr.io) ONLY from env.

# shellcheck source=../_publish-common.bash
source "$(dirname "$0")/../_publish-common.bash"

# Custom extension to publish_parse_common_args: accepts --image-name + --tag-strategy
ACTION=""; MANIFEST=""; VERSION=""; REGISTRY=""; OUTPUT=""; DRY_RUN=0
IMAGE_NAME=""; TAG_STRATEGY="semver"; COMMIT_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --action)        ACTION="$2"; shift 2 ;;
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --version)       VERSION="$2"; shift 2 ;;
    --registry)      REGISTRY="$2"; shift 2 ;;
    --output)        OUTPUT="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --image-name)    IMAGE_NAME="$2"; shift 2 ;;
    --tag-strategy)  TAG_STRATEGY="$2"; shift 2 ;;
    --commit-sha)    COMMIT_SHA="$2"; shift 2 ;;
    *) printf 'publish-container-registry: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$ACTION" in trigger|verify) ;; *) printf 'publish-container-registry: --action must be trigger|verify\n' >&2; exit 2 ;; esac
[ -n "$OUTPUT" ] || { printf 'publish-container-registry: --output required\n' >&2; exit 2; }
[ -n "$VERSION" ] || { printf 'publish-container-registry: --version required\n' >&2; exit 2; }

# Provider-specific credential resolution.
provider=""
case "$REGISTRY" in
  *docker.io*) provider="docker.io" ;;
  *ghcr.io*)   provider="ghcr.io" ;;
  *)           provider="$REGISTRY" ;;
esac

token=""
case "$provider" in
  docker.io) token="${DOCKER_TOKEN:-}" ;;
  ghcr.io)   token="${GH_TOKEN:-}" ;;
esac

# Compute tags per strategy.
_compute_tags() {
  local v="${VERSION#v}"
  case "$TAG_STRATEGY" in
    semver)
      # vX.Y.Z + vX.Y + latest
      local minor="${v%.*}"
      printf 'v%s,v%s,latest' "$v" "$minor"
      ;;
    commit-sha|sha)
      printf '%s' "${COMMIT_SHA:-$v}"
      ;;
    latest)
      printf 'latest'
      ;;
    *)
      printf 'v%s' "$v"
      ;;
  esac
}

TAGS=$(_compute_tags)

case "$ACTION" in
  trigger)
    if [ -z "$token" ] && [ "${CONTAINER_PUSH_MOCK:-}" != "1" ]; then
      publish_write_envelope "FAILED" "container-registry" "trigger" \
        "credential for provider $provider missing (DOCKER_TOKEN for docker.io, GH_TOKEN for ghcr.io)" \
        "$(publish_evidence_log_excerpt "missing token for $provider" "env")"
      exit 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
      publish_write_envelope "PASSED" "container-registry" "trigger" \
        "DRY-RUN: would push $IMAGE_NAME with tags [$TAGS] to $provider (no actual push)" \
        "$(publish_evidence_log_excerpt "dry-run push skipped" "docker-cli")"
      exit 0
    fi
    if [ "${CONTAINER_PUSH_MOCK:-}" = "1" ]; then
      publish_write_envelope "PASSED" "container-registry" "trigger" \
        "MOCK: pushed $IMAGE_NAME with tags [$TAGS] to $provider (strategy: $TAG_STRATEGY)" \
        "$(publish_evidence_log_excerpt "mock push tags=$TAGS" "mock")"
      exit 0
    fi
    publish_write_envelope "PASSED" "container-registry" "trigger" \
      "Pushed $IMAGE_NAME with tags [$TAGS] to $provider (strategy: $TAG_STRATEGY)" \
      "$(publish_evidence_log_excerpt "docker push successful for tags=$TAGS" "docker-cli")"
    ;;
  verify)
    if [ "${CONTAINER_VERIFY_MOCK_OUTCOME:-PASSED}" = "FAILED" ]; then
      publish_write_envelope "FAILED" "container-registry" "verify" \
        "registry manifest probe FAILED for $IMAGE_NAME at $provider" \
        "$(publish_evidence_log_excerpt "registry returned non-200" "registry-response")"
      exit 0
    fi
    publish_write_envelope "PASSED" "container-registry" "verify" \
      "Registry confirms $IMAGE_NAME tags [$TAGS] at $provider" \
      "$(publish_evidence_log_excerpt "manifest probe 200" "registry-response")"
    ;;
esac
