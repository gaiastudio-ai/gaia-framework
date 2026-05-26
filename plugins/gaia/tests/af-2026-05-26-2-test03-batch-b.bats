#!/usr/bin/env bats
# AF-2026-05-26-2: Batch B — gaia-init schema-vs-questionnaire gaps (Test03).
#
# F-2:  generate-config.sh coerces list-form `environments` (empty → omit;
#       non-empty list → warn + omit) instead of crashing on .items().
# F-3:  full-phase web/fullstack shapes default platforms:[web] when none given
#       (gaia-init never emits config_phase=partial, so the gap is full-only).
# F-4:  full-phase seeds a minimal `environments.local` stub when none given,
#       so the generated config satisfies schema allOf[2].
# F-16: gaia-product-brief/scripts/setup.sh honours GAIA_SKIP_BRAINSTORM=1 to
#       bypass the pre_start brainstorm gate (with an audit warning).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GEN="$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  VALIDATE="$PLUGIN_ROOT/skills/gaia-init/scripts/validate-against-schema.sh"
}

teardown() { common_teardown; }

# --- F-2: list-form environments does not crash ---

@test "AF-26-2 F-2: empty list-form environments does not crash generate-config" {
  local out="$BATS_TEST_TMPDIR/p"
  mkdir -p "$out"
  run bash -c "echo '{\"project_name\":\"X\",\"project_shape\":\"web-app\",\"project_kind\":\"web-app\",\"environments\":[],\"stacks\":[{\"name\":\"b\",\"language\":\"python\",\"paths\":[\"b/\"]}]}' | bash '$GEN' --path '$out' --name X --phase full"
  [ "$status" -eq 0 ]
  [[ "$output" != *"AttributeError"* ]]
}

@test "AF-26-2 F-2: non-empty list-form environments warns and omits (no crash)" {
  local out="$BATS_TEST_TMPDIR/p"
  mkdir -p "$out"
  run bash -c "echo '{\"project_name\":\"X\",\"project_shape\":\"web-app\",\"project_kind\":\"web-app\",\"environments\":[\"prod\"],\"stacks\":[{\"name\":\"b\",\"language\":\"python\",\"paths\":[\"b/\"]}]}' | bash '$GEN' --path '$out' --name X --phase full"
  [ "$status" -eq 0 ]
  [[ "$output" == *"environments must be a mapping"* ]]
}

# --- F-3 + F-4: full-phase web-app gets defaults that validate ---

@test "AF-26-2 F-3+F-4: full-phase web-app with no platforms/environments validates against schema" {
  local out="$BATS_TEST_TMPDIR/p"
  mkdir -p "$out"
  echo '{"project_name":"X","project_shape":"web-app","project_kind":"web-app","stacks":[{"name":"backend","language":"python","paths":["backend/"]}]}' \
    | bash "$GEN" --path "$out" --name X --phase full 2>/dev/null
  local cfg="$out/.gaia/config/project-config.yaml"
  [ -f "$cfg" ]
  grep -qE '^platforms:' "$cfg"
  grep -qE '^  - web' "$cfg"
  grep -qE '^environments:' "$cfg"
  grep -qE '^  local:' "$cfg"
  if [ -f "$VALIDATE" ]; then
    run bash "$VALIDATE" "$cfg"
    [ "$status" -eq 0 ]
  fi
}

@test "AF-26-2 F-3: minimal phase does NOT inject platforms (default unchanged)" {
  local out="$BATS_TEST_TMPDIR/p"
  mkdir -p "$out"
  echo '{"project_name":"X","project_shape":"web-app","project_kind":"web-app"}' \
    | bash "$GEN" --path "$out" --name X --phase minimal 2>/dev/null
  local cfg="$out/.gaia/config/project-config.yaml"
  [ -f "$cfg" ]
  run grep -E '^platforms:' "$cfg"
  [ "$status" -ne 0 ]
}

# --- F-16: brainstorm-gate bypass ---

@test "AF-26-2 F-16: gaia-product-brief setup.sh exists under scripts/ (Val path correction)" {
  [ -f "$PLUGIN_ROOT/skills/gaia-product-brief/scripts/setup.sh" ]
}

@test "AF-26-2 F-16: GAIA_SKIP_BRAINSTORM bypass branch is present in setup.sh" {
  run grep -F 'GAIA_SKIP_BRAINSTORM' "$PLUGIN_ROOT/skills/gaia-product-brief/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-26-2 F-16: bypass emits an audit warning" {
  run grep -F 'bypassing pre_start brainstorm gate' "$PLUGIN_ROOT/skills/gaia-product-brief/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-26-2 F-16: SKILL.md documents the GAIA_SKIP_BRAINSTORM escape hatch" {
  run grep -F 'GAIA_SKIP_BRAINSTORM' "$PLUGIN_ROOT/skills/gaia-product-brief/SKILL.md"
  [ "$status" -eq 0 ]
}
