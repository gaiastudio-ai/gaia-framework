#!/usr/bin/env bats
# derive-design-scope.bats — path classifier for design-scope derivation.
#
# Tests the derive-design-scope.sh helper that classifies changed spec paths
# into design-system, product-design, or both.
#
# Public functions covered: (script entry point, not a library)

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------

fail() { printf '%s\n' "$1" >&2; return 1; }

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCOPE_SCRIPT="$PLUGIN_ROOT/scripts/derive-design-scope.sh"
}

teardown() { common_teardown; }

# ===========================================================================
# Path classification tests
# ===========================================================================

@test "tokens path classifies as design-system" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT" "tokens/colors.html"
  [ "$status" -eq 0 ]
  [ "$output" = "design-system" ] || fail "expected design-system, got: $output"
}

@test "dotslash screens path classifies as product-design" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT" "./screens/login.spec.html"
  [ "$status" -eq 0 ]
  [ "$output" = "product-design" ] || fail "expected product-design, got: $output"
}

@test "absolute path under spec root classifies correctly" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  local spec_root="$TEST_TMP/spec"
  mkdir -p "$spec_root/components"

  run bash "$SCOPE_SCRIPT" --spec-root "$spec_root" "$spec_root/components/button.spec.html"
  [ "$status" -eq 0 ]
  [ "$output" = "design-system" ] || fail "expected design-system, got: $output"
}

@test "mixed paths classify as both" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT" "tokens/a.html" "screens/b.html"
  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both, got: $output"
}

@test "unclassified path maps to both" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT" "README.md"
  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both, got: $output"
}

@test "no arguments maps to both" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both, got: $output"
}

@test "templates path classifies as design-system" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT" "templates/header.html"
  [ "$status" -eq 0 ]
  [ "$output" = "design-system" ] || fail "expected design-system, got: $output"
}

@test "flows path classifies as product-design" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT" "flows/checkout.spec.html"
  [ "$status" -eq 0 ]
  [ "$output" = "product-design" ] || fail "expected product-design, got: $output"
}

# ===========================================================================
# Path with .. segments treated as unclassified
# ===========================================================================

@test "dotdot path treated as unclassified" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT" "screens/../tokens/colors.html"
  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (.. is unclassified), got: $output"
}

@test "flag without value exits 2" {
  [ -f "$SCOPE_SCRIPT" ] || fail "derive-design-scope.sh not found at $SCOPE_SCRIPT"

  run bash "$SCOPE_SCRIPT" --spec-root
  [ "$status" -eq 2 ] || fail "expected exit 2 for flag without value, got: $status"
}
