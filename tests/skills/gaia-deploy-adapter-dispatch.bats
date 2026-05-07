#!/usr/bin/env bats
# tests/skills/gaia-deploy-adapter-dispatch.bats — /gaia-deploy adapter dispatch (E78-S4, FR-426).
#
# Covers AC1–AC8 of E78-S4: config-driven adapter resolution from project-config.yaml
# (deployment.adapter, distribution.channels[].deploy_adapter), precedence ordering,
# unknown-adapter BLOCKED, web/mobile zero-behavior-change, and the existing
# GAIA_DEPLOY_ADAPTER_CMD test seam.

bats_require_minimum_version 1.5.0

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../../plugins/gaia" && pwd)"
  SKILL_SCRIPTS="$PLUGIN_ROOT/skills/gaia-deploy/scripts"
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-deploy-dispatch-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP/evidence/deploy" "$WORK_TMP/config"
  unset GAIA_DEPLOY_ADAPTER_CMD || true

  # Build a sandbox plugin tree mirroring plugins/gaia/scripts/adapters/<name>/.
  # Tests can populate fake adapters under SANDBOX_PLUGIN/scripts/adapters/.
  SANDBOX_PLUGIN="$WORK_TMP/sandbox-plugin"
  mkdir -p "$SANDBOX_PLUGIN/scripts/adapters"
  # Copy the real probe so the sandboxed dispatch script can invoke it.
  cp "$PLUGIN_ROOT/scripts/tool-availability-probe.sh" "$SANDBOX_PLUGIN/scripts/tool-availability-probe.sh"
  chmod +x "$SANDBOX_PLUGIN/scripts/tool-availability-probe.sh"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# ---------- Test fixtures helpers ----------

# make_fake_adapter <name> [exit_code]
# Creates plugins/gaia/scripts/adapters/<name>/{adapter.json,run.sh} under SANDBOX_PLUGIN.
# run.sh writes {evidence/deploy/<name>.invoked} on success so tests can verify dispatch.
make_fake_adapter() {
  local name="$1" rc="${2:-0}"
  local dir="$SANDBOX_PLUGIN/scripts/adapters/$name"
  mkdir -p "$dir/test"
  cat > "$dir/adapter.json" <<EOF
{
  "provider": "bash",
  "category": "deploy",
  "runtime-profile": "subprocess",
  "default-timeout-seconds": 600,
  "file-extensions": [],
  "scope": "project"
}
EOF
  cat > "$dir/run.sh" <<EOF
#!/usr/bin/env bash
# Fake adapter for $name — accepts --env --version --output-dir flags.
ENV_NAME=""; VERSION=""; OUT=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --env) ENV_NAME="\$2"; shift 2 ;;
    --version) VERSION="\$2"; shift 2 ;;
    --output-dir) OUT="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "\$OUT"
printf '%s\n' "$name invoked env=\$ENV_NAME version=\$VERSION" > "\$OUT/$name.invoked"
exit $rc
EOF
  chmod +x "$dir/run.sh"
}

# write_config <yaml-body>
# Writes project-config.yaml under WORK_TMP/config/.
write_config() {
  printf '%s\n' "$1" > "$WORK_TMP/config/project-config.yaml"
}

# Run dispatch with the sandbox plugin root injected so adapter resolution
# uses our fake adapters rather than the real plugin tree.
run_dispatch() {
  GAIA_DEPLOY_PLUGIN_ROOT="$SANDBOX_PLUGIN" \
  GAIA_DEPLOY_CONFIG="$WORK_TMP/config/project-config.yaml" \
    run "$SKILL_SCRIPTS/deploy-dispatch.sh" "$@"
}

# ---------- AC1: Config-driven adapter resolution ----------

@test "AC1: deployment.adapter resolves and invokes adapter run.sh" {
  make_fake_adapter "marketplace-publish" 0
  write_config "deployment:
  adapter: marketplace-publish
"
  run_dispatch --env staging --version v1.2.3 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/marketplace-publish.invoked" ]
  grep -q "env=staging" "$WORK_TMP/evidence/deploy/marketplace-publish.invoked"
  grep -q "version=v1.2.3" "$WORK_TMP/evidence/deploy/marketplace-publish.invoked"
}

# ---------- AC2: distribution.channels[] fallback ----------

@test "AC2: distribution.channels[0].deploy_adapter falls back when deployment.adapter absent" {
  make_fake_adapter "marketplace-publish" 0
  write_config "distribution:
  channels:
    - type: marketplace
      deploy_adapter: marketplace-publish
"
  run_dispatch --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/marketplace-publish.invoked" ]
}

# ---------- AC3: Resolution precedence ----------

@test "AC3: deployment.adapter wins over distribution.channels[].deploy_adapter" {
  make_fake_adapter "script-deploy" 0
  make_fake_adapter "marketplace-publish" 0
  write_config "deployment:
  adapter: script-deploy
distribution:
  channels:
    - type: marketplace
      deploy_adapter: marketplace-publish
"
  run_dispatch --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/script-deploy.invoked" ]
  [ ! -f "$WORK_TMP/evidence/deploy/marketplace-publish.invoked" ]
}

