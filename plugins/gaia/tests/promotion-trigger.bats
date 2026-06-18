#!/usr/bin/env bats
# promotion-trigger.bats — post-merge promotion trigger tests.
#
# Validates the release-then-deploy orchestration that fires after a merge
# to the promotion branch. Each test injects shim binaries via env vars
# (GAIA_RELEASE_BIN, GAIA_DEPLOY_BIN) to control release/deploy outcomes
# while verifying real invocation logging and the anti-stub contract.

load 'test_helper.bash'

setup() {
  common_setup

  # -- scaffold a minimal project-config.yaml --
  mkdir -p "$TEST_TMP/project/.gaia/config"
  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" <<'YAML'
ci_cd:
  promotion_chain:
    - id: staging
      branch: staging
    - id: production
      branch: main
release:
  strategy: calendar
  version_files:
    - VERSION
stacks:
  - name: api
    path: services/api
  - name: web
    path: apps/web
  - name: worker
    path: services/worker
YAML

  # -- create a VERSION file so version-bump.js can read it --
  printf '1.0.0\n' > "$TEST_TMP/project/VERSION"

  # -- resolve the trigger script path --
  TRIGGER_SCRIPT="$BATS_TEST_DIRNAME/../scripts/promotion-trigger.sh"

  # -- build a release shim that succeeds --
  mkdir -p "$TEST_TMP/shims"
  cat > "$TEST_TMP/shims/release-success.sh" <<'SH'
#!/usr/bin/env bash
# Shim: emits the same key=value contract as resolve-release-version.sh
printf 'strategy=calendar\n'
printf 'version=2026.6.0\n'
exit 0
SH
  chmod +x "$TEST_TMP/shims/release-success.sh"

  # -- build a version-bump shim that succeeds --
  cat > "$TEST_TMP/shims/version-bump-success.sh" <<'SH'
#!/usr/bin/env bash
# Shim: emits the same JSON contract as version-bump.js
printf '{"old_version":"1.0.0","new_version":"2026.6.0","bump_type":"2026.6.0","bumped":[]}\n'
exit 0
SH
  chmod +x "$TEST_TMP/shims/version-bump-success.sh"

  # -- build a release shim that fails (no releasable changes) --
  cat > "$TEST_TMP/shims/release-fail.sh" <<'SH'
#!/usr/bin/env bash
printf 'strategy=conventional-commits\n'
printf 'bump=none\n'
printf 'message=no releasable changes\n'
exit 0
SH
  chmod +x "$TEST_TMP/shims/release-fail.sh"

  # -- build a release shim that exits non-zero --
  cat > "$TEST_TMP/shims/release-error.sh" <<'SH'
#!/usr/bin/env bash
printf 'resolve-release-version: version conflict\n' >&2
exit 2
SH
  chmod +x "$TEST_TMP/shims/release-error.sh"

  # -- build a deploy shim that logs invocation and succeeds --
  # Parses the same --env/--version/--output-dir/--components flag interface
  # as the real deploy-dispatch.sh to pin the contract in tests.
  cat > "$TEST_TMP/shims/deploy-success.sh" <<'SH'
#!/usr/bin/env bash
_env="" _ver="" _outdir="" _comp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env)        _env="$2"; shift 2 ;;
    --version)    _ver="$2"; shift 2 ;;
    --output-dir) _outdir="$2"; shift 2 ;;
    --components) _comp="$2"; shift 2 ;;
    *) printf 'deploy-shim: unexpected arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done
# Fail fast if required flags are missing (mirrors deploy-dispatch.sh).
if [ -z "$_env" ] || [ -z "$_ver" ] || [ -z "$_outdir" ]; then
  printf 'deploy-shim: missing required flags (--env/--version/--output-dir)\n' >&2
  exit 2
fi
printf 'DEPLOY_INVOCATION: env=%s components=%s version=%s output-dir=%s\n' \
  "$_env" "$_comp" "$_ver" "$_outdir" >> "${DEPLOY_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/deploy-success.sh"

  # -- build a deploy shim that fails on production --
  cat > "$TEST_TMP/shims/deploy-fail.sh" <<'SH'
#!/usr/bin/env bash
_env="" _ver="" _outdir="" _comp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env)        _env="$2"; shift 2 ;;
    --version)    _ver="$2"; shift 2 ;;
    --output-dir) _outdir="$2"; shift 2 ;;
    --components) _comp="$2"; shift 2 ;;
    *) printf 'deploy-shim: unexpected arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [ -z "$_env" ] || [ -z "$_ver" ] || [ -z "$_outdir" ]; then
  printf 'deploy-shim: missing required flags\n' >&2; exit 2
