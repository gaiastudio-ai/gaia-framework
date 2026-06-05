#!/usr/bin/env bash
# adapters/marketplace-publish/probe.sh — three-state availability probe
# for the marketplace-publish deploy adapter.
#
# Exit codes (three-state convention):
#   0 — available  : gh installed, authenticated, repo write scope present, no tag conflict
#   1 — unavailable: gh missing OR auth failed OR token lacks repo write scope
#   2 — degraded   : prerequisites met but target version tag already exists on remote
#                    (mapped from PRD "blocked"; story-as-source-of-truth uses "degraded")
#
# Inputs (all optional — probe is conservative when unset):
#   MARKETPLACE_PUBLISH_VERSION — target tag to check for conflict; if unset, the
#     tag-conflict gate is skipped and the probe returns 0 when gh + auth + scope pass.
#   MARKETPLACE_PUBLISH_REMOTE  — git remote name (default: origin) for ls-remote.

set -u
LC_ALL=C
export LC_ALL

# 1. gh CLI on PATH?
if ! command -v gh >/dev/null 2>&1; then
  echo "probe.sh: gh CLI not found on PATH" >&2
  exit 1
fi

# 2. gh auth status — exits 0 when authenticated and prints scopes on stderr.
auth_output="$(gh auth status 2>&1)"
auth_rc=$?
if [ "$auth_rc" -ne 0 ]; then
  echo "probe.sh: gh auth status failed (not authenticated)" >&2
  exit 1
fi

# 3. Token scopes must include the bare 'repo' write scope. gh prints scopes like:
#    "Token scopes: 'repo', 'read:org', 'workflow'"
# Match the bare 'repo' (not 'public_repo' or 'repo:status') with non-alphanumeric
# delimiters on both sides, including line boundaries.
if ! printf '%s\n' "$auth_output" \
  | grep -Eq "(^|[[:space:],'\"])repo([[:space:],'\"]|$)"; then
  echo "probe.sh: gh token lacks 'repo' write scope" >&2
  exit 1
fi

# 4. Tag-conflict check (only when target version is supplied).
VERSION="${MARKETPLACE_PUBLISH_VERSION:-}"
REMOTE="${MARKETPLACE_PUBLISH_REMOTE:-origin}"
if [ -n "$VERSION" ]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "probe.sh: git not found on PATH (required for tag-conflict check)" >&2
    exit 1
  fi
  ls_output="$(git ls-remote --tags "$REMOTE" "refs/tags/${VERSION}" 2>/dev/null || true)"
  if [ -n "$ls_output" ]; then
    echo "probe.sh: target tag '${VERSION}' already exists on remote '${REMOTE}' (degraded)" >&2
    exit 2
  fi
fi

exit 0
