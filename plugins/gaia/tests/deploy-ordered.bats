#!/usr/bin/env bats
# deploy-ordered.bats — per-stack ordered deploy with health-gate tests.
#
# Validates:
#   - stacks deploy in ascending deploy_order (lower first)
#   - health-check must pass before the next stack deploys
#   - health-check failure halts downstream stacks (+ reports failing stack)
#   - stacks without deploy_order default to alphabetical ordering
#   - health-check timeout is treated as failure (same halt behavior)
#   - per-stack deploy_order / health_check / post_deploy_smoke schema fields
#     validate against the JSON schema

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

have_python_jsonschema() {
  command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import jsonschema' 2>/dev/null
}

have_python_yaml() {
  command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import yaml' 2>/dev/null
}

validate_json_against_schema() {
  local json_file="$1"
  local schema="$2"
  python3 -c "
import json, sys
import jsonschema
with open('$schema') as f:
    schema = json.load(f)
with open('$json_file') as f:
    data = json.load(f)
try:
    jsonschema.validate(data, schema)
    print('valid')
    sys.exit(0)
except jsonschema.ValidationError as e:
    print('error:', e.message)
    sys.exit(1)
" 2>&1
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  DEPLOY_ORDERED="$BATS_TEST_DIRNAME/../skills/gaia-deploy/scripts/deploy-ordered.sh"
  SCHEMA="$BATS_TEST_DIRNAME/../schemas/project-config.schema.json"

  # -- build deploy shim that logs invocations in order --
  mkdir -p "$TEST_TMP/shims"
  export DEPLOY_LOG="$TEST_TMP/deploy.log"
  touch "$DEPLOY_LOG"

  cat > "$TEST_TMP/shims/deploy-ok.sh" <<'SH'
#!/usr/bin/env bash
# Deploy shim: logs stack + env + version and succeeds.
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

  # -- health-check shim that succeeds --
  cat > "$TEST_TMP/shims/health-ok.sh" <<'SH'
#!/usr/bin/env bash
_cmd="" _timeout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) _cmd="$2"; shift 2 ;;
    --timeout) _timeout="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'HEALTH: command=%s timeout=%s result=pass\n' "$_cmd" "$_timeout" >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/health-ok.sh"

  # -- health-check shim that fails on a specific stack --
  cat > "$TEST_TMP/shims/health-fail-db.sh" <<'SH'
#!/usr/bin/env bash
_cmd="" _timeout="" _stack=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) _cmd="$2"; shift 2 ;;
    --timeout) _timeout="$2"; shift 2 ;;
    --stack)   _stack="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'HEALTH: stack=%s command=%s result=' "$_stack" "$_cmd" >> "${DEPLOY_LOG}"
# Fail when the command is "check-db" (the db stack's health command).
if [[ "$_cmd" == "check-db" ]]; then
  printf 'fail\n' >> "${DEPLOY_LOG}"
  printf 'connection refused: database is not reachable\n' >&2
  exit 1
fi
printf 'pass\n' >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/health-fail-db.sh"

  # -- health-check shim that hangs (for timeout test) --
  cat > "$TEST_TMP/shims/health-hang.sh" <<'SH'
#!/usr/bin/env bash
_cmd="" _timeout="" _stack=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) _cmd="$2"; shift 2 ;;
    --timeout) _timeout="$2"; shift 2 ;;
    --stack)   _stack="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'HEALTH: stack=%s command=%s result=hang\n' "$_stack" "$_cmd" >> "${DEPLOY_LOG}"
# Sleep longer than any reasonable timeout to trigger the timeout path.
sleep 300
exit 0
SH
  chmod +x "$TEST_TMP/shims/health-hang.sh"

  # -- post-deploy-smoke shim that succeeds --
  cat > "$TEST_TMP/shims/smoke-ok.sh" <<'SH'
#!/usr/bin/env bash
_cmd="" _timeout="" _stack=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) _cmd="$2"; shift 2 ;;
    --timeout) _timeout="$2"; shift 2 ;;
    --stack)   _stack="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'SMOKE: stack=%s command=%s\n' "$_stack" "$_cmd" >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/smoke-ok.sh"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Helper: write a multi-stack config fixture