fi
printf 'DEPLOY_INVOCATION: env=%s components=%s version=%s output-dir=%s\n' \
  "$_env" "$_comp" "$_ver" "$_outdir" >> "${DEPLOY_LOG:-/dev/null}"
# Fail on the second environment to test partial-failure reporting.
if [[ "$_env" == "production" ]]; then exit 1; fi
exit 0
SH
  chmod +x "$TEST_TMP/shims/deploy-fail.sh"

  # -- build an affected-set shim that returns specific components --
  cat > "$TEST_TMP/shims/affected-set-selective.sh" <<'SH'
#!/usr/bin/env bash
printf '{"stacks":["api","web"],"channel":"ci-artifact"}\n'
exit 0
SH
  chmod +x "$TEST_TMP/shims/affected-set-selective.sh"

  # -- build an affected-set shim that returns wildcard --
  cat > "$TEST_TMP/shims/affected-set-wildcard.sh" <<'SH'
#!/usr/bin/env bash
printf '{"stacks":["*"],"channel":"full-deploy"}\n'
exit 0
SH
  chmod +x "$TEST_TMP/shims/affected-set-wildcard.sh"

  # -- deploy invocation log --
  export DEPLOY_LOG="$TEST_TMP/deploy.log"
  touch "$DEPLOY_LOG"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# AC1 — promotion trigger invokes gaia-release on merge to the promotion branch
# ---------------------------------------------------------------------------
@test "promotion trigger invokes gaia-release on merge to the promotion branch" {
  export GAIA_RELEASE_BIN="$TEST_TMP/shims/release-success.sh"
  export GAIA_VERSION_BUMP_BIN="$TEST_TMP/shims/version-bump-success.sh"
  export GAIA_DEPLOY_BIN="$TEST_TMP/shims/deploy-success.sh"
  export GAIA_AFFECTED_SET_BIN="$TEST_TMP/shims/affected-set-selective.sh"

  # Anti-stub: ensure no *_STUB vars are set.
  unset GAIA_RELEASE_STUB GAIA_DEPLOY_STUB 2>/dev/null || true

  run bash "$TRIGGER_SCRIPT" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP/project"

  # The trigger must succeed.
  [ "$status" -eq 0 ]

  # A real release invocation must be logged (not a stub).
  [[ "$output" == *"release: invoked"* ]]
  [[ "$output" == *"version=2026.6.0"* ]]

  # Anti-stub contract: no *_STUB env vars were active.
  [[ -z "${GAIA_RELEASE_STUB:-}" ]]
  [[ -z "${GAIA_DEPLOY_STUB:-}" ]]
}

# ---------------------------------------------------------------------------
# AC2 — promotion trigger dispatches per-environment deploy of only the affected components
# ---------------------------------------------------------------------------
@test "promotion trigger dispatches per-environment deploy of only the affected components" {
  export GAIA_RELEASE_BIN="$TEST_TMP/shims/release-success.sh"
  export GAIA_VERSION_BUMP_BIN="$TEST_TMP/shims/version-bump-success.sh"
  export GAIA_DEPLOY_BIN="$TEST_TMP/shims/deploy-success.sh"
  export GAIA_AFFECTED_SET_BIN="$TEST_TMP/shims/affected-set-selective.sh"
  unset GAIA_RELEASE_STUB GAIA_DEPLOY_STUB 2>/dev/null || true

  run bash "$TRIGGER_SCRIPT" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP/project"

  [ "$status" -eq 0 ]

  # Deploy must be invoked once per environment in the promotion chain.
  # The affected-set shim returns ["api","web"].
  [[ "$(grep -c 'DEPLOY_INVOCATION' "$DEPLOY_LOG")" -eq 2 ]]

  # Staging env must deploy only the affected components.
  grep -q 'DEPLOY_INVOCATION: env=staging components=api,web' "$DEPLOY_LOG"

  # Production env must deploy only the affected components.
  grep -q 'DEPLOY_INVOCATION: env=production components=api,web' "$DEPLOY_LOG"

  # Real deploy invocations logged (not stub).
  [[ "$output" == *"deploy: invoked env=staging"* ]]
  [[ "$output" == *"deploy: invoked env=production"* ]]
  [[ -z "${GAIA_DEPLOY_STUB:-}" ]]
}

