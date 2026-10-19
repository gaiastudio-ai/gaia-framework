#!/usr/bin/env bats
# publish-gate-release-commit.bats — tests for the pre-publish gate reading
# CI status from the released commit on the release branch, not from the
# staging HEAD whose newest run may be a cancelled promotion-PR trigger.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  ORCH="$PLUGIN_DIR/skills/gaia-publish/scripts/gaia-publish.sh"
  PROJECT_ROOT="$TEST_TMP/project"
  CONFIG="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  mkdir -p "$(dirname "$CONFIG")" "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
}

teardown() { common_teardown; }

_write_plugin_json() {
  local version="${1:-1.0.0}"
  printf '{"version":"%s","name":"example"}\n' "$version" > "$PROJECT_ROOT/plugin.json"
}

# Write a config with TWO promotion-chain entries (staging + release branch),
# mirroring the real project layout where staging is the development branch
# and main is the release target.
_write_config_with_release_chain() {
  local staging_checks="${1:-plugin-ci}" release_checks="${2:-$1}"
  local release_branch="${3:-main}"
  cat > "$CONFIG" <<YAML
distribution:
  channel: claude-marketplace
  registry: https://example.com/marketplace
  manifest: plugin.json
  release_workflow: release.yml
ci_cd:
  promotion_chain:
    - branch: staging
      ci_checks:
$(printf '        - %s\n' $staging_checks)
    - branch: $release_branch
      ci_checks:
$(printf '        - %s\n' $release_checks)
YAML
}

# Extended gh shim that handles:
#   gh run list --branch <b>  -> GH_FAKE_BRANCH_RUNS_JSON (or GH_FAKE_JSON)
#   gh run list --commit <c>  -> GH_FAKE_COMMIT_RUNS_JSON
#   gh pr  list --base main   -> GH_FAKE_PR_MAIN_JSON (or GH_FAKE_PR_JSON)
#   gh pr  list --base staging-> GH_FAKE_PR_STAGING_JSON (or GH_FAKE_PR_JSON)
#
# When GH_SHIM_FAIL_PR=1, the pr-list subcommand exits non-zero.
# When GH_SHIM_FAIL_RUN=1, the run-list subcommand exits non-zero.
_install_gh_shim() {
  local shim_dir="$TEST_TMP/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/gh" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run list")
    [ "${GH_SHIM_FAIL_RUN:-0}" = "1" ] && { echo "gh-shim: network error" >&2; exit 1; }
    has_commit=0
    for a in "$@"; do
      [ "$a" = "--commit" ] && has_commit=1
    done
    if [ "$has_commit" = "1" ]; then
      printf '%s' "${GH_FAKE_COMMIT_RUNS_JSON:-${GH_FAKE_JSON:-[]}}"
    else
      printf '%s' "${GH_FAKE_BRANCH_RUNS_JSON:-${GH_FAKE_JSON:-[]}}"
    fi
    ;;
  "pr list")
    [ "${GH_SHIM_FAIL_PR:-0}" = "1" ] && { echo "gh-shim: network error" >&2; exit 1; }
    # Distinguish --base main from --base staging.
    base_branch=""
    next_is_base=0
    for a in "$@"; do
      if [ "$next_is_base" = "1" ]; then base_branch="$a"; next_is_base=0; fi
      [ "$a" = "--base" ] && next_is_base=1
    done
    case "$base_branch" in
      main)    printf '%s' "${GH_FAKE_PR_MAIN_JSON:-${GH_FAKE_PR_JSON:-[]}}" ;;
      staging) printf '%s' "${GH_FAKE_PR_STAGING_JSON:-${GH_FAKE_PR_JSON:-[]}}" ;;
      *)       printf '%s' "${GH_FAKE_PR_JSON:-[]}" ;;
    esac
    ;;
  *)
    echo "gh-shim: unhandled args: $*" >&2
    exit 2
    ;;
esac
SHIM
  chmod +x "$shim_dir/gh"
  PATH="$shim_dir:$PATH"
  export PATH
}

# Install a minimal git shim that returns a controlled SHA for rev-parse
# and a dummy remote URL.  Falls through to real git for other commands.
_install_git_shim() {
  local sha="${1:-abc123def456789012345678901234567890abcd}"
  local shim_dir="$TEST_TMP/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/git" <<GITSHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "rev-parse" ]; then
    printf '%s' "$sha"
    exit 0
  fi
  if [ "\$arg" = "get-url" ]; then
    printf 'https://github.com/example/repo'
    exit 0
  fi
done
# Fall through to real git for other commands.
exec /usr/bin/git "\$@"
GITSHIM
  chmod +x "$shim_dir/git"
}

