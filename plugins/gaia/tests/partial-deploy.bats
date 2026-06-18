#!/usr/bin/env bats
# partial-deploy.bats — best-effort-with-HOLD partial deploy, crash recovery,
# PARTIAL-DEPLOY composite verdict, and per-component status table.
#
# Validates:
#   - health-check failure marks component HOLD, deployed components stay live
#   - PARTIAL-DEPLOY verdict emitted with per-component status table
#   - version-manifest snapshot written before first component
#   - crash/interrupt resumes from last incomplete component
#   - status-table entries carry name, version, outcome, health result
#   - successful deploy updates/archives snapshot (no stale snapshot)

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  DEPLOY_ORDERED="$BATS_TEST_DIRNAME/../skills/gaia-deploy/scripts/deploy-ordered.sh"
  VERDICT_AGGREGATE="$BATS_TEST_DIRNAME/../skills/gaia-deploy/scripts/verdict-aggregate.sh"

  # -- build deploy shim that logs invocations --
  mkdir -p "$TEST_TMP/shims" "$TEST_TMP/evidence" "$TEST_TMP/state"
  export DEPLOY_LOG="$TEST_TMP/deploy.log"
  touch "$DEPLOY_LOG"

  # Deploy shim: succeeds and logs
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

  # Health shim: fails on "check-api" command (the api stack)
  cat > "$TEST_TMP/shims/health-fail-api.sh" <<'SH'
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
printf 'HEALTH: stack=%s command=%s result=' "$_stack" "$_cmd" >> "${DEPLOY_LOG}"
if [[ "$_cmd" == "check-api" ]]; then
  printf 'fail\n' >> "${DEPLOY_LOG}"
  printf 'api service unhealthy\n' >&2
  exit 1
fi
printf 'pass\n' >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/health-fail-api.sh"

  # Post-deploy-smoke shim: succeeds
  cat > "$TEST_TMP/shims/smoke-ok.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$TEST_TMP/shims/smoke-ok.sh"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Helper: write a 3-stack config (db → api → web)
# ---------------------------------------------------------------------------

write_three_stack_config() {
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
YAML
}

# ===========================================================================
# AC1 — failed health check holds that component, leaves deployed ones live
# ===========================================================================

@test "a failed component health check holds that component and leaves deployed ones live" {
  write_three_stack_config "$TEST_TMP/project-config.yaml"

  # api (order=2) health check fails. db (order=1) already deployed.
  # In best-effort mode: db stays DEPLOYED, api is HOLD, web is SKIPPED.
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "2.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-fail-api.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  echo "output: $output"
  echo "deploy log: $(cat "$DEPLOY_LOG")"
  echo "status: $status"

  # db was deployed and its health passed — it must stay DEPLOYED (no rollback).
  grep -q 'DEPLOY: stack=db' "$DEPLOY_LOG"

  # api was deployed but health failed — the status table must show HOLD for api.
  local status_table="$TEST_TMP/evidence/component-status.json"
  [ -f "$status_table" ]

  # db outcome = DEPLOYED
  local db_outcome
  db_outcome="$(jq -r '.[] | select(.component == "db") | .outcome' "$status_table")"
  [ "$db_outcome" = "DEPLOYED" ]

  # api outcome = HOLD
  local api_outcome
  api_outcome="$(jq -r '.[] | select(.component == "api") | .outcome' "$status_table")"
  [ "$api_outcome" = "HOLD" ]

  # web (downstream of api) = SKIPPED (never attempted)
  local web_outcome
  web_outcome="$(jq -r '.[] | select(.component == "web") | .outcome' "$status_table")"
  [ "$web_outcome" = "SKIPPED" ]
}

# ===========================================================================
# AC2 — PARTIAL-DEPLOY verdict + per-component status table
# ===========================================================================

@test "a partial deploy emits a PARTIAL-DEPLOY verdict with a per-component status table" {
  write_three_stack_config "$TEST_TMP/project-config.yaml"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "2.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-fail-api.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  echo "output: $output"

  # Composite verdict must be PARTIAL-DEPLOY (not PASSED, not FAILED).
  [[ "$output" == *"PARTIAL-DEPLOY"* ]]

  # Per-component status table must be written.
  local status_table="$TEST_TMP/evidence/component-status.json"
  [ -f "$status_table" ]

  # Must contain entries with the three valid outcome values.
  local deployed_count hold_count skipped_count
  deployed_count="$(jq '[.[] | select(.outcome == "DEPLOYED")] | length' "$status_table")"
  hold_count="$(jq '[.[] | select(.outcome == "HOLD")] | length' "$status_table")"
  skipped_count="$(jq '[.[] | select(.outcome == "SKIPPED")] | length' "$status_table")"

  # At least one DEPLOYED and at least one HOLD or SKIPPED.
  [ "$deployed_count" -ge 1 ]
  [ "$((hold_count + skipped_count))" -ge 1 ]
}

