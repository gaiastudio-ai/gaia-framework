#!/usr/bin/env bats
# e28-s284-per-stack-per-env-targeting.bats — declarative per-stack →
# per-environment targeting field (stacks[].environments[]) + deploy-resolver
# enforcement.
#
# Validates:
#   - schema ACCEPTS a stack with environments: [staging] (AC1)
#   - schema ACCEPTS a stack with NO environments field (back-compat) (AC1)
#   - the stacks[] item object remains additionalProperties:false yet admits
#     the new optional property (AC1)
#   - deploy-ordered.sh SKIPS a stack whose declared environments exclude the
#     deploy --env, and DEPLOYS it when they include it (AC2)
#   - an absent/empty environments list = deploy into every environment
#     (zero-regression default) (AC2)

load 'test_helper.bash'

have_python_jsonschema() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null
}

validate_json_against_schema() {
  local json_file="$1" schema="$2"
  python3 -c "
import json, sys, jsonschema
schema = json.load(open('$schema'))
data = json.load(open('$json_file'))
try:
    jsonschema.validate(data, schema)
    print('valid'); sys.exit(0)
except jsonschema.ValidationError as e:
    print('error:', e.message); sys.exit(1)
" 2>&1
}

setup() {
  common_setup
  DEPLOY_ORDERED="$BATS_TEST_DIRNAME/../skills/gaia-deploy/scripts/deploy-ordered.sh"
  SCHEMA="$BATS_TEST_DIRNAME/../schemas/project-config.schema.json"

  mkdir -p "$TEST_TMP/shims"
  export DEPLOY_LOG="$TEST_TMP/deploy.log"
  touch "$DEPLOY_LOG"

  # Deploy shim: logs stack + env and succeeds.
  cat > "$TEST_TMP/shims/deploy-ok.sh" <<'SH'
#!/usr/bin/env bash
_stack="" _env=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) _stack="$2"; shift 2 ;;
    --env)   _env="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'DEPLOY: stack=%s env=%s\n' "$_stack" "$_env" >> "${DEPLOY_LOG}"
exit 0
SH
  chmod +x "$TEST_TMP/shims/deploy-ok.sh"
}

teardown() { common_teardown; }

# A minimal config: backend(all-envs), website(prod-only), prelaunch(staging-only).
write_env_config() {
  cat > "$1" <<'YAML'
stacks:
  - name: backend
    language: go
    paths: ["backend/**"]
    deploy_order: 1
  - name: website
    language: js
    paths: ["web/**"]
    deploy_order: 2
    environments:
      - prod
  - name: prelaunch
    language: js
    paths: ["pre/**"]
    deploy_order: 3
    environments:
      - staging
YAML
}

# ---------------------------------------------------------------------------
# AC1 — schema
# ---------------------------------------------------------------------------

@test "schema accepts a stack with an environments targeting list (AC1)" {
  have_python_jsonschema || skip "python3 + jsonschema not available"
  cat > "$TEST_TMP/cfg.json" <<'JSON'
{ "project_root": ".", "project_path": ".", "memory_path": "_memory",
  "checkpoint_path": "_memory/checkpoints", "installed_path": "_gaia",
  "framework_version": "1.0.0", "date": "2026-06-29",
  "stacks": [ { "name": "web", "language": "js", "paths": ["web/**"],
               "environments": ["staging", "prod"] } ] }
JSON
  run validate_json_against_schema "$TEST_TMP/cfg.json" "$SCHEMA"
  echo "out: $output"
  [[ "$output" == *"valid"* ]]
}

@test "schema accepts a stack with NO environments field — back-compat (AC1)" {
  have_python_jsonschema || skip "python3 + jsonschema not available"
  cat > "$TEST_TMP/cfg.json" <<'JSON'
{ "project_root": ".", "project_path": ".", "memory_path": "_memory",
  "checkpoint_path": "_memory/checkpoints", "installed_path": "_gaia",
  "framework_version": "1.0.0", "date": "2026-06-29",
  "stacks": [ { "name": "web", "language": "js", "paths": ["web/**"] } ] }
JSON
  run validate_json_against_schema "$TEST_TMP/cfg.json" "$SCHEMA"
  echo "out: $output"
  [[ "$output" == *"valid"* ]]
}

@test "schema declares environments as an optional array on the stacks item, item stays additionalProperties:false (AC1)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run python3 -c "
import json
s = json.load(open('$SCHEMA'))
item = s['properties']['stacks']['items']
assert item.get('additionalProperties') is False, 'stacks item must stay closed'
env = item['properties']['environments']
assert env['type'] == 'array', env
assert env['items']['type'] == 'string', env
assert 'environments' not in item.get('required', []), 'environments must be optional'
print('ok')
"
  echo "out: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# ---------------------------------------------------------------------------
# AC2 — deploy-resolver enforcement
# ---------------------------------------------------------------------------

@test "deploy-ordered skips a stack whose environments exclude the deploy --env (AC2)" {
  write_env_config "$TEST_TMP/cfg.yaml"
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env staging --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  echo "status: $status"; echo "output: $output"; echo "log:"; cat "$DEPLOY_LOG"
  [ "$status" -eq 0 ]
  # website is prod-only → MUST NOT deploy to staging.
  ! grep -q 'stack=website' "$DEPLOY_LOG"
  # prelaunch is staging-only → MUST deploy to staging.
  grep -q 'stack=prelaunch env=staging' "$DEPLOY_LOG"
  # The skip is logged.
  [[ "$output" == *"skipping stack=website"* ]]
  [[ "$output" == *"not targeted at env=staging"* ]]
}

