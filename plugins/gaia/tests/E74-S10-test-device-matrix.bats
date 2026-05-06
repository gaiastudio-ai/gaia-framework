#!/usr/bin/env bats
# E74-S10-test-device-matrix.bats — covers AC2, AC3, AC4, AC7 for the
# `/gaia-test-device-matrix` action skill. The skill expands a configured
# device matrix (cartesian product of os_versions × form_factors × screen_sizes),
# dispatches each entry to the device-farm adapter, and aggregates per-device
# verdicts into a composite verdict.

bats_require_minimum_version 1.5.0

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
SKILL_DIR="$PLUGIN_ROOT/skills/gaia-test-device-matrix"
SKILL_MD="$SKILL_DIR/SKILL.md"
EXPAND="$SKILL_DIR/scripts/expand-matrix.sh"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
COMPOSITE="$PLUGIN_ROOT/scripts/composite-verdict.sh"
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

@test "AC7: gaia-test-device-matrix SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "AC7: SKILL.md declares runtime-profile: network" {
  grep -Eq '^runtime-profile:[[:space:]]+network[[:space:]]*$' "$SKILL_MD"
}

@test "AC7: SKILL.md registers /gaia-test-device-matrix trigger" {
  grep -Fq '/gaia-test-device-matrix' "$SKILL_MD"
}

@test "AC7: SKILL.md declares 'run device matrix' natural-language trigger" {
  grep -Eq 'run device matrix' "$SKILL_MD"
}

@test "AC7: SKILL.md declares argument-hint with --platform and --filter flags" {
  grep -Eq '^argument-hint:.*--platform' "$SKILL_MD"
  grep -Eq '^argument-hint:.*--filter' "$SKILL_MD"
}

# ---------------- AC2 — matrix expansion ---------------------------------

@test "AC2: expand-matrix expands 2 OS x 2 form-factors into 4 entries" {
  cat > "$TMPDIR_BATS/cfg.yaml" <<'YAML'
device_farm:
  adapter: firebase-test-lab
device_targets:
  os_versions: ["13", "14"]
  form_factors: ["phone", "tablet"]
  screen_sizes: ["default"]
YAML
  run bash "$EXPAND" --config "$TMPDIR_BATS/cfg.yaml"
  [ "$status" -eq 0 ]
  # Should produce a JSON array with exactly 4 entries.
  count="$(echo "$output" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"
  [ "$count" = "4" ]
}

@test "AC2: expand-matrix expands 3 x 2 x 2 into 12 entries" {
  cat > "$TMPDIR_BATS/cfg.yaml" <<'YAML'
device_farm:
  adapter: firebase-test-lab
device_targets:
  os_versions: ["12", "13", "14"]
  form_factors: ["phone", "tablet"]
  screen_sizes: ["small", "large"]
YAML
  run bash "$EXPAND" --config "$TMPDIR_BATS/cfg.yaml"
  [ "$status" -eq 0 ]
  count="$(echo "$output" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"
  [ "$count" = "12" ]
}

@test "AC2: expanded entries carry os_version, form_factor, screen_size" {
  cat > "$TMPDIR_BATS/cfg.yaml" <<'YAML'
device_farm:
  adapter: firebase-test-lab
device_targets:
  os_versions: ["14"]
  form_factors: ["phone"]
  screen_sizes: ["default"]
YAML
  run bash "$EXPAND" --config "$TMPDIR_BATS/cfg.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"os_version"[[:space:]]*:[[:space:]]*"14"'
  echo "$output" | grep -Eq '"form_factor"[[:space:]]*:[[:space:]]*"phone"'
  echo "$output" | grep -Eq '"screen_size"[[:space:]]*:[[:space:]]*"default"'
}

# ---------------- AC4 — composite verdict logic ---------------------------

@test "AC4: composite-verdict — all PASSED yields PASSED" {
  run bash "$COMPOSITE" --results "$FIXTURES/per-device-all-pass.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"PASSED"'
}

@test "AC4: composite-verdict — any FAILED yields FAILED" {
  run bash "$COMPOSITE" --results "$FIXTURES/per-device-one-fail.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"FAILED"'
}

@test "AC4: composite-verdict — ERROR with no FAILED yields ERROR" {
  run bash "$COMPOSITE" --results "$FIXTURES/per-device-one-error.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"ERROR"'
}

@test "AC4: composite-verdict — TIMEOUT with no FAILED/ERROR yields TIMEOUT" {
  run bash "$COMPOSITE" --results "$FIXTURES/per-device-one-timeout.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"TIMEOUT"'
}

@test "AC4: composite-verdict — FAILED dominates ERROR (priority)" {
  run bash "$COMPOSITE" --results "$FIXTURES/per-device-fail-and-error.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"FAILED"'
}

@test "AC4: composite-verdict emits summary counts" {
  run bash "$COMPOSITE" --results "$FIXTURES/per-device-mixed.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"passed_count"'
  echo "$output" | grep -Eq '"failed_count"'
  echo "$output" | grep -Eq '"error_count"'
  echo "$output" | grep -Eq '"timeout_count"'
}

# ---------------- AC3 — per-device structure carried through dispatch ----

@test "AC3: dispatch produces per_device_results entries with canonical schema" {
  GAIA_DEVICE_FARM_MOCK=1 \
  run bash "$DISPATCH" --config "$FIXTURES/project-config-device-matrix.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '"device_id"'
  echo "$output" | grep -Eq '"os_version"'
  echo "$output" | grep -Eq '"form_factor"'
  echo "$output" | grep -Eq '"verdict"'
  echo "$output" | grep -Eq '"duration_ms"'
}
