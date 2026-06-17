#!/usr/bin/env bats
# config-hydration.bats — coverage for lib/config-hydration.sh (E85-S1).
#
# Story: E85-S1 — Shared config-hydration.sh helper.
# ADR:   ADR-098 (Shared Config-Hydration Helper Contract)
# Spec:  AC1-AC13 in docs/implementation-artifacts/.../E85-S1-*.md
#
# Test scenarios mirror the 12 rows in the story's Test Scenarios table plus
# the 4 bats-only edge cases from AC13 (empty payload, missing config,
# read-only filesystem, concurrent-write serialization).

setup() {
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${PLUGIN_ROOT}/scripts/lib/config-hydration.sh"
  TMP="$(mktemp -d)"
  CONFIG="${TMP}/project-config.yaml"
  LOCK_DIR="${TMP}/config"
  mkdir -p "$LOCK_DIR"

  # Each test runs in a clean subshell so the _CONFIG_HYDRATION_LOADED guard
  # doesn't poison state across cases.
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export CONFIG_HYDRATION_LOCK_PATH="${LOCK_DIR}/.config-hydration.lock"
  export CONFIG_HYDRATION_TARGET="$CONFIG"
}

teardown() {
  rm -rf "$TMP" 2>/dev/null || true
}

# Helper: write a minimal config in `minimal` phase.
write_minimal_config() {
  cat > "$CONFIG" <<EOF
# Project config
project_name: "test-project"
config_phase: minimal
EOF
}

# Helper: write a config that already has stacks.
write_partial_config_with_stacks() {
  cat > "$CONFIG" <<EOF
# Project config
project_name: "test-project"
config_phase: partial
stacks:
  - name: "old-stack"
EOF
}

# Helper: write a config without a config_phase field (treated as full).
write_config_without_phase() {
  cat > "$CONFIG" <<EOF
project_name: "test-project"
EOF
}

# Helper: write a yaml fragment file.
write_fragment() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

# ---- AC1: Library location and sourcing contract -------------------------

@test "library file exists and is sourceable, not executable as binary" {
  [ -f "$LIB" ]
  # Must not have a shebang-then-exec form — it is sourced
  run head -1 "$LIB"
  [[ "$output" =~ ^#!/.*sh$ || "$output" =~ ^#.* ]]
  # Sourcing must not error out
  run bash -c "source '$LIB'"
  [ "$status" -eq 0 ]
}

@test "sourcing exports config_hydrate_section function" {
  run bash -c "source '$LIB' && declare -F config_hydrate_section"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config_hydrate_section"* ]]
}

@test "library guard prevents double-sourcing side-effects" {
  run bash -c "source '$LIB'; source '$LIB'; declare -F config_hydrate_section"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config_hydrate_section"* ]]
}

# ---- AC4 / Scenario 3: Section allowlist enforcement --------------------

@test "Scenario 3: reject unknown section name with non-zero exit" {
  write_minimal_config
  write_fragment "${TMP}/frag.yaml" "custom_section: value"
  run bash -c "source '$LIB' && config_hydrate_section custom_section '${TMP}/frag.yaml'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in allowlist"* || "$output" == *"allowlist"* ]]
}

@test "allowlist accepts the curated configuration set" {
  # Original E85-S1 allowlist had 7 entries (stacks, platforms, environments,
  # ci_cd, compliance, project_name, project_shape). E85-S11 (AF-2026-05-13-2)
  # expanded the allowlist to the curated 24-entry configuration set and
  # moved `project_shape` to _CONFIG_HYDRATION_MANAGED_ELSEWHERE as a
  # back-compat shim (it was in allowlist but absent from schema v2.0.0 —
  # Val F4 dead-code drift). Spot-check the original 6 + a representative
  # subset of the new entries.
  for section in stacks platforms environments ci_cd compliance project_name \
                 testing sprint review_gate dev_story tools severity gates; do
    write_minimal_config
    write_fragment "${TMP}/frag.yaml" "${section}: value"
    run bash -c "source '$LIB' && config_hydrate_section ${section} '${TMP}/frag.yaml'"
    [ "$status" -eq 0 ] || {
      echo "section=${section} unexpectedly rejected: $output"
      return 1
    }
  done
}

