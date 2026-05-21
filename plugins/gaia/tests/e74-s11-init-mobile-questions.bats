#!/usr/bin/env bats
# e74-s11-init-mobile-questions.bats — E74-S11
#
# AC5: `/gaia-init` mobile questions produce a config with canonical
# platforms[] + device_targets blocks (os_versions, form_factors,
# screen_sizes). When user declines mobile, those keys are absent.

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
GENERATE="$PLUGIN_DIR/skills/gaia-init/scripts/generate-config.sh"

setup() { common_setup; }
teardown() { common_teardown; }

_run_with_bundle() {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj"
  printf '%s' "$1" | "$GENERATE" --path "$proj" --name "TestProj"
  printf '%s' "$proj/.gaia/config/project-config.yaml"
}

@test "mobile=yes path emits canonical device_targets shape" {
  bundle='{
    "project_shape":"mobile only",
    "stacks":[{"name":"ios","language":"swift","paths":["ios/**"]}],
    "platforms":["ios"],
    "device_targets":{
      "ios":{
        "os_versions":["16.0","17.0"],
        "form_factors":["phone","tablet"],
        "screen_sizes":[{"width":390,"height":844,"density":3.0}]
      }
    }
  }'
  cfg="$(_run_with_bundle "$bundle")"
  [ -f "$cfg" ]
  python3 - "$cfg" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d.get("platforms") == ["ios"], d.get("platforms")
ios = d["device_targets"]["ios"]
assert ios["os_versions"] == ["16.0","17.0"], ios
assert ios["form_factors"] == ["phone","tablet"], ios
ss = ios["screen_sizes"]
assert ss == [{"width":390,"height":844,"density":3.0}], ss
PY
}

@test "mobile=no path omits platforms and device_targets" {
  bundle='{
    "project_shape":"single backend",
    "stacks":[{"name":"api","language":"node","paths":["src/**"]}]
  }'
  cfg="$(_run_with_bundle "$bundle")"
  [ -f "$cfg" ]
  ! grep -qE '^platforms:' "$cfg"
  ! grep -qE '^device_targets:' "$cfg"
}

@test "backward-compat: legacy device_targets with list-of-strings still emits" {
  # E71-S1 era format.
  bundle='{
    "project_shape":"mobile only",
    "stacks":[{"name":"ios","language":"swift","paths":["ios/**"]}],
    "platforms":["ios"],
    "device_targets":{"ios":["iPhone 15"]}
  }'
  cfg="$(_run_with_bundle "$bundle")"
  [ -f "$cfg" ]
  grep -qE '^device_targets:' "$cfg"
}