# ---------------------------------------------------------------------------
# Gate reads the release branch (main) when --version is supplied
# ---------------------------------------------------------------------------

@test "publish gate uses the release branch (last chain entry) when --version is given" {
  _write_config_with_release_chain "plugin-ci selective-tests"
  _write_plugin_json 1.222.0
  _install_gh_shim
  _install_git_shim "aaa111bbb222ccc333ddd444eee555fff666777a"

  # The merged PR on main maps the release SHA to the promotion PR head commit.
  export GH_FAKE_PR_MAIN_JSON='[{"headRefOid":"pr-head-1234567890","mergeCommit":{"oid":"aaa111bbb222ccc333ddd444eee555fff666777a"}}]'
  # Commit-based query returns green checks for the promotion PR head.
  export GH_FAKE_COMMIT_RUNS_JSON='[
    {"name":"plugin-ci","status":"completed","conclusion":"success","headSha":"pr-head-1234567890"},
    {"name":"selective-tests","status":"completed","conclusion":"success","headSha":"pr-head-1234567890"}
  ]'
  # Branch-based query would have returned cancelled (the staging bug path).
  export GH_FAKE_BRANCH_RUNS_JSON='[
    {"name":"plugin-ci","status":"completed","conclusion":"cancelled","headSha":"stale-staging-sha"}
  ]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.222.0
  [ "$status" -eq 0 ]
  grep -q 'step 1/5 (pre-publish-gate): PASSED' <<<"$output"
  # Detail line must name the release branch and the release commit SHA.
  grep -q 'main' <<<"$output"
  grep -q 'aaa111bbb' <<<"$output"
}

@test "publish gate PASSED with correct SHA when all required checks succeed on released commit" {
  _write_config_with_release_chain "plugin-ci"
  _write_plugin_json 2.0.0
  _install_gh_shim
  _install_git_shim "release-sha-00112233"

  export GH_FAKE_PR_MAIN_JSON='[{"headRefOid":"prh-9999","mergeCommit":{"oid":"release-sha-00112233"}}]'
  export GH_FAKE_COMMIT_RUNS_JSON='[
    {"name":"plugin-ci","status":"completed","conclusion":"success","headSha":"prh-9999"}
  ]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 2.0.0
  [ "$status" -eq 0 ]
  grep -q 'step 1/5 (pre-publish-gate): PASSED' <<<"$output"
  grep -q 'release-sha-00112233' <<<"$output"
}

# ---------------------------------------------------------------------------
# Fail-closed: cancelled, failure, or missing checks on the released commit
# ---------------------------------------------------------------------------

@test "cancelled check on the released commit fails the gate with check name and conclusion" {
  _write_config_with_release_chain "plugin-ci selective-tests"
  _write_plugin_json 1.222.0
  _install_gh_shim
  _install_git_shim "rel-sha-cancel-test"

  export GH_FAKE_PR_MAIN_JSON='[{"headRefOid":"prh-cancel","mergeCommit":{"oid":"rel-sha-cancel-test"}}]'
  export GH_FAKE_COMMIT_RUNS_JSON='[
    {"name":"plugin-ci","status":"completed","conclusion":"cancelled","headSha":"prh-cancel"},
    {"name":"selective-tests","status":"completed","conclusion":"success","headSha":"prh-cancel"}
  ]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.222.0
  [ "$status" -eq 1 ]
  grep -q 'step 1/5 (pre-publish-gate): FAILED' <<<"$output"
  grep -q 'plugin-ci' <<<"$output"
  grep -q 'cancelled' <<<"$output"
}

@test "failure check on the released commit fails the gate" {
  _write_config_with_release_chain "plugin-ci"
  _write_plugin_json 1.0.0
  _install_gh_shim
  _install_git_shim "rel-sha-fail-test"

  export GH_FAKE_PR_MAIN_JSON='[{"headRefOid":"prh-fail","mergeCommit":{"oid":"rel-sha-fail-test"}}]'
  export GH_FAKE_COMMIT_RUNS_JSON='[
    {"name":"plugin-ci","status":"completed","conclusion":"failure","headSha":"prh-fail"}
  ]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 1 ]
  grep -q 'step 1/5 (pre-publish-gate): FAILED' <<<"$output"
  grep -q 'plugin-ci' <<<"$output"
}

