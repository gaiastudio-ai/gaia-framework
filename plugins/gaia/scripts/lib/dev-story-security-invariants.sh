#!/usr/bin/env bash
# dev-story-security-invariants.sh — hard security invariants for pr-create.sh and merge.sh.
#
# Hard security invariants enforced inside pr-create.sh and merge.sh. None
# of these assertions check YOLO mode — by design, YOLO MUST NOT bypass
# them.
# A bats regression in tests/e55-s6-security-invariants.bats locks this in
# by greping this file for the YOLO-mode flag token; if the token ever
# appears here, the regression FAILS and the build halts.
#
# Public functions:
#   - assert_branch_not_protected      : current branch != main / staging
#   - assert_no_secrets_staged         : no .env, *credentials*, common API
#                                        key / Bearer / Slack token in stage
#   - assert_pr_target_from_chain TGT  : TGT == ci_cd.promotion_chain[0].branch
#
# Canonical secret patterns (extend by adding a regex to SECRET_CONTENT_PATTERNS
# below — keep the array literal ordered by vendor and document the source):
#   - AWS access key id  : AKIA[0-9A-Z]{16}
#   - GitHub PAT/token   : gh[ps]_[A-Za-z0-9]{36,}
#   - Bearer token       : Bearer\s+[A-Za-z0-9._-]+
#   - Slack token        : xox[baprs]-[A-Za-z0-9-]{10,}
#
# Usage (from pr-create.sh / merge.sh):
#   source "$(dirname "$0")/../../scripts/lib/dev-story-security-invariants.sh"
#   assert_branch_not_protected
#   assert_no_secrets_staged
#   assert_pr_target_from_chain "$BASE_BRANCH"   # merge.sh only
#
# Each function returns non-zero with a descriptive >&2 message on failure.
# Library file — no top-level main, safe to source repeatedly.

# Note: callers set their own `set -euo pipefail`. Don't override here so
# sourcing this file under bats does not surprise the host script.

# Protected branch list — exact-match only. Substrings such as
# `feat/main-thing` MUST pass.
GAIA_DSSI_PROTECTED_BRANCHES=("main" "staging")

# Canonical secret content patterns. Extended-regex (grep -E) form.
GAIA_DSSI_SECRET_CONTENT_PATTERNS=(
  'AKIA[0-9A-Z]{16}'
  'gh[ps]_[A-Za-z0-9]{36,}'
  'Bearer[[:space:]]+[A-Za-z0-9._-]+'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
)

