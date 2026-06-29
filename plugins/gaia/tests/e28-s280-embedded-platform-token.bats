#!/usr/bin/env bats
# embedded platform token (vocabulary precision for firmware projects).
#
# GAIA's platformId vocabulary (web/ios/android/server) had no token for
# embedded/firmware targets; such projects fell back to `server`. This adds a
# canonical `embedded` token to the schema enum, a trivially-satisfied
# `embedded)` arm in validate-platform-stack.sh stack_supports() (mirroring
# `server`), and a `firmware`→`embedded` write-side normalization (mirroring
# the `backend`→`server` alias).

load 'test_helper.bash'
setup() { common_setup; }
teardown() { common_teardown; }

PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."

@test "schema platformId enum includes embedded (AC1)" {
  grep -qF '"web", "ios", "android", "server", "embedded"' "$PLUGIN_ROOT/schemas/project-config.schema.json"
}

@test "validate-platform-stack.sh accepts 'embedded' platform (AC2)" {
  cfg="$TEST_TMP/cfg.yaml"
  cat >"$cfg" <<EOF
platforms:
  - embedded
stacks:
  - language: c
EOF
  run bash "$PLUGIN_ROOT/skills/gaia-init/scripts/validate-platform-stack.sh" "$cfg"
  [ "$status" -eq 0 ]
}

@test "validate-platform-stack.sh stack_supports has a dedicated embedded arm (AC2)" {
  # The arm also tolerates the `firmware` input alias (symmetry with backend).
  grep -qE '^[[:space:]]*embedded\|firmware\)[[:space:]]*return 0' "$PLUGIN_ROOT/skills/gaia-init/scripts/validate-platform-stack.sh"
}

@test "generate-config.sh normalizes firmware → embedded in platforms[] (AC3)" {
  cd "$TEST_TMP"
  python3 -c 'import json,sys; json.dump({"project_name":"esp","project_kind":"service","stacks":[{"name":"fw","language":"c","paths":["src/"]}],"ci_platform":{"provider":"github-actions"},"platforms":["firmware"]}, sys.stdout)' > bundle.json
  run bash "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh" --path . --name esp --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  [[ "$cfg" == *"- embedded"* ]]
  [[ "$cfg" != *"- firmware"* ]]
}

@test "generate-config.sh normalizes firmware → embedded in primary_platform (AC3)" {
  cd "$TEST_TMP"
  python3 -c 'import json,sys; json.dump({"project_name":"esp","project_kind":"service","stacks":[{"name":"fw","language":"c","paths":["src/"]}],"ci_platform":{"provider":"github-actions"},"platforms":["embedded"],"primary_platform":"firmware"}, sys.stdout)' > bundle.json
  run bash "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh" --path . --name esp --phase full < bundle.json
  [ "$status" -eq 0 ]
  grep -qE '^primary_platform: embedded$' .gaia/config/project-config.yaml
}

@test "embedded platform round-trips through generate-config (AC1)" {
  cd "$TEST_TMP"
  python3 -c 'import json,sys; json.dump({"project_name":"esp","project_kind":"service","stacks":[{"name":"fw","language":"c","paths":["src/"]}],"ci_platform":{"provider":"github-actions"},"platforms":["embedded"]}, sys.stdout)' > bundle.json
  run bash "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh" --path . --name esp --phase full < bundle.json
  [ "$status" -eq 0 ]
  grep -qE '^[[:space:]]*- embedded$' .gaia/config/project-config.yaml
}

@test "validate-platform-stack.sh accepts the 'firmware' alias (symmetry with backend)" {
  cfg="$TEST_TMP/cfg.yaml"
  cat >"$cfg" <<EOF
platforms:
  - firmware
stacks:
  - language: c
EOF
  run bash "$PLUGIN_ROOT/skills/gaia-init/scripts/validate-platform-stack.sh" "$cfg"
  [ "$status" -eq 0 ]
}

@test "backend → server alias still works — no regression (AC5)" {
  cd "$TEST_TMP"
  python3 -c 'import json,sys; json.dump({"project_name":"svc","project_kind":"service","stacks":[{"name":"b","language":"python","paths":["src/"]}],"ci_platform":{"provider":"github-actions"},"platforms":["backend"]}, sys.stdout)' > bundle.json
  run bash "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh" --path . --name svc --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  [[ "$cfg" == *"- server"* ]]
  [[ "$cfg" != *"- backend"* ]]
}
