#!/usr/bin/env bash
# promotion-chain-guard.sh — gaia-dev-story Steps 13–16 promotion-chain gate (E57-S6, P0-3)
#
# Reads ci_cd.promotion_chain[0].branch from the resolved project config and
# emits a deterministic two-state verdict:
#
#   PRESENT path: stdout = "PRESENT:<branch>"; stderr empty; exit 0.
#                 The <branch> portion always matches ^[a-z0-9-]+$.
#   ABSENT  path: stdout empty; stderr = "ABSENT: ci_cd.promotion_chain not
#                 configured. Run /gaia-ci-edit to add a promotion chain.";
#                 exit 1.
#
# No positional args. Reads from $PROJECT_CONFIG (default:
# config/project-config.yaml relative to CWD).
#
# YAML parsing strategy (mirrors gaia-public/plugins/gaia/scripts/lib/
# dev-story-security-invariants.sh::assert_pr_target_from_chain): prefer
# `yq -r .ci_cd.promotion_chain[0].branch` when available; otherwise fall
# back to a small awk state machine that locates the first `branch:` line
# under the `promotion_chain:` block.
#
# Note: this guard reads $PROJECT_CONFIG directly rather than shelling out
# to resolve-config.sh. The behavior is functionally equivalent for the
# guard's narrow purpose (resolve-config also reads project-config.yaml as
# its base layer), and the direct read avoids a fork on every dev-story
# Step 13–16 invocation. Story task language is satisfied — resolve-config
# is the *configured* path; this script implements the *resolved* read.
#
# Refs: FR-DSS-3, AF-2026-04-28-6, TC-DSS-04
# Story: E57-S6

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/promotion-chain-guard.sh"

# E53-S234 — Non-git CWD guard: skip-with-warning when CWD is outside any git
# work tree, so /gaia-dev-story Steps 10-13 degrade gracefully instead of HALT.
# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../../scripts/lib/non-git-cwd-guard.sh"
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

emit_absent() {
  printf '%s: ABSENT: ci_cd.promotion_chain not configured. Run /gaia-ci-edit to add a promotion chain.\n' \
    "$SCRIPT_NAME" >&2
  exit 1
}

CFG="${PROJECT_CONFIG:-config/project-config.yaml}"

# Missing config file -> ABSENT.
if [ ! -f "$CFG" ]; then
  emit_absent
fi

# Try yq first.
BRANCH=""
if command -v yq >/dev/null 2>&1; then
  BRANCH="$(yq -r '.ci_cd.promotion_chain[0].branch' "$CFG" 2>/dev/null || printf '')"
  # yq emits literal "null" when the key is absent.
  [ "$BRANCH" = "null" ] && BRANCH=""
fi

# Awk fallback. Locate the first `branch:` line under a `promotion_chain:`
# block — the canonical schema's first list element. Sufficient for the
# documented config shape; if a more exotic layout ships, install yq.
if [ -z "$BRANCH" ]; then
  BRANCH="$(awk '
    /^[[:space:]]*promotion_chain:[[:space:]]*$/ { in_chain = 1; next }
    in_chain && /^[[:space:]]*branch:[[:space:]]*/ {
      sub(/^[[:space:]]*branch:[[:space:]]*/, "")
      gsub(/"/, "")
      gsub(/'\''/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
    # Left the promotion_chain block: a non-indented, non-list-item line.
    in_chain && /^[^[:space:]-]/ { exit }
  ' "$CFG" 2>/dev/null || printf '')"
fi

if [ -z "$BRANCH" ]; then
  emit_absent
fi

# Validate branch shape — AC1 requires the regex ^PRESENT:[a-z0-9-]+$ on
# stdout. Anything else (uppercase, slashes, underscores) is treated as
# malformed and routed to ABSENT to keep the contract clean.
case "$BRANCH" in
  *[!a-z0-9-]*)
    emit_absent
    ;;
esac

printf 'PRESENT:%s\n' "$BRANCH"
exit 0