# ---------------------------------------------------------------------------

write_config() {
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
  - name: db
    language: sql
    paths:
      - services/db
    deploy_order: 1
    health_check:
      command: "check-db"
      timeout: 10
  - name: web
    language: typescript
    paths:
      - apps/web
    deploy_order: 3
YAML
}

write_config_no_order() {
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
  - name: web
    language: typescript
    paths:
      - apps/web
  - name: api
    language: python
    paths:
      - services/api
  - name: db
    language: sql
    paths:
      - services/db
YAML
}

# ===========================================================================
# AC1 — per-stack deploy fields validate against the JSON schema
# ===========================================================================

@test "per-stack deploy_order and health_check and post_deploy_smoke validate against schema" {
  have_python_jsonschema || skip "python3 jsonschema not available"

  # Build a minimal valid config with per-stack deploy fields.
  local config_json="$TEST_TMP/config-with-deploy-fields.json"
  python3 -c "
import json
config = {
    'project_root': '/tmp/test',
    'project_path': '/tmp/test',
    'memory_path': '/tmp/mem',
    'checkpoint_path': '/tmp/cp',
    'installed_path': '/tmp/inst',
    'framework_version': '1.0.0',
    'date': '2026-01-01',
    'stacks': [
        {
            'name': 'api',
            'language': 'python',
            'paths': ['services/api'],
            'deploy_order': 1,
            'health_check': {
                'command': 'curl -f http://localhost:8080/health',
                'timeout': 30
            },
            'post_deploy_smoke': {
                'command': 'npm run smoke:api',
                'timeout': 60
            }
        },
        {
            'name': 'web',
            'language': 'typescript',
            'paths': ['apps/web'],
            'deploy_order': 2
        }
    ]
}
with open('$config_json', 'w') as f:
    json.dump(config, f)
"
  run validate_json_against_schema "$config_json" "$SCHEMA"
  echo "output: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"valid"* ]]
}

@test "schema rejects non-integer deploy_order" {
  have_python_jsonschema || skip "python3 jsonschema not available"

  local config_json="$TEST_TMP/config-bad-order.json"
  python3 -c "
import json
config = {
    'project_root': '/tmp/test',
    'project_path': '/tmp/test',
    'memory_path': '/tmp/mem',
    'checkpoint_path': '/tmp/cp',
    'installed_path': '/tmp/inst',
    'framework_version': '1.0.0',
    'date': '2026-01-01',
    'stacks': [
        {
            'name': 'api',
            'language': 'python',
            'paths': ['services/api'],
            'deploy_order': 'first'
        }
    ]
}
with open('$config_json', 'w') as f:
    json.dump(config, f)
"
  run validate_json_against_schema "$config_json" "$SCHEMA"
  [ "$status" -ne 0 ]
}