@test "missing required check on the released commit fails the gate" {
  _write_config_with_release_chain "plugin-ci selective-tests"
  _write_plugin_json 1.0.0
  _install_gh_shim
  _install_git_shim "rel-sha-missing-test"

  # Only plugin-ci present; selective-tests is missing entirely.
  export GH_FAKE_PR_MAIN_JSON='[{"headRefOid":"prh-miss","mergeCommit":{"oid":"rel-sha-missing-test"}}]'
  export GH_FAKE_COMMIT_RUNS_JSON='[
    {"name":"plugin-ci","status":"completed","conclusion":"success","headSha":"prh-miss"}
  ]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 1 ]
  grep -q 'step 1/5 (pre-publish-gate): FAILED' <<<"$output"
  grep -q 'selective-tests' <<<"$output"
  grep -q 'missing' <<<"$output"
}

# ---------------------------------------------------------------------------
# Fail-closed: no matching PR for the release SHA
# ---------------------------------------------------------------------------

@test "no merged PR matches the release SHA — gate FAILED with actionable message" {
  _write_config_with_release_chain "plugin-ci"
  _write_plugin_json 1.0.0
  _install_gh_shim
  _install_git_shim "orphan-sha-no-pr"

  # PR list returns PRs, but none match the release SHA.
  export GH_FAKE_PR_MAIN_JSON='[{"headRefOid":"unrelated-pr","mergeCommit":{"oid":"different-sha"}}]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 1 ]
  grep -q 'step 1/5 (pre-publish-gate): FAILED' <<<"$output"
  grep -q 'no merged PR found' <<<"$output"
  grep -q 'orphan-sha-no-pr' <<<"$output"
}

@test "multiple merged PRs match the release SHA — gate FAILED as ambiguous" {
  _write_config_with_release_chain "plugin-ci"
  _write_plugin_json 1.0.0
  _install_gh_shim
  _install_git_shim "multi-match-sha"

  # Two PRs share the same merge commit (shouldn't happen, but guard anyway).
  export GH_FAKE_PR_MAIN_JSON='[
    {"headRefOid":"pr-a","mergeCommit":{"oid":"multi-match-sha"}},
    {"headRefOid":"pr-b","mergeCommit":{"oid":"multi-match-sha"}}
  ]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 1 ]
  grep -q 'step 1/5 (pre-publish-gate): FAILED' <<<"$output"
  grep -q 'ambiguous' <<<"$output"
}

# ---------------------------------------------------------------------------
# Fail-closed: gh CLI errors (network failures, auth issues)
# ---------------------------------------------------------------------------

@test "gh pr list failure causes gate FAILED, not silent empty" {
  _write_config_with_release_chain "plugin-ci"
  _write_plugin_json 1.0.0
  _install_gh_shim
  _install_git_shim "sha-for-gh-fail-test"

  export GH_SHIM_FAIL_PR=1

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 1 ]
  grep -q 'step 1/5 (pre-publish-gate): FAILED' <<<"$output"
  grep -q 'gh pr list failed' <<<"$output"
}

@test "gh run list failure causes gate FAILED, not silent empty" {
  _write_config_with_release_chain "plugin-ci"
  _write_plugin_json 1.0.0
  _install_gh_shim
  _install_git_shim "sha-for-run-fail-test"

  export GH_FAKE_PR_MAIN_JSON='[{"headRefOid":"prh-good","mergeCommit":{"oid":"sha-for-run-fail-test"}}]'
  export GH_SHIM_FAIL_RUN=1

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 1 ]
  grep -q 'step 1/5 (pre-publish-gate): FAILED' <<<"$output"
  grep -q 'gh run list' <<<"$output"
}

# ---------------------------------------------------------------------------
# Legacy fallback: no git, no release SHA -> branch query (single-entry chain)
# ---------------------------------------------------------------------------

@test "single-entry promotion chain still works via branch query" {
  # Config has only one chain entry (staging).  The release-branch override
  # picks staging (the last and only entry), preserving the legacy path.
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: claude-marketplace
  registry: https://example.com/marketplace
  manifest: plugin.json
  release_workflow: release.yml
ci_cd:
  promotion_chain:
    - branch: staging
      ci_checks:
        - plugin-ci
YAML
  _write_plugin_json 1.0.0
  _install_gh_shim

  export GH_FAKE_JSON='[{"name":"plugin-ci","status":"completed","conclusion":"success","headSha":"abc123"}]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  grep -q 'step 1/5 (pre-publish-gate): PASSED' <<<"$output"
}

@test "no git available and no release SHA falls through to branch query" {
  _write_config_with_release_chain "plugin-ci"
  _write_plugin_json 1.0.0
  _install_gh_shim
  # No git shim — rev-parse fails, _release_sha is empty, branch query runs.

  export GH_FAKE_BRANCH_RUNS_JSON='[
    {"name":"plugin-ci","status":"completed","conclusion":"success","headSha":"branch-sha"}
  ]'

  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 0 ]
  grep -q 'step 1/5 (pre-publish-gate): PASSED' <<<"$output"
}
