#!/usr/bin/env bash
# per-sprint-release.sh — cherry-pick-tag-merge-back for per-sprint releases.
#
# Collects a closed sprint's merged commits from the merge ledger, cherry-picks
# them onto a branch cut from the latest tag, bumps the version and generates
# a sprint-scoped CHANGELOG, tags, pushes, creates a GitHub Release, records
# a release intent in the merge ledger, and opens a merge-back PR to main.
#
# In single-sprint mode (max_concurrent_active absent or 1 and no per-sprint
# state files), the script exits immediately with exit 0 and a message
# directing the caller to the legacy release flow (Steps 1-10 in the skill).
#
# Usage:
#   per-sprint-release.sh --sprint <sprint_id> \
#     [--project-root <path>] [--config <path>]
#
# Environment:
#   CLAUDE_PLUGIN_ROOT — plugin root (for sourcing helpers)
#   CLAUDE_PROJECT_ROOT / PROJECT_ROOT — project root fallback
#   PROJECT_CONFIG — config path fallback
#
# Exit codes:
#   0 — success (or clean no-op: single-sprint mode, zero commits)
#   1 — general failure / merge ledger absent
#   3 — sprint close in progress (from pre-release-sprint-check.sh)
#       or L6 lock timeout
#   4 — L6 strict-mode non-regular-file lock path refused
#   5 — L6 strict-mode identity re-check mismatch
#   8 — cherry-pick conflict
#
# Bash 3.2 compatible.

set -euo pipefail
LC_ALL=C; export LC_ALL

_PSR_SCRIPT_NAME="per-sprint-release"
_PSR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PSR_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_PSR_SCRIPT_DIR/../../.." && pwd)}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_psr_log()  { printf '%s: %s\n' "$_PSR_SCRIPT_NAME" "$*" >&2; }
_psr_die()  { _psr_log "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Source shared libraries
# ---------------------------------------------------------------------------
_PSR_LOCK_LIB="${_PSR_PLUGIN_ROOT}/scripts/lib/acquire-lock.sh"
if [ ! -f "$_PSR_LOCK_LIB" ]; then
  _psr_die "lock library not found at $_PSR_LOCK_LIB"
fi
# shellcheck source=../../../scripts/lib/acquire-lock.sh
. "$_PSR_LOCK_LIB"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
_psr_sprint_id=""
_psr_project_root=""
_psr_config_path=""

_psr_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --sprint)       _psr_sprint_id="$2"; shift 2 ;;
      --project-root) _psr_project_root="$2"; shift 2 ;;
      --config)       _psr_config_path="$2"; shift 2 ;;
      --help|-h)
        printf 'Usage: per-sprint-release.sh --sprint <id> [--project-root <path>] [--config <path>]\n'
        exit 0
        ;;
      *) _psr_die "unknown argument: $1" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------
_psr_resolve_paths() {
  # Project root
  if [ -z "$_psr_project_root" ]; then
    _psr_project_root="${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-$PWD}}"
  fi
  if [ ! -d "$_psr_project_root/.gaia/state" ]; then
    _psr_die "project root not found or missing .gaia/state: $_psr_project_root"
  fi

  # Config path
  if [ -z "$_psr_config_path" ]; then
    _psr_config_path="${PROJECT_CONFIG:-${_psr_project_root}/.gaia/config/project-config.yaml}"
  fi
  if [ ! -f "$_psr_config_path" ]; then
    _psr_die "config not found: $_psr_config_path"
  fi

  _psr_state_dir="${_psr_project_root}/.gaia/state"
  _psr_ledger_dir="${_psr_state_dir}/merge"
}