@test "schema rejects health_check with missing command" {
  have_python_jsonschema || skip "python3 jsonschema not available"

  local config_json="$TEST_TMP/config-bad-hc.json"
  python3 -c "
import json
config = {
    'project_root': '/tmp/test',
    'project_path': '/tmp/test',
    'memory_path': '/tmp/mem',
    'checkpoint_path': '/tmp/cp',
    'installed_path': '/tmp/inst',
    'framework_version': '1.0.0',
    'date': '2026-01-01',
    'stacks': [
        {
            'name': 'api',
            'language': 'python',
            'paths': ['services/api'],
            'health_check': {
                'timeout': 30
            }
        }
    ]
}
with open('$config_json', 'w') as f:
    json.dump(config, f)
"
  run validate_json_against_schema "$config_json" "$SCHEMA"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# AC2 — stacks deploy in ascending deploy_order
# ===========================================================================

@test "stacks deploy in ascending deploy_order with lower values first" {
  write_config "$TEST_TMP/project-config.yaml"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "1.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh"

  echo "output: $output"
  echo "status: $status"
  [ "$status" -eq 0 ]

  # Verify deploy order: db (order=1) -> api (order=2) -> web (order=3).
  local first_deploy second_deploy third_deploy
  first_deploy="$(sed -n '1p' "$DEPLOY_LOG" | grep '^DEPLOY:')"
  second_deploy="$(grep '^DEPLOY:' "$DEPLOY_LOG" | sed -n '2p')"
  third_deploy="$(grep '^DEPLOY:' "$DEPLOY_LOG" | sed -n '3p')"

  [[ "$first_deploy" == *"stack=db"* ]]
  [[ "$second_deploy" == *"stack=api"* ]]
  [[ "$third_deploy" == *"stack=web"* ]]
}

# ===========================================================================
# AC3 — health-check runs after deploy and must pass before next stack
# ===========================================================================

@test "health-check runs after each stack deploy and passes before the next deploys" {
  write_config "$TEST_TMP/project-config.yaml"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "1.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh"

  [ "$status" -eq 0 ]

  # The log should interleave: DEPLOY db, HEALTH check-db, DEPLOY api, HEALTH check-api, DEPLOY web.
  # (web has no health_check, so no HEALTH entry for it.)
  local log_content
  log_content="$(cat "$DEPLOY_LOG")"

  # db deploy comes before db health check.
  local db_deploy_line db_health_line api_deploy_line api_health_line web_deploy_line
  db_deploy_line="$(grep -n 'DEPLOY: stack=db' "$DEPLOY_LOG" | head -1 | cut -d: -f1)"
  db_health_line="$(grep -n 'HEALTH:.*check-db' "$DEPLOY_LOG" | head -1 | cut -d: -f1)"
  api_deploy_line="$(grep -n 'DEPLOY: stack=api' "$DEPLOY_LOG" | head -1 | cut -d: -f1)"
  api_health_line="$(grep -n 'HEALTH:.*check-api' "$DEPLOY_LOG" | head -1 | cut -d: -f1)"
  web_deploy_line="$(grep -n 'DEPLOY: stack=web' "$DEPLOY_LOG" | head -1 | cut -d: -f1)"

  # db deploys first, then health check, then api deploys.
  [ "$db_deploy_line" -lt "$db_health_line" ]
  [ "$db_health_line" -lt "$api_deploy_line" ]
  [ "$api_deploy_line" -lt "$api_health_line" ]
  [ "$api_health_line" -lt "$web_deploy_line" ]
}

# ===========================================================================
# AC4 — health-check failure halts downstream stacks
# ===========================================================================

@test "health-check failure halts deployment of downstream stacks and reports the failing stack" {
  write_config "$TEST_TMP/project-config.yaml"

  # Use a health shim that fails on "check-db" (the db stack's health command).
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "1.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-fail-db.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh"

  echo "output: $output"
  echo "deploy log: $(cat "$DEPLOY_LOG")"

  # Must exit non-zero.
  [ "$status" -ne 0 ]

  # db should have been deployed (it's first, order=1).
  grep -q 'DEPLOY: stack=db' "$DEPLOY_LOG"

  # api (order=2) and web (order=3) must NOT have been deployed.
  local api_deploy_count web_deploy_count
  api_deploy_count="$(grep -c 'DEPLOY: stack=api' "$DEPLOY_LOG" || true)"
  web_deploy_count="$(grep -c 'DEPLOY: stack=web' "$DEPLOY_LOG" || true)"
  [ "$api_deploy_count" -eq 0 ]
  [ "$web_deploy_count" -eq 0 ]

  # Output must identify the failing stack and include health-check output.
  [[ "$output" == *"db"* ]]
  [[ "$output" == *"HALTED"* ]] || [[ "$output" == *"halted"* ]] || [[ "$output" == *"BLOCKED"* ]]
}

# ===========================================================================
# AC5 — no deploy_order defaults to alphabetical ordering
# ===========================================================================

@test "stacks without deploy_order deploy in alphabetical order by name" {
  write_config_no_order "$TEST_TMP/project-config.yaml"

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "1.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh"

  echo "output: $output"
  [ "$status" -eq 0 ]

  # Without deploy_order, stacks should be sorted alphabetically: api, db, web.
  local first_deploy second_deploy third_deploy
  first_deploy="$(grep '^DEPLOY:' "$DEPLOY_LOG" | sed -n '1p')"
  second_deploy="$(grep '^DEPLOY:' "$DEPLOY_LOG" | sed -n '2p')"
  third_deploy="$(grep '^DEPLOY:' "$DEPLOY_LOG" | sed -n '3p')"

  [[ "$first_deploy" == *"stack=api"* ]]
  [[ "$second_deploy" == *"stack=db"* ]]
  [[ "$third_deploy" == *"stack=web"* ]]
}

@test "mixed stacks with and without deploy_order sort correctly" {
  mkdir -p "$TEST_TMP"
  cat > "$TEST_TMP/project-config.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test
memory_path: /tmp/test/.gaia/memory
checkpoint_path: /tmp/test/.gaia/memory/checkpoints
installed_path: /tmp/test/.gaia
framework_version: "1.197.0"
date: "2026-06-18"
stacks:
  - name: web
    language: typescript
    paths:
      - apps/web
  - name: api
    language: python
    paths:
      - services/api
    deploy_order: 1
  - name: worker
    language: python
    paths:
      - services/worker
  - name: db
    language: sql
    paths:
      - services/db
    deploy_order: 2
YAML

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "1.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-ok.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh"

  echo "output: $output"
  [ "$status" -eq 0 ]

  # Stacks with deploy_order come first (ascending), then stacks without (alphabetical).
  # api (order=1) -> db (order=2) -> web (no order, alpha) -> worker (no order, alpha)
  local deploys
  deploys="$(grep '^DEPLOY:' "$DEPLOY_LOG")"

  local d1 d2 d3 d4
  d1="$(echo "$deploys" | sed -n '1p')"
  d2="$(echo "$deploys" | sed -n '2p')"
  d3="$(echo "$deploys" | sed -n '3p')"
  d4="$(echo "$deploys" | sed -n '4p')"

  [[ "$d1" == *"stack=api"* ]]
  [[ "$d2" == *"stack=db"* ]]
  [[ "$d3" == *"stack=web"* ]]
  [[ "$d4" == *"stack=worker"* ]]
}

# ===========================================================================
# AC6 — health-check timeout treated as failure
# ===========================================================================

@test "health-check command exceeding timeout is treated as failed and halts downstream" {
  # Config with short timeout on db health check.
  mkdir -p "$TEST_TMP"
  cat > "$TEST_TMP/project-config.yaml" <<'YAML'
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
      timeout: 2
  - name: api
    language: python
    paths:
      - services/api
    deploy_order: 2
YAML

  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/project-config.yaml" \
    --env staging \
    --version "1.0.0" \
    --output-dir "$TEST_TMP/evidence" \
    --deploy-bin "$TEST_TMP/shims/deploy-ok.sh" \
    --health-bin "$TEST_TMP/shims/health-hang.sh" \
    --smoke-bin "$TEST_TMP/shims/smoke-ok.sh"

  echo "output: $output"

  # Must exit non-zero (timeout = failure).
  [ "$status" -ne 0 ]

  # db was deployed but api must NOT have been deployed.
  grep -q 'DEPLOY: stack=db' "$DEPLOY_LOG"
  local api_count
  api_count="$(grep -c 'DEPLOY: stack=api' "$DEPLOY_LOG" || true)"
  [ "$api_count" -eq 0 ]

  # Output must mention timeout.
  [[ "$output" == *"timeout"* ]] || [[ "$output" == *"TIMEOUT"* ]] || [[ "$output" == *"timed out"* ]]
}

# ===========================================================================
# Additional: main-guard + public-function coverage
# ===========================================================================

@test "sourcing deploy-ordered does not execute main" {
  run bash -c "source '$DEPLOY_ORDERED' && echo 'sourced-ok'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

@test "deploy-ordered exposes public functions when sourced" {
  run bash -c "
    source '$DEPLOY_ORDERED'
    type parse_deploy_args
    type read_stacks_deploy_config
    type run_ordered_deploy
    type main
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"parse_deploy_args is a function"* ]]
  [[ "$output" == *"read_stacks_deploy_config is a function"* ]]
  [[ "$output" == *"run_ordered_deploy is a function"* ]]
  [[ "$output" == *"main is a function"* ]]
}