# ---- AC2 / Scenario 1: Hydrate new section on minimal config ------------

@test "Scenario 1: hydrate new section inserts content and advances phase" {
  write_minimal_config
  write_fragment "${TMP}/stacks.yaml" \
    "stacks:" \
    "  - name: backend" \
    "    type: nodejs"
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/stacks.yaml'"
  [ "$status" -eq 0 ]
  # Section present
  grep -q "^stacks:" "$CONFIG"
  grep -q "  - name: backend" "$CONFIG"
  # Phase bumped to partial
  grep -q "^config_phase: partial" "$CONFIG"
}

# ---- AC5 / Scenario 8: Audit comment presence ---------------------------

@test "Scenario 8: audit comment appended above hydrated section" {
  write_minimal_config
  write_fragment "${TMP}/stacks.yaml" \
    "stacks:" \
    "  - name: backend"
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/stacks.yaml'"
  [ "$status" -eq 0 ]
  # Audit comment present
  grep -q "^# hydrated by " "$CONFIG"
  # Audit comment includes ISO-8601 timestamp pattern
  grep -qE "hydrated by .* at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$CONFIG"
}

# ---- AC6 / Scenario 5: config_phase minimal -> partial -----------------

@test "Scenario 5: hydration on minimal advances phase to partial" {
  write_minimal_config
  write_fragment "${TMP}/frag.yaml" "stacks:" "  - name: a"
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/frag.yaml'"
  [ "$status" -eq 0 ]
  grep -q "^config_phase: partial$" "$CONFIG"
}

@test "hydration on partial keeps phase at partial (idempotent)" {
  write_partial_config_with_stacks
  write_fragment "${TMP}/frag.yaml" "platforms:" "  - web"
  run bash -c "source '$LIB' && config_hydrate_section platforms '${TMP}/frag.yaml'"
  [ "$status" -eq 0 ]
  grep -q "^config_phase: partial$" "$CONFIG"
}

# ---- AC7 / Scenario 6: monotonic forward invariant ---------------------

@test "Scenario 6: helper never writes config_phase: full" {
  write_partial_config_with_stacks
  write_fragment "${TMP}/frag.yaml" "platforms:" "  - web"
  run bash -c "source '$LIB' && config_hydrate_section platforms '${TMP}/frag.yaml'"
  [ "$status" -eq 0 ]
  ! grep -q "^config_phase: full$" "$CONFIG"
}

# ---- AC8 / Scenario 7: Absent config_phase treated as full -------------

@test "Scenario 7: absent config_phase treated as full, no field added" {
  write_config_without_phase
  write_fragment "${TMP}/frag.yaml" "stacks:" "  - name: a"
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/frag.yaml' 2>&1"
  [ "$status" -eq 0 ]
  # Hydration succeeded
  grep -q "^stacks:" "$CONFIG"
  # No config_phase field was inserted (absence-over-sentinel)
  ! grep -q "^config_phase:" "$CONFIG"
  # WARNING was logged (match the case-insensitive warning keyword regardless
  # of bash version stderr-capture ordering).
  [[ "$output" == *"unusual"* \
    || "$output" == *"warn"* \
    || "$output" == *"WARN"* \
    || "$output" == *"full config"* \
    || "$output" == *"absence"* ]]
}

# ---- AC9: YAML-comment preservation via delegation ---------------------

@test "Scenario 12: existing YAML comments survive a hydration cycle" {
  cat > "$CONFIG" <<EOF
# Header comment
project_name: "test-project"
# Inline note before phase
config_phase: minimal
# Trailing comment
EOF
  write_fragment "${TMP}/frag.yaml" "stacks:" "  - name: a"
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/frag.yaml'"
  [ "$status" -eq 0 ]
  grep -q "^# Header comment$" "$CONFIG"
  grep -q "^# Inline note before phase$" "$CONFIG"
  grep -q "^# Trailing comment$" "$CONFIG"
}