# ---------------------------------------------------------------------------
# assert_branch_not_protected
# ---------------------------------------------------------------------------
assert_branch_not_protected() {
  local branch protected
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [[ -z "$branch" ]]; then
    echo "security-invariant FAIL: cannot determine current branch" >&2
    return 1
  fi
  for protected in "${GAIA_DSSI_PROTECTED_BRANCHES[@]}"; do
    if [[ "$branch" == "$protected" ]]; then
      echo "security-invariant FAIL: cannot push/merge from protected branch '$branch'" >&2
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# assert_no_secrets_staged
# ---------------------------------------------------------------------------
assert_no_secrets_staged() {
  local files f base diff pat

  files="$(git diff --cached --name-only 2>/dev/null || true)"

  if [[ -n "$files" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      base="$(basename "$f")"
      # Env files: .env, .env.local, .env.production, etc.
      if [[ "$base" =~ ^\.env(\..+)?$ ]]; then
        echo "security-invariant FAIL: staged file looks like an env file: $f" >&2
        return 1
      fi
      # Credentials filename (case-insensitive substring).
      if printf '%s' "$base" | grep -qiE 'credentials'; then
        echo "security-invariant FAIL: staged file looks like credentials: $f" >&2
        return 1
      fi
    done <<<"$files"
  fi

  # Content scan over the full staged diff. Empty diff -> nothing to match.
  diff="$(git diff --cached 2>/dev/null || true)"
  if [[ -n "$diff" ]]; then
    for pat in "${GAIA_DSSI_SECRET_CONTENT_PATTERNS[@]}"; do
      if printf '%s' "$diff" | grep -Eq "$pat"; then
        echo "security-invariant FAIL: staged content matches secret pattern: $pat" >&2
        return 1
      fi
    done
  fi

  return 0
}

# ---------------------------------------------------------------------------
# assert_pr_target_from_chain
# ---------------------------------------------------------------------------
# $1 = the PR target branch the caller is about to use. Must equal
# ci_cd.promotion_chain[0].branch from $PROJECT_CONFIG (default
# config/project-config.yaml).
assert_pr_target_from_chain() {
  local pr_target="${1:-}"
  if [[ -z "$pr_target" ]]; then
    echo "security-invariant FAIL: assert_pr_target_from_chain requires a target argument" >&2
    return 1
  fi

  # Discovery ladder mirrors promotion-chain-guard.sh's discover_config:
  #   1. $PROJECT_CONFIG                                     (explicit env override)
  #   2. $CLAUDE_PROJECT_ROOT/config/project-config.yaml     (if file exists)
  #   3. $PWD/config/project-config.yaml                     (if file exists)
  #   4. Upward walk from $PWD looking for config/project-config.yaml,
  #      capped at 8 levels and stopping at the filesystem root.
  # Without this ladder, /gaia-dev-story Step 13 merges fail the security
  # invariant when CWD is a sub-tree (e.g., gaia-framework/) of a project whose
  # config/ lives at an ancestor.
  local cfg=""
  if [[ -n "${PROJECT_CONFIG:-}" ]]; then
    cfg="$PROJECT_CONFIG"
  elif [[ -n "${CLAUDE_PROJECT_ROOT:-}" ]] \
       && [[ -f "${CLAUDE_PROJECT_ROOT}/config/project-config.yaml" ]]; then
    cfg="${CLAUDE_PROJECT_ROOT}/config/project-config.yaml"
  else
    local dir
    dir="$(pwd -P 2>/dev/null || pwd)"
    local depth=0
    while [[ -n "$dir" && "$depth" -lt 8 ]]; do
      if [[ -f "${dir}/config/project-config.yaml" ]]; then
        cfg="${dir}/config/project-config.yaml"
        break
      fi
      [[ "$dir" == "/" ]] && break
      dir="$(dirname "$dir")"
      depth=$((depth + 1))
    done
  fi
  if [[ -z "$cfg" || ! -f "$cfg" ]]; then
    echo "security-invariant FAIL: project config not found (PROJECT_CONFIG, CLAUDE_PROJECT_ROOT, or upward walk)" >&2
    return 1
  fi

  local expected=""
  if command -v yq >/dev/null 2>&1; then
    expected="$(yq -r '.ci_cd.promotion_chain[0].branch' "$cfg" 2>/dev/null || echo "")"
    # yq emits literal "null" when the key is absent. Treat as empty.
    [[ "$expected" == "null" ]] && expected=""
  fi

  # Fallback parser when yq is unavailable or returned nothing. Looks for
  # the first `branch:` line under a `promotion_chain:` block. Sufficient
  # for the canonical schema; if a more exotic shape ships later, install
  # yq on the runner.
  if [[ -z "$expected" ]]; then
    expected="$(awk '
      /^[[:space:]]*promotion_chain:[[:space:]]*$/ { in_chain = 1; next }
      in_chain && /^[[:space:]]*branch:[[:space:]]*/ {
        sub(/^[[:space:]]*branch:[[:space:]]*/, "")
        gsub(/"/, "")
        print
        exit
      }
      in_chain && /^[^[:space:]-]/ { exit }   # left the block
    ' "$cfg" 2>/dev/null)"
  fi

  if [[ -z "$expected" ]]; then
    echo "security-invariant FAIL: could not read ci_cd.promotion_chain[0].branch from '$cfg'" >&2
    return 1
  fi

  if [[ "$pr_target" != "$expected" ]]; then
    echo "security-invariant FAIL: PR target '$pr_target' != promotion_chain[0].branch '$expected'" >&2
    return 1
  fi

  return 0
}