# ---------------------------------------------------------------------------
# Concurrent mode check
# ---------------------------------------------------------------------------
_psr_is_concurrent_mode() {
  local max_conc=""
  if command -v yq >/dev/null 2>&1; then
    max_conc="$(yq '.sprint.max_concurrent_active // ""' "$_psr_config_path" 2>/dev/null)" || max_conc=""
  else
    # Minimal YAML reader fallback
    max_conc="$(awk '/^[[:space:]]*max_concurrent_active:/ { sub(/.*:/, ""); gsub(/[[:space:]"'\'']+/, ""); print }' "$_psr_config_path" 2>/dev/null)" || max_conc=""
  fi
  acquire_lock_is_concurrent_mode "$max_conc" "$_psr_state_dir"
}

# ---------------------------------------------------------------------------
# Read a YAML field from a file (same pattern as merge-ledger.sh)
# ---------------------------------------------------------------------------
_psr_read_field() {
  local file="$1" field="$2"
  if [ ! -f "$file" ]; then return 1; fi
  sed -n "s/^${field}: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$file" | head -1
}

# ---------------------------------------------------------------------------
# Collect sprint's stories from sprint state file
# ---------------------------------------------------------------------------
_psr_collect_sprint_stories() {
  local sprint_id="$1"
  local state_file="${_psr_state_dir}/sprint-status-${sprint_id}.yaml"

  if [ ! -f "$state_file" ]; then
    _psr_die "sprint state file not found: $state_file"
  fi

  # Check sprint is closed
  local status=""
  status="$(_psr_read_field "$state_file" status)" || status=""
  if [ "$status" != "closed" ]; then
    _psr_die "sprint $sprint_id is not closed (status: ${status:-unknown})"
  fi

  # Extract story keys from the stories list in the sprint state file.
  # The format is either inline [key1, key2] or block list entries.
  awk '
    /^stories:/ { in_stories=1; next }
    in_stories && /^[a-zA-Z_]/ { exit }
    in_stories && /- / {
      sub(/^[[:space:]]*- *"?/, "")
      sub(/"? *$/, "")
      if ($0 != "" && $0 !~ /^[[:space:]]*$/) print
    }
    # Inline array format: stories: [key1, key2]
    /^stories: *\[/ {
      sub(/^stories: *\[/, "")
      sub(/\] *$/, "")
      gsub(/"/, "")
      gsub(/'\''/, "")
      n = split($0, a, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i])
        if (a[i] != "") print a[i]
      }
    }
  ' "$state_file"
}

# ---------------------------------------------------------------------------
# Verify all collected SHAs belong to the named sprint
# ---------------------------------------------------------------------------
_psr_verify_commit_provenance() {
  local sprint_id="$1"
  shift
  # Remaining args: story keys that belong to this sprint

  local sprint_stories=""
  for key in "$@"; do
    sprint_stories="${sprint_stories:+${sprint_stories}|}${key}"
  done

  # Read commit list from stdin (sha story_key per line)
  while IFS=' ' read -r sha story_key; do
    local belongs=false
    for key in "$@"; do
      if [ "$story_key" = "$key" ]; then
        belongs=true
        break
      fi
    done
    if ! $belongs; then
      printf 'commit %s claims story %s which does not belong to sprint %s\n' \
        "$sha" "$story_key" "$sprint_id" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Cherry-pick commits onto a detached branch from the latest tag
# ---------------------------------------------------------------------------
_psr_cherry_pick_commits() {
  local project_root="$1"
  local release_worktree="$2"
  shift 2
  # Remaining args: commit SHAs in order

  for sha in "$@"; do
    if ! git -C "$release_worktree" cherry-pick -x "$sha" 2>"${release_worktree}/.cherry-pick-err" ; then
      # Determine conflicting files
      local conflicts=""
      conflicts="$(git -C "$release_worktree" diff --name-only --diff-filter=U 2>/dev/null || true)"
      local story_key=""
      # Try to get story key from commit message
      story_key="$(git -C "$project_root" log -1 --format='%s' "$sha" 2>/dev/null | sed -n 's/.*Story: *\([^ ]*\).*/\1/p' || true)"
      [ -z "$story_key" ] && story_key="unknown"

      printf 'cherry-pick conflict on commit %s (story: %s)\n' "$sha" "$story_key" >&2
      if [ -n "$conflicts" ]; then
        printf 'conflicting files:\n%s\n' "$conflicts" >&2
      fi

      # Abort the cherry-pick
      git -C "$release_worktree" cherry-pick --abort 2>/dev/null || true
      rm -f "${release_worktree}/.cherry-pick-err"
      return 8
    fi
    rm -f "${release_worktree}/.cherry-pick-err"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Monotonic version guard
# ---------------------------------------------------------------------------
_psr_version_is_higher() {
  # Returns 0 if $1 > $2 (semver numeric comparison)
  local new="$1" old="$2"

  # Strip leading v
  new="${new#v}"
  old="${old#v}"

  local new_major new_minor new_patch old_major old_minor old_patch
  IFS='.' read -r new_major new_minor new_patch <<EOF
$new
EOF
  IFS='.' read -r old_major old_minor old_patch <<EOF
$old
EOF

  # Strip non-numeric suffixes
  new_patch="${new_patch%%[!0-9]*}"
  old_patch="${old_patch%%[!0-9]*}"

  # Default to 0
  new_major="${new_major:-0}"; new_minor="${new_minor:-0}"; new_patch="${new_patch:-0}"
  old_major="${old_major:-0}"; old_minor="${old_minor:-0}"; old_patch="${old_patch:-0}"

  if [ "$new_major" -gt "$old_major" ] 2>/dev/null; then return 0; fi
  if [ "$new_major" -lt "$old_major" ] 2>/dev/null; then return 1; fi
  if [ "$new_minor" -gt "$old_minor" ] 2>/dev/null; then return 0; fi
  if [ "$new_minor" -lt "$old_minor" ] 2>/dev/null; then return 1; fi
  if [ "$new_patch" -gt "$old_patch" ] 2>/dev/null; then return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# Create the merge-back PR (or token fallback)
# ---------------------------------------------------------------------------
_psr_create_merge_back_pr() {
  local project_root="$1"
  local version="$2"
  local version_files="$3"  # space-separated list
  local release_worktree="$4"

  local pr_branch="release/v${version}"

  # Create the merge-back branch from main HEAD
  git -C "$project_root" checkout -b "$pr_branch" main >/dev/null 2>&1 || \
    git -C "$project_root" branch "$pr_branch" main >/dev/null 2>&1

  git -C "$project_root" checkout "$pr_branch" >/dev/null 2>&1

  # Copy version files and CHANGELOG from the tagged commit in the release worktree
  local file=""
  for file in $version_files; do
    if git -C "$release_worktree" show "HEAD:${file}" >/dev/null 2>&1; then
      mkdir -p "$(dirname "${project_root}/${file}")"
      git -C "$release_worktree" show "HEAD:${file}" > "${project_root}/${file}"
      git -C "$project_root" add "$file"
    fi
  done

  # Copy CHANGELOG files
  local changelog_files=""
  changelog_files="$(git -C "$release_worktree" diff --name-only "HEAD~1" HEAD 2>/dev/null | grep 'CHANGELOG' || true)"
  if [ -z "$changelog_files" ]; then
    # Try to find CHANGELOG at project root
    if git -C "$release_worktree" show "HEAD:CHANGELOG.md" >/dev/null 2>&1; then
      changelog_files="CHANGELOG.md"
    fi
  fi
  for file in $changelog_files; do
    if git -C "$release_worktree" show "HEAD:${file}" >/dev/null 2>&1; then
      mkdir -p "$(dirname "${project_root}/${file}")"
      git -C "$release_worktree" show "HEAD:${file}" > "${project_root}/${file}"
      git -C "$project_root" add "$file"
    fi
  done

  # Commit
  git -C "$project_root" commit -m "chore(release): bump version to v${version}" >/dev/null 2>&1 || true

  # Push the branch
  git -C "$project_root" push origin "$pr_branch" >/dev/null 2>&1 || true

  local head_sha=""
  head_sha="$(git -C "$project_root" rev-parse "$pr_branch")"

  # Try to create the PR
  local pr_number=""
  if command -v gh >/dev/null 2>&1; then
    local pr_output=""
    pr_output="$(gh pr create \
      --repo "$(git -C "$project_root" remote get-url origin 2>/dev/null || echo 'origin')" \
      --base main \
      --head "$pr_branch" \
      --title "chore(release): bump version to v${version}" \
      --body "Release merge-back: version bump to v${version}" \
      2>&1)" || true

    # Extract PR number from output
    if [ -n "$pr_output" ]; then
      pr_number="$(printf '%s' "$pr_output" | grep -o '/pull/[0-9]*' | grep -o '[0-9]*' | tail -1)" || pr_number=""
    fi
  fi

  # Record the release intent via the merge ledger (sole writer)
  local _psr_ml="${_PSR_PLUGIN_ROOT}/scripts/merge-ledger.sh"
  if [ -n "$pr_number" ]; then
    MERGE_LEDGER_DIR="$_psr_ledger_dir" \
      bash "$_psr_ml" record --mode release \
        --head-sha "$head_sha" --target "main" --pr-branch "$pr_branch" \
        --pr-number "$pr_number" >/dev/null 2>&1 || true
    _psr_log "merge-back PR #${pr_number} opened on branch $pr_branch"
  else
    MERGE_LEDGER_DIR="$_psr_ledger_dir" \
      bash "$_psr_ml" record --mode release \
        --head-sha "$head_sha" --target "main" --pr-branch "$pr_branch" \
        >/dev/null 2>&1 || true
    # Token fallback: print the one-click PR URL
    local remote_url=""
    remote_url="$(git -C "$project_root" remote get-url origin 2>/dev/null)" || remote_url=""
    if [ -n "$remote_url" ]; then
      # Convert git@ or https:// URL to a compare URL
      local base_url=""
      base_url="$(printf '%s' "$remote_url" | sed 's|git@github.com:|https://github.com/|;s|\.git$||')"
      printf 'merge-back PR could not be created automatically\n'
      printf 'create it manually: %s/compare/main...%s\n' "$base_url" "$pr_branch"
    else
      printf 'merge-back PR could not be created; push branch %s and create PR manually\n' "$pr_branch"
    fi
    _psr_log "token fallback: branch $pr_branch pushed, no PR created"
  fi

  # Restore the original branch
  git -C "$project_root" checkout - >/dev/null 2>&1 || true

  printf '%s\n' "${pr_number:-}"
}

# ---------------------------------------------------------------------------
# Read version_files from config
# ---------------------------------------------------------------------------
_psr_read_version_files() {
  local config="$1"
  if command -v yq >/dev/null 2>&1; then
    yq '.release.version_files[]' "$config" 2>/dev/null || true
  else
    awk '
      /^[[:space:]]*version_files:/ { in_vf=1; next }
      in_vf && /^[a-zA-Z_]/ { exit }
      in_vf && /^[[:space:]]*-/ {
        sub(/^[[:space:]]*- *"?/, "")
        sub(/"? *$/, "")
        print
      }
    ' "$config"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
_psr_main() {
  _psr_parse_args "$@"

  if [ -z "$_psr_sprint_id" ]; then
    _psr_die "--sprint <sprint_id> is required"
  fi

  _psr_resolve_paths

  # ── Step 0: Check concurrent mode ──────────────────────────────────
  if ! _psr_is_concurrent_mode; then
    _psr_log "single-sprint mode: use the legacy release flow (Steps 1-10)"
    exit 0
  fi

  # ── Step 1: Pre-release sprint check (acquires and releases L4) ────
  local pre_check_script="${_PSR_SCRIPT_DIR}/pre-release-sprint-check.sh"
  if [ ! -x "$pre_check_script" ]; then
    pre_check_script="${_PSR_PLUGIN_ROOT}/skills/gaia-release/scripts/pre-release-sprint-check.sh"
  fi

  if [ -x "$pre_check_script" ]; then
    local pre_rc=0
    local _pre_out=""
    _pre_out="$(PROJECT_ROOT="$_psr_project_root" \
    PROJECT_CONFIG="$_psr_config_path" \
      bash "$pre_check_script" 2>&1)" || pre_rc=$?
    if [ "$pre_rc" -ne 0 ]; then
      printf '%s\n' "$_pre_out" >&2
      exit "$pre_rc"
    fi
  fi

  # ── Step 2: Check merge ledger ─────────────────────────────────────
  if [ ! -d "$_psr_ledger_dir" ]; then
    _psr_log "merge ledger not available"
    exit 1
  fi

  # ── Step 3: Collect sprint's stories ───────────────────────────────
  local stories=""
  stories="$(_psr_collect_sprint_stories "$_psr_sprint_id")" || exit 1

  if [ -z "$stories" ]; then
    _psr_log "no stories found for sprint $_psr_sprint_id"
    exit 1
  fi

  # Convert to array (Bash 3.2 compatible)
  local story_array=""
  local _s=""
  while IFS= read -r _s; do
    story_array="${story_array:+${story_array} }${_s}"
  done <<EOF
$stories
EOF

  # ── Step 4: Collect commits from ledger ────────────────────────────
  local _psr_merge_ledger="${_PSR_PLUGIN_ROOT}/scripts/merge-ledger.sh"
  local commit_list=""
  commit_list="$(MERGE_LEDGER_DIR="$_psr_ledger_dir" \
    bash "$_psr_merge_ledger" list --sprint "$_psr_sprint_id" \
      --state-dir "$_psr_state_dir")" || {
    _psr_log "merge ledger not available"
    exit 1
  }

  if [ -z "$commit_list" ]; then
    _psr_log "no commits to release for sprint $_psr_sprint_id"
    exit 0
  fi

  # ── Step 5: Verify commit provenance ───────────────────────────────
  # shellcheck disable=SC2086
  printf '%s\n' "$commit_list" | _psr_verify_commit_provenance "$_psr_sprint_id" $story_array || {
    _psr_log "commit provenance verification failed"
    exit 1
  }

  # Extract just the SHAs in order
  local commit_shas=""
  commit_shas="$(printf '%s\n' "$commit_list" | awk '{print $1}')"

  # ── Step 6: Acquire L6 (release lock) ──────────────────────────────
  # Acquired before tag resolution so that concurrent releases serialize
  # on version selection — otherwise both resolve the same base tag and
  # the second collides on tag creation.
  local l6_path="${_psr_state_dir}/.release.lock"
  local l6_timeout=120

  # Set up cleanup trap (release L6 if held, remove worktree when created)
  _psr_cleanup() {
    release_lock 9 2>/dev/null || true
    if [ -n "${release_worktree:-}" ] && [ -d "$release_worktree" ]; then
      git -C "$_psr_project_root" worktree remove --force "$release_worktree" 2>/dev/null || true
      rm -rf "$release_worktree" 2>/dev/null || true
    fi
  }
  trap '_psr_cleanup' EXIT
  trap '_psr_cleanup; exit 130' INT
  trap '_psr_cleanup; exit 143' TERM

  local l6_rc=0
  acquire_lock "$l6_path" "$l6_timeout" 9 --strict || l6_rc=$?
  if [ "$l6_rc" -ne 0 ]; then
    exit "$l6_rc"
  fi

  # ── Step 7: Resolve the latest tag as cherry-pick base ─────────────
  # Inside L6 so the resolved tag is always the actual latest.
  # Use `git tag -l | sort -V` instead of `git describe` because describe
  # only sees tags reachable from HEAD, and a concurrent release's tag on
  # a cherry-pick branch is not reachable from main.
  local latest_tag=""
  latest_tag="$(git -C "$_psr_project_root" tag -l 'v*' 2>/dev/null | sort -V | tail -1)"

  if [ -z "$latest_tag" ]; then
    _psr_die "no v* tag found; cannot create a per-sprint release without a baseline tag"
  fi

  # ── Step 8: Create a detached worktree and cherry-pick ─────────────
  local release_worktree=""
  release_worktree="$(mktemp -d "${TMPDIR:-/tmp}/psr-release-XXXXXX")"
  # Use a detached worktree from the tag
  git -C "$_psr_project_root" worktree add --detach "$release_worktree" "$latest_tag" 2>/dev/null || {
    # Fallback: clone and checkout the tag
    git clone --no-checkout "$_psr_project_root" "$release_worktree" 2>/dev/null
    git -C "$release_worktree" checkout "$latest_tag" 2>/dev/null
  }

  # Cherry-pick each commit in ledger order
  local sha_array=""
  while IFS= read -r sha; do
    sha_array="${sha_array:+${sha_array} }${sha}"
  done <<EOF
$commit_shas
EOF

  local cherry_rc=0
  # shellcheck disable=SC2086
  _psr_cherry_pick_commits "$_psr_project_root" "$release_worktree" $sha_array || cherry_rc=$?
  if [ "$cherry_rc" -ne 0 ]; then
    exit "$cherry_rc"
  fi

  # ── Step 9: Resolve version and monotonic guard ────────────────────
  local resolve_script="${_PSR_SCRIPT_DIR}/resolve-release-version.sh"
  if [ ! -f "$resolve_script" ]; then
    resolve_script="${_PSR_PLUGIN_ROOT}/skills/gaia-release/scripts/resolve-release-version.sh"
  fi

  # Collect cherry-picked commit messages for the classifier
  local commit_messages=""
  for sha in $sha_array; do
    local msg=""
    msg="$(git -C "$release_worktree" log -1 --format='%B' "$sha" 2>/dev/null || \
           git -C "$_psr_project_root" log -1 --format='%B' "$sha" 2>/dev/null || true)"
    if [ -n "$msg" ]; then
      commit_messages="${commit_messages:+${commit_messages}---COMMIT---}${msg}"
    fi
  done

  local version_output=""
  version_output="$(bash "$resolve_script" \
    --config "$_psr_config_path" \
    --project-root "$release_worktree" \
    --commits "$commit_messages" 2>/dev/null)" || {
    # Fallback: run without --commits (uses git log range from tag)
    version_output="$(bash "$resolve_script" \
      --config "$_psr_config_path" \
      --project-root "$release_worktree" 2>/dev/null)" || _psr_die "version resolution failed"
  }

  # Parse the version output
  local bump_type=""
  local resolved_version=""
  while IFS='=' read -r key val; do
    case "$key" in
      bump)     bump_type="$val" ;;
      version)  resolved_version="$val" ;;
      strategy) : ;; # read but not consumed
    esac
  done <<EOF
$version_output
EOF

  if [ "$bump_type" = "none" ]; then
    _psr_log "no releasable changes for sprint $_psr_sprint_id"
    release_lock 9 2>/dev/null || true
    exit 0
  fi

  # ── Step 10: Version bump ──────────────────────────────────────────
  local bump_script="${_PSR_PLUGIN_ROOT}/skills/gaia-release/scripts/version-bump.js"
  local bump_spec="${resolved_version:-$bump_type}"

  if [ -n "$bump_spec" ] && [ -f "$bump_script" ] && command -v node >/dev/null 2>&1; then
    node "$bump_script" "$bump_spec" \
      --config "$_psr_config_path" \
      --project-root "$release_worktree" >/dev/null 2>&1 || true
  fi

  # Read the new version from the first version file
  local version_files=""
  version_files="$(_psr_read_version_files "$_psr_config_path")"
  local new_version=""
  local first_vf=""
  first_vf="$(printf '%s\n' "$version_files" | head -1)"
  if [ -n "$first_vf" ] && [ -f "${release_worktree}/${first_vf}" ]; then
    new_version="$(cat "${release_worktree}/${first_vf}" | tr -d '[:space:]')"
  fi

  if [ -z "$new_version" ]; then
    new_version="${resolved_version:-${bump_type}}"
  fi
  # Strip leading v for the version number
  new_version="${new_version#v}"

  # Monotonic guard
  local tag_version="${latest_tag#v}"
  if ! _psr_version_is_higher "$new_version" "$tag_version"; then
    _psr_log "monotonic version guard: v${new_version} is not higher than ${latest_tag}"
    release_lock 9 2>/dev/null || true
    exit 1
  fi

  # ── Step 11: Sprint-scoped CHANGELOG ───────────────────────────────
  # Generate CHANGELOG entry from cherry-picked commits
  local changelog="${release_worktree}/CHANGELOG.md"
  local changelog_tmp="${changelog}.tmp"

  {
    printf '## v%s\n\n' "$new_version"
    for sha in $sha_array; do
      local msg=""
      msg="$(git -C "$release_worktree" log -1 --format='%s' "$sha" 2>/dev/null || \
             git -C "$_psr_project_root" log -1 --format='%s' "$sha" 2>/dev/null || true)"
      if [ -n "$msg" ]; then
        printf '%s\n' "- ${msg}"
      fi
    done
    printf '\n'
    if [ -f "$changelog" ]; then
      cat "$changelog"
    fi
  } > "$changelog_tmp"
  mv "$changelog_tmp" "$changelog"

  # ── Step 12: Commit the version bump + CHANGELOG ───────────────────
  git -C "$release_worktree" add -A >/dev/null 2>&1 || true
  git -C "$release_worktree" commit -m "chore(release): bump version to v${new_version}" >/dev/null 2>&1 || true

  # ── Step 13: Tag the cherry-pick branch tip ────────────────────────
  git -C "$release_worktree" tag -a "v${new_version}" -m "v${new_version}" >/dev/null 2>&1 || \
    _psr_die "failed to create tag v${new_version}"

  # ── Step 14: Push tag to origin ────────────────────────────────────
  git -C "$release_worktree" push origin "v${new_version}" 2>/dev/null || \
    git -C "$_psr_project_root" push origin "v${new_version}" 2>/dev/null || \
    _psr_log "warning: could not push tag v${new_version} to origin"

  # ── Step 15: Create GitHub Release ─────────────────────────────────
  local release_title="v${new_version}"
  # Build release notes from the CHANGELOG section we just wrote
  local release_notes_file="${release_worktree}/release-notes.tmp"
  {
    printf '## v%s\n\n' "$new_version"
    for sha in $sha_array; do
      local _rn_msg=""
      _rn_msg="$(git -C "$release_worktree" log -1 --format='%s' "$sha" 2>/dev/null || \
                 git -C "$_psr_project_root" log -1 --format='%s' "$sha" 2>/dev/null || true)"
      if [ -n "$_rn_msg" ]; then
        printf '%s\n' "- ${_rn_msg}"
      fi
    done
  } > "$release_notes_file"

  if command -v gh >/dev/null 2>&1; then
    gh release create "v${new_version}" \
      --title "$release_title" \
      --notes-file "$release_notes_file" \
      --repo "$(git -C "$_psr_project_root" remote get-url origin 2>/dev/null || echo 'origin')" \
      >/dev/null 2>&1 || _psr_log "warning: could not create GitHub Release"
  fi
  rm -f "$release_notes_file"

  # ── Step 16: Release L6 ───────────────────────────────────────────
  release_lock 9 2>/dev/null || true

  # ── Step 17: Create merge-back PR ──────────────────────────────────
  local pr_number=""
  pr_number="$(_psr_create_merge_back_pr "$_psr_project_root" "$new_version" "$version_files" "$release_worktree")"

  _psr_log "per-sprint release complete: v${new_version} for sprint $_psr_sprint_id"
  printf 'version=%s\n' "$new_version"
  printf 'tag=v%s\n' "$new_version"
  if [ -n "$pr_number" ]; then
    printf 'merge_back_pr=%s\n' "$pr_number"
  fi
}

# Main guard — sourcing does not run main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _psr_main "$@"
fi
