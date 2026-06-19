#!/usr/bin/env bats
# per-component-smoke.bats — per-component post-deploy smoke result in the
# status table (independent PASSED/FAILED per component, not aggregated).
#
# Validates:
#   - each component's smoke result is recorded independently in the status table
#   - smoke PASSED and FAILED appear per-component alongside deploy + health
#   - a component with no smoke configured shows "n/a" for smoke_result
#   - smoke failure does not aggregate — other components keep their own result

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  DEPLOY_ORDERED="$BATS_TEST_DIRNAME/../skills/gaia-deploy/scripts/deploy-ordered.sh"

  mkdir -p "$TEST_TMP/shims" "$TEST_TMP/evidence" "$TEST_TMP/state"
  export DEPLOY_LOG="$TEST_TMP/deploy.log"
  touch "$DEPLOY_LOG"

  # Deploy shim: succeeds
  cat > "$TEST_TMP/shims/deploy-ok.sh" <<'SH'
#!/usr/bin/env bash
_stack="" _env="" _ver="" _outdir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stack)      _stack="$2"; shift 2 ;;
    --env)        _env="$2"; shift 2 ;;
    --version)    _ver="$2"; shift 2 ;;
    --output-dir) _outdir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'DEPLOY: stack=%s env=%s version=%s\n' "$_stack" "$_env" "$_ver" >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/deploy-ok.sh"

  # Health shim: succeeds
  cat > "$TEST_TMP/shims/health-ok.sh" <<'SH'
#!/usr/bin/env bash
_stack="" _cmd="" _timeout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) _cmd="$2"; shift 2 ;;
    --timeout) _timeout="$2"; shift 2 ;;
    --stack)   _stack="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'HEALTH: stack=%s command=%s result=pass\n' "$_stack" "$_cmd" >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/health-ok.sh"

  # Smoke shim: succeeds
  cat > "$TEST_TMP/shims/smoke-ok.sh" <<'SH'
#!/usr/bin/env bash
_stack="" _cmd="" _timeout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) _cmd="$2"; shift 2 ;;
    --timeout) _timeout="$2"; shift 2 ;;
    --stack)   _stack="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'SMOKE: stack=%s command=%s result=pass\n' "$_stack" "$_cmd" >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/smoke-ok.sh"

  # Smoke shim: fails on "smoke-api" command
  cat > "$TEST_TMP/shims/smoke-fail-api.sh" <<'SH'
#!/usr/bin/env bash
_stack="" _cmd="" _timeout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) _cmd="$2"; shift 2 ;;
    --timeout) _timeout="$2"; shift 2 ;;
    --stack)   _stack="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'SMOKE: stack=%s command=%s result=' "$_stack" "$_cmd" >> "${DEPLOY_LOG}"
if [[ "$_cmd" == "smoke-api" ]]; then
  printf 'fail\n' >> "${DEPLOY_LOG}"
  printf 'api smoke test failed: login flow broken\n' >&2
  exit 1
fi
printf 'pass\n' >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/smoke-fail-api.sh"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Helper: 3-stack config where api has smoke, db has health only, web has smoke
# ---------------------------------------------------------------------------

write_smoke_config() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test
memory_path: /tmp/test/.gaia/memory
checkpoint_path: /tmp/test/.gaia/memory/checkpoints
installed_path: /tmp/test/.gaia
framework_version: "1.197.0"
date: "2026-06-18"
stacks:
  - name: db
    language: sql
    paths:
      - services/db
    deploy_order: 1
    health_check:
      command: "check-db"
      timeout: 10
  - name: api
    language: python
    paths:
      - services/api
    deploy_order: 2
    health_check:
      command: "check-api"
      timeout: 30
    post_deploy_smoke:
      command: "smoke-api"
      timeout: 60
  - name: web
    language: typescript
    paths:
      - apps/web
    deploy_order: 3
    health_check:
      command: "check-web"
      timeout: 30
    post_deploy_smoke:
      command: "smoke-web"
      timeout: 45
YAML
}

# ===========================================================================
# Per-component smoke result recorded independently in the status table
# ===========================================================================

@test "each component smoke result appears independently in the status table" {
  write_smoke_config "$TEST_TMP/project-config.yaml"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "3.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  echo "output: $output"
  [ "$status" -eq 0 ]

  local status_table="$TEST_TMP/evidence/component-status.json"
  [ -f "$status_table" ]

  # db has no smoke configured — smoke_result must be "n/a"
  local db_smoke
  db_smoke="$(jq -r '.[] | select(.component == "db") | .smoke_result' "$status_table")"
  [ "$db_smoke" = "n/a" ]

  # api has smoke configured and it passed — smoke_result must be "pass"
  local api_smoke
  api_smoke="$(jq -r '.[] | select(.component == "api") | .smoke_result' "$status_table")"
  [ "$api_smoke" = "pass" ]

  # web has smoke configured and it passed — smoke_result must be "pass"
  local web_smoke
  web_smoke="$(jq -r '.[] | select(.component == "web") | .smoke_result' "$status_table")"
  [ "$web_smoke" = "pass" ]
}

@test "a failed smoke test records FAILED independently without aggregating" {
  write_smoke_config "$TEST_TMP/project-config.yaml"

  # smoke-fail-api.sh fails on "smoke-api" but passes "smoke-web"
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "3.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-fail-api.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  echo "output: $output"

  local status_table="$TEST_TMP/evidence/component-status.json"
  [ -f "$status_table" ]

  # api smoke failed — smoke_result must be "fail" and outcome is HOLD
  local api_smoke api_outcome
  api_smoke="$(jq -r '.[] | select(.component == "api") | .smoke_result' "$status_table")"
  api_outcome="$(jq -r '.[] | select(.component == "api") | .outcome' "$status_table")"
  [ "$api_smoke" = "fail" ]
  [ "$api_outcome" = "HOLD" ]

  # db has no smoke — smoke_result is "n/a", outcome is DEPLOYED
  local db_smoke db_outcome
  db_smoke="$(jq -r '.[] | select(.component == "db") | .smoke_result' "$status_table")"
  db_outcome="$(jq -r '.[] | select(.component == "db") | .outcome' "$status_table")"
  [ "$db_smoke" = "n/a" ]
  [ "$db_outcome" = "DEPLOYED" ]

  # web is downstream of api HOLD — skipped, smoke_result is "n/a"
  local web_smoke web_outcome
  web_smoke="$(jq -r '.[] | select(.component == "web") | .smoke_result' "$status_table")"
  web_outcome="$(jq -r '.[] | select(.component == "web") | .outcome' "$status_table")"
  [ "$web_smoke" = "n/a" ]
  [ "$web_outcome" = "SKIPPED" ]
}

@test "status table smoke_result field is present on every entry" {
  write_smoke_config "$TEST_TMP/project-config.yaml"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "3.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  [ "$status" -eq 0 ]

  local status_table="$TEST_TMP/evidence/component-status.json"
  [ -f "$status_table" ]

  # Every entry must have a smoke_result field (not null)
  local missing_smoke
  missing_smoke="$(jq '[.[] | select(.smoke_result == null)] | length' "$status_table")"
  [ "$missing_smoke" -eq 0 ]
}