# ===========================================================================
# AC3 — version-manifest snapshot written before first component
# ===========================================================================

@test "a version-manifest snapshot is written before the first component deploys" {
  write_three_stack_config "$TEST_TMP/project-config.yaml"

  # Use a deploy shim that asserts the manifest exists BEFORE deploying.
  # This proves the snapshot is written before any component is mutated.
  cat > "$TEST_TMP/shims/deploy-check-manifest.sh" <<SH
#!/usr/bin/env bash
_stack="" _env="" _ver="" _outdir=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --stack)      _stack="\$2"; shift 2 ;;
    --env)        _env="\$2"; shift 2 ;;
    --version)    _ver="\$2"; shift 2 ;;
    --output-dir) _outdir="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
# The manifest MUST exist when the first component (db) deploys.
if [ "\$_stack" = "db" ]; then
  if [ ! -f "$TEST_TMP/state/deploy-manifest.json" ]; then
    echo "ERROR: manifest does not exist before first deploy" >&2
    exit 1
  fi
  echo "MANIFEST_EXISTS_BEFORE_FIRST_DEPLOY" >> "${DEPLOY_LOG}"
fi
printf 'DEPLOY: stack=%s env=%s version=%s\n' "\$_stack" "\$_env" "\$_ver" >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/deploy-check-manifest.sh"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "2.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-check-manifest.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  echo "output: $output"
  [ "$status" -eq 0 ]

  # The deploy shim proved the manifest existed before the first deploy.
  grep -q 'MANIFEST_EXISTS_BEFORE_FIRST_DEPLOY' "$DEPLOY_LOG"

  # After a successful deploy, the manifest is archived — check the archive.
  local archive_file
  archive_file="$(find "$TEST_TMP/evidence" -name 'deploy-manifest-*.json' | head -1)"
  [ -n "$archive_file" ]

  # Archived manifest must list all three components with target versions.
  local component_count
  component_count="$(jq '.components | length' "$archive_file")"
  [ "$component_count" -eq 3 ]

  jq -e '.components[] | select(.name == "db") | .target_version' "$archive_file"
  jq -e '.components[] | select(.name == "api") | .target_version' "$archive_file"
  jq -e '.components[] | select(.name == "web") | .target_version' "$archive_file"
}

# ===========================================================================
# AC4 — crash/interrupt resumes from last incomplete component
# ===========================================================================

@test "a restarted deploy resumes from the last incomplete component using the snapshot" {
  write_three_stack_config "$TEST_TMP/project-config.yaml"

  # Simulate a prior crash: db was DEPLOYED, api + web still pending.
  mkdir -p "$TEST_TMP/state"
  cat > "$TEST_TMP/state/deploy-manifest.json" <<'JSON'
{
  "env": "staging",
  "version": "2.0.0",
  "status": "in-progress",
  "components": [
    {"name": "db",  "deploy_order": 1, "target_version": "2.0.0", "outcome": "DEPLOYED", "health_result": "pass"},
    {"name": "api", "deploy_order": 2, "target_version": "2.0.0", "outcome": "PENDING",  "health_result": null},
    {"name": "web", "deploy_order": 3, "target_version": "2.0.0", "outcome": "PENDING",  "health_result": null}
  ]
}
JSON

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "2.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  echo "output: $output"
  echo "deploy log: $(cat "$DEPLOY_LOG")"
  [ "$status" -eq 0 ]

  # db must NOT have been re-deployed (it was already DEPLOYED in the snapshot).
  local db_deploy_count
  db_deploy_count="$(grep -c 'DEPLOY: stack=db' "$DEPLOY_LOG" || true)"
  [ "$db_deploy_count" -eq 0 ]

  # api and web must have been deployed (they were PENDING).
  grep -q 'DEPLOY: stack=api' "$DEPLOY_LOG"
  grep -q 'DEPLOY: stack=web' "$DEPLOY_LOG"
}

# ===========================================================================
# AC5 — status-table entry includes name, version, outcome, health result
# ===========================================================================

