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
  # AF-2026-05-17-7: after `clear`, device_targets is a bare block-style empty
  # section (parses as None), not inline-flow {}. Normalize to {} for callers.
  python3 -c "
import sys, yaml
d = yaml.safe_load(open('$CFG')) or {}
import json
dt = d.get('device_targets')
print(json.dumps(dt if dt is not None else {}))
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

# AF-2026-05-17-7 — clear writes bare 'device_targets:' (block-style empty
# section), NOT inline-flow 'device_targets: {}'. Round-trips to the
# reconciler-hydrated baseline shape so trailing comments stay anchored as
# child-position comments of the empty mapping.

@test "AF-2026-05-17-7: clear writes bare device_targets: (no inline-flow {})" {
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "16.0" --form-factors "phone" --screen-sizes "390x844@3.0"
  [ "$status" -eq 0 ]
  run "$EDITOR" --config "$CFG" clear ios
  [ "$status" -eq 0 ]
  # Must NOT contain inline-flow empty mapping
  run grep -F 'device_targets: {}' "$CFG"
  [ "$status" -ne 0 ]
  # Must contain bare block-style section header
  run grep -E '^device_targets:[[:space:]]*$' "$CFG"
  [ "$status" -eq 0 ]
}

@test "AF-2026-05-17-7: post-clear YAML is well-formed and device_targets resolves to empty mapping" {
  run "$EDITOR" --config "$CFG" set ios \
    --os-versions "16.0" --form-factors "phone" --screen-sizes "390x844@3.0"
  [ "$status" -eq 0 ]
  run "$EDITOR" --config "$CFG" clear ios
  [ "$status" -eq 0 ]
  # python3 yaml.safe_load must succeed; device_targets must be None or empty dict
  run python3 -c "import yaml,sys; d=yaml.safe_load(open('$CFG')); v=d.get('device_targets'); sys.exit(0 if v is None or v == {} else 1)"
  [ "$status" -eq 0 ]
}