# ---------------------------------------------------------------------------
# AC3 — promotion trigger skips deploy and reports when release fails
# ---------------------------------------------------------------------------
@test "promotion trigger skips deploy and reports when release fails" {
  # Use the "bump=none" shim (no releasable changes).
  export GAIA_RELEASE_BIN="$TEST_TMP/shims/release-fail.sh"
  export GAIA_VERSION_BUMP_BIN="$TEST_TMP/shims/version-bump-success.sh"
  export GAIA_DEPLOY_BIN="$TEST_TMP/shims/deploy-success.sh"
  export GAIA_AFFECTED_SET_BIN="$TEST_TMP/shims/affected-set-selective.sh"
  unset GAIA_RELEASE_STUB GAIA_DEPLOY_STUB 2>/dev/null || true

  run bash "$TRIGGER_SCRIPT" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP/project"

  # Non-zero exit: release produced no releasable version.
  [ "$status" -ne 0 ]

  # Deploy must NOT have been invoked.
  [[ "$(grep -c 'DEPLOY_INVOCATION' "$DEPLOY_LOG")" -eq 0 ]]

  # Failure must be reported in the summary.
  [[ "$output" == *"release_outcome"* ]]
  [[ "$output" == *"failed"* ]] || [[ "$output" == *"skipped"* ]]

  # No deploy invocations logged.
  [[ "$output" != *"deploy: invoked"* ]]
}

