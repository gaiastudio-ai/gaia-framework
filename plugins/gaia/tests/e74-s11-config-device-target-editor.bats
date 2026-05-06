#!/usr/bin/env bats
# e74-s11-config-device-target-editor.bats — E74-S11
#
# AC3, AC4, AC8 — `/gaia-config-device-target` editor.

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
EDITOR="$SCRIPTS/gaia-config-device-target-edit.sh"

setup() {
  common_setup
  CFG="$TEST_TMP/project-config.yaml"
  cat > "$CFG" <<'YAML'
project_root: /tmp/x
project_path: /tmp/x
memory_path: /tmp/x/_memory
checkpoint_path: /tmp/x/_memory/checkpoints
installed_path: /tmp/x
framework_version: 0.0.0
date: 2026-05-05

stacks:
  - name: app
    language: swift
    paths: ["src/**"]

platforms:
  - ios
YAML
}
teardown() { common_teardown; }

_yaml_get() {
  python3 -c "
import sys, yaml
d = yaml.safe_load(open('$CFG')) or {}
import json
print(json.dumps(d.get('device_targets', {})))
"
}

# AC3 set ---------------------------------------------------------

@test "set ios with os-versions/form-factors/screen-sizes writes canonical block" {
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "16.0,17.0" \
    --form-factors "phone,tablet" \
    --screen-sizes "390x844@3.0,1024x1366@2.0"
  [ "$status" -eq 0 ]
  json="$(_yaml_get)"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ios = d["ios"]
assert ios["os_versions"] == ["16.0","17.0"], ios["os_versions"]
assert ios["form_factors"] == ["phone","tablet"], ios["form_factors"]
ss = ios["screen_sizes"]
assert ss == [
  {"width":390,"height":844,"density":3.0},
  {"width":1024,"height":1366,"density":2.0}
], ss
'
}

# AC4 orphan rejection --------------------------------------------

@test "set ios rejected when ios not in platforms[]" {
  cat > "$CFG" <<'YAML'
project_root: /tmp/x
project_path: /tmp/x
memory_path: /tmp/x/_memory
checkpoint_path: /tmp/x/_memory/checkpoints
installed_path: /tmp/x
framework_version: 0.0.0
date: 2026-05-05

platforms:
  - android
YAML
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "16.0" --form-factors "phone" --screen-sizes "390x844@3.0"
  [ "$status" -eq 1 ]
}

# AC8 idempotent replace ------------------------------------------

@test "set ios twice replaces, never appends" {
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "16.0" --form-factors "phone" --screen-sizes "390x844@3.0"
  [ "$status" -eq 0 ]
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "17.0" --form-factors "tablet" --screen-sizes "1024x1366@2.0"
  [ "$status" -eq 0 ]
  json="$(_yaml_get)"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ios"]["os_versions"] == ["17.0"], d
assert d["ios"]["form_factors"] == ["tablet"], d
'
}

# show + clear ----------------------------------------------------

@test "show ios after set prints the os_versions" {
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "16.0,17.0" --form-factors "phone" --screen-sizes "390x844@3.0"
  [ "$status" -eq 0 ]
  run "$EDITOR" --config "$CFG" show ios
  [ "$status" -eq 0 ]
  [[ "$output" == *"16.0"* ]]
  [[ "$output" == *"17.0"* ]]
}

@test "clear ios removes the entry" {
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "16.0" --form-factors "phone" --screen-sizes "390x844@3.0"
  [ "$status" -eq 0 ]
  run "$EDITOR" --config "$CFG" clear ios
  [ "$status" -eq 0 ]
  json="$(_yaml_get)"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "ios" not in d, d
'
}

# Bad screen-size format ------------------------------------------

@test "malformed screen-size rejected" {
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "16.0" --form-factors "phone" --screen-sizes "garbage"
  [ "$status" -eq 1 ]
}