@test "each status-table entry records component, version, outcome, and health result" {
  write_three_stack_config "$TEST_TMP/project-config.yaml"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "2.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-fail-api.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  echo "output: $output"

  local status_table="$TEST_TMP/evidence/component-status.json"
  [ -f "$status_table" ]

  # Every entry must have all four fields.
  local missing_fields
  missing_fields="$(jq '[.[] | select(
    (.component == null) or
    (.target_version == null) or
    (.outcome == null) or
    (.health_result == null)
  )] | length' "$status_table")"
  [ "$missing_fields" -eq 0 ]

  # Spot-check: db has a passing health result.
  local db_health
  db_health="$(jq -r '.[] | select(.component == "db") | .health_result' "$status_table")"
  [ "$db_health" = "pass" ]

  # api has a failing health result.
  local api_health
  api_health="$(jq -r '.[] | select(.component == "api") | .health_result' "$status_table")"
  [ "$api_health" = "fail" ]

  # web was skipped — health result is "n/a" (never ran).
  local web_health
  web_health="$(jq -r '.[] | select(.component == "web") | .health_result' "$status_table")"
  [ "$web_health" = "n/a" ]
}

# ===========================================================================
# AC6 — successful deploy updates/archives snapshot (no stale)
# ===========================================================================

@test "a successful deploy updates or archives the snapshot leaving none stale" {
  write_three_stack_config "$TEST_TMP/project-config.yaml"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "2.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh" \
    --mode best-effort \
    --state-dir "$TEST_TMP/state"

  echo "output: $output"
  [ "$status" -eq 0 ]

  # The in-progress manifest must NOT persist at the well-known path.
  local manifest="$TEST_TMP/state/deploy-manifest.json"
  if [ -f "$manifest" ]; then
    # If it exists, it must be in "completed" status (not "in-progress").
    local manifest_status
    manifest_status="$(jq -r '.status' "$manifest")"
    [ "$manifest_status" = "completed" ]
  fi

  # An archived snapshot must exist in the evidence directory.
  local archive_count
  archive_count="$(find "$TEST_TMP/evidence" -name 'deploy-manifest-*.json' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$archive_count" -ge 1 ]

  # The archived snapshot must have all components DEPLOYED.
  local archive_file
  archive_file="$(find "$TEST_TMP/evidence" -name 'deploy-manifest-*.json' | head -1)"
  local all_deployed
  all_deployed="$(jq '[.components[] | select(.outcome != "DEPLOYED")] | length' "$archive_file")"
  [ "$all_deployed" -eq 0 ]
}

# ===========================================================================
# Additional: PARTIAL-DEPLOY verdict is distinct from PASSED and FAILED
# ===========================================================================

@test "verdict-aggregate emits PARTIAL-DEPLOY when component-status has mixed outcomes" {
  mkdir -p "$TEST_TMP/evidence/smoke"

  # Write a component-status.json with mixed outcomes.
  cat > "$TEST_TMP/evidence/component-status.json" <<'JSON'
[
  {"component": "db",  "target_version": "2.0.0", "outcome": "DEPLOYED", "health_result": "pass"},
  {"component": "api", "target_version": "2.0.0", "outcome": "HOLD",     "health_result": "fail"},
  {"component": "web", "target_version": "2.0.0", "outcome": "SKIPPED",  "health_result": "n/a"}
]
JSON

  run bash "$VERDICT_AGGREGATE" \
    --evidence-dir "$TEST_TMP/evidence" \
    --env staging \
    --version "2.0.0" \
    --skip-smoke

  echo "output: $output"

  # Must emit PARTIAL-DEPLOY (not PASSED, not FAILED).
  # Output includes log lines on stderr captured by bats, so pattern-match.
  [[ "$output" == *"PARTIAL-DEPLOY"* ]]
  # Must NOT contain a bare PASSED or FAILED line (only PARTIAL-DEPLOY).
  local stdout_verdict
  stdout_verdict="$(printf '%s\n' "$output" | grep -v '^gaia-deploy' | head -1)"
  [ "$stdout_verdict" = "PARTIAL-DEPLOY" ]
}

# ===========================================================================
# Additional: sourcing and public-function coverage
# ===========================================================================

@test "deploy-ordered exposes best-effort public functions when sourced" {
  run bash -c "
    source '$DEPLOY_ORDERED'
    type write_manifest_snapshot
    type read_manifest_snapshot
    type write_component_status
    type run_ordered_deploy
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"write_manifest_snapshot is a function"* ]]
  [[ "$output" == *"read_manifest_snapshot is a function"* ]]
  [[ "$output" == *"write_component_status is a function"* ]]
  [[ "$output" == *"run_ordered_deploy is a function"* ]]
}
