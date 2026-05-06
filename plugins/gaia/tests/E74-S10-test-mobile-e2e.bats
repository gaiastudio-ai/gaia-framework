#!/usr/bin/env bats
# E74-S10-test-mobile-e2e.bats — covers AC1, AC3, AC5, AC6, AC7 for the
# `/gaia-test-mobile-e2e` action skill. The skill resolves a configured
# device-farm adapter from project-config.yaml and dispatches via
# dispatch-device-farm.sh (E74-S9), normalizing per-device results into the
# canonical AC3 schema and emitting a composite verdict.
#
# Composite verdict logic and matrix expansion are tested by the peer file
# E74-S10-test-device-matrix.bats.

bats_require_minimum_version 1.5.0

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
SKILL_DIR="$PLUGIN_ROOT/skills/gaia-test-mobile-e2e"
SKILL_MD="$SKILL_DIR/SKILL.md"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
SETUP="$SKILL_DIR/scripts/setup.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/E74-S10"

setup() {
  TMPDIR_BATS="$(mktemp -d)"
  export BROWSERSTACK_ACCESS_KEY="test-bs-key"
  export FIREBASE_TEST_LAB_TOKEN="test-fb-token"
}

teardown() {
  [ -n "${TMPDIR_BATS:-}" ] && rm -rf "$TMPDIR_BATS"
}

# ---------------- AC7 — SKILL.md registration -----------------------------

@test "AC7: gaia-test-mobile-e2e SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "AC7: SKILL.md declares runtime-profile: network" {
  grep -Eq '^runtime-profile:[[:space:]]+network[[:space:]]*$' "$SKILL_MD"
}

@test "AC7: SKILL.md registers /gaia-test-mobile-e2e trigger" {
  grep -Fq '/gaia-test-mobile-e2e' "$SKILL_MD"
}

@test "AC7: SKILL.md declares 'run mobile e2e' natural-language trigger" {
  grep -Eq 'run mobile e2e' "$SKILL_MD"
}

@test "AC7: SKILL.md declares argument-hint with --suite and --device flags" {
  grep -Eq '^argument-hint:.*--suite' "$SKILL_MD"
  grep -Eq '^argument-hint:.*--device' "$SKILL_MD"
}

# ---------------- AC1 — skill resolves and dispatches ---------------------

@test "AC1: dispatch.sh resolves Firebase adapter from config and dispatches" {
  GAIA_DEVICE_FARM_MOCK=1 \
  run bash "$DISPATCH" --config "$FIXTURES/project-config-device-farm-firebase.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"PASSED"'* ]] || [[ "$output" == *'"verdict": "PASSED"'* ]]
}

@test "AC1: dispatch.sh resolves BrowserStack adapter from config and dispatches" {
  GAIA_DEVICE_FARM_MOCK=1 \
  run bash "$DISPATCH" --config "$FIXTURES/project-config-device-farm-browserstack.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"adapter":[[:space:]]*"browserstack"'
}

# ---------------- AC3 — per-device verdict structure ----------------------

@test "AC3: per_device_results entries contain canonical schema fields" {
  GAIA_DEVICE_FARM_MOCK=1 \
  run bash "$DISPATCH" --config "$FIXTURES/project-config-device-farm-firebase.yaml"
  [ "$status" -eq 0 ]
  # Each device entry must have device_id, os_version, form_factor, verdict, duration_ms.
  echo "$output" | grep -Eq '"device_id"'
  echo "$output" | grep -Eq '"os_version"'
  echo "$output" | grep -Eq '"form_factor"'
  echo "$output" | grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"(PASSED|FAILED|ERROR|TIMEOUT)"'
  echo "$output" | grep -Eq '"duration_ms"'
}

# ---------------- AC5 — bridge-disabled enforcement -----------------------

@test "AC5: bridge_enabled=false yields verdict=SKIPPED with diagnostic" {
  run bash "$DISPATCH" --config "$FIXTURES/project-config-bridge-disabled.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"SKIPPED"'
  echo "$output" | grep -iEq 'bridge'
}

# ---------------- AC6 — missing adapter fails gracefully ------------------

@test "AC6: missing device_farm adapter yields verdict=ERROR with guidance" {
  run bash "$DISPATCH" --config "$FIXTURES/project-config-no-device-farm.yaml"
  [ "$status" -ne 0 ] || [ "$status" -eq 0 ]   # non-throwing path; either is acceptable
  echo "$output" | grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"ERROR"'
  echo "$output" | grep -iEq 'device-farm|gaia-config-device-target'
}

@test "AC6: dispatch.sh does not throw an unhandled exception on missing adapter" {
  run bash "$DISPATCH" --config "$FIXTURES/project-config-no-device-farm.yaml"
  # Exit codes must be deterministic — 0 (graceful) or any controlled non-zero
  # but never 127 (cmd not found) or 139 (segfault) or 134 (abort).
  [ "$status" -ne 127 ]
  [ "$status" -ne 139 ]
  [ "$status" -ne 134 ]
}

# ---------------- AC1 — setup.sh hook -------------------------------------

@test "AC1: setup.sh exists and is executable" {
  [ -x "$SETUP" ]
}