# ---------- AC4: Opt-in only — no auto-detection from project_kind ----------

@test "AC4: project_kind: claude-code-plugin without adapter config falls back to script-deploy" {
  make_fake_adapter "script-deploy" 0
  make_fake_adapter "marketplace-publish" 0
  write_config "project_kind: claude-code-plugin
"
  run_dispatch --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/script-deploy.invoked" ]
  [ ! -f "$WORK_TMP/evidence/deploy/marketplace-publish.invoked" ]
}

# ---------- AC5: Adapter contract compliance — flags + probe ----------

@test "AC5: dispatch invokes adapter run.sh with --env --version --output-dir flags" {
  make_fake_adapter "marketplace-publish" 0
  write_config "deployment:
  adapter: marketplace-publish
"
  run_dispatch --env prod --version v9.9.9 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  grep -q "env=prod" "$WORK_TMP/evidence/deploy/marketplace-publish.invoked"
  grep -q "version=v9.9.9" "$WORK_TMP/evidence/deploy/marketplace-publish.invoked"
}

# ---------- AC6: Unknown adapter BLOCKED ----------

@test "AC6: unknown adapter name halts with BLOCKED + lists available adapters" {
  make_fake_adapter "script-deploy" 0
  make_fake_adapter "marketplace-publish" 0
  write_config "deployment:
  adapter: nonexistent-adapter
"
  run_dispatch --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "BLOCKED"
  echo "$output" | grep -q "nonexistent-adapter"
  echo "$output" | grep -q "script-deploy"
  echo "$output" | grep -q "marketplace-publish"
}

# ---------- AC7: Web/mobile zero behavior change ----------

@test "AC7: web project without adapter config falls back to script-deploy default" {
  make_fake_adapter "script-deploy" 0
  write_config "platforms:
  - web
"
  run_dispatch --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/script-deploy.invoked" ]
}

@test "AC7: empty config (no deployment, no distribution) defaults to script-deploy" {
  make_fake_adapter "script-deploy" 0
  write_config "# empty"
  run_dispatch --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/script-deploy.invoked" ]
}

# ---------- AC8: Test seam preserved ----------

@test "AC8: GAIA_DEPLOY_ADAPTER_CMD overrides resolved adapter (test seam)" {
  make_fake_adapter "marketplace-publish" 0
  write_config "deployment:
  adapter: marketplace-publish
"
  cat > "$WORK_TMP/seam-adapter.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$3"
echo "seam invoked env=$1 ver=$2" > "$3/seam.invoked"
exit 0
EOF
  chmod +x "$WORK_TMP/seam-adapter.sh"
  GAIA_DEPLOY_ADAPTER_CMD="$WORK_TMP/seam-adapter.sh" \
  GAIA_DEPLOY_PLUGIN_ROOT="$SANDBOX_PLUGIN" \
  GAIA_DEPLOY_CONFIG="$WORK_TMP/config/project-config.yaml" \
    run "$SKILL_SCRIPTS/deploy-dispatch.sh" --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/seam.invoked" ]
  [ ! -f "$WORK_TMP/evidence/deploy/marketplace-publish.invoked" ]
}

# ---------- Adapter availability probe wired in ----------

@test "AC5: missing adapter binary (probe expected_and_missing) yields BLOCKED" {
  # Build an adapter declaring a provider that is NOT on PATH.
  local name="missing-tool-adapter"
  local dir="$SANDBOX_PLUGIN/scripts/adapters/$name"
  mkdir -p "$dir/test"
  cat > "$dir/adapter.json" <<EOF
{
  "provider": "this-binary-does-not-exist-zzzqqq",
  "category": "deploy",
  "runtime-profile": "subprocess",
  "default-timeout-seconds": 600,
  "file-extensions": [],
  "scope": "project"
}
EOF
  cat > "$dir/run.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$dir/run.sh"

  write_config "deployment:
  adapter: $name
"
  run_dispatch --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "BLOCKED"
  echo "$output" | grep -q "this-binary-does-not-exist-zzzqqq"
}

# ---------- Backward-compat sanity: existing positional test seam ----------

@test "backward compat: existing GAIA_DEPLOY_ADAPTER_CMD positional invocation unchanged" {
  cat > "$WORK_TMP/legacy-adapter.sh" <<'EOF'
#!/usr/bin/env bash
# Legacy adapters expect positional: $1=env $2=version $3=output-dir
mkdir -p "$3"
echo "legacy env=$1 ver=$2" > "$3/legacy.invoked"
exit 0
EOF
  chmod +x "$WORK_TMP/legacy-adapter.sh"
  GAIA_DEPLOY_ADAPTER_CMD="$WORK_TMP/legacy-adapter.sh" \
    run "$SKILL_SCRIPTS/deploy-dispatch.sh" --env staging --version v2 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/legacy.invoked" ]
  grep -q "env=staging" "$WORK_TMP/evidence/deploy/legacy.invoked"
  grep -q "ver=v2" "$WORK_TMP/evidence/deploy/legacy.invoked"
}
