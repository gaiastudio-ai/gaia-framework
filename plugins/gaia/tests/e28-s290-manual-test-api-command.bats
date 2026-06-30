#!/usr/bin/env bats
# e28-s290-manual-test-api-command.bats — sprint_review.manual_test.api_command
# config key + the functional api --target in Track B.
#
# Defect: track-b-dispatch.sh passed --target "sprint-review-${sprint_id}" (a
# slug) to the api surface, which runs `bash -c "$TARGET"` → command-not-found.
# Fix: a sprint_review.manual_test.api_command config key whose value is passed
# as the api --target; absent ⇒ api surface SKIPPED (not a bogus slug run).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  RUNNER="$PLUGIN_DIR/skills/gaia-sprint-review/scripts/track-b-dispatch.sh"
  SCHEMA="$PLUGIN_DIR/schemas/project-config.schema.json"

  TMP="$(mktemp -d)"
  CONFIG="$TMP/cfg.yaml"

  # Mock dispatch-surface.sh that ECHOES its --target into the JSON, so a test
  # can assert what target the api surface received.
  MOCK_DIR="$TMP/mock"
  mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/dispatch-surface.sh" <<'MOCK'
#!/usr/bin/env bash
SURFACE="" TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --surface) SURFACE="$2"; shift 2 ;;
    --target)  TARGET="$2"; shift 2 ;;
    *)         shift ;;
  esac
done
# Emit the received target so the test can assert on it.
printf '{"surface":"%s","verdict":"PASSED","target":"%s","exit_code":0}\n' "$SURFACE" "$TARGET"
MOCK
  chmod +x "$MOCK_DIR/dispatch-surface.sh"
  export DISPATCH_SURFACE_BIN="$MOCK_DIR/dispatch-surface.sh"

  mkdir -p "$TMP/.gaia/memory/checkpoints"
  printf '%s\n' '.gaia/memory/checkpoints/sprint-review-*' > "$TMP/.gitignore"
  cd "$TMP"
}

teardown() { rm -rf "$TMP"; }

have_yq() { command -v yq >/dev/null 2>&1; }
have_python_jsonschema() { command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; }

# ---------- AC1: schema ----------

@test "schema accepts sprint_review.manual_test.api_command (AC1)" {
  have_python_jsonschema || skip "python3 + jsonschema not available"
  cat > "$TMP/c.json" <<'JSON'
{ "project_root":".","project_path":".","memory_path":"_memory",
  "checkpoint_path":"_memory/checkpoints","installed_path":"_gaia",
  "framework_version":"1.0.0","date":"2026-06-30",
  "sprint_review": { "manual_test": { "api_command": "curl -fsS http://localhost:3000/health" } } }
JSON
  run python3 -c "
import json,jsonschema,sys
s=json.load(open('$SCHEMA')); d=json.load(open('$TMP/c.json'))
try: jsonschema.validate(d,s); print('valid')
except jsonschema.ValidationError as e: print('error:',e.message)
"
  echo "out: $output"
  [[ "$output" == *"valid"* ]]
}

@test "schema rejects an unknown key under manual_test (additionalProperties:false) (AC1)" {
  have_python_jsonschema || skip "python3 + jsonschema not available"
  cat > "$TMP/c.json" <<'JSON'
{ "project_root":".","project_path":".","memory_path":"_memory",
  "checkpoint_path":"_memory/checkpoints","installed_path":"_gaia",
  "framework_version":"1.0.0","date":"2026-06-30",
  "sprint_review": { "manual_test": { "bogus_key": "x" } } }
JSON
  run python3 -c "
import json,jsonschema,sys
s=json.load(open('$SCHEMA')); d=json.load(open('$TMP/c.json'))
try: jsonschema.validate(d,s); print('valid')
except jsonschema.ValidationError as e: print('error')
"
  [[ "$output" == *"error"* ]]
}

# ---------- AC2: track-b passes the command, not the slug ----------

@test "Track B passes the configured api_command as the api --target, not the sprint slug (AC2)" {
  have_yq || skip "yq not available"
  cat > "$CONFIG" <<'YAML'
project_name: test-project
platforms: [server, web]
sprint_review:
  playwright_headed: true
  manual_test:
    api_command: "echo FUNCTIONAL-SMOKE-OK"
YAML
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | sed -n '/^{/,/^}/p')
  printf '%s' "$json" | python3 -c "
import sys,json
data=json.load(sys.stdin)
env=data.get('envelopes', data if isinstance(data,list) else [])
api=[e for e in env if e.get('type')=='manual-test' and e.get('surface')=='api']
assert api, 'no api manual-test envelope found'
raw=api[0].get('raw','')
# The api surface received the configured command, NOT the sprint slug.
assert 'FUNCTIONAL-SMOKE-OK' in raw, 'configured command not passed to api surface: '+raw
assert 'sprint-review-sprint-50' not in raw, 'sprint slug leaked into api surface: '+raw
print('ok')
"
}

# ---------- AC2: absent key → api SKIPPED, not a bogus slug run ----------

@test "a whitespace-only api_command is treated as not-configured (api SKIPPED) (AC2)" {
  have_yq || skip "yq not available"
  cat > "$CONFIG" <<'YAML'
project_name: test-project
platforms: [server, web]
sprint_review:
  playwright_headed: true
  backend_commands:
    backend-go: "echo backend-run"
  manual_test:
    api_command: "   "
YAML
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | sed -n '/^{/,/^}/p')
  printf '%s' "$json" | python3 -c "
import sys,json
data=json.load(sys.stdin)
env=data.get('envelopes', data if isinstance(data,list) else [])
api=[e for e in env if e.get('type')=='manual-test' and e.get('surface')=='api']
assert api, 'no api envelope'
assert api[0]['verdict']=='SKIPPED', 'whitespace api_command must be SKIPPED, got: '+str(api[0])
print('ok')
"
}

@test "Track B SKIPS the api surface when no api_command is configured (AC2)" {
  have_yq || skip "yq not available"
  # A backend stack IS configured (so the surface loop runs), but no
  # api_command — the api surface must be SKIPPED, not run with the sprint slug.
  cat > "$CONFIG" <<'YAML'
project_name: test-project
platforms: [server, web]
sprint_review:
  playwright_headed: true
  backend_commands:
    backend-go: "echo backend-run"
YAML
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 0 ]
  # The runner mixes log lines with a JSON object output — extract the object.
  json=$(printf '%s\n' "$output" | sed -n '/^{/,/^}/p')
  echo "json: $json"
  # The api surface must appear as a SKIPPED manual-test envelope.
  printf '%s' "$json" | python3 -c "
import sys,json
data=json.load(sys.stdin)
env=data.get('envelopes', data if isinstance(data,list) else [])
api=[e for e in env if e.get('type')=='manual-test' and e.get('surface')=='api']
assert api, 'no api manual-test envelope found'
assert api[0]['verdict']=='SKIPPED', 'api verdict not SKIPPED: '+str(api[0])
assert 'sprint-review-sprint-50' not in api[0].get('raw',''), 'sprint slug leaked into api surface'
print('ok')
"
  # The log notes the skip reason.
  echo "$output" | grep -qi 'no sprint_review.manual_test.api_command configured'
}