@test "promotion trigger skips deploy when release exits non-zero" {
  export GAIA_RELEASE_BIN="$TEST_TMP/shims/release-error.sh"
  export GAIA_VERSION_BUMP_BIN="$TEST_TMP/shims/version-bump-success.sh"
  export GAIA_DEPLOY_BIN="$TEST_TMP/shims/deploy-success.sh"
  export GAIA_AFFECTED_SET_BIN="$TEST_TMP/shims/affected-set-selective.sh"
  unset GAIA_RELEASE_STUB GAIA_DEPLOY_STUB 2>/dev/null || true

  run bash "$TRIGGER_SCRIPT" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP/project"

  # Non-zero exit from a release error.
  [ "$status" -ne 0 ]

  # Deploy must NOT have been invoked.
  [[ "$(grep -c 'DEPLOY_INVOCATION' "$DEPLOY_LOG")" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# AC4 — wildcard affected-set deploys all components to every environment
# ---------------------------------------------------------------------------
@test "wildcard affected-set deploys all components to every environment in the chain" {
  export GAIA_RELEASE_BIN="$TEST_TMP/shims/release-success.sh"
  export GAIA_VERSION_BUMP_BIN="$TEST_TMP/shims/version-bump-success.sh"
  export GAIA_DEPLOY_BIN="$TEST_TMP/shims/deploy-success.sh"
  export GAIA_AFFECTED_SET_BIN="$TEST_TMP/shims/affected-set-wildcard.sh"
  unset GAIA_RELEASE_STUB GAIA_DEPLOY_STUB 2>/dev/null || true

  run bash "$TRIGGER_SCRIPT" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP/project"

  [ "$status" -eq 0 ]

  # The wildcard must be expanded to all stacks from config: api, web, worker.
  # Deploy invoked twice (once per env in promotion_chain).
  [[ "$(grep -c 'DEPLOY_INVOCATION' "$DEPLOY_LOG")" -eq 2 ]]

  # Both envs must deploy ALL components (api,web,worker).
  grep -q 'DEPLOY_INVOCATION: env=staging components=api,web,worker' "$DEPLOY_LOG"
  grep -q 'DEPLOY_INVOCATION: env=production components=api,web,worker' "$DEPLOY_LOG"
}

# ---------------------------------------------------------------------------
# AC5 — promotion trigger emits a machine-readable promotion summary
# ---------------------------------------------------------------------------
@test "promotion trigger emits a machine-readable promotion summary" {
  export GAIA_RELEASE_BIN="$TEST_TMP/shims/release-success.sh"
  export GAIA_VERSION_BUMP_BIN="$TEST_TMP/shims/version-bump-success.sh"
  export GAIA_DEPLOY_BIN="$TEST_TMP/shims/deploy-success.sh"
  export GAIA_AFFECTED_SET_BIN="$TEST_TMP/shims/affected-set-selective.sh"
  unset GAIA_RELEASE_STUB GAIA_DEPLOY_STUB 2>/dev/null || true

  run bash "$TRIGGER_SCRIPT" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP/project"

  [ "$status" -eq 0 ]

  # The last line of output must be valid JSON (the summary).
  local summary_line
  summary_line="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
  [[ -n "$summary_line" ]]

  # Validate it is parseable JSON with expected keys.
  printf '%s' "$summary_line" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'version' in data, 'missing version key'
assert 'release_outcome' in data, 'missing release_outcome key'
assert 'deployments' in data, 'missing deployments key'
assert isinstance(data['deployments'], list), 'deployments must be a list'
assert data['version'] == '2026.6.0', f'wrong version: {data[\"version\"]}'
assert data['release_outcome'] == 'success', f'wrong outcome: {data[\"release_outcome\"]}'
# Each deployment entry must have env, components, status.
for dep in data['deployments']:
    assert 'env' in dep, 'deployment missing env'
    assert 'components' in dep, 'deployment missing components'
    assert 'status' in dep, 'deployment missing status'
"
}

@test "promotion trigger emits a machine-readable failure summary when release fails" {
  export GAIA_RELEASE_BIN="$TEST_TMP/shims/release-fail.sh"
  export GAIA_VERSION_BUMP_BIN="$TEST_TMP/shims/version-bump-success.sh"
  export GAIA_DEPLOY_BIN="$TEST_TMP/shims/deploy-success.sh"
  export GAIA_AFFECTED_SET_BIN="$TEST_TMP/shims/affected-set-selective.sh"
  unset GAIA_RELEASE_STUB GAIA_DEPLOY_STUB 2>/dev/null || true

  run bash "$TRIGGER_SCRIPT" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP/project"

  [ "$status" -ne 0 ]

  # The summary must still be emitted on the failure path.
  local summary_line
  summary_line="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
  [[ -n "$summary_line" ]]

  printf '%s' "$summary_line" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data['release_outcome'] == 'failed', f'expected failed, got {data[\"release_outcome\"]}'
assert data['deployments'] == [], f'expected empty deployments on failure, got {data[\"deployments\"]}'
assert 'reason' in data, 'missing reason on failure path'
"
}

# ---------------------------------------------------------------------------
# Contract integration: trigger emits the exact flag form deploy-dispatch.sh requires
# ---------------------------------------------------------------------------
@test "trigger invokes the real deploy-dispatch flag interface without BLOCKED error" {
  export GAIA_RELEASE_BIN="$TEST_TMP/shims/release-success.sh"
  export GAIA_VERSION_BUMP_BIN="$TEST_TMP/shims/version-bump-success.sh"
  export GAIA_AFFECTED_SET_BIN="$TEST_TMP/shims/affected-set-selective.sh"
  unset GAIA_RELEASE_STUB GAIA_DEPLOY_STUB GAIA_DEPLOY_BIN 2>/dev/null || true

  # Use the REAL deploy-dispatch.sh — but stub the adapter layer below it
  # via its GAIA_DEPLOY_ADAPTER_CMD test seam so we do not need a real adapter.
  # The adapter shim receives positional args from deploy-dispatch.sh's test-seam
  # path: $ADAPTER_CMD "$ENV_NAME" "$VERSION" "$OUTPUT_DIR" ["$COMPONENTS"].
  cat > "$TEST_TMP/shims/adapter-cmd.sh" <<'SH'
#!/usr/bin/env bash
# Adapter-layer shim: accepts positional args from deploy-dispatch.sh and logs.
printf 'ADAPTER_INVOCATION: env=%s version=%s output-dir=%s components=%s\n' \
  "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "${DEPLOY_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/adapter-cmd.sh"

  export GAIA_DEPLOY_ADAPTER_CMD="$TEST_TMP/shims/adapter-cmd.sh"
  # Point GAIA_DEPLOY_BIN at the real deploy-dispatch.sh.
  export GAIA_DEPLOY_BIN="$BATS_TEST_DIRNAME/../skills/gaia-deploy/scripts/deploy-dispatch.sh"

  run bash "$TRIGGER_SCRIPT" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP/project"

  # Must not get "BLOCKED: --env is required" or exit 2 from deploy-dispatch.sh.
  [[ "$output" != *"BLOCKED: --env is required"* ]]
  [ "$status" -eq 0 ]

  # The real deploy-dispatch.sh must have parsed the flags and reached the
  # adapter invocation — verify the adapter log shows both environments.
  [[ "$(grep -c 'ADAPTER_INVOCATION' "$DEPLOY_LOG")" -eq 2 ]]
  grep -q 'ADAPTER_INVOCATION: env=staging' "$DEPLOY_LOG"
  grep -q 'ADAPTER_INVOCATION: env=production' "$DEPLOY_LOG"

  # Verify components were passed through.
  grep -q 'components=api,web' "$DEPLOY_LOG"
}

# ---------------------------------------------------------------------------
# Main-guard + public-function coverage
# ---------------------------------------------------------------------------
@test "sourcing promotion-trigger does not execute main" {
  # Source the script in a subshell — it must not produce output or exit.
  run bash -c "source '$TRIGGER_SCRIPT' && echo 'sourced-ok'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

@test "promotion-trigger exposes public functions when sourced" {
  run bash -c "
    source '$TRIGGER_SCRIPT'
    type parse_args
    type run_release
    type run_deploy
    type emit_summary
    type main
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"parse_args is a function"* ]]
  [[ "$output" == *"run_release is a function"* ]]
  [[ "$output" == *"run_deploy is a function"* ]]
  [[ "$output" == *"emit_summary is a function"* ]]
  [[ "$output" == *"main is a function"* ]]
}