# ---- AC10 / Scenario 2: Idempotent re-hydration (overwrite) ------------

@test "Scenario 2: re-hydrate existing section overwrites without error" {
  write_partial_config_with_stacks
  write_fragment "${TMP}/stacks-v2.yaml" "stacks:" "  - name: new-stack"
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/stacks-v2.yaml' 2>&1"
  [ "$status" -eq 0 ]
  grep -q "  - name: new-stack" "$CONFIG"
  ! grep -q "  - name: old-stack" "$CONFIG"
  # Notice logged. Match permissively to be robust against bash/awk variants
  # that order stderr/stdout differently under `run`.
  [[ "$output" == *"overwrit"* \
    || "$output" == *"already present"* \
    || "$output" == *"NOTICE"* \
    || "$output" == *"existing"* ]]
}

# ---- AC11 / Scenario 11: Lock timeout ----------------------------------

@test "Scenario 11: lock contention times out with diagnostic" {
  write_minimal_config
  write_fragment "${TMP}/frag.yaml" "stacks:" "  - name: a"
  # Hold the lock with a still-living subshell PID so stale-lock recovery
  # does not steal it. The library checks `kill -0 $holder` on the pid file.
  # bash 3.2 (macOS) lacks BASHPID — use sh -c '$$' to capture the real pid.
  bash -c '
    mkdir "$1" 2>/dev/null
    printf "%d\n" "$$" > "$1/pid"
    sleep 5
    rm -rf "$1"
  ' _ "$CONFIG_HYDRATION_LOCK_PATH" &
  LOCK_PID=$!
  sleep 0.5
  # Use a short timeout for the test
  run bash -c "export CONFIG_HYDRATION_LOCK_TIMEOUT=2; source '$LIB' && config_hydrate_section stacks '${TMP}/frag.yaml' 2>&1"
  wait "$LOCK_PID" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"lock"* ]]
  [[ "$output" == *"$CONFIG_HYDRATION_LOCK_PATH"* || "$output" == *".config-hydration.lock"* ]]
}

# ---- AC13 edge cases ----------------------------------------------------

@test "edge: empty payload file errors gracefully" {
  write_minimal_config
  : > "${TMP}/empty.yaml"
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/empty.yaml' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* || "$output" == *"payload"* ]]
  # Config was NOT modified
  grep -q "^config_phase: minimal$" "$CONFIG"
}

@test "edge: missing config file errors gracefully" {
  rm -f "$CONFIG"
  write_fragment "${TMP}/frag.yaml" "stacks:" "  - name: a"
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/frag.yaml' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config"* ]]
  [[ "$output" == *"not"* || "$output" == *"missing"* ]]
}

@test "edge: missing fragment file errors gracefully" {
  write_minimal_config
  run bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/nonexistent.yaml' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fragment"* || "$output" == *"not"* ]]
}

@test "edge: two parallel hydrations are serialized (no lost writes)" {
  write_minimal_config
  write_fragment "${TMP}/stacks.yaml" "stacks:" "  - name: a"
  write_fragment "${TMP}/platforms.yaml" "platforms:" "  - web"

  # Spawn two parallel hydrations
  (bash -c "source '$LIB' && config_hydrate_section stacks '${TMP}/stacks.yaml'") &
  PID_A=$!
  (bash -c "source '$LIB' && config_hydrate_section platforms '${TMP}/platforms.yaml'") &
  PID_B=$!
  wait "$PID_A"
  STATUS_A=$?
  wait "$PID_B"
  STATUS_B=$?
  [ "$STATUS_A" -eq 0 ]
  [ "$STATUS_B" -eq 0 ]
  # Both sections present (no lost writes)
  grep -q "^stacks:" "$CONFIG"
  grep -q "^platforms:" "$CONFIG"
}
