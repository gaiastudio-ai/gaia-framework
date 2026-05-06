#!/usr/bin/env bats
# adapters/script-deploy/test/contract.bats — ADR-078 deploy adapter contract (E73-S5).
#
# script-deploy is the reference deploy adapter for /gaia-deploy Pattern A. The
# adapter is invoked with --env / --version / --output-dir; it shells out to a
# user-declared deploy script resolved from `deployment.script_path` in
# `config/project-config.yaml` (or the SCRIPT_DEPLOY_PATH env-var override used
# by tests). Exit 0 = deploy succeeded; non-zero = deploy failed (BLOCKED).

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ADAPTER_DIR="$(cd "$TEST_DIR/.." && pwd)"
  RUN_SH="$ADAPTER_DIR/run.sh"
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/script-deploy-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP/out"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

@test "script-deploy contract: adapter.json + run.sh present and well-formed" {
  [ -f "$ADAPTER_DIR/adapter.json" ]
  [ -f "$RUN_SH" ]
  [ -x "$RUN_SH" ]
  run jq -e '.["runtime-profile"] == "subprocess" and .category == "deploy"' "$ADAPTER_DIR/adapter.json"
  [ "$status" -eq 0 ]
}

@test "script-deploy contract: --env, --version, --output-dir flags accepted" {
  cat > "$WORK_TMP/deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "deployed env=$1 version=$2"
exit 0
EOF
  chmod +x "$WORK_TMP/deploy.sh"
  SCRIPT_DEPLOY_PATH="$WORK_TMP/deploy.sh" run "$RUN_SH" --env staging --version v1.2.3 --output-dir "$WORK_TMP/out"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/out/deploy.stdout" ]
  grep -q "env=staging" "$WORK_TMP/out/deploy.stdout"
  grep -q "version=v1.2.3" "$WORK_TMP/out/deploy.stdout"
}

@test "script-deploy contract: non-zero exit from user script propagates" {
  cat > "$WORK_TMP/deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 7
EOF
  chmod +x "$WORK_TMP/deploy.sh"
  SCRIPT_DEPLOY_PATH="$WORK_TMP/deploy.sh" run "$RUN_SH" --env staging --version v1 --output-dir "$WORK_TMP/out"
  [ "$status" -ne 0 ]
  [ -f "$WORK_TMP/out/deploy.stderr" ]
  grep -q "boom" "$WORK_TMP/out/deploy.stderr"
}

@test "script-deploy contract: missing user script -> exit non-zero with diagnostic" {
  SCRIPT_DEPLOY_PATH="$WORK_TMP/does-not-exist.sh" run "$RUN_SH" --env staging --version v1 --output-dir "$WORK_TMP/out"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "script.*not.*found\|not executable"
}

@test "script-deploy contract: missing --env produces usage error" {
  run "$RUN_SH" --version v1 --output-dir "$WORK_TMP/out"
  [ "$status" -ne 0 ]
}