@test "deploy-ordered deploys a stack into an environment it declares (AC2)" {
  write_env_config "$TEST_TMP/cfg.yaml"
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env prod --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  echo "status: $status"; echo "log:"; cat "$DEPLOY_LOG"
  [ "$status" -eq 0 ]
  # website is prod-only → MUST deploy to prod.
  grep -q 'stack=website env=prod' "$DEPLOY_LOG"
  # prelaunch is staging-only → MUST NOT deploy to prod.
  ! grep -q 'stack=prelaunch' "$DEPLOY_LOG"
}

@test "a stack with no environments field deploys into every environment — zero-regression (AC2)" {
  write_env_config "$TEST_TMP/cfg.yaml"
  # backend declares no environments → deploys to BOTH staging and prod.
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env staging --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  [ "$status" -eq 0 ]
  grep -q 'stack=backend env=staging' "$DEPLOY_LOG"
  : > "$DEPLOY_LOG"
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env prod --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  [ "$status" -eq 0 ]
  grep -q 'stack=backend env=prod' "$DEPLOY_LOG"
}

@test "inline-flow environments form is honored, not silently dropped (AC2)" {
  # `environments: [prod]` (inline flow) must scope identically to the block
  # form — otherwise a flow-style declaration fails OPEN (deploys everywhere).
  cat > "$TEST_TMP/cfg.yaml" <<'YAML'
stacks:
  - name: flowonly
    language: js
    paths: ["f/**"]
    deploy_order: 1
    environments: [prod]
YAML
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env staging --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  echo "status: $status"; echo "output: $output"; echo "log:"; cat "$DEPLOY_LOG"
  [ "$status" -eq 0 ]
  # prod-only (inline) → MUST be skipped on a staging deploy.
  ! grep -q 'stack=flowonly' "$DEPLOY_LOG"
  [[ "$output" == *"skipping stack=flowonly"* ]]
  # ...and MUST deploy on a prod deploy.
  : > "$DEPLOY_LOG"
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env prod --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  [ "$status" -eq 0 ]
  grep -q 'stack=flowonly env=prod' "$DEPLOY_LOG"
}

@test "env membership uses exact equality, not substring — prod must not match production (AC2)" {
  cat > "$TEST_TMP/cfg.yaml" <<'YAML'
stacks:
  - name: prodonly
    language: go
    paths: ["p/**"]
    deploy_order: 1
    environments:
      - production
YAML
  # Deploying to env=prod must NOT match a stack scoped to "production".
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env prod --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  [ "$status" -eq 0 ]
  ! grep -q 'stack=prodonly' "$DEPLOY_LOG"
  # ...but env=production deploys it.
  : > "$DEPLOY_LOG"
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env production --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  [ "$status" -eq 0 ]
  grep -q 'stack=prodonly env=production' "$DEPLOY_LOG"
}

@test "a deploy that targets zero stacks emits an advisory warning (AC2)" {
  # Every stack is staging-only; deploying to a typo'd env skips them all.
  cat > "$TEST_TMP/cfg.yaml" <<'YAML'
stacks:
  - name: only_staging
    language: go
    paths: ["s/**"]
    deploy_order: 1
    environments:
      - staging
YAML
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env prde --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  echo "status: $status"; echo "output: $output"
  [ "$status" -eq 0 ]
  ! grep -q 'DEPLOY:' "$DEPLOY_LOG"
  [[ "$output" == *"0 of 1 stack"* ]]
  [[ "$output" == *"check the --env value"* ]]
}

@test "environments declared FIRST on the dash line (block form) still scopes — no fail-open (AC2)" {
  # Security regression: a stack listing environments as its first dash-line
  # key must NOT silently revert to all-environments.
  cat > "$TEST_TMP/cfg.yaml" <<'YAML'
stacks:
  - environments:
      - prod
    name: prodonly_envfirst
    deploy_order: 1
YAML
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env staging --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  echo "status: $status"; echo "log:"; cat "$DEPLOY_LOG"
  [ "$status" -eq 0 ]
  ! grep -q 'stack=prodonly_envfirst' "$DEPLOY_LOG"
  : > "$DEPLOY_LOG"
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env prod --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  [ "$status" -eq 0 ]
  grep -q 'stack=prodonly_envfirst env=prod' "$DEPLOY_LOG"
}

@test "environments declared as inline-flow ON the dash line still scopes — no fail-open (AC2)" {
  cat > "$TEST_TMP/cfg.yaml" <<'YAML'
stacks:
  - environments: [prod]
    name: prodonly_flowondash
    deploy_order: 1
YAML
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env staging --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  echo "status: $status"; echo "log:"; cat "$DEPLOY_LOG"
  [ "$status" -eq 0 ]
  ! grep -q 'stack=prodonly_flowondash' "$DEPLOY_LOG"
  : > "$DEPLOY_LOG"
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env prod --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  [ "$status" -eq 0 ]
  grep -q 'stack=prodonly_flowondash env=prod' "$DEPLOY_LOG"
}

@test "an empty environments list means all-environments, not no-environments (AC2)" {
  cat > "$TEST_TMP/cfg.yaml" <<'YAML'
stacks:
  - name: solo
    language: go
    paths: ["solo/**"]
    deploy_order: 1
    environments: []
YAML
  run bash "$DEPLOY_ORDERED" \
    --config "$TEST_TMP/cfg.yaml" --env prod --version 1.0.0 \
    --output-dir "$TEST_TMP/evidence" --deploy-bin "$TEST_TMP/shims/deploy-ok.sh"
  echo "status: $status"; echo "log:"; cat "$DEPLOY_LOG"
  [ "$status" -eq 0 ]
  grep -q 'stack=solo env=prod' "$DEPLOY_LOG"
}
